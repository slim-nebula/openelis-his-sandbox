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
if [[ -f "$CERTS/openelis-client.crt" && "$FORCE" == false ]]; then
    echo "==> OpenELIS certificate already exported, keeping it"
elif docker ps --format '{{.Names}}' | grep -qx openelis-webapp; then
    echo "==> Exporting OpenELIS's certificate from its truststore"
    TS_PASS=$(grep -E '^SSL_TRUSTSTORE_PASSWORD=' "$ROOT/.env" | cut -d= -f2-)
    docker exec openelis-webapp keytool -exportcert -rfc \
        -alias oecert -keystore /etc/openelis-global/truststore \
        -storepass "$TS_PASS" -storetype PKCS12 > "$CERTS/openelis-client.crt"
else
    echo "!! OpenELIS is not running, so its certificate cannot be exported." >&2
    echo "   Start the stack, then run this again." >&2
    exit 1
fi

chmod 600 "$CERTS"/*.key
chmod 644 "$CERTS"/*.crt

echo
echo "Certificates in $CERTS:"
for f in ca.crt bridge.crt openelis-client.crt; do
    printf '  %-22s %s\n' "$f" \
        "$(openssl x509 -in "$CERTS/$f" -noout -subject | sed 's/^subject=//')"
done
echo
echo "OpenELIS must trust our CA. 'make up' imports it into the truststore;"
echo "to do it now:  make trust-bridge"
