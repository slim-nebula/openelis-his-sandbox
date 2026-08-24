#!/usr/bin/env bash
# =============================================================================
# Renders the config templates that cannot read environment variables at
# runtime. OpenELIS's common.properties is one of them: it is mounted as a
# docker secret, and Tomcat reads it as a plain file.
#
# Keeping it templated means .env stays the single source of truth for the
# integration endpoints on both sides of the bridge.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
    echo "error: .env not found in $ROOT" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

mkdir -p openelis/generated

render() {
    local template="$1" output="$2"
    envsubst < "$template" > "$output"
    echo "  rendered $output"
}

echo "Rendering configuration from .env:"
render openelis/properties/common.properties.template openelis/generated/common.properties

# --- Consistency check ------------------------------------------------------
# The single most common way to break this sandbox is for the Task.owner the
# bridge stamps and the identifier OpenELIS polls for to drift apart. They come
# from the same variable, so just prove it landed in the rendered file.
if ! grep -q "^org.openelisglobal.remote.source.identifier=${OE_REMOTE_SOURCE_IDENTIFIER}$" \
        openelis/generated/common.properties; then
    echo "error: remote.source.identifier did not render correctly" >&2
    exit 1
fi

echo "OK — OpenELIS will poll ${BRIDGE_FHIR_BASE} for Task?status=requested&owner=${OE_REMOTE_SOURCE_IDENTIFIER}"

# --- .env drift -------------------------------------------------------------
# .env is generated from .env.example once and then never again, because
# `make secrets` refuses to overwrite it — regenerating passwords against
# databases initialised with the old ones locks you out rather than rotating
# anything. The cost of that decision is that every setting added afterwards is
# missing from every .env that already exists.
#
# Silence is the wrong response to that. Some settings fall back to a sensible
# default and some do not, and either way the person running this should be told
# rather than discovering it as behaviour they did not choose. A warning, not an
# error: a missing key is usually harmless, and stopping the stack over one
# would be worse than the problem.
MISSING=$(comm -23 \
    <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env.example | tr -d '=' | sort -u) \
    <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env         | tr -d '=' | sort -u))

if [[ -n "$MISSING" ]]; then
    echo
    echo "note: .env is missing $(wc -w <<< "$MISSING" | tr -d ' ') setting(s) added to .env.example since it was created:"
    sed 's/^/    /' <<< "$MISSING"
    echo "      Each falls back to a built-in default. Copy the ones you want to set."
fi
