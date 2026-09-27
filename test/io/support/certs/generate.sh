#!/bin/sh
# Regenerates the test-only TLS material in this directory.
#
# Validity is 825 days: macOS rejects TLS server certificates valid for
# longer, even when their CA is trusted. Rerun this before they expire.
set -eu
cd "$(dirname "$0")"

days=825
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Throwaway CA. Its key lives only in $tmp and is deleted on exit.
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ca.key"
openssl req -x509 -new -key "$tmp/ca.key" -subj "/CN=typesafe_ai test CA" \
  -days "$days" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out ca.pem

cat > "$tmp/server.ext" <<'EOF'
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
EOF

# Server certificate signed by the CA.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out localhost.key
openssl req -new -key localhost.key -subj "/CN=localhost" -out "$tmp/localhost.csr"
openssl x509 -req -in "$tmp/localhost.csr" -CA ca.pem -CAkey "$tmp/ca.key" \
  -CAcreateserial -CAserial "$tmp/ca.srl" -days "$days" \
  -extfile "$tmp/server.ext" -out localhost.pem

# Self-signed certificate that no test trusts. Same validity and extensions
# as the trusted one, so it is rejected only for being untrusted.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out untrusted.key
openssl req -x509 -new -key untrusted.key -subj "/CN=localhost" \
  -days "$days" -extensions v3_srv \
  -config /dev/stdin -out untrusted.pem <<EOF
[req]
distinguished_name=dn
[dn]
[v3_srv]
$(cat "$tmp/server.ext")
EOF

openssl verify -CAfile ca.pem localhost.pem
openssl x509 -in localhost.pem -noout -enddate
