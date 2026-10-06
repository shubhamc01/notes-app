#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd /opt/app
: "${DEPLOY_ENV:?}" "${IMAGE_TAG:?}" "${DA_ECR_REPOSITORY_URL:?}" "${DA_HOST_URL_DEV:?}" "${DA_HOST_IP_DEV:?}"
[[ "$DEPLOY_ENV" == dev && "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid deployment identifier' >&2; exit 1; }
export IMAGE_TAG DA_ECR_REPOSITORY_URL
compose() { docker compose -f docker-compose.prod.yml "$@"; }
mkdir -p /etc/letsencrypt deploy/nginx
[[ -f deploy/nginx/http.conf && -f deploy/nginx/https.conf ]] || { echo 'Platform nginx configuration missing' >&2; exit 1; }
# The host and its named database volume are a single failure domain. Scaling requires a new architecture.
previous=''
[[ ! -f .image-tag ]] || previous=$(cat .image-tag)
backup=$(mktemp -d)
for f in api.env db.env web.env deploy/nginx/active.conf; do
  [[ ! -f "$f" ]] || { mkdir -p "$backup/$(dirname "$f")"; cp -p "$f" "$backup/$f"; }
done
rollback() {
  code=$?
  trap - ERR
  echo "Deployment failed (exit $code); restoring previous release" >&2
  if [[ -n "$previous" ]]; then
    for f in api.env db.env web.env deploy/nginx/active.conf; do
      [[ ! -f "$backup/$f" ]] || cp -p "$backup/$f" "$f"
    done
    IMAGE_TAG=$previous
    export IMAGE_TAG
    compose up -d --wait --wait-timeout 300 || echo 'Rollback also failed; operator intervention required' >&2
    compose exec -T proxy nginx -s reload || true
  else
    echo 'No previous release exists; manual recovery required' >&2
  fi
  rm -rf "$backup"
  exit "$code"
}
trap rollback ERR
# Fetch from the instance profile, never from the CI environment or image layers.
python3 - "$DEPLOY_ENV" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys

env = sys.argv[1]
for service, required in {
    'web': set(),
    'api': {'DB_HOST', 'DB_NAME', 'DB_PASSWORD', 'DB_USER'},
    'db': {'MYSQL_DATABASE', 'MYSQL_PASSWORD', 'MYSQL_RANDOM_ROOT_PASSWORD', 'MYSQL_USER'},
}.items():
    prefix = f'/notes-app-f308/{env}/{service}/'
    args = ['aws', 'ssm', 'get-parameters-by-path', '--with-decryption', '--recursive', '--path', prefix, '--output', 'json']
    values = {}
    token = None
    while True:
        cmd = args + (['--next-token', token] if token else [])
        result = json.loads(subprocess.check_output(cmd, stderr=subprocess.DEVNULL))
        for parameter in result.get('Parameters', []):
            name = parameter['Name']
            key = name[len(prefix):]
            if not name.startswith(prefix) or '/' in key or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key):
                raise SystemExit('Unexpected parameter name')
            if key not in required or key in values:
                raise SystemExit('Unexpected or duplicate parameter for ' + service)
            value = parameter['Value']
            if '\n' in value or '\r' in value or '\x00' in value:
                raise SystemExit('Multiline environment value not supported')
            values[key] = value
        token = result.get('NextToken')
        if not token:
            break
    if values.keys() != required:
        raise SystemExit('Missing required parameters for ' + service)
    dest = pathlib.Path('/opt/app') / (service + '.env')
    temp = dest.with_suffix('.env.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, 'w') as output:
            for key in sorted(values):
                output.write(key + '=' + values[key] + '\n')
        os.replace(temp, dest)
    finally:
        temp.unlink(missing_ok=True)
PY
chmod 600 web.env api.env db.env
cp deploy/nginx/http.conf deploy/nginx/active.conf
compose pull web api db proxy certbot
if [[ -n "${DA_SITE_DOMAINS_DEV:-}" && ! -d /etc/letsencrypt/live/app ]]; then
  # Validate DNS before requesting a certificate; names must already point at this VM.
  mapfile -t domains < <(printf '%s' "$DA_SITE_DOMAINS_DEV" | tr ', ' '\n\n' | sed '/^$/d')
  [[ ${#domains[@]} -gt 0 ]] || { echo 'No usable site domains' >&2; false; }
  for domain in "${domains[@]}"; do
    if ! python3 - "$domain" "$DA_HOST_IP_DEV" <<'PY'
import socket
import sys
try:
    addresses = {item[4][0] for item in socket.getaddrinfo(sys.argv[1], None)}
    sys.exit(0 if sys.argv[2] in addresses else 1)
except socket.gaierror:
    sys.exit(1)
PY
    then
      echo 'Domain does not resolve to DA_HOST_IP_DEV yet; configure DNS before deploying' >&2
      false
    fi
  done
  compose up -d proxy
  args=()
  for domain in "${domains[@]}"; do args+=(-d "$domain"); done
  compose run --rm --no-deps --entrypoint certbot certbot certonly --webroot -w /var/www/certbot --cert-name app "${args[@]}" --agree-tos --register-unsafely-without-email --non-interactive
fi
if [[ -d /etc/letsencrypt/live/app ]]; then
  cp deploy/nginx/https.conf deploy/nginx/active.conf
elif [[ -n "${DA_SITE_DOMAINS_DEV:-}" ]]; then
  echo 'Certificate issuance failed' >&2
  false
fi
# --wait checks every routed service locally; the last request checks the actual proxy path.
compose up -d --wait --wait-timeout 300
compose exec -T proxy nginx -s reload
status=$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "${DA_HOST_URL_DEV%/}/")
if (( 10#$status >= 500 || 10#$status < 100 )); then echo 'Proxy returned an unhealthy response' >&2; false; fi
printf '%s\n' "$IMAGE_TAG" > .image-tag
rm -rf "$backup"
trap - ERR
echo 'Deployment healthy'
