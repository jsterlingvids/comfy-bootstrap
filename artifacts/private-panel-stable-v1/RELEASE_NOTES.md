# Private ComfyUI Panel — Stable v1.0.0

This release publishes Josh's private server-hosted ComfyUI Panel → Hermes control plane as a stable, Hermes-operated Vast.ai launch template.

## Immutable runtime

- Panel commit: `a3e75aa6bb836d4034a20fb94eb4792ee91b1606`
- Panel bundle SHA-256: `fa71e450599ee63b7c0de3e87c9c9fa965da00f0c6de16b3c3d8d43c46a31b9d`
- Bootstrap runtime commit: `82088809685b6f150808aced3adfe7f943874d77`
- Stable private Vast template: `534171`
- Template hash after stable-name promotion: `aa3398addd01913455e7ebd3fadf680f`
- Image: `vastai/comfy:v0.30.0-cuda-13.2-py312`
- Recommended disk: `250 GB` (provider template-creation/readback evidence)

The Panel is distributed as an immutable Git bundle vendored in this pushed bootstrap repository. This release does **not** claim publication of a standalone Panel source repository.

## Fresh R14 acceptance

Fresh instance `47549423` passed:

- real non-interactive SSH and secure `authorized_keys` ownership/mode
- exact detached bootstrap and Panel provenance with clean Panel checkout
- loopback-only ComfyUI plus private Tailnet routing
- public-IP `8443` unreachable
- Agent first-frame rendering
- visible **Connect → connected → Reconnect → connected**
- fresh split WSS endpoint/subprotocol capability reacquisition
- no loopback/local-`npx` fallback
- visible CivitAI explorer and bounded `flux` search returning results
- one active Panel route, zero pending commands
- repeatedly empty queue

No inference was performed during release acceptance.

## Lifecycle lineage

The accepted R12 lineage passed browser Save As → list → save → close → strict reopen, exact workflow UUID/content/canvas fencing, one reversible Reroute edit, browser-native Ctrl+Z, and exact zero-node restoration. R14's subsequent source delta is restricted to secure reconnect readback/race fencing and its tests; the lifecycle/Undo sequence was not repeated on R14.

## Security properties

- ComfyUI binds to loopback only
- no Funnel or public ComfyUI mapping
- no static bridge capability in template/environment
- capability travels only as an ephemeral WebSocket subprotocol
- HTTPS fails closed without a valid private advertised route
- Reconnect is latest-wins and cannot override explicit Disconnect
- bootstrap rejects Panel commit/checksum override drift

## Daily use

Ask Hermes:

> **Launch my Comfy workspace**

Hermes will select a compatible on-demand Vast host, launch stable template `534171`, prove SSH and immutable runtime provenance, wait for ComfyUI/Panel readiness, establish the private route, advertise a fresh in-memory capability, and return the private Panel URL.

## Rollback

Preserved rollback template: `532775`.

If the stable template fails a required gate, stop/destroy the disposable candidate and use the rollback template. Do not mutate or delete the rollback template during routine launches.

## Scope note

LTXVideo/Kornia compatibility is not part of this Panel publication gate and can be handled separately when that workflow lane matters.
