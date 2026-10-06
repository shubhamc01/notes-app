#!/usr/bin/env bash
# ENGINE-RENDERED by devops-agent (knowledge/delivery) — do not edit; regenerate instead.
# Runs in CI: sends ONE command to the host through SSM Run Command — fetch release $SHA, run its
# deploy/deploy.sh with exactly the values below — waits, and prints the host's output either way.
set -euo pipefail
: "${INSTANCE:?}" "${AWS_REGION:?}" "${SHA:?}" "${DEPLOY_ENV:?}"
: "${REGISTRY:?}"

params=$(python3 - <<'PY'
import json, os, shlex

# the values the host's deploy script reads — the same names on both sides, by construction
names = ["DEPLOY_ENV", "SHA", "AWS_REGION", "DOMAINS", "REGISTRY"]
env = " ".join(f"{n}={shlex.quote(os.environ.get(n, ''))}" for n in names)
sha, region = os.environ["SHA"], os.environ["AWS_REGION"]
registry = os.environ["REGISTRY"]
bundle = shlex.quote(f"{registry}:bundle-{sha}")
fetch = (f"aws ecr get-login-password --region {shlex.quote(region)} | docker login --username AWS "
         f"--password-stdin {shlex.quote(registry.split('/')[0])} >/dev/null; "
         f'docker pull -q {bundle} >/dev/null; app="${{APP_DIR:-/opt/app}}"; mkdir -p "$app"; rm -rf "$app/deploy"; '
         f'id=$(docker create {bundle} noop); docker cp "$id:/app/." "$app/"; docker rm "$id" >/dev/null; '
         'cd "$app"; ')
print(json.dumps({"commands": [f"set -eu; {fetch}{env} bash ./deploy/deploy.sh"], "executionTimeout": ["1800"]}))
PY
)

command_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript --comment "deploy ${SHA:0:12} to $DEPLOY_ENV" \
  --parameters "$params" --query Command.CommandId --output text)

status=Pending
for _ in $(seq 1 240); do
  sleep 10
  status=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$command_id" \
    --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Pending|InProgress|Delayed) continue ;; *) break ;; esac
done

show() {
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$command_id" \
    --instance-id "$INSTANCE" --query "$1" --output text | tail -n 80
}
echo "----- host output -----"; show StandardOutputContent || true
if [ "$status" != Success ]; then
  echo "----- host errors -----" >&2; show StandardErrorContent >&2 || true
  echo "deploy to $DEPLOY_ENV failed on the host: $status" >&2
  exit 1
fi
echo "deployed ${SHA:0:12} to $DEPLOY_ENV"
