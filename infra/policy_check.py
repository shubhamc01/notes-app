# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
"""Plan-output policy (infra-arch §8.2), standard library only. The engine copies this file
verbatim to infra/policy_check.py with its data in infra/policy.json, so a CI apply runs the
same check as the CLI:  python3 infra/policy_check.py infra/<env> plan.json  (exit 1 = blocked).

policy.json: {"privileged_types": [regex], "files": {path: sha256},
              "roots": {"infra/<x>": {"engine_addresses": [full address], "prod": bool, "boundary": arn|null}}}"""

import hashlib
import json
import re
import sys
from pathlib import Path

_INDEX = re.compile(r"\[[^\]]*\]")
_SECURITY = re.compile(r"^(aws_security_group.*|aws_vpc_security_group_.*|aws_network_acl.*|"
                       r"aws_default_security_group|aws_default_network_acl)$")


def tampered(policy: dict, repo: Path) -> list[str]:
    """Engine files edited since they were rendered: their addresses are no longer trusted."""
    out = []
    for rel, sha in sorted((policy.get("files") or {}).items()):
        p = repo / rel
        if p.exists() and hashlib.sha256(p.read_bytes()).hexdigest() != sha:
            out.append(f"{rel}: engine file changed since it was rendered — regenerate instead of editing")
    return out


def violations(plan_json: dict, policy: dict, root: str) -> list[str]:
    meta = (policy.get("roots") or {}).get(root)
    if meta is None:
        return [f"{root}: not an engine-rendered root in policy.json"]
    engine = set(meta.get("engine_addresses") or [])
    privileged = [re.compile(p) for p in policy.get("privileged_types") or []]
    out = []
    for rc in plan_json.get("resource_changes", []) or []:
        change = rc.get("change") or {}
        if set(change.get("actions") or []) <= {"no-op", "read", "delete"}:
            continue
        typ, addr = rc.get("type", ""), rc.get("address", "?")
        after = change.get("after") or {}
        unknown = change.get("after_unknown") or {}
        if (any(p.fullmatch(typ) for p in privileged) or _SECURITY.match(typ)) and _INDEX.sub("", addr) not in engine:
            out.append(f"{addr}: {typ} is security-relevant but not engine-rendered")
        if typ == "aws_iam_role" and meta.get("boundary") and after.get("permissions_boundary") != meta["boundary"]:
            out.append(f"{addr}: role without the app's permissions boundary")
        if ("tags_all" in after or "tags_all" in unknown) and not unknown.get("tags_all") \
                and "app_id" not in (after.get("tags_all") or {}):
            out.append(f"{addr}: missing the app_id tag (provider default_tags)")
        if typ == "aws_db_instance":
            if after.get("publicly_accessible") is True:
                out.append(f"{addr}: database is publicly accessible")
            if after.get("storage_encrypted") is False:
                out.append(f"{addr}: database storage is not encrypted")
            if meta.get("prod") and after.get("deletion_protection") is not True:
                out.append(f"{addr}: production database without deletion protection")
        if typ.endswith("public_access_block"):
            for k in ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"):
                if after.get(k) is False:
                    out.append(f"{addr}: {k} is false")
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: policy_check.py infra/<root> plan.json", file=sys.stderr)
        return 2
    here = Path(__file__).resolve().parent
    policy = json.loads((here / "policy.json").read_text())
    found = tampered(policy, here.parent) + violations(json.loads(Path(argv[2]).read_text()), policy,
                                                       argv[1].rstrip("/"))
    for f in found:
        print(f"POLICY VIOLATION: {f}")
    print("policy: blocked" if found else "policy: passed")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
