#!/usr/bin/env bash
set -euo pipefail

CA_OPENSSL_DIR="${CA_OPENSSL_DIR:-$HOME/ca/openssl}"
OPENSSL3="${OPENSSL3:-$HOME/opt/openssl-3/bin/openssl}"
export LD_LIBRARY_PATH="$HOME/opt/openssl-3/lib64:$HOME/opt/openssl-3/lib:${LD_LIBRARY_PATH:-}"

if [ ! -x "$OPENSSL3" ]; then
  echo "OpenSSL 3 binary was not found or is not executable: $OPENSSL3" >&2
  echo "Set OPENSSL3 to a local OpenSSL 3 binary with cmp support." >&2
  exit 1
fi

cd "$CA_OPENSSL_DIR"

NAME="${1:-simple-$(date +%Y%m%d-%H%M%S)}"

"$OPENSSL3" req -new \
  -newkey ec:<("$OPENSSL3" ecparam -name secp384r1) \
  -keyout "ecc/$NAME.key.enc" \
  -passout pass:0 \
  -out "ecc/$NAME.csr" \
  -subj "/CN=$NAME"

"$OPENSSL3" cmp \
  -cmd p10cr \
  -server 127.0.0.1:8829 \
  -secret pass:0000 \
  -ref cmptestp10cr \
  -path . \
  -srvcert synrc.pem \
  -certout "ecc/$NAME.pem" \
  -csr "ecc/$NAME.csr"

"$OPENSSL3" x509 -in "ecc/$NAME.pem" -noout -subject -issuer -dates

echo
echo "Generated:"
echo "  ecc/$NAME.key.enc"
echo "  ecc/$NAME.csr"
echo "  ecc/$NAME.pem"
