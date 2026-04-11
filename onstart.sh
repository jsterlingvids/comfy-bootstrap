#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
readonly MANIFEST_REMOTE="myb2:comfy-bootstrap/custom_nodes_manifest.txt"
readonly REMOTE_WORKFLOWS="myb2:comfy-bootstrap/workflows"
readonly REMOTE_CODEX_HOME="myb2:comfy-bootstrap/codex-home"
readonly AUTOSAVE_LOG="${WORKSPACE_ROOT}/autosave.log"
readonly AUTOSAVE_PIDFILE="${WORKSPACE_ROOT}/comfy-bootstrap-autosave.pid"
readonly COMFY_LOG="${WORKSPACE_ROOT}/comfyui.log"
readonly CODEX_HOME_DIR="${WORKSPACE_ROOT}/.codex"

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

install_codex_cli() {
  if command -v codex >/dev/null 2>&1; then
    log "Codex CLI already installed."
    return
  fi

  if ! command -v npm >/dev/null 2>&1; then
    log "Installing Node.js and npm for Codex CLI."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nodejs npm
  fi

  log "Installing Codex CLI."
  npm install -g @openai/codex
}

restore_codex_home() {
  mkdir -p "${CODEX_HOME_DIR}"

  log "Attempting to restore Codex home from B2."
  if rclone sync "${REMOTE_CODEX_HOME}" "${CODEX_HOME_DIR}" --create-empty-src-dirs; then
    log "Codex home restore complete."
  else
    log "Codex home restore skipped or failed; continuing with local state."
  fi

  rm -rf /root/.codex
  ln -sfn "${CODEX_HOME_DIR}" /root/.codex
}

configure_codex_defaults() {
  local config_file="${CODEX_HOME_DIR}/config.toml"

  mkdir -p "${CODEX_HOME_DIR}"
  touch "${config_file}"

  if ! grep -q '^approval_policy *= *"never"' "${config_file}" 2>/dev/null; then
    printf 'approval_policy = "never"\n' >> "${config_file}"
  fi

  if ! grep -q '^sandbox_mode *= *"danger-full-access"' "${config_file}" 2>/dev/null; then
    printf 'sandbox_mode = "danger-full-access"\n' >> "${config_file}"
  fi
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

install_comfy_requirements() {
  local comfy_requirements="${COMFY_ROOT}/requirements.txt"

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is missing; cannot install ComfyUI requirements."
    exit 1
  fi

  if [[ -f "${comfy_requirements}" ]]; then
    log "Installing ComfyUI core requirements from ${comfy_requirements}"
    python3 -m pip install --no-cache-dir -r "${comfy_requirements}"
  else
    log "ComfyUI requirements.txt not found at ${comfy_requirements}; skipping core dependency install."
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
      sleep 300
    done
  ) &
  local autosave_pid=$!
  echo "${autosave_pid}" > "${AUTOSAVE_PIDFILE}"
  log "Autosave loop running with PID ${autosave_pid}."
}

ensure_comfy_running() {
  local comfy_args_raw="${COMFYUI_ARGS:---listen 0.0.0.0 --port 8188}"
  local -a comfy_args=()
  local has_listen=0

  read -r -a comfy_args <<< "${comfy_args_raw}"

  for arg in "${comfy_args[@]}"; do
    if [[ "${arg}" == "--listen" || "${arg}" == "--host" ]]; then
      has_listen=1
      break
    fi
  done

  if (( has_listen == 0 )); then
    comfy_args=(--listen 0.0.0.0 "${comfy_args[@]}")
  fi

  if pgrep -f "${COMFY_ROOT}/main.py" >/dev/null 2>&1; then
    log "ComfyUI process already running."
    return
  fi

  if pgrep -fa "python.*main.py" | grep -q "ComfyUI" 2>/dev/null; then
    log "Detected an existing ComfyUI-like process; not starting a duplicate."
    return
  fi

  log "Starting ComfyUI with args: ${comfy_args[*]}"
  (
    cd "${COMFY_ROOT}"
    nohup python3 main.py "${comfy_args[@]}" >>"${COMFY_LOG}" 2>&1 &
  )
  log "ComfyUI launch requested; logging to ${COMFY_LOG}."
}

main() {
  log "Bootstrap starting."
  wait_for_workspace
  install_packages_if_missing
  discover_comfy_root
  initialize_paths
  configure_rclone
  restore_codex_home
  configure_codex_defaults
  install_codex_cli
  ensure_directories
  restore_workflows
  fetch_manifest
  sync_custom_nodes
  install_comfy_requirements
  install_node_requirements
  ensure_comfy_running
  start_autosave_loop
  log "Bootstrap complete."
}

main "$@"
