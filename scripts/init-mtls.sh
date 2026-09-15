#!/usr/bin/env bash
# =============================================================================
# Certificates for the bridge <-> OpenELIS hop.
#
# This closes the one weak door in the design. Until now that hop was plain
# HTTP, and the only control was "the request came from an address I recognise"
# — which authenticates a network location, not a node. IHE ATNA requires node
# authentication to be bidirectional and certificate-based, and is explicit that
# PHI must not cross a link that is not.
#
# ── Why this needs no change to OpenELIS ─────────────────────────────────────
# OpenELIS already presents a client certificate on every FHIR call. Three
# facts, read from the deployed webapp rather than from documentation:
#
#   1. common.properties — which THIS repository renders — sets
#      server.ssl.key-store and server.ssl.trust-store to the certgen stores.
#   2. org.openelisglobal.config.HttpClientConfig builds the shared Apache
#      HttpClient with loadKeyMaterial(keystore) and loadTrustMaterial(truststore).
#   3. FhirConfig hands that client to every FHIR client it creates, including
#      the remote-source poll and the subscriber push.
#
# So OpenELIS has always been willing to prove who it is. Nothing was asking.
# All that is missing is a server on the other end that requires a certificate,
# and a trust anchor so each side accepts the other.
#
# ── What this script creates ─────────────────────────────────────────────────
#   certs/ca.crt / ca.key            our own small CA for this hop
#   certs/bridge.crt / bridge.key    the bridge's TLS server certificate
#   certs/openelis-client.crt        OpenELIS's certificate, EXPORTED from its
#                                    own truststore — never generated here
#
# The bridge pins that exported certificate. It never holds OpenELIS's private
# key, so it cannot impersonate OpenELIS; it can only recognise it.
#
# ── Ordering ────────────────────────────────────────────────────────────────
# The first two need nothing running, so `make config` calls this before the
# stack starts — which is what lets a fresh clone come up already mutually
# authenticated. The third cannot: OpenELIS's certificate does not exist until
# certgen has made it. The `oe-peer-cert` one-shot in compose/openelis.yml does
# that export from the volume during `make up`, and the branch below is the
# hand-run equivalent for a stack that is already up.
#
# Idempotent. Existing files are left alone, because regenerating a CA that
# OpenELIS's truststore already trusts would break the link until the truststore
# was updated too.
#
#   scripts/init-mtls.sh            create what is missing
#   scripts/init-mtls.sh --force    start again from nothing
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS="$ROOT/certs"
DAYS=3650

# The name OpenELIS will use for the bridge. It must match a SAN on the
# bridge's certificate or Java rejects the connection after trusting it — a
# failure that reads as "handshake failed" and sends people looking at the CA.
BRIDGE_DNS="${BRIDGE_MTLS_DNS:-bridge.openelis.org}"

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

mkdir -p "$CERTS"
chmod 700 "$CERTS"

if [[ "$FORCE" == true ]]; then
    echo "==> Removing existing certificates"
    rm -f "$CERTS"/{ca,bridge,openelis-client}.{crt,key,srl}
fi

# --- 1. Our CA ---------------------------------------------------------------
# A real CA certificate, with basicConstraints CA:true — not a self-signed leaf
# pressed into service as a trust anchor. Java's PKIX will not build a chain
# through a certificate that does not claim to be a CA.
if [[ -f "$CERTS/ca.crt" ]]; then
    echo "==> CA already exists, keeping it"
else
    echo "==> Creating the integration CA"
    openssl req -x509 -newkey rsa:4096 -sha256 -days "$DAYS" -nodes \
        -keyout "$CERTS/ca.key" -out "$CERTS/ca.crt" \
        -subj "/C=MU/O=HIS Sandbox/OU=Integration/CN=HIS Sandbox Integration CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
fi

# --- 2. The bridge's server certificate --------------------------------------
if [[ -f "$CERTS/bridge.crt" ]]; then
    echo "==> Bridge certificate already exists, keeping it"
else
    echo "==> Issuing the bridge's server certificate for $BRIDGE_DNS"
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "$CERTS/bridge.key" -out "$CERTS/bridge.csr" \
        -subj "/C=MU/O=HIS Sandbox/OU=Integration/CN=$BRIDGE_DNS" 2>/dev/null

    # localhost and 127.0.0.1 are here so the container can call its own TLS
    # port during a health check without a name that only exists on one network.
    cat > "$CERTS/bridge.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$BRIDGE_DNS,DNS:bridge,DNS:localhost,IP:127.0.0.1
EXT

    openssl x509 -req -in "$CERTS/bridge.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" \
        -CAcreateserial -out "$CERTS/bridge.crt" -days "$DAYS" -sha256 \
        -extfile "$CERTS/bridge.ext" 2>/dev/null

    rm -f "$CERTS/bridge.csr" "$CERTS/bridge.ext"
fi

# --- 3. OpenELIS's certificate, exported ------------------------------------
# Taken from OpenELIS's own truststore rather than generated, because it is
# OpenELIS's identity and belongs to OpenELIS. The bridge stores only the public
# certificate: enough to recognise the peer, not enough to be it.
#
# Not having it is NOT an error, and that is the point of this branch. On a
# fresh clone nothing is running yet, so this script runs to generate the two
# certificates above and the export happens later, inside `make up`. Treating
# the absent peer as fatal here is what made `make config` fail before the stack
# had ever been started — the chicken-and-egg that left a new clone with no
# working bridge at all.
if [[ -f "$CERTS/openelis-client.crt" && "$FORCE" == false ]]; then
    echo "==> OpenELIS certificate already exported, keeping it"
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx openelis-webapp; then
    echo "==> Exporting OpenELIS's certificate from its truststore"
    TS_PASS=$(grep -E '^SSL_TRUSTSTORE_PASSWORD=' "$ROOT/.env" | cut -d= -f2-)
    # Through a temporary file: a failed export that wrote straight to the
    # destination would replace a good certificate with an empty one, and the
    # bridge would then refuse every handshake OpenELIS made.
    if docker exec openelis-webapp keytool -exportcert -rfc \
        -alias oecert -keystore /etc/openelis-global/truststore \
        -storepass "$TS_PASS" -storetype PKCS12 > "$CERTS/.openelis-client.tmp" 2>/dev/null \
        && [[ -s "$CERTS/.openelis-client.tmp" ]]; then
        mv "$CERTS/.openelis-client.tmp" "$CERTS/openelis-client.crt"
    else
        rm -f "$CERTS/.openelis-client.tmp"
        echo "!! The export failed. Is certgen finished? Check: make logs S=oe-certs" >&2
    fi
else
    echo "==> OpenELIS is not running; its certificate will be exported by"
    echo "    'make up' (the oe-peer-cert one-shot). Nothing to do here yet."
fi

chmod 600 "$CERTS"/*.key
chmod 644 "$CERTS"/*.crt 2>/dev/null || true

echo
echo "Certificates in $CERTS:"
for f in ca.crt bridge.crt openelis-client.crt; do
    if [[ -f "$CERTS/$f" ]]; then
        printf '  %-22s %s\n' "$f" \
            "$(openssl x509 -in "$CERTS/$f" -noout -subject | sed 's/^subject=//')"
    else
        printf '  %-22s %s\n' "$f" "not yet — exported during 'make up'"
    fi
done
