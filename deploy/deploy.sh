#!/usr/bin/env bash
# Run on the SSM-managed EC2 host, not in GitHub Actions. The GitHub deploy
# role only sends/checks SSM commands; it does not read application secrets.
# The EC2 instance profile must separately allow ssm:GetParametersByPath with
# decryption for /notes-app-f308/dev/* and ECR pull access. This single-VM
# deployment has no HA, and scaling requires manual intervention.
set -Eeuo pipefail
umask 077
cd /opt/app
: "${ENVIRONMENT:?}" "${IMAGE_TAG:?}" "${DA_ECR_REPOSITORY_URL:?}" "${AWS_REGION:?}"
[[ "$ENVIRONMENT" == dev && "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Only the bound dev environment and a 40-character commit SHA are supported.' >&2
  exit 1
}
: "${DA_HOST_IP_DEV:?}" "${DA_HOST_URL_DEV:?}"
export IMAGE_TAG DA_ECR_REPOSITORY_URL

compose() { docker compose -f docker-compose.prod.yml "$@"; }

# Force host-side AWS calls to use the EC2 instance profile, never credentials
# forwarded from CI or a local AWS credentials/config file. In particular,
# GetParametersByPath is NOT an action granted to the GitHub deploy role.
host_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    -u AWS_SECURITY_TOKEN -u AWS_PROFILE -u AWS_ROLE_ARN \
    -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
    -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null \
    AWS_EC2_METADATA_DISABLED=false aws "$@"
}

previous_tag=''
[[ ! -f .current-image-tag ]] || previous_tag=$(<.current-image-tag)
backup=$(mktemp -d)
for file in web.env api.env db.env deploy/nginx/active.conf; do
  if [[ -f "$file" ]]; then
    mkdir -p "$backup/$(dirname "$file")"
    cp -p "$file" "$backup/$file"
  fi
done
committed=0
rollback() {
  local status=$?
  trap - EXIT
  if (( committed == 0 )); then
    echo 'Deployment failed; restoring the previous configuration and image.' >&2
    for file in web.env api.env db.env deploy/nginx/active.conf; do
      if [[ -f "$backup/$file" ]]; then cp -p "$backup/$file" "$file"; else rm -f "$file"; fi
    done
    if [[ -n "$previous_tag" ]]; then
      IMAGE_TAG=$previous_tag compose up -d --remove-orphans || echo 'ROLLBACK FAILED: compose up' >&2
      IMAGE_TAG=$previous_tag compose exec -T proxy nginx -s reload || echo 'ROLLBACK FAILED: nginx reload' >&2
    else
      echo 'No previously healthy image tag exists; manual recovery required.' >&2
    fi
  fi
  rm -rf "$backup"
  exit "$status"
}
trap rollback EXIT
mkdir -p deploy/nginx

write_env() {
  local service=$1 expected=$2 response
  # Paginated by the AWS CLI using only the host instance profile. Never
  # include decrypted values in SSM command parameters, logs, or CI output.
  response=$(host_aws ssm get-parameters-by-path --region "$AWS_REGION" \
    --path "/notes-app-f308/$ENVIRONMENT/$service/" --with-decryption --output json)
  python3 -c '
import json, os, sys, tempfile
service, expected, environment = sys.argv[1:]
required = set(expected.split())
path = f"/notes-app-f308/{environment}/{service}/"
params = json.load(sys.stdin)["Parameters"]
found = {}
for param in params:
    name = param["Name"]
    key = name.removeprefix(path)
    value = param["Value"]
    if not name.startswith(path) or key not in required or key in found or "\n" in value or "\r" in value:
        sys.exit(f"Invalid SSM parameter for {service}")
    found[key] = value
if set(found) != required:
    sys.exit(f"Missing or unexpected SSM parameters for {service}")
fd, temp = tempfile.mkstemp(prefix=f".{service}.env.", dir=".")
try:
    with os.fdopen(fd, "w") as out:
        for key in sorted(found):
            value = found[key].replace("\\", "\\\\").replace("\u0027", "\\\u0027")
            out.write(f"{key}=\u0027{value}\u0027\n")
    os.chmod(temp, 0o600)
    os.replace(temp, f"{service}.env")
finally:
    if os.path.exists(temp):
        os.unlink(temp)
' "$service" "$expected" "$ENVIRONMENT" <<< "$response"
}
write_env web ''
write_env api 'DB_HOST DB_NAME DB_PASSWORD DB_USER'
write_env db 'MYSQL_DATABASE MYSQL_PASSWORD MYSQL_RANDOM_ROOT_PASSWORD MYSQL_USER'

# Database and certificate state must remain in persistent Docker volumes;
# neither deployment nor rollback removes them.
cp deploy/nginx/http.conf deploy/nginx/active.conf
certificate_exists() {
  compose run --rm --no-deps --entrypoint /bin/sh certbot \
    -c 'test -d /etc/letsencrypt/live/app' >/dev/null 2>&1
}
compose pull api web
if [[ -n "${DA_SITE_DOMAINS_DEV:-}" ]] && ! certificate_exists; then
  domains=()
  for domain in $DA_SITE_DOMAINS_DEV; do
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo 'Invalid site domain' >&2; exit 1; }
    if ! getent ahostsv4 "$domain" | awk '{print $1}' | grep -Fxq "$DA_HOST_IP_DEV"; then
      echo "DNS for $domain does not resolve to $DA_HOST_IP_DEV yet; stopping before certificate issuance." >&2
      exit 1
    fi
    domains+=(-d "$domain")
  done
  # Start HTTP upstreams before the ACME webroot challenge reaches the proxy.
  compose up -d db api web proxy
  compose run --rm --no-deps --entrypoint certbot certbot certonly \
    --webroot -w /var/www/certbot --cert-name app "${domains[@]}" \
    --agree-tos --register-unsafely-without-email --non-interactive
fi
if certificate_exists; then cp deploy/nginx/https.conf deploy/nginx/active.conf; fi
compose up -d --remove-orphans
compose exec -T proxy nginx -s reload

# The proxy must forward /api/healthz to the API's /healthz.
url="${DA_HOST_URL_DEV%/}/api/healthz"
ready=0
for (( attempt=0; attempt<30; attempt++ )); do
  if curl --fail --silent --show-error --max-time 5 --output /dev/null "$url"; then
    ready=1
    break
  fi
  sleep 5
done
if (( ready != 1 )); then echo "Proxy health check failed at $url" >&2; exit 1; fi
printf '%s\n' "$IMAGE_TAG" > .current-image-tag
chmod 600 .current-image-tag
committed=1
echo "Deployment $IMAGE_TAG healthy through proxy."
