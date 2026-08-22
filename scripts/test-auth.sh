#!/usr/bin/env bash
# =============================================================================
# Authentication
#
# Covers the estate's pattern as both services implement it: an HS256 token
# signed by IAM, a session in Redis that can end it early, and what happens when
# Redis cannot be reached. Plus the service credential the bridge presents on
# /internal/*.
#
# The interesting assertions are the last two groups. Anyone can check that a
# missing token is refused; what is worth proving is that a *revoked* token is
# refused, and that an outage in the cache does not take the laboratory down
# with it.
#
#   scripts/test-auth.sh
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLINICAL="${API}/patients/search?q=a"
INTERNAL_UNKNOWN="/internal/patients/00000000-0000-0000-0000-000000000000"

# Plain curl, no automatic credential: this suite supplies each one by hand.
code_for() {  # code_for <url> [curl args...]
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" "$url"
}

in_his() {   # in_his <method> <path> [curl args...]
    local method="$1" path="$2"; shift 2
    docker exec his-api curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
        -X "$method" "$@" "http://localhost:8080$path"
}

in_bridge() { # in_bridge <path> [curl args...]
    local path="$1"; shift
    docker exec bridge curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
        "$@" "http://localhost:8080$path"
}

mint() { bash "$ROOT/scripts/mint-token.sh" --quiet "$@"; }

if [[ -z "$HIS_TOKEN" ]]; then
    bad "Could not sign in — is the sandbox up?"
    summary; exit 1
fi

# ---------------------------------------------------------------------------
section "1 · A token must be present, and must be ours"

check "No token is refused with 401" \
    "[[ \$(code_for '$CLINICAL') == 401 ]]"

check "A token in the wrong scheme is refused" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Token $HIS_TOKEN') == 401 ]]"

check "Rubbish in place of a token is refused" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer not.a.jwt') == 401 ]]"

# The one that matters. A token whose claims are perfect but whose signature was
# made with another key is exactly what an attacker produces, and it is what
# `jwt.decode` — used in two of the estate's services — accepts.
FORGED=$(docker exec his-api node -e '
const jwt = require("jsonwebtoken");
process.stdout.write(jwt.sign(
  { usr_id: 1, usr_name: "sandbox.user", group_names: ["lab-orders"] },
  "an-attacker-chosen-secret", { expiresIn: 3600 }));
')
check "A token signed with a different secret is refused" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $FORGED') == 401 ]]"

check_contains "The refusal says nothing about why the signature failed" \
    "curl -s '$CLINICAL' -H 'Authorization: Bearer $FORGED'" \
    'Invalid or expired token'

check "A valid token is accepted" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $HIS_TOKEN') == 200 ]]"

# ---------------------------------------------------------------------------
section "2 · Expiry and group membership"

SHORT=$(mint --user 5 --name briefly --ttl 1 --groups "$LAB_ORDER_GROUP")
sleep 2
check "An expired token is refused" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $SHORT') == 401 ]]"

if [[ -n "$LAB_ORDER_GROUP" ]]; then
    UNGROUPED=$(mint --user 6 --name no.groups --groups "")
    check "A valid token without $LAB_ORDER_GROUP is refused with 403, not 401" \
        "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $UNGROUPED') == 403 ]]"
    info "403, not 401: the caller is authenticated, and being told so"
else
    info "LAB_ORDER_GROUP is empty; group enforcement is off in this deployment"
fi

# ---------------------------------------------------------------------------
section "3 · Revocation — the reason Redis is in this path at all"

# A signature alone cannot express "this person logged out four minutes ago".
# The session in Redis is what can, and these two assertions are the difference
# between a token that is valid and a session that still exists.
# Given both groups, because section 4 presents it to the bridge as well.
ORPHAN=$(mint --user 8 --name orphan --groups "$LAB_ORDER_GROUP,$BRIDGE_OPS_GROUP" --no-session)
check "A correctly signed token with no Redis session is refused" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $ORPHAN') == 401 ]]"

check_contains "…and is told the session ended, not that the token is bad" \
    "curl -s '$CLINICAL' -H 'Authorization: Bearer $ORPHAN'" \
    'Session ended or token revoked'

LOGOUT=$(mint --user 9 --name logs.out --groups "$LAB_ORDER_GROUP")
check "That user can call the API" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $LOGOUT') == 200 ]]"

# What IAM's logout does: AuthService.clearUserData deletes the whole hash.
docker exec his-redis redis-cli DEL user:9 >/dev/null
check "After logout the same token stops working immediately" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $LOGOUT') == 401 ]]"
info "the token has not expired — the session behind it is gone"

# The estate stores one `token` field per user, so a second sign-in overwrites
# the first. Worth asserting because it is a real, user-visible consequence:
# signing in on a phone ends the session on the desktop.
FIRST=$(mint --user 10 --name two.devices --groups "$LAB_ORDER_GROUP")
SECOND=$(mint --user 10 --name two.devices --groups "$LAB_ORDER_GROUP")
check "A second sign-in ends the first session" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $FIRST') == 401 ]]"
check "…and the newer token works" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $SECOND') == 200 ]]"

# ---------------------------------------------------------------------------
section "4 · Redis outage: degraded, not down"

DEGRADED_BEFORE=$(docker logs his-api 2>&1 | grep -c 'degraded authentication mode')

docker stop his-redis >/dev/null
info "stopped Redis"
sleep 2

# The whole point. Signature verification does not need Redis, so a clinician
# holding a valid token can still order a test during a cache outage. What is
# lost is revocation — and that is the trade the estate has chosen.
START=$SECONDS
DEGRADED_CODE=$(code_for "$CLINICAL" -H "Authorization: Bearer $HIS_TOKEN")
ELAPSED=$((SECONDS - START))

check "The clinical API still answers with Redis stopped" \
    "[[ '$DEGRADED_CODE' == 200 ]]"

# Not a performance nicety. ioredis queues commands while disconnected and
# replays them on reconnect, so with its defaults this request waits for Redis
# to come back before reaching the degraded path at all — the fallback never
# runs, and every request hangs instead. See services/his-api/src/config/redis.ts.
check "…and answers immediately, rather than waiting for Redis to return" \
    "[[ $ELAPSED -lt 5 ]]"
info "answered in ${ELAPSED}s"

# The orphan token was refused a moment ago. Now it is accepted, because there
# is nothing to check it against. That is what degraded mode COSTS, stated as
# an assertion rather than a caveat in a document.
check "A revoked token is accepted while Redis is down" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $ORPHAN') == 200 ]]"

check_contains "The degraded check is counted in /metrics" \
    "docker exec his-api curl -sf http://localhost:8080/metrics | grep 'auth_revocation_checks_total{' | grep degraded" \
    'result="degraded"'

# Ten more requests during the outage.
for _ in $(seq 1 10); do
    code_for "$CLINICAL" -H "Authorization: Bearer $HIS_TOKEN" >/dev/null
done
DEGRADED_AFTER=$(docker logs his-api 2>&1 | grep -c 'degraded authentication mode')

# An outage is precisely when traffic does not fall. The estate's middleware
# logs inside the per-request catch block, which at any real rate is thousands
# of identical lines a minute on a topic shared with every other service.
check "Ten requests during the outage add no further log lines" \
    "[[ $((DEGRADED_AFTER - DEGRADED_BEFORE)) -le 1 ]]"
info "log lines about degraded mode: $DEGRADED_BEFORE before, $DEGRADED_AFTER after"

# The same trade, in the other language. This call also forces the bridge to
# open its Redis connection FOR THE FIRST TIME during the outage, which is what
# the next assertion depends on.
check "The bridge's /ops also degrades rather than refusing" \
    "[[ \$(in_bridge /ops/orders -H 'Authorization: Bearer $ORPHAN') == 200 ]]"

docker start his-redis >/dev/null
info "started Redis"
bash "$ROOT/scripts/wait-for.sh" "docker exec his-redis redis-cli ping" 60 >/dev/null 2>&1

# Redis holds sessions in memory with no persistence, so a restart is a
# hospital-wide logout. Everything minted above is gone, including this suite's
# own sign-in.
sleep 2
check "Once Redis returns, the revoked token is refused again" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $ORPHAN') == 401 ]]"

check_contains "…and the service says so, once" \
    "docker logs his-api 2>&1 | tail -50" \
    'Redis reachable again'

HIS_TOKEN=$(mint --user 1 --name suite.runner --groups "$LAB_ORDER_GROUP")
check "Signing in again works after the outage" \
    "[[ \$(code_for '$CLINICAL' -H 'Authorization: Bearer $HIS_TOKEN') == 200 ]]"

# The bridge first reached for Redis while it was stopped. StackExchange.Redis
# throws from Connect() in that situation unless told not to, and a caught throw
# there leaves the connection permanently absent — the service would keep
# serving, silently never checking revocation again. These two prove it
# recovered rather than gave up.
RECOVERED=$(mint --user 13 --name after.outage --groups "$LAB_ORDER_GROUP,$BRIDGE_OPS_GROUP")
check "The bridge accepts that user" \
    "[[ \$(in_bridge /ops/orders -H 'Authorization: Bearer $RECOVERED') == 200 ]]"
docker exec his-redis redis-cli DEL user:13 >/dev/null
check "…and enforces revocation again once Redis is back" \
    "[[ \$(in_bridge /ops/orders -H 'Authorization: Bearer $RECOVERED') == 401 ]]"

# ---------------------------------------------------------------------------
section "5 · The bridge is a service, not a person"

check "/internal/* refuses a call with no key" \
    "[[ \$(in_his GET '$INTERNAL_UNKNOWN') == 401 ]]"

check "/internal/* refuses a wrong key" \
    "[[ \$(in_his GET '$INTERNAL_UNKNOWN' -H 'x-internal-api-key: wrong') == 401 ]]"

# 404 rather than 200: the id is deliberately absent. Reaching a 404 proves the
# request got past the guard, which is what is being tested.
check "/internal/* accepts the estate's service key" \
    "[[ \$(in_his GET '$INTERNAL_UNKNOWN' -H 'x-internal-api-key: $INTERNAL_API_KEY') == 404 ]]"

check "A user token is NOT a service key" \
    "[[ \$(in_his GET '$INTERNAL_UNKNOWN' -H 'Authorization: Bearer $HIS_TOKEN') == 401 ]]"

# ---------------------------------------------------------------------------
section "6 · The bridge's operational views take either credential"

check "/ops refuses an anonymous caller" \
    "[[ \$(in_bridge /ops/orders) == 401 ]]"

check "/ops accepts the shared operator token" \
    "[[ \$(in_bridge /ops/orders -H 'Authorization: Bearer $BRIDGE_ADMIN_TOKEN') == 200 ]]"

OPS_USER=$(mint --user 11 --name lab.operator --groups "$LAB_ORDER_GROUP,$BRIDGE_OPS_GROUP")
check "/ops accepts a signed-in HIS user in $BRIDGE_OPS_GROUP" \
    "[[ \$(in_bridge /ops/orders -H 'Authorization: Bearer $OPS_USER') == 200 ]]"
info "a .NET service verifying a token a Node service issued — same secret, no call to IAM"

if [[ -n "$BRIDGE_OPS_GROUP" ]]; then
    CLINICIAN=$(mint --user 12 --name just.a.doctor --groups "$LAB_ORDER_GROUP")
    check "…and refuses one without that group" \
        "[[ \$(in_bridge /ops/orders -H 'Authorization: Bearer $CLINICIAN') == 403 ]]"
fi

check_contains "Who ran an operational request is in the log" \
    "docker logs bridge --since 10m 2>&1 | grep 'by user' | tail -5" \
    'by user 11'

# The dead-letter queue names patients and the tests they were sent for. It is
# behind the same door as the endpoints that change things, for that reason.
check "/ops/dead-letters is not readable anonymously" \
    "[[ \$(in_bridge /ops/dead-letters) == 401 ]]"

summary
