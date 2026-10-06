#!/usr/bin/env bash
# Runs on the EC2 host through SSM. The instance profile must be restricted to
# this environment's SSM subtree and ECR image pulls; no repository checkout is needed.
# This single EC2 host is a single point of failure and scaling is manual. Persist
# database state in a Docker volume or external store so a redeploy cannot erase it.
set -Eeuo pipefail
umask 077

: "${DEPLOY_ENV:?DEPLOY_ENV is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${DA_AWS_REGION:?DA_AWS_REGION is required}"
: "${DA_ECR_REPOSITORY_URL:?DA_ECR_REPOSITORY_URL is required}"

# Only dev infrastructure bindings are present in the deployment specification.
# Do not synthesize other DA_* names: add explicit bindings before enabling another
# environment on this host.
if [[ "$DEPLOY_ENV" != "dev" ]]; then
  echo "Unsupported deployment environment: $DEPLOY_ENV (only the bound dev environment is configured)." >&2
  exit 2
fi
: "${DA_HOST_URL_DEV:?DA_HOST_URL_DEV is required}"
: "${DA_HOST_IP_DEV:?DA_HOST_IP_DEV is required}"
: "${DA_SITE_DOMAINS_DEV:?DA_SITE_DOMAINS_DEV is required}"

host_url="$DA_HOST_URL_DEV"
host_ip="$DA_HOST_IP_DEV"
site_domains="$DA_SITE_DOMAINS_DEV"

cd /opt/app
mkdir -p deploy/nginx
chmod 700 /opt/app

old_tag=""
if [[ -s .image-tag ]]; then
  old_tag="$(cat .image-tag)"
fi

# Back up only host configuration needed to restore the previous deployment.
backup_dir="$(mktemp -d /opt/app/.deploy-backup.XXXXXX)"
chmod 700 "$backup_dir"
for file in web.env api.env db.env deploy/nginx/active.conf; do
  if [[ -f "$file" ]]; then
    mkdir -p "$backup_dir/$(dirname "$file")"
    cp -p "$file" "$backup_dir/$file"
  fi
done

deployment_started=1
rollback() {
  local status=$?
  trap - ERR
  if (( deployment_started )); then
    echo "Deployment failed; attempting rollback." >&2
    for file in web.env api.env db.env deploy/nginx/active.conf; do
      if [[ -f "$backup_dir/$file" ]]; then
        cp -p "$backup_dir/$file" "$file"
      elif [[ "$file" == deploy/nginx/active.conf && -f deploy/nginx/http.conf ]]; then
        cp deploy/nginx/http.conf deploy/nginx/active.conf
      fi
    done
    if [[ -n "$old_tag" ]]; then
      if docker pull "${DA_ECR_REPOSITORY_URL}:${old_tag}"; then
        IMAGE_TAG="$old_tag" docker compose -f docker-compose.prod.yml up -d || true
        docker compose -f docker-compose.prod.yml exec -T proxy nginx -s reload || true
        if ! curl --fail --silent --show-error --max-time 10 "${host_url%/}/healthz"; then
          echo "Rollback was attempted but the health endpoint remains unavailable." >&2
        fi
      else
        echo "Could not pull the previous image tag; automatic rollback was not possible." >&2
      fi
    else
      echo "No prior image tag exists; there is no application version to restore." >&2
    fi
  fi
  rm -rf "$backup_dir"
  exit "$status"
}
trap rollback ERR

# Read only documented keys from this environment's parameter subtree. Values
# are written to mode-600 service env files and are never printed to logs.
write_service_env() {
  local service="$1"
  local allowed="$2"
  local parameter_path="/notes-app-f308/${DEPLOY_ENV}/${service}/"
  local json_file
  local output_tmp
  json_file="$(mktemp)"
  output_tmp="${service}.env.tmp"
  if ! aws ssm get-parameters-by-path \
    --region "$DA_AWS_REGION" \
    --with-decryption \
    --path "$parameter_path" \
    --output json > "$json_file"; then
    rm -f "$json_file" "$output_tmp"
    return 1
  fi

  SERVICE="$service" ALLOWED_KEYS="$allowed" ENV_PATH="$output_tmp" \
    python3 - "$json_file" <<'PY'
import json
import os
import sys

source, = sys.argv[1:]
service = os.environ["SERVICE"]
allowed = set(filter(None, os.environ["ALLOWED_KEYS"].split(",")))
with open(source, encoding="utf-8") as handle:
    parameters = json.load(handle).get("Parameters", [])
values = {}
for item in parameters:
    key = item["Name"].rstrip("/").split("/")[-1]
    if key in allowed:
        values[key] = item["Value"]
required = {
    "api": {"DB_HOST", "DB_NAME", "DB_PASSWORD", "DB_USER"},
    "db": {"MYSQL_DATABASE", "MYSQL_PASSWORD", "MYSQL_RANDOM_ROOT_PASSWORD", "MYSQL_USER"},
    "web": set(),
}[service]
missing = required - values.keys()
if missing:
    raise SystemExit(
        f"Missing required SSM parameters for {service}: {', '.join(sorted(missing))}"
    )
# Compose dotenv single-quoted values support escaped quotes, slashes, and newlines.
with open(os.environ["ENV_PATH"], "w", encoding="utf-8") as output:
    for key in sorted(values):
        value = values[key].replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")
        output.write(f"{key}='{value}'\n")
os.chmod(os.environ["ENV_PATH"], 0o600)
PY
  rm -f "$json_file"
  chmod 600 "$output_tmp"
  mv -f "$output_tmp" "${service}.env"
}

write_service_env web ""
write_service_env api "DB_HOST,DB_NAME,DB_PASSWORD,DB_USER"
write_service_env db "MYSQL_DATABASE,MYSQL_PASSWORD,MYSQL_RANDOM_ROOT_PASSWORD,MYSQL_USER"

# HTTP remains active while the first certificate is issued. nginx/ files are
# platform-provided; this script selects the supplied HTTP or HTTPS config only.
cp deploy/nginx/http.conf deploy/nginx/active.conf
if [[ -n "$site_domains" ]]; then
  read -r -a domains <<< "$site_domains"
  if (( ${#domains[@]} > 0 )); then
    # The proxy serves ACME challenges before certbot attempts issuance.
    docker compose -f docker-compose.prod.yml up -d proxy certbot
    certificate_exists=0
    if docker compose -f docker-compose.prod.yml exec -T certbot \
      sh -c 'test -f /etc/letsencrypt/live/app/fullchain.pem' >/dev/null 2>&1; then
      certificate_exists=1
    fi

    if (( ! certificate_exists )); then
      for domain in "${domains[@]}"; do
        resolved="$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u || true)"
        if ! grep -Fxq "$host_ip" <<< "$resolved"; then
          echo "Certificate not requested: $domain does not resolve to the configured dev host IP yet. Update DNS and rerun deployment." >&2
          exit 1
        fi
      done

      certbot_args=(certbot certonly --webroot -w /var/www/certbot --cert-name app)
      for domain in "${domains[@]}"; do
        certbot_args+=(-d "$domain")
      done
      certbot_args+=(--agree-tos --register-unsafely-without-email --non-interactive)
      docker compose -f docker-compose.prod.yml exec -T certbot "${certbot_args[@]}"
    fi
    cp deploy/nginx/https.conf deploy/nginx/active.conf
  fi
fi

# Pull and activate the immutable SHA-tagged image while retaining the previous
# tag in .image-tag so a failed health check can restore the prior release.
docker pull "${DA_ECR_REPOSITORY_URL}:${IMAGE_TAG}"
IMAGE_TAG="$IMAGE_TAG" docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml exec -T proxy nginx -s reload

healthy=0
for ((check = 0; check < 30; check++)); do
  if curl --fail --silent --show-error --max-time 5 "${host_url%/}/healthz" >/dev/null; then
    healthy=1
    break
  fi
  sleep 5
done
if (( ! healthy )); then
  echo "Health check failed through proxy at ${host_url%/}/healthz" >&2
  false
fi

printf '%s\n' "$IMAGE_TAG" > .image-tag.tmp
chmod 600 .image-tag.tmp
mv -f .image-tag.tmp .image-tag
deployment_started=0
rm -rf "$backup_dir"
trap - ERR
echo "Deployment succeeded: ${DA_ECR_REPOSITORY_URL}:${IMAGE_TAG}"
