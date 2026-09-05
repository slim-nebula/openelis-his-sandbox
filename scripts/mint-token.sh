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
#
#   # A clinician with a specific provider identity (hcp.id + licence)
#   scripts/mint-token.sh --user 7 --provider-id 4412 --license ML-4412
#   # An account with no provider row: a receptionist, a ward clerk
#   scripts/mint-token.sh --user 8 --name front.desk --no-provider
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

# The signed-in user's CLINICAL identity, which is not their account.
#
# In the estate these live in two different services. IAM owns usr_id — the
# account. HIS-org-setup-service owns mlh_his_hcp_health_care_provider, whose
# `id` is the clinician a laboratory holds accountable for a test, and whose
# usr_id column is NULLABLE: a visiting consultant or a referring physician
# exists as a provider with no login at all.
#
# A real deployment resolves one from the other. The sandbox has no provider
# table to resolve against — building one would be modelling YOUR system inside
# a sandbox meant to demonstrate an integration — so the claim carries it
# directly, standing in for that lookup.
#
# Defaulted to something that is obviously NOT the usr_id, because the whole
# point is that they are different numbers for different things and a default
# that made them look alike would teach the wrong lesson.
HCP_ID=""
HCP_LICENSE=""
NO_PROVIDER=false
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
        # mlh_his_hcp_health_care_provider.id and .license_number.
        --provider-id) HCP_ID="$2"; shift 2 ;;
        --license)     HCP_LICENSE="$2"; shift 2 ;;
        # A user with an account and no provider row — a receptionist, a ward
        # clerk. Their orders reach the laboratory with no clinician named,
        # rather than with the account substituted for one.
        --no-provider) NO_PROVIDER=true; shift ;;
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

# usr_id must be a NUMBER, and it is worth failing loudly rather than minting a
# token that cannot work.
#
# The claim is built with Number(process.env.MINT_USER_ID). Anything
# non-numeric becomes NaN, JSON.stringify turns NaN into null, and the services
# reject the result with "Invalid token structure" — after this script has
# already printed the token and a cheerful "Signed in as …" line. The token
# looks fine, the failure surfaces three layers away in an HTTP 401, and nothing
# connects the two.
#
# This is not hypothetical: `make token` passed --user $(USER), and USER is
# inherited from the shell by every make invocation, so it silently minted
# --user <your login name> and produced usr_id: null on any interactive machine.
if ! [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
    echo "--user must be a number (usr_id), not '$USER_ID'." >&2
    echo "A non-numeric value mints a token with usr_id: null, which every" >&2
    echo "service rejects with 'Invalid token structure'." >&2
    exit 2
fi

# 9000 + usr_id, so the two identities are never the same number in a sandbox
# session. That matters: the change this stands in for is precisely that the
# laboratory must be told the CLINICIAN and not the ACCOUNT, and a default where
# both read "42" would make the distinction invisible in every example.
if [[ "$NO_PROVIDER" == true ]]; then
    HCP_ID=""; HCP_LICENSE=""
else
    [[ -n "$HCP_ID" ]]      || HCP_ID=$(( 9000 + USER_ID ))
    [[ -n "$HCP_LICENSE" ]] || HCP_LICENSE="ML-${HCP_ID}"
fi

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
    -e MINT_HCP_ID="$HCP_ID" \
    -e MINT_HCP_LICENSE="$HCP_LICENSE" \
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
  is_hcp_usr: Boolean(process.env.MINT_HCP_ID),
  is_employee_usr: true,
  group_names: groups,
  group_ids: groups.map((_, i) => i + 1),
  business_unit_ids: [1],
};
// Omitted entirely rather than sent as null when the user is not a clinician.
// An absent claim says "this account has no provider row"; a null one says
// "there is a provider whose id is nothing", and the second would key a
// nameless Practitioner into the laboratory records.
if (process.env.MINT_HCP_ID) {
  payload.hcp_id = Number(process.env.MINT_HCP_ID);
  payload.hcp_license = process.env.MINT_HCP_LICENSE;
}
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
