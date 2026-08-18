#!/usr/bin/env bash
# Build a self-contained ENCRYPTED + SIGNED payload object.
#
#   scripts/make-payload.sh <signing-key> <recipient-cert> <node-id> <serial> [key=value ...]
#
# Object layout, in one file:
#     <CMS ciphertext, PEM>
#     -----BEGIN SSH SIGNATURE-----   (over the ciphertext)
#
# ⚠️ ENCRYPT THEN SIGN. The signature covers the ciphertext so a node can
# authenticate BEFORE decrypting — a decryptor is a parser, and a parser fed
# attacker-controlled bytes is an attack surface no key hygiene fixes.
#
# ⚠️ ONE object, not two. Separately-fetched payload and signature were the
# original design and were wrong: a CDN caches them independently, so a new
# payload can be served beside an old signature — which verifies as TAMPERED
# and makes ordinary staleness indistinguishable from an attack.
#
# Everything instructional — SERIAL included — is inside the ciphertext.
set -euo pipefail

key=${1:?signing key}; cert=${2:?recipient cert}; node=${3:?node id}; serial=${4:?serial}; shift 4
[ -r "$key" ]  || { echo "signing key not readable: $key" >&2; exit 1; }
[ -r "$cert" ] || { echo "recipient cert not readable: $cert" >&2; exit 1; }
case "$serial" in ''|*[!0-9]*) echo "serial must be a plain integer" >&2; exit 1 ;; esac

dir="nodes/$node"; mkdir -p "$dir"; out="$dir/config"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

{ printf 'SERIAL=%s\n' "$serial"; for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$tmp/clear"

# ⚠️ The published serial is now ENCRYPTED, so it cannot be read back from the
# repo to check that it advances. It is tracked in a cleartext ledger instead —
# which carries no instruction, only a number, and exists so the operator is
# warned before publishing something the node will refuse as stale.
ledger="$dir/.serial"
if [ -f "$ledger" ]; then
  prev=$(cat "$ledger")
  if [ "$serial" -le "$prev" ]; then
    echo "serial $serial is not greater than the published $prev — the node would refuse it as stale" >&2
    exit 1
  fi
fi

openssl cms -encrypt -binary -aes-256-cbc -recip "$cert" -in "$tmp/clear" -outform PEM -out "$tmp/enc"
if grep -q '^-----BEGIN SSH SIGNATURE-----$' "$tmp/enc"; then
  echo "ciphertext contains the signature delimiter — refusing to build an ambiguous object" >&2; exit 1
fi
ssh-keygen -Y sign -f "$key" -n file "$tmp/enc" >/dev/null 2>&1
cat "$tmp/enc" "$tmp/enc.sig" > "$out"
printf '%s\n' "$serial" > "$ledger"

echo "wrote $out — serial $serial (ENCRYPTED), $(wc -c < "$out") bytes"
echo "  cleartext in the object: $(grep -c 'SERIAL=\|REPORT=\|RENDEZVOUS=' "$out" || true) instruction lines (must be 0)"
