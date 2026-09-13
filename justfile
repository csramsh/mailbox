# mailbox — publish signed, encrypted config payloads for field nodes.
#
# ⚠️ NODE OPERATIONS MOVED TO THE FLASH KIT (2026-09-13). This justfile was
# written for ONE node: NODE_ID, its relay bind and its relay user all came from
# .env. The fleet now has several, their ids and ports live in the operator's
# secrets store, and every node uses the same relay account. So instructions to
# a node are published by csramsh/nodes:
#
#     dist/flash.sh mailbox <node> report [all|slot|uptime|version|kernel|uname]
#     dist/flash.sh mailbox <node> backhaul on|off [--route b]
#     dist/flash.sh mailbox <node> send KEY=VALUE...
#
# The kit still publishes THROUGH this repo: scripts/make-payload.sh builds the
# object and `just publish` (below) commits and pushes it, with NODE_ID given
# for that run. .env now holds only what the fleet shares: BACKHAUL_HOST,
# BACKHAUL_PORT, BACKHAUL_B_HOST, BACKHAUL_B_PORT.
#
# ⚠️ WHAT THIS TOOLING STILL WILL NOT DO
#   1. It never pushes as a side effect of building.
#   2. It never invents a serial. The ledger is the authority; `next` is
#      ledger+1, and make-payload.sh refuses anything not strictly greater.

set dotenv-load := true
set positional-arguments

node     := env_var_or_default('NODE_ID', '')

# Where node operations went.
default: _moved

# ── moved: these acted on the single NODE_ID in .env ──────────────────────

[doc('Moved: dist/flash.sh mailbox <node> ... in csramsh/nodes')]
menu: _moved
[doc('Moved: dist/flash.sh mailbox <node> report <what>')]
report *args: _moved
[doc('Moved: dist/flash.sh mailbox <node> backhaul on [--route b]')]
backhaul-on *args: _moved
[doc('Moved: dist/flash.sh mailbox <node> backhaul off [--route b]')]
backhaul-off *args: _moved
[doc('Moved: dist/flash.sh mailbox <node> send KEY=VALUE...')]
send *args: _moved
[doc('Moved: the ledger is nodes/<id>/.serial; ids are in the secrets store')]
status: _moved

_moved:
    #!/usr/bin/env bash
    echo "node operations moved to csramsh/nodes — one command per named node:" >&2
    echo "    dist/flash.sh mailbox <node> report [all|slot|uptime|version|kernel|uname]" >&2
    echo "    dist/flash.sh mailbox <node> backhaul on|off [--route b]" >&2
    echo "    dist/flash.sh mailbox <node> send KEY=VALUE..." >&2
    exit 2

# ── publishing: what the kit calls, with NODE_ID set for the run ──────────

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

[doc('Print the next serial (ledger + 1). Never guesses; the ledger is the authority.')]
next:
    #!/usr/bin/env bash
    set -euo pipefail
    f="nodes/{{node}}/.serial"
    if [ -r "$f" ]; then echo $(( $(cat "$f") + 1 )); else echo 1; fi

[doc('Check .env is untracked and ignored in this PUBLIC repo.')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    rc=0
    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
      echo "✗ .env is TRACKED in a PUBLIC repo — git rm --cached .env" >&2; rc=1
    else echo "✓ .env is not tracked"; fi
    git check-ignore -q .env && echo "✓ .env is gitignored" || { echo "✗ .env is NOT gitignored" >&2; rc=1; }
    exit $rc
