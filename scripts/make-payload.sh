#!/usr/bin/env bash
# Build a self-contained signed payload object.
#
#   scripts/make-payload.sh <signing-key> <node-id> <serial> [key=value ...]
#
# The object is the payload followed by its armored signature, in ONE file.
# Two separate files were tried first and were wrong: raw.githubusercontent.com
# caches each object independently, so a new payload could be served beside an
# old signature — a combination that verifies as TAMPERED, making cache skew
# indistinguishable from an attack.
set -euo pipefail

key=${1:?signing key path}; node=${2:?node id}; serial=${3:?serial}; shift 3
[ -r "$key" ] || { echo "signing key not readable: $key" >&2; exit 1; }
case "$serial" in ''|*[!0-9]*) echo "serial must be a plain integer" >&2; exit 1 ;; esac

dir="nodes/$node"; mkdir -p "$dir"
out="$dir/config"
tmp=$(mktemp); trap 'rm -f "$tmp" "$tmp.sig"' EXIT

{
  printf 'SERIAL=%s\n' "$serial"
  for kv in "$@"; do printf '%s\n' "$kv"; done
} > "$tmp"

# ⚠️ A payload containing the delimiter would shift the split. It cannot help an
# attacker (the bytes before their marker would still need a valid signature),
# but it WOULD break a legitimate payload, so refuse it at build time.
if grep -q '^-----BEGIN SSH SIGNATURE-----$' "$tmp"; then
  echo "payload contains the signature delimiter — refusing to build an ambiguous object" >&2
  exit 1
fi

# ⚠️ Serial must move forward, or the node refuses its own operator's update as
# stale. Checked here because the node cannot tell an honest mistake from a
# replay, and should not have to.
if [ -f "$out" ]; then
  prev=$(sed -n 's/^SERIAL=\([0-9][0-9]*\)$/\1/p' "$out" | head -n1 || true)
  if [ -n "${prev:-}" ] && [ "$serial" -le "$prev" ]; then
    echo "serial $serial is not greater than the published $prev — the node would refuse it as stale" >&2
    exit 1
  fi
fi

ssh-keygen -Y sign -f "$key" -n file "$tmp" >/dev/null 2>&1
cat "$tmp" "$tmp.sig" > "$out"

echo "wrote $out (serial $serial, $(wc -c < "$out") bytes)"
