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
MANIFEST_REMOTE_CACHE=""
MANIFEST_ACTIVE=""
STATE_DIR=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

pip_install_with_fallback() {
  local -a pip_args=("$@")

  if python3 -m pip "${pip_args[@]}"; then
    return 0
  fi

  log "pip install failed; retrying with --break-system-packages."
  python3 -m pip "${pip_args[@]}" --break-system-packages
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
