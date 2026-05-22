#!/bin/bash
# Create a stable self-signed code signing certificate so TCC permissions
# (Accessibility) persist across rebuilds. Idempotent: skips if cert exists.
set -euo pipefail

CERT_NAME="mMouse Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Pin to system LibreSSL: Homebrew OpenSSL 3.x produces PKCS#12 encodings
# the macOS `security` tool may silently fail to import.
OPENSSL=/usr/bin/openssl

verify_codesign() {
    # `find-identity -v -p codesigning` excludes self-signed identities even
    # though `codesign` itself accepts them. Do a real test-sign instead.
    local tmpbin
    tmpbin=$(mktemp)
    /bin/cp /bin/echo "$tmpbin"
    chmod +w "$tmpbin"
    if codesign --force --sign "$CERT_NAME" "$tmpbin" 2>/dev/null; then
        rm -f "$tmpbin"
        return 0
    else
        rm -f "$tmpbin"
        return 1
    fi
}

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "✓ Certificate '$CERT_NAME' already exists in login keychain."
    if verify_codesign; then
        echo "✓ Verified: codesign accepts this identity."
        exit 0
    fi
    echo "  ⚠ Cert present but codesign rejected it. Delete in Keychain Access and rerun."
    exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_codesign

[dn]
CN = $CERT_NAME

[v3_codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "Generating self-signed code signing cert (10-year validity)..."
"$OPENSSL" req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
    -days 3650 -nodes \
    -config "$TMPDIR/openssl.cnf"

echo "Bundling into PKCS#12..."
# Force legacy SHA1 + 3DES encryption so macOS `security import` can read it.
# LibreSSL's default (newer SHA-256 + AES) produces a PKCS#12 that the system
# security tool rejects with "MAC verification failed".
# Use a non-empty password — required by macOS `security import` to MAC-verify.
P12_PASS="mMouse-temp-pass"
"$OPENSSL" pkcs12 -export \
    -in "$TMPDIR/cert.pem" -inkey "$TMPDIR/key.pem" \
    -out "$TMPDIR/bundle.p12" -name "$CERT_NAME" \
    -passout "pass:$P12_PASS" \
    -macalg sha1 \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

echo "Importing into login keychain..."
# -T grants codesign access to the private key without prompting.
# We deliberately omit -A (which grants ALL apps access — too broad).
security import "$TMPDIR/bundle.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

# Verify by test-signing (find-identity -v rejects self-signed even though
# codesign accepts it).
if ! verify_codesign; then
    echo "⚠ Cert imported but codesign couldn't use it."
    echo "  Open Keychain Access, find '$CERT_NAME', expand it,"
    echo "  double-click the private key → Access Control →"
    echo "  'Allow all applications to access this item'."
    exit 1
fi

echo ""
echo "✓ Certificate '$CERT_NAME' created and verified successfully."
echo "  Next 'make bundle' will sign with this stable identity."
echo "  TCC (Accessibility) grants will now persist across rebuilds."
