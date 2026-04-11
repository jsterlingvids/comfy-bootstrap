# ComfyUI Bootstrap for Vast.ai

This repo bootstraps a fresh Vast.ai instance running the `vastai/comfy` image without reinstalling ComfyUI. It restores workflows from Backblaze B2, recreates `custom_nodes` from a manifest, installs each node's Python dependencies, and keeps the instance synced back to B2 with periodic snapshots.

It will auto-detect the ComfyUI install path on startup. If your image uses a custom location, you can also set `COMFY_ROOT` explicitly in Vast.

## What it does

- Restores workflows into the detected ComfyUI `user/default/workflows` directory
- Restores the custom node manifest from B2 when available, otherwise uses the repo-local fallback
- Clones missing custom node repos and fast-forwards existing ones
- Installs every `requirements.txt` found under `/workspace/ComfyUI/custom_nodes`
- Installs the OpenAI Codex CLI so `codex` is available in the shell
- Starts a background autosave loop that runs every 15 minutes and logs to `/workspace/autosave.log`
- Provides a manual snapshot script you can run at any time

## Required environment variables

Set these on the Vast.ai instance before `onstart.sh` runs:

- `B2_ACCOUNT_ID`
- `B2_APP_KEY`
- `COMFY_ROOT` (optional override if ComfyUI is not in a standard location)
- `OPENAI_API_KEY` (optional, if you want Codex CLI ready for API-key auth)

The scripts use those values to configure the `myb2` rclone remote at runtime.

If you want `codex` to work immediately in the shell, either export `OPENAI_API_KEY` on the instance or complete the Codex CLI login flow once after boot.

## Vast.ai on-start setup

Put this in Vast's **On-start Script** field:

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

## Repo layout

```text
comfy-bootstrap/
|- onstart.sh
|- save_snapshot.sh
|- custom_nodes_manifest.txt
|- generate_manifest.sh
`- README.md
```

## First-time bootstrap flow

1. Add your custom node Git repos to `custom_nodes_manifest.txt`, one URL per line.
2. Upload your saved workflows to `myb2:comfy-bootstrap/workflows`, or let the repo start with an empty workflow directory.
3. Launch the Vast.ai instance with `B2_ACCOUNT_ID` and `B2_APP_KEY` set.
4. Let `onstart.sh` restore workflows, sync nodes, install requirements, and start autosave.

## Manual snapshot

Run this on the instance whenever you want an immediate backup:

```bash
cd /workspace/comfy-bootstrap
bash save_snapshot.sh
```

The snapshot script is safe to run repeatedly. It syncs:

- Workflows
- A small set of ComfyUI settings files when present
- `custom_nodes`, excluding `.git`, `__pycache__`, `*.pyc`, and `node_modules`

## Updating workflows and nodes

To update workflows:

```bash
cp /path/to/your/workflow.json /workspace/ComfyUI/user/default/workflows/
bash /workspace/comfy-bootstrap/save_snapshot.sh
```

To update the manifest after adding or removing custom nodes directly on the machine:

```bash
cd /workspace/comfy-bootstrap
bash generate_manifest.sh
```

If you want the updated manifest to become the source of truth for future instances, upload it to B2:

```bash
rclone copyto /workspace/comfy-bootstrap/custom_nodes_manifest.txt myb2:comfy-bootstrap/custom_nodes_manifest.txt
```

## Notes

- `onstart.sh` is idempotent and safe to run more than once.
- The autosave loop avoids launching duplicate background workers by tracking its PID.
- If the remote manifest is missing, the local `custom_nodes_manifest.txt` remains the fallback.
