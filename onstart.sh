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
readonly BOOTSTRAP_STATE_ROOT="${WORKSPACE_ROOT}/.comfy-bootstrap-state"
readonly DEFAULT_COMFY_PORT="8188"
readonly CODEX_STABLE_FILES=(
  "auth.json"
  "config.toml"
  "installation_id"
  "version.json"
)

COMFY_ROOT=""
BOOTSTRAP_ROOT=""
CUSTOM_NODES_DIR=""
WORKFLOWS_DIR=""
MANIFEST_LOCAL=""
STATE_DIR=""

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

compute_file_fingerprint() {
  local source_file="$1"

  {
    printf '%s\n' "${source_file}"
    sha256sum "${source_file}"
    python3 --version 2>&1 || true
  } | sha256sum | awk '{print $1}'
}

compute_node_requirements_fingerprint() {
  local requirements_file

  if [[ ! -d "${CUSTOM_NODES_DIR}" ]]; then
    printf 'missing\n'
    return
  fi

  while IFS= read -r requirements_file; do
    printf '%s\n' "${requirements_file}"
    sha256sum "${requirements_file}"
  done < <(find "${CUSTOM_NODES_DIR}" -type f -name requirements.txt | sort)

  python3 --version 2>&1 || true
}

read_stamp() {
  local stamp_file="$1"

  if [[ -f "${stamp_file}" ]]; then
    cat "${stamp_file}"
  fi
}

write_stamp() {
  local stamp_file="$1"
  local stamp_value="$2"

  mkdir -p "$(dirname "${stamp_file}")"
  printf '%s\n' "${stamp_value}" > "${stamp_file}"
}

restore_codex_home() {
  local codex_file=""
  local restored_files=0

  mkdir -p "${CODEX_HOME_DIR}"

  log "Attempting to restore stable Codex files from B2."
  for codex_file in "${CODEX_STABLE_FILES[@]}"; do
    if rclone copyto "${REMOTE_CODEX_HOME}/${codex_file}" "${CODEX_HOME_DIR}/${codex_file}"; then
      restored_files=$((restored_files + 1))
    fi
  done
  log "Codex restore complete; restored ${restored_files}/${#CODEX_STABLE_FILES[@]} stable files."

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
    "/opt/workspace-internal/ComfyUI"
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
  STATE_DIR="${BOOTSTRAP_STATE_ROOT}"
}

ensure_directories() {
  mkdir -p "${BOOTSTRAP_ROOT}"
  mkdir -p "${STATE_DIR}"
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
  local -a requirements_files=()
  local current_fingerprint=""
  local current_stamp=""
  local stamp_file="${STATE_DIR}/custom-node-requirements.sha256"

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is missing; cannot install node requirements."
    exit 1
  fi

  mapfile -t requirements_files < <(find "${CUSTOM_NODES_DIR}" -type f -name requirements.txt | sort)

  if (( ${#requirements_files[@]} == 0 )); then
    write_stamp "${stamp_file}" "none"
    log "No custom node requirements.txt files found."
    return
  fi

  current_fingerprint="$(compute_node_requirements_fingerprint | sha256sum | awk '{print $1}')"
  current_stamp="$(read_stamp "${stamp_file}")"
  if [[ "${current_fingerprint}" == "${current_stamp}" ]]; then
    log "Custom node requirements unchanged; skipping reinstall."
    return
  fi

  local requirements_file=""
  for requirements_file in "${requirements_files[@]}"; do
    log "Installing Python requirements from ${requirements_file}"
    python3 -m pip install --no-cache-dir -r "${requirements_file}"
  done

  write_stamp "${stamp_file}" "${current_fingerprint}"
}

install_comfy_requirements() {
  local comfy_requirements="${COMFY_ROOT}/requirements.txt"
  local current_fingerprint=""
  local current_stamp=""
  local stamp_file="${STATE_DIR}/comfy-requirements.sha256"

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is missing; cannot install ComfyUI requirements."
    exit 1
  fi

  if [[ -f "${comfy_requirements}" ]]; then
    current_fingerprint="$(compute_file_fingerprint "${comfy_requirements}")"
    current_stamp="$(read_stamp "${stamp_file}")"
    if [[ "${current_fingerprint}" == "${current_stamp}" ]]; then
      log "ComfyUI core requirements unchanged; skipping reinstall."
      return
    fi

    log "Installing ComfyUI core requirements from ${comfy_requirements}"
    python3 -m pip install --no-cache-dir -r "${comfy_requirements}"
    write_stamp "${stamp_file}" "${current_fingerprint}"
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

get_comfy_port_from_args() {
  local default_port="$1"
  shift

  local arg=""
  local next_is_port=0
  for arg in "$@"; do
    if (( next_is_port == 1 )); then
      printf '%s\n' "${arg}"
      return
    fi

    case "${arg}" in
      --port)
        next_is_port=1
        ;;
      --port=*)
        printf '%s\n' "${arg#--port=}"
        return
        ;;
    esac
  done

  printf '%s\n' "${default_port}"
}

list_listening_pids_for_port() {
  local port="$1"

  ss -ltnp 2>/dev/null | awk -v port="${port}" '$4 ~ ":" port "$"' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u
}

pid_matches_comfy_root() {
  local pid="$1"
  local cmdline=""
  local cwd=""

  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  [[ -L "/proc/${pid}/cwd" ]] || return 1

  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"

  [[ -n "${cmdline}" ]] || return 1
  [[ "${cmdline}" == *"main.py"* ]] || return 1
  [[ "${cwd}" == "${COMFY_ROOT}" ]] || return 1
}

find_comfy_listener_pid_for_port() {
  local port="$1"
  local pid=""

  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    if pid_matches_comfy_root "${pid}"; then
      printf '%s\n' "${pid}"
      return
    fi
  done < <(list_listening_pids_for_port "${port}")
}

list_comfy_root_pids() {
  local pid=""

  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    if pid_matches_comfy_root "${pid}"; then
      printf '%s\n' "${pid}"
    fi
  done < <(pgrep -f 'main\.py' 2>/dev/null || true)
}

wait_for_comfy_listener() {
  local port="$1"
  local attempts="${2:-30}"
  local listener_pid=""

  while (( attempts > 0 )); do
    listener_pid="$(find_comfy_listener_pid_for_port "${port}" || true)"
    if [[ -n "${listener_pid}" ]]; then
      printf '%s\n' "${listener_pid}"
      return
    fi

    sleep 1
    attempts=$((attempts - 1))
  done
}

ensure_comfy_running() {
  local comfy_args_raw="${COMFYUI_ARGS:---listen 0.0.0.0 --port ${DEFAULT_COMFY_PORT}}"
  local -a comfy_args=()
  local has_listen=0
  local configured_port=""
  local listener_pid=""
  local launch_pid=""
  local foreign_pids=""
  local existing_root_pids=""

  read -r -a comfy_args <<< "${comfy_args_raw}"

  local arg=""
  for arg in "${comfy_args[@]}"; do
    if [[ "${arg}" == "--listen" || "${arg}" == "--host" ]]; then
      has_listen=1
      break
    fi
  done

  if (( has_listen == 0 )); then
    comfy_args=(--listen 0.0.0.0 "${comfy_args[@]}")
  fi

  configured_port="$(get_comfy_port_from_args "${DEFAULT_COMFY_PORT}" "${comfy_args[@]}")"
  listener_pid="$(find_comfy_listener_pid_for_port "${configured_port}" || true)"
  if [[ -n "${listener_pid}" ]]; then
    log "ComfyUI already serving port ${configured_port} with PID ${listener_pid}."
    return
  fi

  foreign_pids="$(list_listening_pids_for_port "${configured_port}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "${foreign_pids}" ]]; then
    log "Configured ComfyUI port ${configured_port} is already in use by PID(s): ${foreign_pids}"
    exit 1
  fi

  existing_root_pids="$(list_comfy_root_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "${existing_root_pids}" ]]; then
    log "Detected ComfyUI process(es) from ${COMFY_ROOT} without port ${configured_port}: ${existing_root_pids}. Waiting for listener."
    listener_pid="$(wait_for_comfy_listener "${configured_port}" 30 || true)"
    if [[ -n "${listener_pid}" ]]; then
      log "ComfyUI became ready on port ${configured_port} with PID ${listener_pid}."
      return
    fi

    log "ComfyUI process(es) ${existing_root_pids} never bound port ${configured_port}; refusing duplicate launch."
    exit 1
  fi

  log "Starting ComfyUI with args: ${comfy_args[*]}"
  launch_pid="$(
    cd "${COMFY_ROOT}"
    nohup python3 main.py "${comfy_args[@]}" >>"${COMFY_LOG}" 2>&1 &
    echo $!
  )"
  log "ComfyUI launch requested with PID ${launch_pid}; logging to ${COMFY_LOG}."

  listener_pid="$(wait_for_comfy_listener "${configured_port}" 60 || true)"
  if [[ -n "${listener_pid}" ]]; then
    log "ComfyUI is serving port ${configured_port} with PID ${listener_pid}."
    return
  fi

  if [[ -n "${launch_pid}" ]] && kill -0 "${launch_pid}" 2>/dev/null; then
    log "ComfyUI PID ${launch_pid} is still running but never bound port ${configured_port}."
  else
    log "ComfyUI launch process exited before binding port ${configured_port}."
  fi

  tail -n 40 "${COMFY_LOG}" 2>/dev/null || true
  exit 1
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
