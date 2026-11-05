#!/bin/sh
# Creates a free self-signed code signing certificate in your login keychain, once.
# With it every build carries the same signature, so macOS keeps the Input Monitoring
# permission when you rebuild or update. Run it yourself, in your own terminal. macOS asks
# for your password once, to trust the certificate for code signing.
# The private key stays in your keychain. This script leaves no copy of it on disk.
set -eu

NAME="Plastikey Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Apple's tools only: the import below does not read files from a newer OpenSSL.
OPENSSL=/usr/bin/openssl
SECURITY=/usr/bin/security

if "$SECURITY" find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in your keychain. Nothing to do."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/cert.cnf" <<CONFIG
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONFIG

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The password only protects the temporary file on its way into the keychain.
PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

"$SECURITY" import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
"$SECURITY" add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
"$SECURITY" find-identity -p codesigning | grep "\"$NAME\""
cat <<DONE

Done. "$NAME" is in your login keychain, valid for 10 years.

Next:
  ./build.sh
The first build may ask to use the key. Enter your login password and choose Always Allow.

Moving to another Mac:
  1. Open Keychain Access and find "$NAME" under login > My Certificates.
  2. Right-click it, choose Export, save as .p12 and set a strong password.
  3. On the other Mac, double-click the .p12, then open the certificate's Trust section
     and set Code Signing to Always Trust.
Keep that .p12 out of any repository. Anyone holding it can sign apps as this certificate.
DONE
