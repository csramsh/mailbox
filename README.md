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
recipients/<node-id>.pub      public encryption recipient for that node
nodes/<node-id>/config        payload
nodes/<node-id>/config.sig    detached signature over it
```

Node ids are opaque and derived from the node's own public key. **Directory
names in a public repository are public even when file contents are not**, so
they deliberately encode nothing about a deployment.

## ⚠️ Current payloads are NOT yet encrypted

Signing is implemented; encryption is not. Until it is, **every payload here
must be inert** — placeholders only, and nothing that identifies a host, an
address, a network or a location. Do not commit a real endpoint to this
repository before encryption lands.
