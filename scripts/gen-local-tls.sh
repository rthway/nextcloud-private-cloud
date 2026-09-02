#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generate a local development certificate for config/nginx/tls/.
#
# THIS IS FOR LOCAL WORK ONLY. It creates a self-signed certificate and a
# throwaway CA. Browsers will warn, and they are right to. Production
# certificates come from ACME -- see DEPLOYMENT.md.
#
# A private CA rather than a bare self-signed leaf, because trusting one local
# CA once beats clicking through an interstitial on every stack you run, and
# because it exercises the same chain-of-trust path a real certificate takes:
# fullchain.pem ends up containing leaf + issuer, exactly as certbot produces
# it, so swapping in a real certificate is a file copy and not a config change.
#
#   ./scripts/gen-local-tls.sh                 # uses NEXTCLOUD_DOMAIN from .env
#   ./scripts/gen-local-tls.sh erp.internal    # explicit domain
#
# Implementation note: every openssl invocation is driven by a config file
# rather than by -subj/-addext flags. That is not stylistic. Git Bash and MSYS
# rewrite any argument that looks like an absolute POSIX path into a Windows
# path before handing it to a native binary, so "-subj /C=NP/O=..." arrives at
# openssl as "C:/Program Files/Git/C=NP/O=..." and is rejected with a message
# about subject name format that points nowhere near the real cause. Setting
# MSYS_NO_PATHCONV=1 fixes -subj and simultaneously breaks every -out path.
# Config files sidestep the whole problem, and read better besides.
# ---------------------------------------------------------------------------
set -euo pipefail

# Declared and assigned separately: `readonly x="$(cmd)"` discards the
# command's exit status, so a failing cd would leave REPO_ROOT empty and
# the script would carry on operating relative to the wrong directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TLS_DIR="${REPO_ROOT}/config/nginx/tls"
readonly DAYS_CA=3650
readonly DAYS_LEAF=825   # the CA/Browser Forum maximum; browsers reject longer

log() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl is required and was not found on PATH"

# --- Resolve the domain ----------------------------------------------------
DOMAIN="${1:-}"
if [[ -z "${DOMAIN}" && -f "${REPO_ROOT}/.env" ]]; then
    DOMAIN="$(sed -n 's/^NEXTCLOUD_DOMAIN=//p' "${REPO_ROOT}/.env" | head -n1 | sed 's/#.*//' | xargs || true)"
fi
DOMAIN="${DOMAIN:-nextcloud.localhost}"

mkdir -p "${TLS_DIR}"

if [[ -f "${TLS_DIR}/privkey.pem" ]]; then
    printf 'Certificate material already exists in %s. Overwrite? [y/N] ' "${TLS_DIR}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { log "left existing material in place"; exit 0; }
fi

# Work with bare filenames from here on, so nothing openssl sees is an
# absolute path that a shell layer might rewrite.
cd "${TLS_DIR}"

log "issuing certificate for ${DOMAIN}"

# --- Config files ----------------------------------------------------------
cat > ca.cnf <<CACNF
[req]
prompt             = no
distinguished_name = dn
x509_extensions    = v3_ca

[dn]
C  = NP
O  = nextcloud-private-cloud local development
CN = nextcloud-private-cloud local CA

[v3_ca]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
CACNF

# subjectAltName, not merely CN. Every current browser ignores the Common Name
# entirely; a certificate whose SAN list does not include the hostname is
# simply invalid to them, regardless of what CN says.
cat > leaf.cnf <<LEAFCNF
[req]
prompt             = no
distinguished_name = dn
req_extensions     = v3_leaf

[dn]
C  = NP
O  = nextcloud-private-cloud local development
CN = ${DOMAIN}

[v3_leaf]
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
subjectAltName         = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = localhost
IP.1  = 127.0.0.1
IP.2  = ::1
LEAFCNF

# --- Certificate authority -------------------------------------------------
# ECDSA P-256 rather than RSA-2048: smaller, faster handshakes, universally
# supported for a decade, and it matches what a modern ACME issuer hands out.
log "generating local CA"
openssl ecparam -genkey -name prime256v1 -out ca-key.pem 2>/dev/null

openssl req -x509 -new -nodes \
    -config ca.cnf \
    -key ca-key.pem \
    -sha256 -days "${DAYS_CA}" \
    -out ca.pem

# --- Leaf certificate ------------------------------------------------------
log "generating server key and signing request"
openssl ecparam -genkey -name prime256v1 -out privkey.pem 2>/dev/null

openssl req -new \
    -config leaf.cnf \
    -key privkey.pem \
    -out server.csr

log "signing leaf certificate"
openssl x509 -req \
    -in server.csr \
    -CA ca.pem \
    -CAkey ca-key.pem \
    -CAcreateserial \
    -out cert.pem \
    -days "${DAYS_LEAF}" -sha256 \
    -extfile leaf.cnf -extensions v3_leaf

# nginx's ssl_certificate expects the leaf first, then the issuing chain.
cat cert.pem ca.pem > fullchain.pem

rm -f server.csr ca.cnf leaf.cnf

chmod 600 privkey.pem ca-key.pem
chmod 644 fullchain.pem cert.pem ca.pem

log "verifying chain"
openssl verify -CAfile ca.pem cert.pem

echo
openssl x509 -in cert.pem -noout -subject -issuer -dates
openssl x509 -in cert.pem -noout -ext subjectAltName

cat <<NOTE

  Written to config/nginx/tls/ (git-ignored):

    fullchain.pem   leaf + CA, referenced by ssl_certificate
    privkey.pem     server private key, mode 0600
    ca.pem          the local CA -- import this to silence browser warnings
    ca-key.pem      CA private key; delete it if you will not issue again

  To trust the CA:
    Linux    sudo cp config/nginx/tls/ca.pem /usr/local/share/ca-certificates/nextcloud-local.crt && sudo update-ca-certificates
    macOS    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain config/nginx/tls/ca.pem
    Windows  Import-Certificate -FilePath config\\nginx\\tls\\ca.pem -CertStoreLocation Cert:\\CurrentUser\\Root

  Do not use any of this beyond local development.

NOTE
