#!/usr/bin/env bash
# =============================================================================
# Build .env from .env.example, minting a random value for every __GENERATE__.
#
# .env holds the values and is not committed. .env.example holds the shape and
# is. Adding a new setting means adding it to the example; adding a new secret
# means adding it as __GENERATE__ and getting a fresh one for free.
#
# This refuses to overwrite an existing .env. Regenerating passwords against
# databases that were initialised with the old ones does not rotate anything -
# it locks you out - so replacing them is a deliberate act with volumes to
# destroy first, not something a script should do because it was run twice.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

EXAMPLE=.env.example
TARGET=.env

[[ -f $EXAMPLE ]] || { echo "error: $EXAMPLE is missing" >&2; exit 1; }

if [[ -f $TARGET && "${FORCE:-}" != "true" ]]; then
    echo "  .env already exists — leaving it alone."
    echo "  Its passwords are the ones your database volumes were created with."
    echo "  To start over: make clean && rm .env && make secrets"
    exit 0
fi

# 24 bytes of urandom, base64, punctuation stripped. Alphanumeric because these
# land in PostgreSQL connection strings, YAML, Java keystore arguments and URLs
# without any of them agreeing on how to escape anything.
secret() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

generated=0
: > "$TARGET"
while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == *__GENERATE__* ]]; then
        printf '%s\n' "${line/__GENERATE__/$(secret)}" >> "$TARGET"
        generated=$((generated + 1))
    else
        printf '%s\n' "$line" >> "$TARGET"
    fi
done < "$EXAMPLE"

chmod 600 "$TARGET"

echo "  Wrote .env with $generated generated secret(s), mode 600."

# __SET_ME__ values cannot be invented: they are credentials for OpenELIS, a
# system this repository does not own. Say so loudly rather than letting the
# stack come up and fail somewhere less obvious.
# Settings only — the legend at the top of the file explains what __SET_ME__
# means and is not itself something to fill in.
outstanding=$(grep -nE '^[A-Z_]+=.*__SET_ME__' "$TARGET" || true)
if [[ -n $outstanding ]]; then
    echo ""
    echo "  Still to fill in by hand, before \`make up\`:"
    sed 's/^/      /' <<< "$outstanding"
    echo ""
    echo "  These are OpenELIS's own credentials. See README.md → Configuration."
fi
