# mailbox — build and publish signed config payloads for field nodes.
#
# Wraps scripts/make-payload.sh so the day-to-day loop is a menu rather than a
# remembered command line. Operator config lives in .env (gitignored); see
# .env.example.
#
# ⚠️ TWO THINGS THIS TOOLING WILL NOT DO FOR YOU
#   1. It never pushes as a side effect. Building a payload and publishing it
#      are separate verbs, because publishing burns a serial permanently and
#      costs a 5-minute CDN wait to correct.
#   2. It never invents a serial. The ledger is the authority; `next` is
#      ledger+1, and make-payload.sh refuses anything not strictly greater.

set dotenv-load := true
set positional-arguments

payload  := "scripts/make-payload.sh"
node     := env_var_or_default('NODE_ID', '')
signkey  := env_var_or_default('SIGNING_KEY', '')

# Show the menu.
default: menu

# ── the menu ──────────────────────────────────────────────────────────────

[doc('Interactive chooser — pick an action, it builds the payload (does not push).')]
menu:
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{justfile()}}" _require-env
    routes="${BACKHAUL_ROUTES:-}"
    # ⚠️ The COMMAND is a real field, tab-separated from its description, and is
    # recovered with `cut -f1`. An earlier version rendered one aligned column
    # and re-parsed the display text with awk — which silently turned the
    # primary route's "backhaul-on / PRIMARY route ON" into
    # `backhaul-on PRIMARY`, i.e. the description's first word arriving as a
    # route name. Never reconstruct an instruction from the text you drew for a
    # human; carry it separately.
    entry() { printf '%-24s\t%s\n' "$1" "$2"; }
    {
      entry "report all"     "the usual one-liner: kernel, slot, image, uptime"
      entry "report slot"    "which RAUC slot is running"
      entry "report uptime"  "minutes up"
      entry "report version" "/etc/version"
      entry "report kernel"  "uname -r"
      entry "report uname"   "uname -a"
      entry "backhaul-on"    "PRIMARY route ON  (endpoint from .env)"
      entry "backhaul-off"   "PRIMARY route OFF"
      for r in $routes; do
        entry "backhaul-on $r"  "route '$r' ON  (endpoint from .env)"
        entry "backhaul-off $r" "route '$r' OFF"
      done
      entry "status"  "ledger serial, node id, what is staged"
      entry "publish" "COMMIT + PUSH what is already built"
    } | fzf --prompt="mailbox > " --height=60% --border --delimiter='\t' \
            --header="serial $(just --justfile "{{justfile()}}" next) will be used · nothing is pushed until you choose publish" \
      | cut -f1 \
      | xargs -r just --justfile "{{justfile()}}"

# ── the actions ───────────────────────────────────────────────────────────

[doc('Ask the node for a read-only report. WHAT: all|slot|uptime|version|kernel|uname')]
report what='all':
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{what}}" in
      all|slot|uptime|version|kernel|uname) : ;;
      *) echo "unknown report '{{what}}' — the node refuses anything outside the fixed vocabulary" >&2
         echo "valid: all slot uptime version kernel uname" >&2; exit 1 ;;
    esac
    just --justfile "{{justfile()}}" _build "REPORT={{what}}"

[doc('Turn a backhaul route ON. ROUTE empty = the primary; otherwise the instance name.')]
backhaul-on route='':
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{justfile()}}" _require-env
    r="{{route}}"
    if [ -z "$r" ]; then
      host="${BACKHAUL_HOST:-}"; user="${BACKHAUL_USER:-}"
      port="${BACKHAUL_PORT:-22}"; bind="${BACKHAUL_BIND:-}"
      inst=""
    else
      # ⚠️ Validated here as well as on the node. The node refuses a bad name,
      # but a refusal costs a serial and a 5-minute wait to discover.
      case "$r" in
        [a-z0-9]*) : ;;
        *) echo "route '$r' must start with a lowercase letter or digit" >&2; exit 1 ;;
      esac
      case "$r" in *[!a-z0-9-]*) echo "route '$r': only a-z, 0-9 and - are allowed" >&2; exit 1 ;; esac
      [ "${#r}" -le 16 ] || { echo "route '$r' is longer than 16 characters" >&2; exit 1; }
      u=$(printf '%s' "$r" | tr 'a-z-' 'A-Z_')
      eval "host=\${BACKHAUL_${u}_HOST:-}"
      eval "user=\${BACKHAUL_${u}_USER:-}"
      eval "port=\${BACKHAUL_${u}_PORT:-22}"
      eval "bind=\${BACKHAUL_${u}_BIND:-}"
      inst="$r"
    fi
    miss=""
    [ -n "$host" ] || miss="$miss HOST"
    [ -n "$user" ] || miss="$miss USER"
    [ -n "$bind" ] || miss="$miss BIND"
    if [ -n "$miss" ]; then
      echo "missing in .env for route '${inst:-<primary>}':$miss" >&2
      echo "the node would refuse a half-specified endpoint — fill .env in first" >&2
      exit 1
    fi
    args="BACKHAUL=on BACKHAUL_HOST=$host BACKHAUL_USER=$user BACKHAUL_PORT=$port BACKHAUL_BIND=$bind"
    [ -n "$inst" ] && args="$args BACKHAUL_INSTANCE=$inst"
    # shellcheck disable=SC2086
    just --justfile "{{justfile()}}" _build $args

[doc('Turn a backhaul route OFF. ROUTE empty = the primary. Needs no endpoint.')]
backhaul-off route='':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{route}}" ]; then
      just --justfile "{{justfile()}}" _build "BACKHAUL=off" "BACKHAUL_INSTANCE={{route}}"
    else
      just --justfile "{{justfile()}}" _build "BACKHAUL=off"
    fi

[doc('Escape hatch: pass raw KEY=VALUE pairs straight through. You are on your own.')]
send *args:
    #!/usr/bin/env bash
    set -euo pipefail
    [ $# -gt 0 ] || { echo "nothing to send — pass KEY=VALUE pairs" >&2; exit 1; }
    just --justfile "{{justfile()}}" _build "$@"

# ── publishing ────────────────────────────────────────────────────────────

[doc('Commit and push the built payload. THIS is the step that reaches the node.')]
publish message='':
    #!/usr/bin/env bash
    set -euo pipefail
    # ⚠️ THE GUARD THAT MATTERS. This repo is public; .env holds an endpoint.
    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
      echo "REFUSING: .env is TRACKED by git in a PUBLIC repo." >&2
      echo "  git rm --cached .env   # then confirm .gitignore covers it" >&2
      exit 1
    fi
    if git diff --cached --name-only | grep -qx '.env'; then
      echo "REFUSING: .env is STAGED. Unstage it before publishing." >&2
      exit 1
    fi
    if git status --porcelain -- "nodes/{{node}}/config" | grep -q .; then :; else
      echo "nothing to publish — no change to nodes/{{node}}/config" >&2
      echo "build something first (just menu), or the payload is already pushed" >&2
      exit 1
    fi
    serial=$(cat "nodes/{{node}}/.serial")
    msg="{{message}}"
    [ -n "$msg" ] || msg="config({{node}}): serial $serial"
    git add -A -- "nodes/{{node}}" recipients
    git commit -m "$msg"
    git push
    echo
    echo "⚠️  WAIT ~5 MINUTES before expecting the node to see this."
    echo "    raw.githubusercontent.com caches for 300 s and no cache-buster works."
    echo "    Fetched too early, the node gets the PREVIOUS object and correctly"
    echo "    refuses it as a replay — CDN staleness and an attack look identical"
    echo "    from its side."

# ── inspection ────────────────────────────────────────────────────────────

[doc('Ledger serial, node id, and what is staged.')]
status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "node:          {{node}}"
    echo "ledger serial: $(cat "nodes/{{node}}/.serial" 2>/dev/null || echo '(none yet)')"
    echo "next serial:   $(just --justfile "{{justfile()}}" next)"
    echo "signing key:   ${SIGNING_KEY:-(unset)}"
    echo "recipient:     $(just --justfile "{{justfile()}}" _recipient)"
    echo "primary route: ${BACKHAUL_USER:-?}@${BACKHAUL_HOST:-?}:${BACKHAUL_PORT:-22} bind ${BACKHAUL_BIND:-?}"
    echo "extra routes:  ${BACKHAUL_ROUTES:-(none)}"
    echo
    echo "--- working tree ---"
    git status --short || true

[doc('Print the next serial (ledger + 1). Never guesses; the ledger is the authority.')]
next:
    #!/usr/bin/env bash
    set -euo pipefail
    f="nodes/{{node}}/.serial"
    if [ -r "$f" ]; then echo $(( $(cat "$f") + 1 )); else echo 1; fi

[doc('Validate .env and the preconditions, without building anything.')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{justfile()}}" _require-env
    rc=0
    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
      echo "✗ .env is TRACKED in a PUBLIC repo — git rm --cached .env" >&2; rc=1
    else echo "✓ .env is not tracked"; fi
    git check-ignore -q .env && echo "✓ .env is gitignored" || { echo "✗ .env is NOT gitignored" >&2; rc=1; }
    [ -r "${SIGNING_KEY:-/nonexistent}" ] && echo "✓ signing key readable" || { echo "✗ signing key unreadable: ${SIGNING_KEY:-unset}" >&2; rc=1; }
    r=$(just --justfile "{{justfile()}}" _recipient)
    [ -r "$r" ] && echo "✓ recipient cert readable ($r)" || { echo "✗ recipient cert unreadable: $r" >&2; rc=1; }
    command -v fzf >/dev/null && echo "✓ fzf present (menu works)" || echo "· fzf absent — recipes work, 'just menu' will not"
    exit $rc

# ── internals ─────────────────────────────────────────────────────────────

_recipient:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${RECIPIENT:-}" ]; then echo "$RECIPIENT"; else echo "recipients/{{node}}.crt"; fi

_require-env:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f .env ]; then
      echo "no .env — copy .env.example and fill it in:" >&2
      echo "  cp .env.example .env && \$EDITOR .env" >&2
      exit 1
    fi
    [ -n "{{node}}" ]    || { echo "NODE_ID is unset in .env" >&2; exit 1; }
    [ -n "{{signkey}}" ] || { echo "SIGNING_KEY is unset in .env" >&2; exit 1; }

# Build a payload at the next serial. Shows what was built; never pushes.
_build *args:
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{justfile()}}" _require-env
    serial=$(just --justfile "{{justfile()}}" next)
    recip=$(just --justfile "{{justfile()}}" _recipient)
    echo "building serial $serial for node {{node}}:"
    for a in "$@"; do echo "    $a"; done
    echo
    "{{payload}}" "${SIGNING_KEY}" "$recip" "{{node}}" "$serial" "$@"
    echo
    echo "built, NOT published. Review then:  just publish"
