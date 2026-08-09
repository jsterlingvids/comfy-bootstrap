# Shared Comfy State Contract

`COMFY_STATE_ROOT` is the provider-neutral Backblaze B2 root consumed by Vast and RunPod. It is an immutable-generation store, not a mutable directory mirror.

## Layout and authority

```text
COMFY_STATE_ROOT/
|- generations/
|  `- <YYYYMMDDTHHMMSSZ-12hex>/
|     |- workflows/
|     |- settings/
|     |- custom_nodes/
|     |- custom_nodes_manifest.txt
|     `- snapshot.manifest.json
`- snapshot.complete.json
```

A generation is authoritative only when `snapshot.complete.json` has the exact supported schema, names a valid generation ID, and carries the SHA-256 of that generation's valid manifest. Readers verify the manifest and every staged surface before transactional activation. Missing, malformed, partial, tampered, symlinked, or unexpected content leaves live state unchanged.

The completion marker is written last, only after remote object-set/content verification. Generation prefixes are never overwritten.

## Shared surfaces

- workflows
- selected ComfyUI and Manager settings
- custom-node source, excluding Git metadata, caches, `node_modules`, and MCP Panel
- the verified generation's custom-node repository manifest

The repository's curated required-node manifest remains the baseline. A verified generation manifest may add repositories. An unverified mutable B2 manifest is not authoritative.

## Deliberately not shared

- MCP Panel (preserved locally and pinned by bootstrap)
- model files, checkpoints, LoRAs, outputs, or input media
- SSH keys, B2 credentials, Tailscale keys, Hermes bridge capability URLs, or provider credentials
- Codex / ChatGPT authentication
- provider-specific bootstrap code, runtime paths, or image configuration

`CODEX_STATE_ROOT` is provider-local by default:

```text
myb2:comfy-provider-local/<provider>/codex-home
```

Codex state is never included in shared generations. A designated writer may separately opt into provider-local Codex persistence with `ENABLE_CODEX_SNAPSHOT=1`.

## Reader and writer roles

All instances, including Vast, default to readers (`SNAPSHOT_WRITER=0` by absence). Readers restore verified generations and never autosave.

Publication requires both:

```text
SNAPSHOT_WRITER=1
SNAPSHOT_WRITER_ID=<unique stable writer identity>
```

Use one writer at a time. For a handoff, stop/revoke the old writer first, verify it no longer publishes, then authorize the new writer with a different identity. Templates/configuration must not enable publication by default.

The writer checks live Comfy health and an idle queue before and after freezing, publishes to a unique generation prefix, verifies remote content, and updates the completion marker last. Interrupted or corrupt publication is invisible to readers.

## Legacy migration

The old mutable layout at `COMFY_STATE_ROOT/{workflows,settings,custom_nodes}` is disabled by default. Set `ALLOW_LEGACY_SNAPSHOT=1` only for an intentional one-time migration when no completed generation marker exists. Legacy custom nodes are downloaded into isolation and safely activated; unverified legacy manifests do not override the required repository baseline. Remove the flag after a valid generation is published.

## Runtime acceptance

Bootstrap requires a runtime-provided `HERMES_PANEL_BRIDGE_URL` with a `wss://` endpoint, non-empty fragment capability, and no query string. It advertises that external durable Hermes companion endpoint to pinned MCP Panel and verifies readback without logging or persisting the URL. Vast never installs, starts, monitors, or manages the bridge; it is re-advertised after an idle restart.

`WORKFLOW_VALIDATION_POLICY` defaults to `required`:

- `/object_info` fetch/JSON failures are fatal.
- malformed workflow JSON is fatal.
- every class listed in `REQUIRED_RUNTIME_NODES` must exist in live `/object_info`.
- other runtime-missing nodes are reported but remain optional under `required`; use `strict` to make all runtime-missing nodes fatal.

The clean Vast base image does not carry the approved Torch stack. Bootstrap therefore establishes Torch `2.9.1+cu130`, torchvision `0.24.1+cu130`, torchaudio `2.9.1+cu130`, SageAttention `1.0.6`, CUDA identity `13.0`, and live GPU availability before reading B2 generation state. It then checks that exact identity around every mutable dependency hook and again before live node acceptance; any later drift is fatal.
