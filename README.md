# ComfyUI Bootstrap for Vast.ai

This repository bootstraps the existing ComfyUI installation in `vastai/comfy`, preserves the image's runtime and Tailscale behavior, and consumes shared state as verified **immutable generations**. Vast is a snapshot reader by default.

## Safety model

- `COMFY_STATE_ROOT` contains immutable `generations/<generation-id>/` trees and one authority pointer, `snapshot.complete.json`.
- A generation is downloaded to an isolated stage, checked against its manifest, and activated transactionally. Malformed, partial, unexpected, or tampered content never replaces live state.
- The old mutable root is ignored unless `ALLOW_LEGACY_SNAPSHOT=1` is explicitly set for a one-time migration.
- Vast does not autosave unless both `SNAPSHOT_WRITER=1` and a unique `SNAPSHOT_WRITER_ID` are supplied. Do not authorize two providers/instances at once; stop the old writer before handing publication to a new one.
- Codex state is provider-local by default at `myb2:comfy-provider-local/vast/codex-home`. Codex/provider credentials are not part of shared Comfy generations.
- The MCP Panel is not mutable shared state. Bootstrap preserves and pins `comfyui-mcp-panel` at `3f939750ddc46b55713f147dd680d72f523a4a16` and disables Panel backend autospawn.
- The Hermes bridge is an external companion service on the durable local Hermes host (currently `openclawv03.tail…:9177`), not a process inside a disposable Vast GPU box. Vast only advertises its runtime-provided endpoint to the MCP Panel; it never installs, starts, monitors, or persists a bridge.

## Required configuration

Set before `onstart.sh` runs:

- `B2_ACCOUNT_ID`
- `B2_APP_KEY`
- `HERMES_PANEL_BRIDGE_URL` — required runtime-provided `wss://` URL with a non-empty fragment capability and no query string. Bootstrap advertises it to Panel and verifies readback without logging or persisting it. It must target the external durable Hermes companion service.

Common optional configuration:

- `COMFY_STATE_ROOT` (default `myb2:comfy-bootstrap`)
- `CODEX_STATE_ROOT` (default provider-local Vast path above)
- `COMFY_ROOT` (only for a nonstandard ComfyUI location)
- `REQUIRED_RUNTIME_NODES` (comma/newline-separated node classes that must appear in live `/object_info`)
- `WORKFLOW_VALIDATION_POLICY=required` (default; malformed workflow JSON, `/object_info` failure, and required-node absence are fatal; other runtime-missing nodes are reported but optional)
- `ALLOW_LEGACY_SNAPSHOT=1` (temporary, explicit migration only)
- `TAILSCALE_ENABLED=1`, `TAILSCALE_PROVIDER=vast`, and `TAILSCALE_AUTH_KEY` for private Tailnet ingress

The clean `vastai/comfy:v0.27.0-cuda-12.9-py312` base does not provide the approved Torch stack. Before B2 selection or any mutable state restore, bootstrap installs Torch `2.9.1+cu130`, torchvision `0.24.1+cu130`, torchaudio `2.9.1+cu130`, and SageAttention `1.0.6`, then immediately verifies CUDA `13.0` and GPU availability. All later dependency hooks remain constrained by that established identity and runtime drift is fatal. Existing Comfy reuse also requires the expected executable, Comfy root, configured port, and loopback listener.

## Normal startup order

1. Discover the existing Vast ComfyUI path, establish and verify the exact approved CUDA 13 runtime, then configure bounded B2 access.
2. Select the completed generation, verify it, and transactionally activate workflows/settings/custom nodes; otherwise retain the local baseline.
3. Restore only an explicitly allowed legacy snapshot when migrating.
4. Reconcile the verified generation manifest with the required repository baseline.
5. Preserve/pin MCP Panel and ensure Manager v4.
6. Start or safely reuse loopback ComfyUI, start private Tailscale ingress, then advertise/read back the external Hermes companion's WSS capability URL.
7. Run constrained requirements/install hooks, recheck the exact runtime, restart only while idle, and re-advertise the bridge.
8. Validate live node acceptance under the required policy.
9. Start autosave only on an explicitly authorized writer; readers log that autosave is disabled.

## On-start setup

```bash
#!/usr/bin/env bash
set -e
mkdir -p /workspace
apt-get update && apt-get install -y git
cd /workspace
if [ ! -d comfy-bootstrap/.git ]; then
  git clone https://github.com/jsterlingvids/comfy-bootstrap.git
else
  git -C comfy-bootstrap pull --ff-only
fi
cd /workspace/comfy-bootstrap
bash onstart.sh
```

## Publishing a generation (designated writer only)

Readers should not run `save_snapshot.sh`. During an explicit single-writer handoff:

```bash
export SNAPSHOT_WRITER=1
export SNAPSHOT_WRITER_ID=vast-primary-unique-id
cd /workspace/comfy-bootstrap
bash save_snapshot.sh
```

The writer requires healthy, idle ComfyUI before and after freezing; excludes Git metadata, caches, `node_modules`, and MCP Panel; creates a unique immutable generation; refuses an existing prefix; verifies the complete remote object set/bytes; and writes `snapshot.complete.json` last. Provider-local Codex files are also skipped unless `ENABLE_CODEX_SNAPSHOT=1` is explicitly enabled.

## Repository layout

```text
comfy-bootstrap/
|- onstart.sh
|- save_snapshot.sh
|- snapshot_contract.py
|- snapshot_activate.py
|- workflow_validation.py
|- custom_nodes_manifest.txt
|- generate_manifest.sh
|- SHARED_COMFY_STATE.md
`- tests/
```

## Verification

```bash
bash -n onstart.sh save_snapshot.sh generate_manifest.sh lib/tailscale-private-comfy.sh
python3 -m unittest discover -s tests -p 'test_*.py' -q
python3 -m py_compile snapshot_contract.py snapshot_activate.py workflow_validation.py
```
