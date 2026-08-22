#!/usr/bin/env bash
# =============================================================================
# Stands in for signing into the HIS.
#
# In the estate, a user posts to IAM's /api/auth/login; IAM verifies the
# password, signs an HS256 token, and writes the session to Redis at
# user:{usr_id} with a 24-hour TTL. Every other service then only ever
# *verifies* — none of them mints.
#
# The sandbox has no IAM, so this script does IAM's two write steps and nothing
# else. It is not a login: there is no password, no user table, no lockout.
#
# ── Why it can do this at all ────────────────────────────────────────────────
# It signs the token inside the his-api container, using that container's own
# JWT_SECRET. That works because the estate signs HS256, where the verifying key
# and the signing key are the same string. Every service holding the secret to
# check tokens can therefore also issue them, and — since IAM's payload has no
# `aud` claim — issue them for any service in the estate.
#
# That is a real property of the current design, not a shortcut taken here. It
# is written up in docs/security.md under "What HS256 costs".
#
# Usage:
#   scripts/mint-token.sh                                  # a default user
#   scripts/mint-token.sh --user 7 --name dr.reed --groups lab-orders,lab-ops
#   scripts/mint-token.sh --ttl 60 --quiet                 # 60s token, token only
#   eval "$(scripts/mint-token.sh --export)"               # sets HIS_TOKEN
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Only for the group defaults and the example URL at the end. The secret is
# never read here — it is used inside the container that already holds it.
LAB_ORDER_GROUP=""
if [[ -f "$ROOT/.env" ]]; then
    LAB_ORDER_GROUP=$(grep -E '^LAB_ORDER_GROUP=' "$ROOT/.env" | cut -d= -f2- || true)
fi

USER_ID=1
USER_NAME=sandbox.user
FULL_NAME="Sandbox User"
# Defaults to whatever the clinical API requires, so a token from `make token`
# can actually order a test. Override with --groups.
#
# NOT named GROUPS: that is a bash special variable holding the caller's own
# group IDs, and bash repopulates it after an assignment. Setting it appears to
# work and then silently yields something like "20" — which is exactly what
# happened here, producing tokens whose group_names was the local staff group.
USER_GROUPS="$LAB_ORDER_GROUP"
TTL=86400
QUIET=false
EXPORT=false
NO_SESSION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)       USER_ID="$2"; shift 2 ;;
        --name)       USER_NAME="$2"; shift 2 ;;
        --full-name)  FULL_NAME="$2"; shift 2 ;;
        --groups)     USER_GROUPS="$2"; shift 2 ;;
        --ttl)        TTL="$2"; shift 2 ;;
        --quiet)      QUIET=true; shift ;;
        --export)     EXPORT=true; QUIET=true; shift ;;
        # Mints a token but does NOT create the Redis session, so the services
        # see a correctly signed token for a session that does not exist. Used
        # by the auth suite to prove revocation is actually enforced.
        --no-session) NO_SESSION=true; shift ;;
        -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if ! docker ps --format '{{.Names}}' | grep -qx his-api; then
    echo "his-api is not running — start the sandbox with 'make up' first." >&2
    exit 1
fi

# The payload IAM builds, claim for claim (AuthService.generateJwtToken).
# `usr_id` is a number there, so it is a number here; the services accept
# either, because a claim that changes type between environments is a bug
# waiting for whoever writes the strict comparison.
TOKEN=$(docker exec -i \
    -e MINT_USER_ID="$USER_ID" \
    -e MINT_USER_NAME="$USER_NAME" \
    -e MINT_FULL_NAME="$FULL_NAME" \
    -e MINT_GROUPS="$USER_GROUPS" \
    -e MINT_TTL="$TTL" \
    his-api node -e '
const jwt = require("jsonwebtoken");
const secret = process.env.JWT_SECRET;
if (!secret) { console.error("JWT_SECRET is not set in the his-api container"); process.exit(1); }
const groups = (process.env.MINT_GROUPS || "").split(",").filter(Boolean);
const payload = {
  usr_id: Number(process.env.MINT_USER_ID),
  usr_name: process.env.MINT_USER_NAME,
  usr_full_name: process.env.MINT_FULL_NAME,
  is_hcp_usr: true,
  is_employee_usr: true,
  group_names: groups,
  group_ids: groups.map((_, i) => i + 1),
  business_unit_ids: [1],
};
process.stdout.write(jwt.sign(payload, secret, { expiresIn: Number(process.env.MINT_TTL) }));
')

if [[ "$NO_SESSION" == false ]]; then
    # IAM's second write: storeUserTokenAndPermissionsInRedis. One `token` field
    # per user, which is why signing in on a second device ends the first
    # session — a property of the estate's design, kept here rather than
    # improved, so the sandbox behaves the way the real thing does.
    GROUPS_JSON=$(G="$USER_GROUPS" python3 -c '
import json, os
print(json.dumps([g for g in os.environ["G"].split(",") if g]))')

    docker exec his-redis redis-cli \
        HSET "user:$USER_ID" \
        token "$TOKEN" \
        permissions '[]' \
        group_names "$GROUPS_JSON" >/dev/null
    docker exec his-redis redis-cli EXPIRE "user:$USER_ID" "$TTL" >/dev/null
fi

if [[ "$EXPORT" == true ]]; then
    printf 'export HIS_TOKEN=%s\n' "$TOKEN"
elif [[ "$QUIET" == true ]]; then
    printf '%s\n' "$TOKEN"
else
    printf '\nSigned in as %s (usr_id %s)%s\n' "$USER_NAME" "$USER_ID" \
        "$([[ -n "$USER_GROUPS" ]] && printf ', groups: %s' "$USER_GROUPS")"
    printf 'Session valid for %ss%s\n\n' "$TTL" \
        "$([[ "$NO_SESSION" == true ]] && printf ' (no Redis session written)')"
    printf '%s\n\n' "$TOKEN"
    printf 'Try it:\n'
    printf '  curl -H "Authorization: Bearer $TOKEN" http://localhost:%s/api/patients/search?q=a\n' \
        "$(grep -E '^EDGE_HTTP_PORT=' "$ROOT/.env" | cut -d= -f2)"
    printf '\nPaste it into the test frontend with the "Sign in" button.\n'
fi
