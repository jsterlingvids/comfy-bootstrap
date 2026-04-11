#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
readonly REMOTE_ROOT="myb2:comfy-bootstrap"
readonly CODEX_HOME_DIR="${WORKSPACE_ROOT}/.codex"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-3}"
readonly RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-10}"
readonly CODEX_STABLE_FILES=(
  "auth.json"
  "config.toml"
  "installation_id"
  "version.json"
)

COMFY_ROOT=""
WORKFLOWS_DIR=""
CUSTOM_NODES_DIR=""

readonly CUSTOM_NODES_RCLONE_ARGS=(
  --create-empty-src-dirs
  --exclude ".git/**"
  --exclude "**/.git/**"
  --exclude "__pycache__/**"
  --exclude "**/__pycache__/**"
  --exclude "*.pyc"
  --exclude "node_modules/**"
  --exclude "**/node_modules/**"
)

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

rclone_run() {
  rclone "$@" \
    --check-first \
    --retries "${RCLONE_RETRIES}" \
    --low-level-retries "${RCLONE_LOW_LEVEL_RETRIES}"
}

is_comfy_root() {
  local candidate="$1"
  [[ -d "${candidate}" ]] || return 1
  [[ -f "${candidate}/main.py" || -d "${candidate}/custom_nodes" ]] || return 1
}

discover_comfy_root() {
  local candidates=()
  local candidate

  if [[ -n "${DEFAULT_COMFY_ROOT}" ]]; then
    candidates+=("${DEFAULT_COMFY_ROOT}")
  fi

  candidates+=(
    "${WORKSPACE_ROOT}/ComfyUI"
    "${WORKSPACE_ROOT}/comfy/ComfyUI"
    "/opt/ComfyUI"
    "/opt/comfyui"
    "/opt/workspace-internal/ComfyUI"
    "/app/ComfyUI"
    "/ComfyUI"
    "/root/ComfyUI"
  )

  for candidate in "${candidates[@]}"; do
    if is_comfy_root "${candidate}"; then
      COMFY_ROOT="${candidate}"
      return
    fi
  done

  candidate="$(find "${WORKSPACE_ROOT}" /opt /app /root -maxdepth 3 -type f -name main.py -path '*/ComfyUI/*' 2>/dev/null | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    COMFY_ROOT="$(dirname "${candidate}")"
    return
  fi

  log "Unable to locate ComfyUI automatically for snapshot."
  exit 1
}

initialize_paths() {
  WORKFLOWS_DIR="${COMFY_ROOT}/user/default/workflows"
  CUSTOM_NODES_DIR="${COMFY_ROOT}/custom_nodes"
}

sync_if_present() {
  local source_path="$1"
  local remote_path="$2"

  if [[ -e "${source_path}" ]]; then
    log "Syncing ${source_path} -> ${remote_path}"
    rclone_run copyto "${source_path}" "${remote_path}"
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
    rclone_run sync "${source_dir}" "${remote_dir}" "$@"
  else
    log "Skipping missing directory: ${source_dir}"
  fi
}

count_local_files() {
  local source_dir="$1"

  case "${source_dir}" in
    "${CUSTOM_NODES_DIR}")
      find "${source_dir}" \
        \( -path '*/.git' -o -path '*/.git/*' -o -path '*/__pycache__' -o -path '*/__pycache__/*' -o -path '*/node_modules' -o -path '*/node_modules/*' \) -prune -o \
        -type f ! -name '*.pyc' -print | wc -l
      ;;
    *)
      find "${source_dir}" -type f -print | wc -l
      ;;
  esac
}

count_local_bytes() {
  local source_dir="$1"

  case "${source_dir}" in
    "${CUSTOM_NODES_DIR}")
      find "${source_dir}" \
        \( -path '*/.git' -o -path '*/.git/*' -o -path '*/__pycache__' -o -path '*/__pycache__/*' -o -path '*/node_modules' -o -path '*/node_modules/*' \) -prune -o \
        -type f ! -name '*.pyc' -printf '%s\n' | awk '{sum+=$1} END {print sum+0}'
      ;;
    *)
      find "${source_dir}" -type f -printf '%s\n' | awk '{sum+=$1} END {print sum+0}'
      ;;
  esac
}

count_remote_files() {
  local remote_dir="$1"
  shift
  rclone_run lsf "${remote_dir}" -R --files-only "$@" | wc -l
}

verify_file_if_present() {
  local source_path="$1"
  local remote_path="$2"
  local file_size=""
  local remote_size=""
  local remote_entry_count=""

  if [[ ! -e "${source_path}" ]]; then
    return
  fi

  log "Verifying ${source_path} -> ${remote_path}"
  file_size="$(stat -c '%s' "${source_path}")"
  remote_entry_count="$(rclone_run lsjson "${remote_path}" | grep -c '"Path"')"
  remote_size="$(rclone_run lsjson "${remote_path}" | sed -n 's/.*"Size":\([0-9][0-9]*\).*/\1/p' | head -n 1)"

  if [[ "${remote_entry_count}" != "1" || -z "${remote_size}" ]]; then
    log "Verification failed for ${source_path}: remote file metadata missing at ${remote_path}"
    exit 1
  fi

  if [[ "${file_size}" != "${remote_size}" ]]; then
    log "Verification failed for ${source_path}: local=${file_size} remote=${remote_size}"
    exit 1
  fi

  log "Verified file ${source_path} (${file_size} bytes)"
}

verify_directory_if_present() {
  local source_dir="$1"
  local remote_dir="$2"
  local combined_report=""
  local local_files=""
  local remote_files=""
  local local_bytes=""
  local verify_args=()
  local arg=""
  shift 2

  if [[ ! -d "${source_dir}" ]]; then
    return
  fi

  for arg in "$@"; do
    case "${arg}" in
      --create-empty-src-dirs)
        ;;
      *)
        verify_args+=("${arg}")
        ;;
    esac
  done

  combined_report="$(mktemp)"
  log "Verifying ${source_dir} -> ${remote_dir}"
  if ! rclone_run check "${source_dir}" "${remote_dir}" --combined "${combined_report}" "${verify_args[@]}"; then
    log "Verification failed for ${source_dir}. Combined diff:"
    sed 's/^/  /' "${combined_report}" >&2 || true
    rm -f "${combined_report}"
    exit 1
  fi

  rm -f "${combined_report}"
  local_files="$(count_local_files "${source_dir}")"
  local_bytes="$(count_local_bytes "${source_dir}")"
  remote_files="$(count_remote_files "${remote_dir}" "${verify_args[@]}")"

  if [[ "${local_files}" != "${remote_files}" ]]; then
    log "Verification count mismatch for ${source_dir}: local=${local_files} remote=${remote_files}"
    exit 1
  fi

  log "Verified ${source_dir}: ${local_files} files, ${local_bytes} bytes"
}

sync_codex_stable_files() {
  local codex_file=""

  mkdir -p "${CODEX_HOME_DIR}"

  for codex_file in "${CODEX_STABLE_FILES[@]}"; do
    sync_if_present "${CODEX_HOME_DIR}/${codex_file}" "${REMOTE_ROOT}/codex-home/${codex_file}"
    verify_file_if_present "${CODEX_HOME_DIR}/${codex_file}" "${REMOTE_ROOT}/codex-home/${codex_file}"
  done
}
main() {
  log "Snapshot starting."
  configure_rclone
  discover_comfy_root
  initialize_paths
  log "Using ComfyUI at ${COMFY_ROOT}."

  sync_directory_if_present "${WORKFLOWS_DIR}" "${REMOTE_ROOT}/workflows" --create-empty-src-dirs
  verify_directory_if_present "${WORKFLOWS_DIR}" "${REMOTE_ROOT}/workflows" --create-empty-src-dirs

  sync_if_present "${COMFY_ROOT}/extra_model_paths.yaml" "${REMOTE_ROOT}/settings/extra_model_paths.yaml"
  verify_file_if_present "${COMFY_ROOT}/extra_model_paths.yaml" "${REMOTE_ROOT}/settings/extra_model_paths.yaml"
  sync_if_present "${COMFY_ROOT}/user/default/comfy.settings.json" "${REMOTE_ROOT}/settings/comfy.settings.json"
  verify_file_if_present "${COMFY_ROOT}/user/default/comfy.settings.json" "${REMOTE_ROOT}/settings/comfy.settings.json"
  sync_if_present "${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini" "${REMOTE_ROOT}/settings/ComfyUI-Manager-config.ini"
  verify_file_if_present "${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini" "${REMOTE_ROOT}/settings/ComfyUI-Manager-config.ini"
  sync_if_present "${COMFY_ROOT}/user/__manager/config.ini" "${REMOTE_ROOT}/settings/manager-config.ini"
  verify_file_if_present "${COMFY_ROOT}/user/__manager/config.ini" "${REMOTE_ROOT}/settings/manager-config.ini"

  sync_directory_if_present "${CUSTOM_NODES_DIR}" "${REMOTE_ROOT}/custom_nodes" "${CUSTOM_NODES_RCLONE_ARGS[@]}"
  verify_directory_if_present "${CUSTOM_NODES_DIR}" "${REMOTE_ROOT}/custom_nodes" "${CUSTOM_NODES_RCLONE_ARGS[@]}"

  sync_codex_stable_files

  log "Snapshot complete."
}

main "$@"
