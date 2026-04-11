#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
readonly MANIFEST_REMOTE="myb2:comfy-bootstrap/custom_nodes_manifest.txt"
readonly REMOTE_WORKFLOWS="myb2:comfy-bootstrap/workflows"
readonly AUTOSAVE_LOG="${WORKSPACE_ROOT}/autosave.log"
readonly AUTOSAVE_PIDFILE="${WORKSPACE_ROOT}/comfy-bootstrap-autosave.pid"

COMFY_ROOT=""
BOOTSTRAP_ROOT=""
CUSTOM_NODES_DIR=""
WORKFLOWS_DIR=""
MANIFEST_LOCAL=""

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

install_packages_if_missing() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v rclone >/dev/null 2>&1 || missing+=("rclone")

  if (( ${#missing[@]} == 0 )); then
    log "Required packages already present."
    return
  fi

  log "Installing missing packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing[@]}"
}

wait_for_workspace() {
  local attempts=30

  mkdir -p "${WORKSPACE_ROOT}"

  while (( attempts > 0 )); do
    if [[ -d "${WORKSPACE_ROOT}" ]]; then
      log "Workspace root ready at ${WORKSPACE_ROOT}."
      return
    fi

    log "Waiting for workspace root ${WORKSPACE_ROOT} to become available."
    sleep 2
    attempts=$((attempts - 1))
  done

  log "Workspace root ${WORKSPACE_ROOT} did not become available in time."
  exit 1
}

configure_rclone() {
  require_env "B2_ACCOUNT_ID"
  require_env "B2_APP_KEY"

  export RCLONE_CONFIG_MYB2_TYPE="b2"
  export RCLONE_CONFIG_MYB2_ACCOUNT="${B2_ACCOUNT_ID}"
  export RCLONE_CONFIG_MYB2_KEY="${B2_APP_KEY}"

  log "Configured rclone remote 'myb2' from environment variables."
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
    "/app/ComfyUI"
    "/ComfyUI"
    "/root/ComfyUI"
  )

  for candidate in "${candidates[@]}"; do
    if is_comfy_root "${candidate}"; then
      COMFY_ROOT="${candidate}"
      log "Detected ComfyUI at ${COMFY_ROOT}."
      return
    fi
  done

  candidate="$(find "${WORKSPACE_ROOT}" /opt /app /root -maxdepth 3 -type f -name main.py -path '*/ComfyUI/*' 2>/dev/null | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    COMFY_ROOT="$(dirname "${candidate}")"
    log "Detected ComfyUI at ${COMFY_ROOT}."
    return
  fi

  log "Unable to locate ComfyUI automatically."
  log "Set COMFY_ROOT explicitly if the image uses a non-standard path."
  exit 1
}

initialize_paths() {
  BOOTSTRAP_ROOT="${WORKSPACE_ROOT}/comfy-bootstrap"
  CUSTOM_NODES_DIR="${COMFY_ROOT}/custom_nodes"
  WORKFLOWS_DIR="${COMFY_ROOT}/user/default/workflows"
  MANIFEST_LOCAL="${BOOTSTRAP_ROOT}/custom_nodes_manifest.txt"
}

ensure_directories() {
  mkdir -p "${BOOTSTRAP_ROOT}"
  mkdir -p "${CUSTOM_NODES_DIR}" "${WORKFLOWS_DIR}"
  log "Ensured ComfyUI directories exist."
}

restore_workflows() {
  log "Restoring workflows from Backblaze B2."
  if rclone sync "${REMOTE_WORKFLOWS}" "${WORKFLOWS_DIR}" --create-empty-src-dirs; then
    log "Workflow restore complete."
  else
    log "Workflow restore skipped or failed; continuing with local state."
  fi
}

fetch_manifest() {
  local tmp_manifest
  tmp_manifest="$(mktemp)"

  log "Attempting to download custom node manifest from B2."
  if rclone copyto "${MANIFEST_REMOTE}" "${tmp_manifest}"; then
    install -m 0644 "${tmp_manifest}" "${MANIFEST_LOCAL}"
    log "Using manifest downloaded from B2."
  elif [[ -f "${MANIFEST_LOCAL}" ]]; then
    log "Remote manifest not found; using local fallback."
  else
    log "No remote manifest found and no local fallback exists; continuing with an empty manifest."
    : > "${MANIFEST_LOCAL}"
  fi

  rm -f "${tmp_manifest}"
}

sync_custom_nodes() {
  if [[ ! -f "${MANIFEST_LOCAL}" ]]; then
    log "Manifest file missing; skipping custom node sync."
    return
  fi

  local repo_url repo_name repo_dir
  while IFS= read -r repo_url || [[ -n "${repo_url}" ]]; do
    repo_url="${repo_url#"${repo_url%%[![:space:]]*}"}"
    repo_url="${repo_url%"${repo_url##*[![:space:]]}"}"

    [[ -z "${repo_url}" ]] && continue
    [[ "${repo_url}" == \#* ]] && continue

    repo_name="$(basename "${repo_url}")"
    repo_name="${repo_name%.git}"
    repo_dir="${CUSTOM_NODES_DIR}/${repo_name}"

    if [[ -d "${repo_dir}/.git" ]]; then
      log "Updating custom node: ${repo_url}"
      git -C "${repo_dir}" pull --ff-only
    elif [[ -d "${repo_dir}" ]]; then
      log "Directory exists without git metadata, skipping clone: ${repo_dir}"
    else
      log "Cloning custom node: ${repo_url}"
      git clone --depth 1 "${repo_url}" "${repo_dir}"
    fi
  done < "${MANIFEST_LOCAL}"
}

install_node_requirements() {
  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is missing; cannot install node requirements."
    exit 1
  fi

  local requirements_found=0
  while IFS= read -r requirements_file; do
    requirements_found=1
    log "Installing Python requirements from ${requirements_file}"
    python3 -m pip install --no-cache-dir -r "${requirements_file}"
  done < <(find "${CUSTOM_NODES_DIR}" -type f -name requirements.txt | sort)

  if (( requirements_found == 0 )); then
    log "No custom node requirements.txt files found."
  fi
}

start_autosave_loop() {
  mkdir -p "$(dirname "${AUTOSAVE_LOG}")"
  touch "${AUTOSAVE_LOG}"

  if [[ -f "${AUTOSAVE_PIDFILE}" ]]; then
    local existing_pid
    existing_pid="$(cat "${AUTOSAVE_PIDFILE}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      log "Autosave loop already running with PID ${existing_pid}."
      return
    fi
  fi

  log "Starting autosave loop."
  (
    export COMFY_ROOT WORKSPACE_ROOT
    while true; do
      bash "${BOOTSTRAP_ROOT}/save_snapshot.sh" >>"${AUTOSAVE_LOG}" 2>&1 || true
      sleep 900
    done
  ) &
  local autosave_pid=$!
  echo "${autosave_pid}" > "${AUTOSAVE_PIDFILE}"
  log "Autosave loop running with PID ${autosave_pid}."
}

main() {
  log "Bootstrap starting."
  wait_for_workspace
  install_packages_if_missing
  discover_comfy_root
  initialize_paths
  configure_rclone
  ensure_directories
  restore_workflows
  fetch_manifest
  sync_custom_nodes
  install_node_requirements
  start_autosave_loop
  log "Bootstrap complete."
}

main "$@"
