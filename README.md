# mailbox

Signed configuration payloads for unattended field nodes.

Each node fetches its own directory over plain HTTPS, verifies the signature
against a trust root **baked into its firmware image**, and refuses anything
that does not verify or is not newer than what it has already accepted.

## Why this repo is public

Because the node then carries **no credential**. There is no token to leak,
rotate or expire, and no authentication failure mode to debug on a device that
is powered for a few minutes at a time and may be physically out of reach.

That is only safe because of the two properties below.

## Push access is not device control

Payloads are **signed**. A push to this repository produces bytes; a node obeys
only what verifies against a signing key that never leaves the operator's
workstation and is not present in this repository, in CI, or on any node.

Encryption stops a leak. A signature stops a takeover. Both matter, and only
the signature decides what a device will act on.

## Replay is refused, not just forgery

A signature proves authorship, never freshness — a CDN can serve a stale object
and an old commit can be pinned, and both replay something that was genuinely
signed. Every payload therefore carries a `SERIAL`; a node records the highest
it has accepted and refuses anything not **strictly greater**, equal included.

## Layout

```
recipients/<node-id>.crt      public encryption recipient for that node
nodes/<node-id>/config        the payload: CMS ciphertext with its SSH signature appended
nodes/<node-id>/.serial       cleartext ledger: the last serial published (a number, no instruction)
```

One object per node, replaced by each new serial; older serials exist only in
git history. The signature is appended rather than a separate `config.sig`:
a CDN caches two files independently, and a new payload served beside an old
signature verifies as tampered.

Node ids are opaque and derived from the node's own public key. **Directory
names in a public repository are public even when file contents are not**, so
they deliberately encode nothing about a deployment.

## Payloads are encrypted as well as signed

Each object is **encrypt-then-sign**: an openssl CMS envelope addressed to that
node's recipient, with a detached signature over the *ciphertext* appended to
it. A node therefore authenticates **before** it decrypts — a decryptor is a
parser, and a parser fed attacker-controlled bytes is an attack surface no key
hygiene fixes.

Everything instructional is inside the envelope, **including the serial**, so
nothing in this repository states what any device is being told to do. What
remains visible is the node-id directory name (opaque by construction), the
object size, and commit timestamps.

## Publishing to a node

Instructions are published per named node by the flash kit in `csramsh/nodes`,
which keeps node ids and relay ports in the operator's secrets store:

```
dist/flash.sh mailbox <node> report [all|slot|uptime|version|kernel|uname]
dist/flash.sh mailbox <node> backhaul on|off [--route b]
dist/flash.sh mailbox <node> send KEY=VALUE...
```

A node's recipient and first serial are published by `dist/flash.sh card --node
<name>` when its card is written. Retiring a node (`dist/flash.sh retire <id>`)
removes its directory and recipient here; git history keeps them.

The kit publishes through this repo's own tooling: `scripts/make-payload.sh`
builds the object, and `just publish` commits and pushes it.

```
scripts/make-payload.sh <signing-key> <recipient-cert> <node-id> <serial> KEY=VALUE ...
```

It refuses a serial that does not advance, because a node cannot distinguish an
operator's mistake from a replay and should not have to. The gitignored `.env`
holds only what the fleet shares: `BACKHAUL_HOST`, `BACKHAUL_PORT`,
`BACKHAUL_B_HOST`, `BACKHAUL_B_PORT`.
