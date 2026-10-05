#!/usr/bin/env bash
set -Eeuo pipefail

# Runs on the EC2 host after the deployment bundle is unpacked to /opt/app.
# A single VM is a single point of failure; scaling is manual, and this layout
# does not provide HA. Persist required container state in volumes/external stores.
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <environment> <immutable-image-uri>" >&2
  exit 2
fi
DEPLOY_ENV="$1"
APP_IMAGE="$2"
case "$DEPLOY_ENV" in
  *[!a-zA-Z0-9_-]*|'') echo "Invalid deployment environment" >&2; exit 2 ;;
  dev) ;;
  *) echo "Unsupported deployment environment: $DEPLOY_ENV" >&2; exit 2 ;;
esac
[[ -n "$APP_IMAGE" ]] || { echo "Image URI is required" >&2; exit 2; }

# These are the infrastructure bindings supplied to the host deployment command.
: "${DA_AWS_REGION:?DA_AWS_REGION is required}"
: "${DA_HOST_IP_DEV:?DA_HOST_IP_DEV is required}"
: "${DA_HOST_URL_DEV:?DA_HOST_URL_DEV is required}"
AWS_REGION="$DA_AWS_REGION"
HOST_IP="$DA_HOST_IP_DEV"
HOST_URL="$DA_HOST_URL_DEV"
SITE_DOMAINS="${DA_SITE_DOMAINS_DEV:-}"

ROOT=/opt/app
STATE_FILE="$ROOT/.current-image"
mkdir -p "$ROOT/deploy/nginx"
cd "$ROOT"

# Pull only the permitted keys from each service's SSM path. An empty
# allow-list (web) still creates a protected, empty env file for Compose.
write_service_env() {
  local service="$1"
  shift
  local path="/notes-app-f308/${DEPLOY_ENV}/${service}/"
  local tmp
  tmp=$(mktemp "$ROOT/.${service}.env.XXXXXX")
  PARAM_PATH="$path" ALLOWED_KEYS="$*" OUT_FILE="$tmp" AWS_REGION="$AWS_REGION" python3 - <<'PY'
import json
import os
import subprocess

path = os.environ["PARAM_PATH"]
allowed = set(os.environ["ALLOWED_KEYS"].split())
out = os.environ["OUT_FILE"]
raw = subprocess.check_output([
    "aws", "ssm", "get-parameters-by-path", "--with-decryption",
    "--recursive", "--path", path, "--region", os.environ["AWS_REGION"],
    "--output", "json",
], text=True)
parameters = json.loads(raw).get("Parameters", [])
values = {}
for parameter in parameters:
    key = parameter["Name"].rstrip("/").split("/")[-1]
    if key not in allowed:
        continue
    value = parameter["Value"]
    if "\n" in value or "\r" in value or "\x00" in value:
        raise SystemExit(f"Invalid multiline SSM value for {key}")
    values[key] = value
missing = allowed - values.keys()
if missing:
    raise SystemExit("Missing required SSM parameters: " + ", ".join(sorted(missing)))
with open(out, "w", encoding="utf-8") as stream:
    for key in sorted(values):
        # JSON quoting gives Compose a valid double-quoted dotenv value.
        stream.write(f"{key}={json.dumps(values[key], ensure_ascii=False)}\n")
os.chmod(out, 0o600)
PY
  chmod 600 "$tmp"
  mv -f "$tmp" "$ROOT/${service}.env"
}

write_service_env web
write_service_env api DB_HOST DB_NAME DB_PASSWORD DB_USER
write_service_env db MYSQL_DATABASE MYSQL_PASSWORD MYSQL_RANDOM_ROOT_PASSWORD MYSQL_USER
chmod 600 web.env api.env db.env

# Use plain HTTP for ACME validation before enabling TLS.
cp deploy/nginx/http.conf deploy/nginx/active.conf

compose() {
  APP_IMAGE="$1" docker compose -f docker-compose.prod.yml "${@:2}"
}

if [[ -n "$SITE_DOMAINS" && ! -d /etc/letsencrypt/live/app ]]; then
  compose "$APP_IMAGE" up -d proxy
  domain_args=()
  for domain in ${SITE_DOMAINS//,/ }; do
    resolved="$(getent ahostsv4 "$domain" | awk 'NR==1 {print $1}')"
    if [[ -z "$resolved" || "$resolved" != "$HOST_IP" ]]; then
      echo "Cannot issue TLS certificate: $domain must resolve to $HOST_IP before deployment (currently ${resolved:-unresolved})." >&2
      exit 1
    fi
    domain_args+=( -d "$domain" )
  done
  docker compose -f docker-compose.prod.yml run --rm \
    --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
    --cert-name app "${domain_args[@]}" --agree-tos \
    --register-unsafely-without-email --non-interactive
fi

if [[ -d /etc/letsencrypt/live/app ]]; then
  cp deploy/nginx/https.conf deploy/nginx/active.conf
else
  cp deploy/nginx/http.conf deploy/nginx/active.conf
fi

previous=""
if [[ -s "$STATE_FILE" ]]; then
  previous="$(cat "$STATE_FILE")"
fi

health_check() {
  local base_url="${1%/}"
  local attempt=1
  while [[ "$attempt" -le 30 ]]; do
    if curl --fail --silent --show-error --max-time 5 \
      "${base_url}/healthz" >/dev/null; then
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

rollback() {
  if [[ -z "$previous" ]]; then
    echo "No previous image is recorded; automatic rollback is unavailable on first deployment." >&2
    return 1
  fi
  echo "Rolling back to $previous" >&2
  compose "$previous" up -d || return 1
  compose "$previous" exec -T proxy nginx -s reload || return 1
  if ! health_check "$HOST_URL"; then
    echo "Rollback completed, but the previous deployment also failed its health check." >&2
    return 1
  fi
}

# Keep the recorded image unchanged until the candidate passes proxy health checks.
docker pull "$APP_IMAGE"
if ! compose "$APP_IMAGE" up -d; then
  echo "Compose failed for $APP_IMAGE" >&2
  rollback || true
  exit 1
fi
if ! compose "$APP_IMAGE" exec -T proxy nginx -s reload; then
  echo "Nginx reload failed; attempting rollback." >&2
  rollback || true
  exit 1
fi
if ! health_check "$HOST_URL"; then
  echo "Health check failed through proxy at ${HOST_URL%/}/healthz; attempting rollback." >&2
  rollback || true
  exit 1
fi

printf '%s\n' "$APP_IMAGE" > "$STATE_FILE.tmp"
chmod 600 "$STATE_FILE.tmp"
mv -f "$STATE_FILE.tmp" "$STATE_FILE"
echo "Deployment healthy: $APP_IMAGE"
