#!/usr/bin/env bash
# Run as root on the SSM-managed host with Docker Compose, AWS CLI, curl and Python 3.
# A single VM has no HA or automatic scaling; persist database and certificates in volumes.
set -Eeuo pipefail
umask 077
if (( $# != 6 )); then
  echo 'usage: deploy.sh <env> <sha> <ecr-repository-url> <host-url> <host-ip> <domains>' >&2
  exit 2
fi
environment=$1
new_tag=$2
registry=$3
host_url=${4%/}
host_ip=$5
domains=$6
if [[ ! $environment =~ ^[a-z][a-z0-9_-]*$ || ! $new_tag =~ ^[0-9a-f]{40}$ || ! $registry =~ ^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-zA-Z0-9_./-]+$ || ! $host_url =~ ^https?://[^/[:space:]]+$ || ! $host_ip =~ ^[0-9.]+$ ]]; then
  echo 'invalid deployment arguments' >&2
  exit 2
fi
cd /opt/app
compose=(docker compose --env-file .release.env -f docker-compose.prod.yml)
previous_tag=''
previous_registry=''
if [[ -f .release.env ]]; then
  previous_tag=$(sed -n 's/^IMAGE_TAG=//p' .release.env)
  previous_registry=$(sed -n 's/^DA_ECR_REPOSITORY_URL=//p' .release.env)
fi
# Retain the last image/tag, configuration and env files until the new proxy is healthy.
backup=$(mktemp -d /opt/app/.rollback.XXXXXXXX)
for file in .release.env web.env api.env db.env deploy/nginx/active.conf; do
  if [[ -f $file ]]; then
    mkdir -p "$backup/$(dirname "$file")"
    cp -p "$file" "$backup/$file"
  fi
done
changed=false
rollback() {
  local status=$?
  trap - ERR EXIT
  if (( status == 0 )); then
    rm -rf "$backup"
    return
  fi
  echo "deployment failed (exit $status); restoring prior release" >&2
  for file in .release.env web.env api.env db.env deploy/nginx/active.conf; do
    if [[ -f $backup/$file ]]; then
      cp -p "$backup/$file" "$file"
    fi
  done
  if [[ $changed == true && -n $previous_tag && -n $previous_registry ]]; then
    "${compose[@]}" up -d --remove-orphans >&2 || true
    "${compose[@]}" exec -T proxy nginx -s reload >&2 || true
  else
    echo 'no previous release to restore; manual recovery may be needed' >&2
  fi
  rm -rf "$backup"
  exit "$status"
}
trap rollback ERR EXIT
# Never print decrypted SSM values or put them on a command line.
python3 - "$environment" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

env = sys.argv[1]
required = {
    'web': set(),
    'api': {'DB_HOST', 'DB_NAME', 'DB_PASSWORD', 'DB_USER'},
    'db': {'MYSQL_DATABASE', 'MYSQL_PASSWORD', 'MYSQL_RANDOM_ROOT_PASSWORD', 'MYSQL_USER'},
}
for service, keys in required.items():
    path = f'/notes-app-f308/{env}/{service}/'
    output = subprocess.check_output([
        'aws', 'ssm', 'get-parameters-by-path', '--with-decryption',
        '--path', path, '--output', 'json',
    ])
    values = {}
    for parameter in json.loads(output)['Parameters']:
        name = parameter['Name']
        key = name.rsplit('/', 1)[-1]
        if name != path + key or key not in keys or key in values:
            raise SystemExit(f'unexpected SSM parameter for {service}')
        value = parameter['Value']
        if '\n' in value or '\r' in value or '\x00' in value:
            raise SystemExit(f'invalid SSM parameter value for {service}')
        values[key] = value
    if set(values) != keys or any(not values[key] for key in keys):
        raise SystemExit(f'missing required SSM parameters for {service}')
    temporary = Path(f'{service}.env.tmp')
    fd = os.open(temporary, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as file:
        for key in sorted(values):
            file.write(f'{key}={values[key]}\n')
    os.chmod(temporary, 0o600)
    os.replace(temporary, Path(f'{service}.env'))
PY
printf 'DA_ECR_REPOSITORY_URL=%s\nIMAGE_TAG=%s\n' "$registry" "$new_tag" > .release.env
chmod 600 .release.env
changed=true
"${compose[@]}" pull web api db proxy certbot
# nginx templates are platform-managed; select only on the host at deploy time.
cp deploy/nginx/http.conf deploy/nginx/active.conf
cert_exists() {
  "${compose[@]}" run --rm --no-deps --entrypoint /bin/sh certbot -c 'test -f /etc/letsencrypt/live/app/fullchain.pem && test -f /etc/letsencrypt/live/app/privkey.pem' >/dev/null
}
if [[ -n $domains ]] && ! cert_exists; then
  domain_list=()
  domains=${domains//,/ }
  for domain in $domains; do
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
      echo "invalid site domain: $domain" >&2
      exit 1
    fi
    if ! getent ahostsv4 "$domain" | awk '{print $1}' | grep -Fxq "$host_ip"; then
      echo "domain $domain does not resolve to expected host IP ($host_ip) yet; configure DNS before requesting a certificate" >&2
      exit 1
    fi
    domain_list+=(-d "$domain")
  done
  "${compose[@]}" up -d --no-deps proxy
  "${compose[@]}" run --rm --no-deps --entrypoint certbot certbot certonly --webroot -w /var/www/certbot --cert-name app "${domain_list[@]}" --agree-tos --register-unsafely-without-email --non-interactive
fi
if cert_exists; then cp deploy/nginx/https.conf deploy/nginx/active.conf; fi
"${compose[@]}" up -d --remove-orphans
"${compose[@]}" exec -T proxy nginx -s reload
# Test the public proxy, never an unpublished container port.
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 "$host_url/healthz" >/dev/null 2>&1; then
    echo "release $new_tag ready through proxy"
    exit 0
  fi
  if (( attempt < 30 )); then sleep 5; fi
done
echo "proxy health endpoint failed: $host_url/healthz" >&2
exit 1
