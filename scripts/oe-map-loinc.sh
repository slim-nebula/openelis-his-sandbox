#!/bin/sh
# Add (or clear) a LOINC mapping on an OpenELIS test, through OpenELIS's own
# admin REST API — the same call its Test Management screen makes. Nothing here
# touches OpenELIS's database directly.
#
# This exists to rehearse the "the laboratory enabled a test" event, which is
# what makes a test orderable from the HIS and is the moment a billing mapping
# goes missing. See docs/billing-integration.md.
#
#   docker cp scripts/oe-map-loinc.sh bridge:/tmp/ && \
#   docker exec -e OE_SERVICE_USER=admin -e OE_SERVICE_PASSWORD=... \
#     bridge sh /tmp/oe-map-loinc.sh <testId> <loinc|none>
#
# The CSRF dance is the fiddly part and the reason this is a script rather than
# a one-liner: Spring holds the token in the SESSION, not a cookie, and rotates
# it on login. The value to send is the `csrf` field of GET /session, as the
# React frontend does — a token scraped from the login page is already stale by
# the time you are authenticated, and yields a 302 that looks like a lost
# session rather than a CSRF failure.
set -e
B=https://oe.openelis.org:8443/OpenELIS-Global
C=/tmp/oemap.$$

CSRF=$(curl -sk -c $C "$B/LoginPage" | sed -n 's/.*name="_csrf"[^>]*value="\([^"]*\)".*/\1/p' | head -1)
curl -sk -b $C -c $C -o /dev/null -X POST \
  --data-urlencode "loginName=$OE_SERVICE_USER" \
  --data-urlencode "password=$OE_SERVICE_PASSWORD" \
  --data-urlencode "_csrf=$CSRF" "$B/ValidateLogin"

# The authenticated token, from the same place the frontend reads it.
CSRF2=$(curl -sk -b $C "$B/session" | sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p')
[ -n "$CSRF2" ] || { echo "no csrf on /session — did the login fail?" >&2; exit 1; }

if [ "$2" = "none" ]; then
  BODY='{"mappings":[]}'
else
  BODY='{"mappings":[{"source":"LOINC","code":"'"$2"'","relationship":"SAME_AS"}]}'
fi
echo "body: $BODY"

CODE=$(curl -sk -b $C -o /tmp/oemap.out -w '%{http_code}' \
  -H "X-CSRF-Token: $CSRF2" -H "Content-Type: application/json" \
  -X PUT -d "$BODY" "$B/rest/test-catalog/tests/$1/terminology")
echo "HTTP $CODE"
[ "$CODE" = "200" ] || { head -c 300 /tmp/oemap.out; echo; exit 1; }

echo "--- terminology now reads:"
curl -sk -b $C "$B/rest/test-catalog/tests/$1/terminology"
echo
rm -f $C /tmp/oemap.out
