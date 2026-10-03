#!/usr/bin/env bash
# One-time setup: creates a free, self-signed code-signing identity named
# "Pane Local Signing" in your login keychain. Signing every build with the same
# identity lets macOS remember Pane's Screen Recording / Camera / Mic permissions.
# Remove it any time in Keychain Access (search "Pane Local Signing").
set -euo pipefail

NAME="Pane Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="pane-$RANDOM$RANDOM"

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign

echo "Created \"$NAME\"."
