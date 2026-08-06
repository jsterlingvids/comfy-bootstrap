#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
# COMFY_STATE_ROOT is the provider-neutral, non-secret state surface.
# Point Vast and Runpod at the same value to share workflows, settings, and
# custom nodes. Keep CODEX_STATE_ROOT provider-local: interactive credentials
# must never be copied between GPU providers.
readonly LEGACY_B2_ROOT="${B2_ROOT:-myb2:comfy-bootstrap}"
readonly COMFY_STATE_ROOT="${COMFY_STATE_ROOT:-${LEGACY_B2_ROOT}}"
readonly CODEX_STATE_ROOT="${CODEX_STATE_ROOT:-${LEGACY_B2_ROOT}/codex-home}"
readonly MANIFEST_REMOTE="${COMFY_STATE_ROOT}/custom_nodes_manifest.txt"
readonly REMOTE_CUSTOM_NODES="${COMFY_STATE_ROOT}/custom_nodes"
readonly REMOTE_WORKFLOWS="${COMFY_STATE_ROOT}/workflows"
readonly REMOTE_SETTINGS="${COMFY_STATE_ROOT}/settings"
readonly REMOTE_CODEX_HOME="${CODEX_STATE_ROOT}"
readonly AUTOSAVE_LOG="${WORKSPACE_ROOT}/autosave.log"
readonly AUTOSAVE_PIDFILE="${WORKSPACE_ROOT}/comfy-bootstrap-autosave.pid"
readonly COMFY_LOG="${WORKSPACE_ROOT}/comfyui.log"
readonly CODEX_HOME_DIR="${WORKSPACE_ROOT}/.codex"
readonly BOOTSTRAP_STATE_ROOT="${WORKSPACE_ROOT}/.comfy-bootstrap-state"
readonly DEFAULT_COMFY_PORT="8188"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tailscale-private-comfy.sh
source "${SCRIPT_DIR}/lib/tailscale-private-comfy.sh"
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
MANIFEST_REMOTE_CACHE=""
MANIFEST_ACTIVE=""
STATE_DIR=""
CUSTOM_NODES_SNAPSHOT_RESTORED=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

pip_install_with_fallback() {
  local -a pip_args=("$@")
  local -a network_args=(
    --retries "${PIP_NETWORK_RETRIES:-20}"
    --timeout "${PIP_NETWORK_TIMEOUT:-180}"
  )

  if python3 -m pip "${pip_args[@]}" "${network_args[@]}"; then
    return 0
  fi

  log "pip install failed; retrying with --break-system-packages and resilient network settings."
  python3 -m pip "${pip_args[@]}" "${network_args[@]}" --break-system-packages
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

ensure_node_22() {
  local node_major="0"

  if command -v node >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')"
  fi

  if [[ "${node_major}" =~ ^[0-9]+$ ]] && (( node_major >= 22 )); then
    log "Node.js ${node_major} already satisfies the Agent Panel requirement."
    return
  fi

  if ! command -v npm >/dev/null 2>&1; then
    log "Installing Node.js and npm bootstrap packages."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nodejs npm
  fi

  log "Installing Node.js 22 for the ComfyUI Agent Panel."
  npm install -g n
  n 22
  hash -r
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')"
  if [[ ! "${node_major}" =~ ^[0-9]+$ ]] || (( node_major < 22 )); then
    log "Node.js 22 installation failed; found Node.js ${node_major}."
    return 1
  fi
  log "Node.js ${node_major} installed."
}

install_codex_cli() {
  ensure_node_22

  if command -v codex >/dev/null 2>&1; then
    log "Codex CLI already installed."
    return
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

compute_node_install_scripts_fingerprint() {
  local install_script=""

  if [[ ! -d "${CUSTOM_NODES_DIR}" ]]; then
    printf 'missing\n'
    return
  fi

  while IFS= read -r install_script; do
    printf '%s\n' "${install_script}"
    sha256sum "${install_script}"
  done < <(find "${CUSTOM_NODES_DIR}" -maxdepth 2 -type f \( -name install.py -o -name install.sh \) | sort)

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
  STATE_DIR="${BOOTSTRAP_STATE_ROOT}"
  MANIFEST_LOCAL="${BOOTSTRAP_ROOT}/custom_nodes_manifest.txt"
  MANIFEST_REMOTE_CACHE="${STATE_DIR}/custom_nodes_manifest.remote.txt"
  MANIFEST_ACTIVE="${STATE_DIR}/custom_nodes_manifest.merged.txt"
}

ensure_directories() {
  mkdir -p "${BOOTSTRAP_ROOT}"
  mkdir -p "${STATE_DIR}"
  mkdir -p "${CUSTOM_NODES_DIR}" "${WORKFLOWS_DIR}"
  mkdir -p "${COMFY_ROOT}/web/extensions"
  mkdir -p "${COMFY_ROOT}/web/extensions/pysssss"
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

restore_settings() {
  local remote_file local_file
  local -a state_files=(
    "extra_model_paths.yaml:${COMFY_ROOT}/extra_model_paths.yaml"
    "comfy.settings.json:${COMFY_ROOT}/user/default/comfy.settings.json"
    "ComfyUI-Manager-config.ini:${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini"
    "manager-config.ini:${COMFY_ROOT}/user/__manager/config.ini"
  )

  log "Restoring ComfyUI and Manager settings from Backblaze B2."
  for state_file in "${state_files[@]}"; do
    remote_file="${REMOTE_SETTINGS}/${state_file%%:*}"
    local_file="${state_file#*:}"
    mkdir -p "$(dirname "${local_file}")"
    if rclone copyto "${remote_file}" "${local_file}"; then
      log "Restored setting: ${state_file%%:*}"
    else
      log "Setting unavailable; preserving local/default value: ${state_file%%:*}"
    fi
  done
}

restore_custom_nodes_snapshot() {
  local restored_file_count=0

  log "Attempting fast custom-node restore from Backblaze B2 snapshot."
  if ! rclone sync "${REMOTE_CUSTOM_NODES}" "${CUSTOM_NODES_DIR}" --create-empty-src-dirs; then
    log "Custom-node snapshot restore failed; falling back to manifest clones."
    return
  fi

  restored_file_count="$(find "${CUSTOM_NODES_DIR}" -type f | wc -l)"
  if (( restored_file_count == 0 )); then
    log "Custom-node snapshot was empty; falling back to manifest clones."
    return
  fi

  CUSTOM_NODES_SNAPSHOT_RESTORED=1
  log "Custom-node snapshot restore complete: ${restored_file_count} files."
}

count_manifest_repos() {
  local manifest_file="$1"
  awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 == "" || $0 ~ /^#/) {
        next
      }
      count++
    }
    END {
      print count+0
    }
  ' "${manifest_file}"
}

fetch_manifest() {
  local tmp_remote=""
  local normalized_local=""
  local normalized_remote=""
  local merged_tmp=""
  local local_count=0
  local remote_count=0
  local merged_count=0

  tmp_remote="$(mktemp)"
  normalized_local="$(mktemp)"
  normalized_remote="$(mktemp)"
  merged_tmp="$(mktemp)"

  normalize_manifest_file "${MANIFEST_LOCAL}" "${normalized_local}" "repo baseline"
  local_count="$(wc -l < "${normalized_local}")"

  log "Attempting to download custom node manifest from B2."
  if rclone copyto "${MANIFEST_REMOTE}" "${tmp_remote}"; then
    normalize_manifest_file "${tmp_remote}" "${normalized_remote}" "B2 catch-all"
    remote_count="$(wc -l < "${normalized_remote}")"
    install -m 0644 "${normalized_remote}" "${MANIFEST_REMOTE_CACHE}"
    if ! cmp -s "${normalized_local}" "${normalized_remote}" 2>/dev/null; then
      log "Repo baseline and B2 catch-all manifests differ; using the union of both."
    fi
  else
    : > "${normalized_remote}"
    remote_count=0
    log "B2 manifest unavailable; continuing with repo baseline only."
  fi

  cat "${normalized_local}" "${normalized_remote}" | sed '/^$/d' | sort -u > "${merged_tmp}"
  install -m 0644 "${merged_tmp}" "${MANIFEST_ACTIVE}"
  merged_count="$(wc -l < "${MANIFEST_ACTIVE}")"

  log "Manifest repo counts: baseline=${local_count} b2=${remote_count} merged=${merged_count}"
  if (( merged_count == 0 )); then
    log "WARNING: merged custom node manifest contains zero repos; custom node sync will be skipped."
  fi

  rm -f "${tmp_remote}" "${normalized_local}" "${normalized_remote}" "${merged_tmp}"
}

normalize_manifest_file() {
  local input_file="$1"
  local output_file="$2"
  local source_label="${3:-manifest}"
  local raw_line=""
  local trimmed=""
  local invalid_count=0
  local valid_count=0

  : > "${output_file}"

  if [[ ! -f "${input_file}" ]]; then
    log "No ${source_label} manifest found at ${input_file}."
    return
  fi

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    trimmed="${raw_line#"${raw_line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [[ -z "${trimmed}" ]] && continue
    [[ "${trimmed}" == \#* ]] && continue

    if [[ "${trimmed}" =~ ^https?://[^[:space:]]+$ || "${trimmed}" =~ ^git@github\.com:[^[:space:]]+$ ]]; then
      printf '%s\n' "${trimmed}" >> "${output_file}"
      valid_count=$((valid_count + 1))
    else
      invalid_count=$((invalid_count + 1))
      log "Ignoring invalid ${source_label} manifest entry: ${trimmed}"
    fi
  done < "${input_file}"

  sort -u -o "${output_file}" "${output_file}"
  log "Normalized ${source_label} manifest: ${valid_count} valid entries, ${invalid_count} invalid entries."
}

sync_custom_nodes() {
  if (( CUSTOM_NODES_SNAPSHOT_RESTORED )); then
    log "Using restored custom-node snapshot; skipping slow Git manifest synchronization."
    return
  fi

  if [[ ! -f "${MANIFEST_ACTIVE}" ]]; then
    log "Merged manifest file missing; skipping custom node sync."
    return
  fi

  local repo_url repo_name repo_dir repo_count=0 synced_count=0 failed_count=0
  while IFS= read -r repo_url || [[ -n "${repo_url}" ]]; do
    [[ -z "${repo_url}" ]] && continue
    repo_count=$((repo_count + 1))
    repo_name="$(basename "${repo_url}")"
    repo_name="${repo_name%.git}"
    repo_dir="${CUSTOM_NODES_DIR}/${repo_name}"

    if [[ -d "${repo_dir}/.git" ]]; then
      if sync_custom_node_repo "${repo_url}" "${repo_dir}" "update"; then
        synced_count=$((synced_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
    elif [[ -d "${repo_dir}" ]]; then
      log "Directory exists without git metadata, skipping clone: ${repo_dir}"
      failed_count=$((failed_count + 1))
    else
      if sync_custom_node_repo "${repo_url}" "${repo_dir}" "clone"; then
        synced_count=$((synced_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
    fi
  done < "${MANIFEST_ACTIVE}"

  log "Custom node sync summary: expected=${repo_count} succeeded=${synced_count} failed=${failed_count}"
  if (( repo_count == 0 )); then
    log "WARNING: no custom node repos were requested by the merged manifest."
  elif (( failed_count > 0 )); then
    log "WARNING: custom node sync incomplete; ${failed_count} repo(s) failed."
  fi
}

sync_custom_node_repo() {
  local repo_url="$1"
  local repo_dir="$2"
  local mode="$3"
  local attempt=1
  local origin_url=""

  while (( attempt <= 3 )); do
    if [[ "${mode}" == "update" ]]; then
      log "Updating custom node (${attempt}/3): ${repo_url}"
      if git -C "${repo_dir}" pull --ff-only; then
        :
      else
        attempt=$((attempt + 1))
        sleep 2
        continue
      fi
    else
      log "Cloning custom node (${attempt}/3): ${repo_url}"
      if git clone --depth 1 "${repo_url}" "${repo_dir}"; then
        :
      else
        rm -rf "${repo_dir}" 2>/dev/null || true
        attempt=$((attempt + 1))
        sleep 2
        continue
      fi
    fi

    if [[ ! -d "${repo_dir}/.git" ]]; then
      attempt=$((attempt + 1))
      sleep 2
      continue
    fi

    origin_url="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"
    if [[ "${origin_url}" == "${repo_url}" ]]; then
      return 0
    fi

    log "Origin URL mismatch for ${repo_dir}: expected ${repo_url}, got ${origin_url}"
    attempt=$((attempt + 1))
    sleep 2
  done

  log "Failed to ${mode} custom node after retries: ${repo_url}"
  return 1
}

install_node_requirements() {
  local -a requirements_files=()
  local current_fingerprint=""
  local current_stamp=""
  local stamp_file="${STATE_DIR}/custom-node-requirements.sha256"
  local success_count=0
  local failed_count=0

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
    if pip_install_with_fallback install --no-cache-dir -r "${requirements_file}"; then
      success_count=$((success_count + 1))
    else
      failed_count=$((failed_count + 1))
      log "WARNING: failed installing requirements from ${requirements_file}"
    fi
  done

  log "Custom node requirements install summary: total=${#requirements_files[@]} succeeded=${success_count} failed=${failed_count}"
  if (( failed_count == 0 )); then
    write_stamp "${stamp_file}" "${current_fingerprint}"
  else
    log "Requirements install had failures; preserving previous stamp to retry next launch."
  fi
}

run_custom_node_install_scripts() {
  local -a install_scripts=()
  local current_fingerprint=""
  local current_stamp=""
  local stamp_file="${STATE_DIR}/custom-node-install-scripts.sha256"
  local install_script=""
  local success_count=0
  local failed_count=0

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is missing; cannot run custom node install scripts."
    exit 1
  fi

  mapfile -t install_scripts < <(find "${CUSTOM_NODES_DIR}" -maxdepth 2 -type f \( -name install.py -o -name install.sh \) | sort)

  if (( ${#install_scripts[@]} == 0 )); then
    write_stamp "${stamp_file}" "none"
    log "No custom node install scripts found."
    return
  fi

  current_fingerprint="$(compute_node_install_scripts_fingerprint | sha256sum | awk '{print $1}')"
  current_stamp="$(read_stamp "${stamp_file}")"
  if [[ "${current_fingerprint}" == "${current_stamp}" ]]; then
    log "Custom node install scripts unchanged; skipping re-run."
    return
  fi

  for install_script in "${install_scripts[@]}"; do
    if [[ "${install_script}" == *.py ]]; then
      log "Running custom node install script: ${install_script}"
      if (cd "$(dirname "${install_script}")" && python3 "${install_script}"); then
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
        log "WARNING: install script failed: ${install_script}"
      fi
    else
      log "Running custom node install script: ${install_script}"
      if (cd "$(dirname "${install_script}")" && bash "${install_script}"); then
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
        log "WARNING: install script failed: ${install_script}"
      fi
    fi
  done

  log "Custom node install script summary: total=${#install_scripts[@]} succeeded=${success_count} failed=${failed_count}"
  if (( failed_count == 0 )); then
    write_stamp "${stamp_file}" "${current_fingerprint}"
  else
    log "Install script run had failures; preserving previous stamp to retry next launch."
  fi
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
    if ! pip_install_with_fallback install --no-cache-dir -r "${comfy_requirements}"; then
      log "Failed installing ComfyUI core requirements."
      exit 1
    fi
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

ensure_comfyui_manager_v4() {
  local manager_package="comfyui-manager==4.2.2"
  local manager_archive_dir="${BOOTSTRAP_STATE_ROOT}/disabled-custom-nodes"
  local archived_manager_dir="${manager_archive_dir}/ComfyUI-Manager"
  local legacy_manager_dir

  log "Ensuring pip-installed ComfyUI-Manager v4 (${manager_package})."
  python3 -m pip install --break-system-packages --no-cache-dir --upgrade "${manager_package}"

  # V4 is a pip-installed Comfy extension. Keep any V3 clone OUTSIDE
  # custom_nodes so ComfyUI cannot import it alongside the package.
  mkdir -p "${manager_archive_dir}"
  for legacy_manager_dir in "${CUSTOM_NODES_DIR}/ComfyUI-Manager" "${CUSTOM_NODES_DIR}/ComfyUI-Manager.disabled"; do
    if [[ -e "${legacy_manager_dir}" ]]; then
      rm -rf "${archived_manager_dir}"
      mv "${legacy_manager_dir}" "${archived_manager_dir}"
      log "Archived legacy custom-node ComfyUI-Manager outside custom_nodes."
      break
    fi
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
    comfy_args=(--listen 127.0.0.1 "${comfy_args[@]}")
  fi

  # Manager v4 keeps its privileged HTTP surfaces disabled on a public bind.
  # Access this remote ComfyUI through the per-device SSH tunnel instead.
  for ((i=0; i<${#comfy_args[@]}; i++)); do
    case "${comfy_args[i]}" in
      --listen|--host)
        if (( i + 1 < ${#comfy_args[@]} )); then
          comfy_args[i+1]=127.0.0.1
        fi
        ;;
      --listen=*|--host=*)
        comfy_args[i]="${comfy_args[i]%%=*}=127.0.0.1"
        ;;
    esac
  done

  if [[ " ${comfy_args[*]} " != *" --enable-manager "* ]]; then
    comfy_args+=(--enable-manager)
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

validate_workflow_nodes_available() {
  local comfy_args_raw="${COMFYUI_ARGS:---listen 0.0.0.0 --port ${DEFAULT_COMFY_PORT}}"
  local -a comfy_args=()
  local configured_port=""

  read -r -a comfy_args <<< "${comfy_args_raw}"
  configured_port="$(get_comfy_port_from_args "${DEFAULT_COMFY_PORT}" "${comfy_args[@]}")"

  log "Validating workflow node classes against live ComfyUI object_info."
  python3 - "${WORKFLOWS_DIR}" "${configured_port}" <<'PY'
import glob
import json
import re
import sys
import urllib.request

workflows_dir = sys.argv[1]
port = sys.argv[2]
frontend_known = {
    "Fast Bypasser (rgthree)",
    "GetNode",
    "MarkdownNote",
    "Mute / Bypass Repeater (rgthree)",
    "Note",
    "Reroute",
    "SetNode",
}

def iter_types(obj):
    if isinstance(obj, dict):
        node_type = obj.get("class_type") or obj.get("type")
        if isinstance(node_type, str):
            yield node_type
        for value in obj.values():
            yield from iter_types(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from iter_types(item)

used = set()
for workflow_file in glob.glob(f"{workflows_dir}/*.json"):
    try:
        with open(workflow_file, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        continue
    used.update(iter_types(payload))

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=10) as response:
        object_info = json.load(response)
except Exception as exc:
    print(f"VALIDATION_ERROR unable to fetch object_info: {exc}")
    sys.exit(0)

available = set(object_info.keys())
missing = sorted(node for node in used if node not in available)
uuid_like = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

frontend_missing = []
runtime_missing = []
for node in missing:
    if node in frontend_known or uuid_like.match(node):
        frontend_missing.append(node)
    else:
        runtime_missing.append(node)

print(f"VALIDATION_SUMMARY workflows={len(glob.glob(f'{workflows_dir}/*.json'))} used={len(used)} available={len(available)} runtime_missing={len(runtime_missing)} frontend_missing={len(frontend_missing)}")
for node in runtime_missing:
    print(f"VALIDATION_RUNTIME_MISSING {node}")
for node in frontend_missing:
    print(f"VALIDATION_FRONTEND_MISSING {node}")
PY
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
  restore_settings

  # The paid-instance acceptance gate comes first: a usable Comfy/PyTorch
  # runtime must not wait behind Codex or dozens of optional node clones.
  install_comfy_requirements
  # The shared Agent Panel is a frontend extension; Node.js 22 is a runtime
  # requirement independent of optional remote Codex authentication.
  ensure_node_22
  restore_custom_nodes_snapshot
  fetch_manifest
  sync_custom_nodes
  install_node_requirements
  run_custom_node_install_scripts
  ensure_comfyui_manager_v4
  ensure_comfy_running
  start_private_tailscale_comfy
  validate_workflow_nodes_available

  # Nice-to-have tooling is deliberately post-readiness.
  restore_codex_home
  configure_codex_defaults
  install_codex_cli
  start_autosave_loop
  log "Bootstrap complete."
}

main "$@"
