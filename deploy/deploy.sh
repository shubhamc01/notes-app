#!/usr/bin/env bash
# Executed by SSM as root on the EC2 host. Requires Docker Compose >= 2.30
# (raw env_file support), AWS CLI, curl, getent, and the instance's scoped IAM
# profile. No repository checkout or workflow-supplied secrets are required.
set -euo pipefail
umask 077

if [[ $# -ne 6 ]]; then
  echo 'Usage: deploy.sh <env> <40-character SHA> <ECR URL> <host URL> <host IP> <domains>' >&2
  exit 2
fi
environment=$1
image_tag=$2
repository=$3
host_url=$4
host_ip=$5
domains=$6
[[ "$environment" =~ ^[a-z0-9-]+$ && "$image_tag" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Invalid environment or image tag' >&2; exit 2;
}
[[ "$repository" =~ ^[a-zA-Z0-9.-]+/[a-zA-Z0-9_./-]+$ ]] || {
  echo 'Invalid ECR repository URL' >&2; exit 2;
}
[[ "$host_url" =~ ^https?://[^/]+/?$ ]] || {
  echo 'Invalid host URL' >&2; exit 2;
}
cd /opt/app
compose=(docker compose -f docker-compose.prod.yml)
for conf in deploy/nginx/http.conf deploy/nginx/https.conf; do
  [[ -f "$conf" ]] || { echo "Missing platform-managed $conf" >&2; exit 1; }
done
# The bundle contains neither nginx config nor secrets. SSM fetched below is
# the sole source of application credentials. Snapshots stay on this host.
snapshot=$(mktemp -d /opt/app/.rollback.XXXXXXXX)
previous=0
if [[ -f .env && -f docker-compose.prod.rollback.yml ]]; then
  previous=1
  cp -p .env "$snapshot/.env"
  cp -p docker-compose.prod.rollback.yml "$snapshot/docker-compose.prod.yml"
  for service in proxy certbot web api db; do
    [[ ! -f "${service}.env" ]] || cp -p "${service}.env" "$snapshot/${service}.env"
  done
  [[ ! -f deploy/nginx/active.conf ]] || cp -p deploy/nginx/active.conf "$snapshot/active.conf"
fi
finished=0
rollback() {
  result=$?
  trap - EXIT
  if (( result != 0 && finished == 0 )); then
    echo "Deployment ${image_tag} failed; attempting rollback" >&2
    if (( previous == 1 )); then
      cp -p "$snapshot/.env" .env
      cp -p "$snapshot/docker-compose.prod.yml" docker-compose.prod.yml
      for service in proxy certbot web api db; do
        if [[ -f "$snapshot/${service}.env" ]]; then
          cp -p "$snapshot/${service}.env" "${service}.env"
        else
          rm -f "${service}.env"
        fi
      done
      if [[ -f "$snapshot/active.conf" ]]; then
        cp -p "$snapshot/active.conf" deploy/nginx/active.conf
      fi
      if "${compose[@]}" up -d && "${compose[@]}" exec -T proxy nginx -s reload &&
         curl --fail --silent --show-error --max-time 15 "${host_url%/}/healthz" >/dev/null; then
        echo 'Previous image and configuration restored and healthy' >&2
      else
        echo 'CRITICAL: rollback did not pass its health check; manual repair required' >&2
      fi
    else
      echo 'First deployment has no previous image to restore; manual repair required' >&2
    fi
  fi
  rm -rf -- "$snapshot"
  exit "$result"
}
trap rollback EXIT

# Use a temporary file, never log decrypted values; Compose raw env_file keeps
# $, quotes, and # literal. Reject newline-containing values (not env-file safe).
write_service_env() {
  local service=$1 json_file=$snapshot/ssm.json
  aws ssm get-parameters-by-path --with-decryption \
    --path "/notes-app-f308/${environment}/${service}/" --output json > "$json_file"
  python3 - "$service" "$json_file" "${service}.env" <<'PY'
import json
import os
import sys

service, source, destination = sys.argv[1:]
required = {
    'web': set(),
    'api': {'DB_HOST', 'DB_NAME', 'DB_PASSWORD', 'DB_USER'},
    'db': {'MYSQL_DATABASE', 'MYSQL_PASSWORD', 'MYSQL_RANDOM_ROOT_PASSWORD', 'MYSQL_USER'},
}[service]
with open(source, encoding='utf-8') as stream:
    values = json.load(stream)['Parameters']
found = {}
for parameter in values:
    key = parameter['Name'].rsplit('/', 1)[-1]
    if key not in required or key in found:
        raise SystemExit('Unexpected or duplicate SSM parameter for ' + service)
    value = parameter['Value']
    if '\n' in value or '\r' in value or '\x00' in value:
        raise SystemExit('SSM parameter is not env-file safe: ' + key)
    found[key] = value
if found.keys() != required:
    raise SystemExit('Missing required SSM parameters for ' + service)
temporary = destination + '.new'
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w', encoding='utf-8') as output:
    for key in sorted(found):
        output.write(key + '=' + found[key] + '\n')
os.replace(temporary, destination)
os.chmod(destination, 0o600)
PY
  rm -f "$json_file"
}
for service in web api db; do
  write_service_env "$service"
done
# These infrastructure containers have no application parameters in SSM.
for service in proxy certbot; do
  : > "${service}.env"
  chmod 600 "${service}.env"
done
printf 'DA_ECR_REPOSITORY_URL=%s\nIMAGE_TAG=%s\n' "$repository" "$image_tag" > .env.new
chmod 600 .env.new
mv -f .env.new .env

# Keep the old images locally: neither pull nor up removes previous tags.
"${compose[@]}" pull web api db proxy certbot
cp -f deploy/nginx/http.conf deploy/nginx/active.conf
chmod 644 deploy/nginx/active.conf

# Named volumes persist certificates across redeploys. Inspect the shared
# letsencrypt volume from inside the certbot container, not the host's /etc.
certificate_exists() {
  "${compose[@]}" run --rm --no-deps --entrypoint /bin/sh certbot \
    -c 'test -f /etc/letsencrypt/live/app/fullchain.pem' >/dev/null 2>&1
}
if [[ -n "${domains//[[:space:],]/}" ]] && ! certificate_exists; then
  cert_args=()
  read -r -a domain_list <<< "${domains//,/ }"
  for domain in "${domain_list[@]}"; do
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo 'Invalid site domain' >&2; exit 1; }
    addresses=$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u || true)
    if [[ -z "$addresses" ]] || [[ "$(printf '%s\n' "$addresses" | grep -Fxc "$host_ip" || true)" == 0 ]] ||
       [[ "$(printf '%s\n' "$addresses" | wc -l)" -ne 1 ]]; then
      echo "Domain $domain does not resolve exclusively to ${host_ip} yet; update DNS before requesting a certificate" >&2
      exit 1
    fi
    cert_args+=(-d "$domain")
  done
  # HTTP-only proxy exposes the ACME challenge through the platform nginx
  # config. Only the proxy publishes host ports.
  "${compose[@]}" up -d proxy
  "${compose[@]}" run --rm --no-deps --entrypoint certbot certbot \
    certonly --webroot -w /var/www/certbot --cert-name app \
    "${cert_args[@]}" --agree-tos --register-unsafely-without-email --non-interactive
fi
if certificate_exists; then
  cp -f deploy/nginx/https.conf deploy/nginx/active.conf
  chmod 644 deploy/nginx/active.conf
fi
"${compose[@]}" up -d
"${compose[@]}" exec -T proxy nginx -s reload
# Test the externally routed endpoint, not a container's loopback. Allow for
# startup and proxy routing convergence; on failure restore the prior revision.
for (( attempt=0; attempt<30; attempt++ )); do
  if curl --fail --silent --show-error --max-time 10 "${host_url%/}/healthz" >/dev/null 2>&1; then
    finished=1
    echo "Healthy deployment: ${image_tag}"
    exit 0
  fi
  sleep 5
done
echo "Health check failed through ${host_url%/}/healthz" >&2
exit 1
