#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly COMFY_ROOT="${WORKSPACE_ROOT}/ComfyUI"
readonly WORKFLOWS_DIR="${COMFY_ROOT}/user/default/workflows"
readonly CUSTOM_NODES_DIR="${COMFY_ROOT}/custom_nodes"
readonly REMOTE_ROOT="myb2:comfy-bootstrap"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "Missing required environment variable: ${name}"
    exit 1
  fi
}

configure_rclone() {
  require_env "B2_ACCOUNT_ID"
  require_env "B2_APP_KEY"

  export RCLONE_CONFIG_MYB2_TYPE="b2"
  export RCLONE_CONFIG_MYB2_ACCOUNT="${B2_ACCOUNT_ID}"
  export RCLONE_CONFIG_MYB2_KEY="${B2_APP_KEY}"
}

sync_if_present() {
  local source_path="$1"
  local remote_path="$2"

  if [[ -e "${source_path}" ]]; then
    log "Syncing ${source_path} -> ${remote_path}"
    rclone copyto "${source_path}" "${remote_path}"
  else
    log "Skipping missing path: ${source_path}"
  fi
}

sync_directory_if_present() {
  local source_dir="$1"
  local remote_dir="$2"
  shift 2

  if [[ -d "${source_dir}" ]]; then
    log "Syncing ${source_dir} -> ${remote_dir}"
    rclone sync "${source_dir}" "${remote_dir}" "$@"
  else
    log "Skipping missing directory: ${source_dir}"
  fi
}

main() {
  log "Snapshot starting."
  configure_rclone

  sync_directory_if_present "${WORKFLOWS_DIR}" "${REMOTE_ROOT}/workflows" --create-empty-src-dirs

  sync_if_present "${COMFY_ROOT}/extra_model_paths.yaml" "${REMOTE_ROOT}/settings/extra_model_paths.yaml"
  sync_if_present "${COMFY_ROOT}/user/default/comfy.settings.json" "${REMOTE_ROOT}/settings/comfy.settings.json"
  sync_if_present "${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini" "${REMOTE_ROOT}/settings/ComfyUI-Manager-config.ini"

  sync_directory_if_present "${CUSTOM_NODES_DIR}" "${REMOTE_ROOT}/custom_nodes" \
    --create-empty-src-dirs \
    --exclude ".git/**" \
    --exclude "**/.git/**" \
    --exclude "__pycache__/**" \
    --exclude "**/__pycache__/**" \
    --exclude "*.pyc" \
    --exclude "node_modules/**" \
    --exclude "**/node_modules/**"

  log "Snapshot complete."
}

main "$@"
