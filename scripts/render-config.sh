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
