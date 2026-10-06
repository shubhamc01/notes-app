#!/usr/bin/env bash
# ENGINE-RENDERED by devops-agent (knowledge/delivery) — do not edit; regenerate instead.
# Runs ON THE HOST (root, via SSM) from /opt/app after the bundle of release $SHA was unpacked.
set -Eeuo pipefail
: "${DEPLOY_ENV:?}" "${SHA:?}" "${AWS_REGION:?}" "${REGISTRY:?}"
DOMAINS="${DOMAINS:-}"
cd "${APP_DIR:-/opt/app}"
export REGISTRY IMAGE_TAG="$SHA"
compose() { docker compose -f docker-compose.prod.yml "$@"; }
previous="$(cat .release 2>/dev/null || true)"

rollback() {
  local code=$?
  trap - ERR
  echo "release ${SHA:0:12} failed (exit $code)" >&2
  if [ -n "$previous" ] && [ "$previous" != "$SHA" ]; then
    echo "rolling back to ${previous:0:12}" >&2
    IMAGE_TAG="$previous" compose up -d --remove-orphans --wait --wait-timeout 300 || echo "rollback failed too" >&2
  else
    echo "no earlier release on this host to roll back to" >&2
  fi
  exit "$code"
}
trap rollback ERR

# 1. config: one env file per service, from SSM (and the managed database), mode 600
python3 - "$PWD" <<'PY'
import json, os, subprocess, sys, urllib.parse

# Config values from SSM (/<app>/<env>/<service>/<KEY>), plus a managed database's endpoint and
# credentials (its Secrets Manager secret) for the keys the platform provides. Nothing is guessed:
# a key the app reads that has no value stops the deploy with the exact list to set.
env, region = os.environ["DEPLOY_ENV"], os.environ["AWS_REGION"]
services = json.loads("{\"web\": [], \"api\": [\"DB_HOST\", \"DB_NAME\", \"DB_PASSWORD\", \"DB_USER\"], \"db\": [\"MYSQL_DATABASE\", \"MYSQL_PASSWORD\", \"MYSQL_RANDOM_ROOT_PASSWORD\", \"MYSQL_USER\"]}")   # service -> the keys its code reads
provides = json.loads("{}")   # service -> {kind: [keys]} filled from the managed database
db = json.loads("null")               # {"name", "scheme", "port"} of the managed database, or None
dest = sys.argv[1]                   # where the <service>.env files go


def aws(*args):
    return json.loads(subprocess.run(["aws", *args, "--region", region, "--output", "json"],
                                     check=True, capture_output=True, text=True).stdout or "null")


managed = {}
if db and os.environ.get("DB_SECRET_ARN"):
    secret = json.loads(aws("secretsmanager", "get-secret-value", "--secret-id", os.environ["DB_SECRET_ARN"],
                            "--query", "SecretString"))
    user, password = secret["username"], secret["password"]
    host = os.environ["DB_ENDPOINT"]
    managed = {"host": host, "port": str(db["port"]), "username": user, "password": password, "name": db["name"],
               "url": f"{db['scheme']}://{urllib.parse.quote(user, safe='')}:{urllib.parse.quote(password, safe='')}"
                      f"@{host}:{db['port']}/{db['name']}"}

missing = []
for service, keys in services.items():
    stored = aws("ssm", "get-parameters-by-path", "--recursive", "--with-decryption",
                 "--path", f"/notes-app-f308/{env}/{service}/", "--query", "Parameters[].[Name,Value]") or []
    values = {name.rsplit("/", 1)[1]: value for name, value in stored}
    for kind, kind_keys in (provides.get(service) or {}).items():
        for key in kind_keys:
            if kind in managed:
                values[key] = managed[kind]
    missing += [f"{service}/{key}" for key in keys if key not in values]
    lines = []
    for key in sorted(values):
        value = values[key]
        if "\n" in value or "\r" in value:
            sys.exit(f"{service}/{key}: multi-line values are not supported in env files")
        # single quotes = literal in compose env files and systemd EnvironmentFile alike
        lines.append(f"{key}='{value}'" if "'" not in value else
                     key + '="' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"')
    path = os.path.join(dest, f"{service}.env")
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(path + ".tmp", path)
if missing:
    sys.exit("missing config values (set them with `devops-agent apply`): " + ", ".join(missing))

PY

# 2. registry login, pull every image of this release
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${REGISTRY%%/*}" >/dev/null
compose pull --quiet

# 3. proxy config: plain HTTP until a certificate exists for the domain(s)
cp deploy/nginx/http.conf deploy/nginx/active.conf
if [ -n "$DOMAINS" ] && ! compose run --rm --no-deps --entrypoint test certbot -d /etc/letsencrypt/live/app; then
  compose up -d --no-deps proxy
  args=()
  for d in ${DOMAINS//,/ }; do args+=(-d "$d"); done
  compose run --rm --no-deps --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
    --cert-name app "${args[@]}" --agree-tos --register-unsafely-without-email --non-interactive
fi
if [ -n "$DOMAINS" ]; then cp deploy/nginx/https.conf deploy/nginx/active.conf; fi

# 4. start: --wait = every service with a healthcheck (datastores, images that declare one) is healthy
compose up -d --remove-orphans --wait --wait-timeout 300
compose exec -T proxy nginx -s reload

# 5. every route answers through the proxy (an upstream that is down = 0/502/503/504)
down=" 0 502 503 504 "
probe() {
  local path="$1" host="$2" code=000
  for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${host:+-H "Host: $host"} "http://127.0.0.1$path" || true)
    case "$down" in *" $((10#$code)) "*) sleep 5 ;; *) echo "route $path answers ($code)"; return 0 ;; esac
  done
  echo "route $path is not served (last answer $code)" >&2
  return 1
}
probe "/" ""
probe "/api" ""

echo "$SHA" > .release
trap - ERR
echo "release ${SHA:0:12} is live on $DEPLOY_ENV"
