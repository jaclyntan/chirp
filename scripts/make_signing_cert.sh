#!/bin/bash
# Creates a self-signed code-signing certificate "Chirp Dev" in the
# login keychain, so rebuilds keep the same signature and macOS permission
# grants (Accessibility) survive. Idempotent.
set -euo pipefail

NAME="Chirp Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Signing identity '$NAME' already exists."
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -config cert.cnf

openssl pkcs12 -export -legacy -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:chirp 2>/dev/null \
 || openssl pkcs12 -export -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:chirp

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import identity.p12 -k "$KEYCHAIN" -P chirp \
    -T /usr/bin/codesign -T /usr/bin/security

# Mark the certificate trusted for code signing (may show an auth prompt).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem

# Authorise codesign to *use* the private key without a GUI prompt.
#
# `-T /usr/bin/codesign` above only adds codesign to the key's ACL; on
# modern macOS the key also carries a partition list, and a tool missing
# from it fails with `errSecInternalComponent` — codesign's uniquely
# unhelpful way of saying "not allowed to touch this key". Without this
# line signing tends to work in the session that created the cert and
# then break later, which is exactly as confusing as it sounds.
#
# Prompts once for the login-keychain password; it cannot be supplied
# non-interactively without putting the password in the script.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -l "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "NOTE: could not set the key partition list automatically. If signing" \
            "later fails with errSecInternalComponent, run:" \
            $'\n  security set-key-partition-list -S apple-tool:,apple:,codesign:' \
            "-s -l '$NAME' \"$KEYCHAIN\""

echo "Created signing identity '$NAME'."
