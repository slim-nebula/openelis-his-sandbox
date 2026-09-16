#!/usr/bin/env bash
# =============================================================================
# Build a patched OpenELIS image from a named upstream release tag.
#
#   scripts/build-openelis.sh [version]        default: $OE_VERSION from .env
#
# What it does, in order:
#   1. clone upstream at the tag, into a scratch directory
#   2. apply every patch in openelis-patches/<version>/ in numeric order
#   3. build with upstream's own Dockerfile
#   4. tag the result his-sandbox/openelis-global-2:<version>
#
# It NEVER edits a running container and never writes into the upstream clone
# outside step 2. The clone is disposable; the patches are the artefact.
#
# A patch that does not apply STOPS the build. That is deliberate: a conflict
# means upstream changed the code the patch depends on, which is a decision for a
# person, not something to force with --3way and hope.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -f .env ]] && { set -a; . ./.env; set +a; }

VERSION="${1:-${OE_VERSION:-}}"
if [[ -z "$VERSION" ]]; then
    echo "No version. Pass one, or set OE_VERSION in .env." >&2
    exit 1
fi

PATCH_DIR="$ROOT/openelis-patches/$VERSION"
if [[ ! -d "$PATCH_DIR" ]]; then
    echo "No patches for $VERSION at openelis-patches/$VERSION/." >&2
    echo >&2
    echo "This repository currently carries NO patches, deliberately — the last" >&2
    echo "one was retired on 2026-09-16 because the bridge's delivery lease" >&2
    echo "covers what it did. So there is nothing to build here that stock does" >&2
    echo "not already give you: run OE_IMAGE_REPO=itechuw, which is the default." >&2
    echo >&2
    echo "If you are adding a patch, put it in openelis-patches/$VERSION/ and" >&2
    echo "read openelis-patches/README.md first — 'The rules' is the bar it has" >&2
    echo "to clear." >&2
    exit 1
fi

WORK="${TMPDIR:-/tmp}/openelis-build-$VERSION"
rm -rf "$WORK"

echo "==> Cloning upstream at $VERSION"
git clone --depth 1 --single-branch --branch "$VERSION" \
    https://github.com/I-TECH-UW/OpenELIS-Global-2.git "$WORK" --quiet

# dataexport is a SUBMODULE, and the Dockerfile builds it before anything else:
#     COPY ./dataexport /build/dataexport
#     WORKDIR /build/dataexport/dataexport-core && mvn dependency:go-offline
# A plain clone leaves the directory empty and that step dies with
# "no POM in /build/dataexport/dataexport-core".
#
# Only this one is initialised, deliberately. The repo declares eleven
# submodules; Consolidated-Server is declared over SSH (git@github.com:), which
# fails without keys, and --recurse-submodules would drag in all of them for no
# benefit. The Dockerfile copies ./dataexport, ./install, ./pom.xml, ./src and
# ./tomcat — dataexport is the only submodule among them.
echo "==> Fetching the dataexport submodule"
# --quiet before the path: after it, git reads it as a second pathspec and fails
# with "pathspec '--quiet' did not match any file(s) known to git".
git -C "$WORK" submodule update --init --depth 1 --quiet dataexport

if [[ ! -f "$WORK/dataexport/dataexport-core/pom.xml" ]]; then
    echo "dataexport did not check out — the build would fail at the first Maven step." >&2
    exit 1
fi

echo "==> Applying patches"
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
    echo "    none found — the build would be identical to stock." >&2
    exit 1
fi
for patch in "${patches[@]}"; do
    printf '    %s ... ' "$(basename "$patch")"
    if git -C "$WORK" apply --check "$patch" 2>/dev/null; then
        git -C "$WORK" apply "$patch"
        echo "applied"
    else
        echo "FAILED"
        echo "" >&2
        echo "$(basename "$patch") does not apply to $VERSION." >&2
        echo "" >&2
        echo "This is the signal the process exists for: upstream has changed the" >&2
        echo "code this patch depends on. Read their change before doing anything." >&2
        echo "The patch may now be unnecessary — if upstream fixed it, delete the" >&2
        echo "patch and record that in openelis-patches/README.md." >&2
        exit 1
    fi
done

# The webapp image is a Maven build into Tomcat — no React. The React UI is a
# separate upstream image we never patch. Still slow here: the stack pins
# linux/amd64, so on an arm64 host every javac runs under emulation.
echo "==> Building (Maven under linux/amd64 emulation; expect it to be slow)"

# Retried, because Maven Central transfers get truncated on a slow link.
#
#   Could not transfer artifact org.springframework:spring-beans:jar:6.1.15
#   Premature end of Content-Length delimited message body
#     (expected: 862,674; received: 630,784)
#
# Observed three times on three different artifacts. The Dockerfile is
# upstream's and we do not edit it, so we cannot pass Maven's wagon retry
# flags — but we do not need to. Every RUN that resolves dependencies mounts
# --mount=type=cache,target=/root/.m2, and a BuildKit cache mount is a volume,
# not a layer: it persists even when the step FAILS. So each attempt banks the
# artifacts it did fetch and the next one resumes from there. Attempts converge
# rather than repeat.
#
# This retries a TRANSFER, not a defect. A patch that does not apply has already
# stopped the script above, and a genuine compile error fails identically every
# time and exhausts the attempts with the same message — which is the signal.
ATTEMPTS="${BUILD_ATTEMPTS:-5}"
for attempt in $(seq 1 "$ATTEMPTS"); do
    if docker build --platform linux/amd64 \
        -t "his-sandbox/openelis-global-2:$VERSION" \
        -f "$WORK/Dockerfile" "$WORK"; then
        break
    fi

    if [[ "$attempt" -eq "$ATTEMPTS" ]]; then
        echo "" >&2
        echo "Build failed $ATTEMPTS times." >&2
        echo "" >&2
        echo "If the last error was a truncated transfer, the link is the problem and" >&2
        echo "another run will get further — the Maven cache keeps what it fetched." >&2
        echo "If it was the same compile error each time, that is a real failure." >&2
        exit 1
    fi

    echo ""
    echo "==> Attempt $attempt failed. Retrying ($((attempt + 1))/$ATTEMPTS) — the Maven"
    echo "    cache keeps what was already fetched, so this resumes rather than restarts."
    echo ""
done

echo ""
echo "==> Built his-sandbox/openelis-global-2:$VERSION"
echo ""
echo "    To run it, set in .env:   OE_IMAGE_REPO=his-sandbox"
echo "    then:                     make up"
echo ""
echo "    Only the webapp image is patched. The fhir, frontend, proxy and"
echo "    database images stay stock — no patch touches them, and building"
echo "    unmodified copies under our own name would hide that."
