#!/bin/bash
# Creates a local "Murmur Local Signing" certificate in your login keychain, once.
#
# Why: macOS remembers which apps you allowed (Accessibility, Input Monitoring, Microphone) by the app's signature.
# Murmur is normally signed "ad hoc", and an ad hoc signature changes on every rebuild, so macOS forgets the
# permissions each time. A certificate gives every build the same signature, so you only allow Murmur once.
#
# What it touches: your login keychain only (adds one certificate and its private key). It does not change
# system settings, trust settings or anything that needs an administrator password. The certificate is
# self-signed, valid for 10 years, and only good for signing code on this Mac.
# To remove it later: open Keychain Access, find "Murmur Local Signing" under My Certificates, and delete it.
set -euo pipefail

NAME="Murmur Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT   # the key and password files below never outlive this script
PASS="$(openssl rand -hex 16)"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# The older packaging (SHA1 and 3DES) is on purpose: this Mac's OpenSSL defaults to newer encryption
# that macOS's keychain importer rejects with "MAC verification failed".
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T lets the codesign tool use the key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\" in your login keychain."
