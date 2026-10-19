#!/bin/sh
# Creates a self-signed code signing certificate, "Kea Local Signing", in your login
# keychain. `make install` then signs with it instead of ad hoc, so macOS keeps Kea's
# Accessibility and other privacy grants across rebuilds. Run it yourself, once:
#
#   sh scripts/make-signing-cert.sh
#
# macOS asks for your password to trust the certificate for code signing.
set -e
NAME="Kea Local Signing"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."; exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
pass=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$NAME" \
  -out "$dir/cert.p12" -passout "pass:$pass" -legacy 2>/dev/null ||
  openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$NAME" \
    -out "$dir/cert.p12" -passout "pass:$pass"
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$dir/cert.p12" -k "$KC" -P "$pass" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$dir/cert.pem"
security find-identity -v -p codesigning | grep "$NAME"
echo "Done. Next: make install && make reload, then turn Kea on once more under Accessibility."
