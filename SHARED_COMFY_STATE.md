# Shared Comfy State Contract

`COMFY_STATE_ROOT` is the provider-neutral Backblaze B2 root used by both Vast and Runpod.

## Required configuration

Set the **same** value on both templates. The current canonical state is the established Vast root:

```text
COMFY_STATE_ROOT=myb2:comfy-bootstrap
```

Runpod needs a distinct B2 application key scoped to the existing `comfy-bootstrap` bucket; Vast can retain its existing bucket-scoped key. This preserves the existing Vast workflows/panel snapshot without a migration.

## Shared state

- `workflows/` — saved ComfyUI workflows
- `custom_nodes/` — source snapshot, excluding Git metadata, node_modules, and Python caches
- `custom_nodes_manifest.txt` — canonical upstream repository list
- `settings/` — ComfyUI user settings, Manager settings, and `extra_model_paths.yaml`

## Deliberately not shared

- model files, checkpoints, LoRAs, outputs, or input media
- SSH keys and provider credentials
- Codex / ChatGPT authentication
- provider-specific bootstrap code, runtime paths, or image configuration

`CODEX_STATE_ROOT` remains provider-local by default even when `COMFY_STATE_ROOT` is shared.

## Restore and backup order

1. Bootstrap restores workflows and settings before ComfyUI starts.
2. It restores the custom-node snapshot; if unavailable, it falls back to the manifest.
3. It verifies node availability against restored workflows.
4. The autosave snapshot uploads the same workflows, settings, node source, and regenerated manifest.

Only snapshot a fully healthy, idle ComfyUI instance. Avoid making state changes concurrently on Vast and Runpod: the most recent validated snapshot is authoritative.
