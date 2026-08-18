#!/usr/bin/env bash
# Trust-tier guard for the PUBLIC GitHub mirror. Shared by the local pre-push
# hook (scripts/git-hooks/pre-push) and the GitHub Actions backstop
# (.github/workflows/trust-tier-guard.yaml) so both enforce identical rules.
#
# Two checks:
#   1. infra IDs in MESSAGES      — message-denylist.txt over the commit range
#   2. external leaks in CONTENT  — content-denylist.txt over added lines
#   3. SECRETS in content         — gitleaks (optional; used when available)
#
# Usage:
#   scan.sh <git-range>     e.g. scan.sh origin/main..HEAD   (range mode)
#   scan.sh                 no range → whole-tree content scan, no messages
#
# Exit 0 = clean, 1 = at least one finding (with detail on stderr).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
DIR="$ROOT/scripts/trust-tier"
RANGE="${1:-}"
rc=0

# Denylist entries are base64-encoded (so the forbidden identifiers don't sit in
# plaintext in this public tree). Strip comments/blanks, then decode each line
# back to its grep -E pattern.
load_patterns() {
  grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | while IFS= read -r b64; do
    printf '%s' "$b64" | base64 -d 2>/dev/null && printf '\n'
  done
}

note()  { printf '%s\n' "$*" >&2; }
fail()  { printf '✗ %s\n' "$*" >&2; rc=1; }

# ── 1. commit messages vs message-denylist (range mode only) ─────────────────
if [ -n "$RANGE" ]; then
  note "→ commit-message identifier scan ($RANGE)…"
  msgs="$(git -C "$ROOT" log --no-merges --format='%H%n%B' "$RANGE" 2>/dev/null || true)"
  if [ -n "$msgs" ]; then
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      hit="$(printf '%s' "$msgs" | grep -Eo "$pat" | head -1 || true)"
      [ -n "$hit" ] && fail "commit message contains internal identifier '$hit' (pattern: $pat)"
    done < <(load_patterns "$DIR/message-denylist.txt")
  fi
fi

# ── 2. file content vs content-denylist ──────────────────────────────────────
note "→ content external-leak scan…"
# Added lines in range mode; whole tracked tree otherwise.
# Exclude SOPS payloads and scripts/trust-tier/ itself (the denylists document
# the very patterns we scan for — scanning them would produce false positives).
excludes=(
  ':(exclude)*.sops.yaml'
  ':(exclude)*.sops.yml'
  ':(exclude)*.sops.json'
  ':(exclude)scripts/trust-tier/*'
)
if [ -n "$RANGE" ]; then
  added="$(git -C "$ROOT" diff "$RANGE" -- . "${excludes[@]}" \
            | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
else
  added="$(git -C "$ROOT" grep -hI -nE '.' -- . "${excludes[@]}" 2>/dev/null || true)"
fi
if [ -n "$added" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    hit="$(printf '%s' "$added" | grep -Eo "$pat" | head -1 || true)"
    [ -n "$hit" ] && fail "tracked content contains sensitive identifier '$hit' (pattern: $pat)"
  done < <(load_patterns "$DIR/content-denylist.txt")
fi

# ── 3. gitleaks (secrets) — optional ────────────────────────────────────────
if command -v gitleaks >/dev/null 2>&1; then GL=(gitleaks)
elif command -v mise >/dev/null 2>&1 && mise exec -- gitleaks version >/dev/null 2>&1; then GL=(mise exec -- gitleaks)
else GL=(); fi

if [ ${#GL[@]} -gt 0 ]; then
  note "→ gitleaks (secrets)…"
  glargs=(detect --no-banner --redact --source "$ROOT")
  [ -f "$ROOT/.gitleaks.toml" ] && glargs+=(--config "$ROOT/.gitleaks.toml")
  if [ -n "$RANGE" ]; then
    "${GL[@]}" "${glargs[@]}" --log-opts="$RANGE" || fail "gitleaks found secret material in $RANGE"
  else
    "${GL[@]}" "${glargs[@]}" || fail "gitleaks found secret material in the worktree"
  fi
else
  note "→ gitleaks not found — skipping secret scan (install for full coverage)"
fi

if [ "$rc" -eq 0 ]; then note "✓ trust-tier guard clean"; fi
exit "$rc"
