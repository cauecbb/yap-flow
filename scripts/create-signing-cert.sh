#!/usr/bin/env bash
#
# Creates a self-signed code-signing certificate, "Yap Local Signing", in your
# login keychain. install-local.sh signs with it, so every rebuild keeps the same
# identity and macOS keeps the permissions you granted. Run it once.
#
# The certificate only signs builds on this Mac. It isn't trusted by anyone
# else, and it doesn't need to be: macOS ties permissions to the signature, not
# to who issued it.

set -euo pipefail

NAME="Yap Local Signing"

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 12)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# OpenSSL 3+ needs -legacy for a PKCS#12 that the macOS keychain can import.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -out "$WORK/cert.p12" -passout "pass:$PASS" -name "$NAME"

security import "$WORK/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Now run ./install-local.sh."
