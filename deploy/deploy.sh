#!/usr/bin/env bash
# Run as root on the managed EC2 host. Requires aws, docker compose, python3 and curl.
# The platform supplies deploy/nginx/http.conf and https.conf; persistent DB and TLS
# state must live on Docker volumes or external stores, never in a container layer.
set -Eeuo pipefail
umask 077
cd /opt/app
: "${DEPLOY_ENV:?}" "${DA_AWS_REGION:?}" "${DA_ECR_REPOSITORY_URL:?}" "${IMAGE_TAG:?}" "${DA_HOST_URL_DEV:?}" "${DA_HOST_IP_DEV:?}"
[[ "$DEPLOY_ENV" == dev && "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid deployment environment or SHA' >&2; exit 1; }
compose() { docker compose -f docker-compose.prod.yml "$@"; }
work=$(mktemp -d /opt/app/.deploy-backup.XXXXXXXX)
previous=0
if [[ -f .env ]]; then
  previous=1
  cp -p .env "$work/.env"
  for service in web api db; do
    [[ ! -f "$service.env" ]] || cp -p "$service.env" "$work/$service.env"
  done
  [[ ! -f deploy/nginx/active.conf ]] || cp -p deploy/nginx/active.conf "$work/active.conf"
fi
rollback() {
  local status=$?
  trap - ERR
  echo "Deployment failed (exit $status); restoring previous image and configuration" >&2
  if (( previous )); then
    cp -p "$work/.env" .env
    for service in web api db; do
      if [[ -f "$work/$service.env" ]]; then cp -p "$work/$service.env" "$service.env"; fi
    done
    if [[ -f "$work/active.conf" ]]; then cp -p "$work/active.conf" deploy/nginx/active.conf; fi
    if ! compose up -d --force-recreate || ! compose exec -T proxy nginx -s reload; then
      echo 'ROLLBACK FAILED: operator intervention required' >&2
    fi
  else
    echo 'No previous deployment exists to roll back to' >&2
  fi
  rm -rf "$work"
  exit "$status"
}
trap rollback ERR
# Never log decrypted values. Validate names and refuse missing, duplicate or unsafe values.
for service in web api db; do
  case "$service" in
    web) expected='' ;;
    api) expected='DB_HOST DB_NAME DB_PASSWORD DB_USER' ;;
    db) expected='MYSQL_DATABASE MYSQL_PASSWORD MYSQL_RANDOM_ROOT_PASSWORD MYSQL_USER' ;;
  esac
  tmp=$(mktemp "/opt/app/.$service.env.XXXXXXXX")
  if [[ -n "$expected" ]]; then
    aws ssm get-parameters-by-path --region "$DA_AWS_REGION" --with-decryption --recursive \
      --path "/notes-app-f308/$DEPLOY_ENV/$service/" --output json |
      python3 -c '
import json, os, sys
service, expected = sys.argv[1], set(sys.argv[2].split())
prefix = f"/notes-app-f308/{os.environ[\"DEPLOY_ENV\"]}/{service}/"
parameters = json.load(sys.stdin)["Parameters"]
found = {}
for param in parameters:
    name = param["Name"]
    key = name[len(prefix):] if name.startswith(prefix) else ""
    value = param["Value"]
    if key not in expected or key in found or any(c in value for c in "\n\r\x00"):
        raise SystemExit("Invalid SSM parameter set for " + service)
    found[key] = value
if set(found) != expected:
    raise SystemExit("Missing SSM parameters for " + service)
for key in sorted(found):
    value = found[key].replace("\\", "\\\\").replace("\u0027", "\\\u0027")
    print(f"{key}=\u0027{value}\u0027")
' "$service" "$expected" > "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$service.env"
done
printf 'DA_ECR_REPOSITORY_URL=%s\nIMAGE_TAG=%s\n' "$DA_ECR_REPOSITORY_URL" "$IMAGE_TAG" > "$work/new.env"
chmod 600 "$work/new.env"
mv -f "$work/new.env" .env
compose pull web api db
# These templates are platform-owned; only active.conf is managed by this script.
cp deploy/nginx/http.conf deploy/nginx/active.conf
if [[ -n "${DA_SITE_DOMAINS_DEV:-}" ]]; then
  # The certbot service mounts the same persistent letsencrypt volume as the proxy.
  if ! compose run --rm --no-deps --entrypoint /bin/sh certbot -c 'test -d /etc/letsencrypt/live/app'; then
    # Check public DNS before attempting ACME; each domain must resolve to this VM.
    python3 - "$DA_HOST_IP_DEV" "$DA_SITE_DOMAINS_DEV" <<'PY'
import socket, sys
ip, names = sys.argv[1:]
for domain in names.replace(',', ' ').split():
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(domain, 80, family=socket.AF_INET)}
    except socket.gaierror:
        addresses = set()
    if ip not in addresses:
        raise SystemExit(f"Domain {domain} does not resolve to {ip} yet; configure DNS and retry")
PY
    compose up -d proxy
    read -r -a domains <<< "${DA_SITE_DOMAINS_DEV//,/ }"
    args=()
    for domain in "${domains[@]}"; do args+=(-d "$domain"); done
    compose run --rm --no-deps --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
      --cert-name app "${args[@]}" --agree-tos --register-unsafely-without-email --non-interactive
  fi
  cp deploy/nginx/https.conf deploy/nginx/active.conf
fi
compose up -d
compose exec -T proxy nginx -s reload
# Verify the routed endpoint, not just a container process; curl fails on 4xx/5xx.
ready=0
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 "${DA_HOST_URL_DEV%/}/healthz" >/dev/null; then
    ready=1
    break
  fi
  echo "Waiting for proxy health endpoint ($attempt/30)" >&2
  sleep 5
done
(( ready )) || { echo 'Proxy health endpoint did not become ready' >&2; false; }
trap - ERR
rm -rf "$work"
echo "Deployed $IMAGE_TAG; proxy health check passed"
