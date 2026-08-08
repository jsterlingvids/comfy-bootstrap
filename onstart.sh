#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
# COMFY_STATE_ROOT is the provider-neutral, non-secret state surface.
# Point Vast and Runpod at the same value to share workflows, settings, and
# custom nodes. Keep CODEX_STATE_ROOT provider-local: interactive credentials
# must never be copied between GPU providers.
readonly LEGACY_B2_ROOT="${B2_ROOT:-myb2:comfy-bootstrap}"
COMFY_STATE_ROOT_WAS_SET=0
CODEX_STATE_ROOT_WAS_SET=0
[[ -v COMFY_STATE_ROOT ]] && COMFY_STATE_ROOT_WAS_SET=1
[[ -v CODEX_STATE_ROOT ]] && CODEX_STATE_ROOT_WAS_SET=1
COMFY_STATE_ROOT="${COMFY_STATE_ROOT:-${LEGACY_B2_ROOT}}"
readonly PROVIDER_NAME="${PROVIDER_NAME:-vast}"
CODEX_STATE_ROOT="${CODEX_STATE_ROOT:-myb2:comfy-provider-local/${PROVIDER_NAME}/codex-home}"
ACTIVE_STATE_ROOT=""
REMOTE_CUSTOM_NODES=""
REMOTE_WORKFLOWS=""
REMOTE_SETTINGS=""
REMOTE_CODEX_HOME=""
readonly AUTOSAVE_LOG="${WORKSPACE_ROOT}/autosave.log"
readonly AUTOSAVE_PIDFILE="${WORKSPACE_ROOT}/comfy-bootstrap-autosave.pid"
readonly COMFY_LOG="${WORKSPACE_ROOT}/comfyui.log"
readonly CODEX_HOME_DIR="${WORKSPACE_ROOT}/.codex"
readonly BOOTSTRAP_STATE_ROOT="${WORKSPACE_ROOT}/.comfy-bootstrap-state"
readonly DEFAULT_COMFY_PORT="8188"
RUNTIME_PYTHON=python3
if [[ -x /opt/conda/bin/python3 ]]; then
  RUNTIME_PYTHON=/opt/conda/bin/python3
fi
readonly RUNTIME_PYTHON
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/runtime-profile.sh
source "${SCRIPT_DIR}/lib/runtime-profile.sh"
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
SNAPSHOT_MODE="none"
SELECTED_GENERATION_ID=""
SELECTED_MANIFEST_SHA256=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

pip_install_with_fallback() {
  local -a pip_args=("$@")
  local -a network_args=(
    --retries "${PIP_NETWORK_RETRIES:-20}"
    --timeout "${PIP_NETWORK_TIMEOUT:-180}"
  )

  if "${RUNTIME_PYTHON}" -m pip "${pip_args[@]}" "${network_args[@]}"; then
    return 0
  fi

  log "pip install failed; retrying with --break-system-packages and resilient network settings."
  "${RUNTIME_PYTHON}" -m pip "${pip_args[@]}" "${network_args[@]}" --break-system-packages
}

requirements_use_existing_torch_build_env() {
  local requirements_file="$1"
  grep -Eiq 'github\.com[/:]facebookresearch/sam2(\.git)?([@#?[:space:]]|$)' "${requirements_file}"
}

capture_torch_runtime_identity() {
  "${RUNTIME_PYTHON}" - <<'PY'
import importlib
import importlib.metadata as metadata
import json
import torch
import torchaudio
import torchvision

payload = {
    "torch_version": torch.__version__,
    "torch_path": torch.__file__,
    "torch_cuda": torch.version.cuda,
    "torch_cuda_available": torch.cuda.is_available(),
    "torchaudio_version": torchaudio.__version__,
    "torchaudio_path": torchaudio.__file__,
    "torchvision_version": torchvision.__version__,
    "torchvision_path": torchvision.__file__,
}
try:
    sage = importlib.import_module("sageattention")
    payload.update({
        "sageattention_version": metadata.version("sageattention"),
        "sageattention_path": sage.__file__,
        "sageattention_import": "ok",
    })
except metadata.PackageNotFoundError:
    payload.update({
        "sageattention_version": "absent",
        "sageattention_path": "absent",
        "sageattention_import": "absent",
    })
print(json.dumps(payload, sort_keys=True))
PY
}

verify_approved_torch_runtime() {
  "${RUNTIME_PYTHON}" - \
    "${APPROVED_TORCH_VERSION}" \
    "${APPROVED_TORCHVISION_VERSION}" \
    "${APPROVED_TORCHAUDIO_VERSION}" \
    "${APPROVED_TORCH_CUDA_VERSION}" \
    "${APPROVED_SAGEATTENTION_VERSION}" <<'PY'
import importlib
import importlib.metadata as metadata
import sys
import torch
import torchaudio
import torchvision

expected = {
    "torch": sys.argv[1],
    "torchvision": sys.argv[2],
    "torchaudio": sys.argv[3],
    "cuda": sys.argv[4],
    "sageattention": sys.argv[5],
}
actual = {
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "torchaudio": torchaudio.__version__,
    "cuda": torch.version.cuda,
    "sageattention": metadata.version("sageattention"),
}
importlib.import_module("sageattention")
if not torch.cuda.is_available():
    raise SystemExit("approved runtime requires CUDA availability")
if actual != expected:
    raise SystemExit(f"approved runtime identity mismatch: expected={expected!r} actual={actual!r}")
PY
}

ensure_approved_torch_runtime() {
  if verify_approved_torch_runtime >/dev/null 2>&1; then
    log "Approved Torch/torchvision/CUDA/SageAttention runtime already present."
    return 0
  fi

  log "Installing the approved ${COMFY_RUNTIME_PROFILE} Torch runtime for this fresh Vast image."
  if ! pip_install_with_fallback install --no-cache-dir \
      --index-url "${APPROVED_TORCH_INDEX_URL}" \
      "torch==${APPROVED_TORCH_VERSION}" \
      "torchvision==${APPROVED_TORCHVISION_VERSION}" \
      "torchaudio==${APPROVED_TORCHAUDIO_VERSION}"; then
    log "Failed installing the approved Torch/torchvision/torchaudio runtime."
    return 1
  fi
  if ! pip_install_with_fallback install --no-cache-dir --no-deps \
      "sageattention==${APPROVED_SAGEATTENTION_VERSION}"; then
    log "Failed installing the approved SageAttention runtime without dependency mutation."
    return 1
  fi
  if ! verify_approved_torch_runtime; then
    log "Fresh-image runtime installation did not produce the exact approved identity."
    return 1
  fi
  log "Approved ${COMFY_RUNTIME_PROFILE} Torch runtime installed and verified."
}

write_torch_runtime_constraints() {
  local constraints_file="$1"
  "${RUNTIME_PYTHON}" - "${constraints_file}" <<'PY'
import importlib.metadata as metadata
import sys
import torch

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"torch=={torch.__version__}\n")
    handle.write(f"torchvision=={metadata.version('torchvision')}\n")
    handle.write(f"torchaudio=={metadata.version('torchaudio')}\n")
PY
}

verify_existing_torch_build_env() {
  "${RUNTIME_PYTHON}" - <<'PY'
import importlib.metadata as metadata
from packaging.version import Version
import torch

minimums = {
    "setuptools": "61.0",
    "torchvision": "0.20.1",
    "numpy": "1.24.4",
    "tqdm": "4.66.1",
    "hydra-core": "1.3.2",
    "iopath": "0.1.10",
    "pillow": "9.4.0",
}
if Version(torch.__version__.split("+", 1)[0]) < Version("2.5.1"):
    raise SystemExit(f"SAM2 requires torch>=2.5.1; found {torch.__version__}")
if not torch.cuda.is_available() or not torch.version.cuda:
    raise SystemExit("SAM2 build requires the existing CUDA-enabled Torch runtime")
for package, minimum in minimums.items():
    found = metadata.version(package)
    if Version(found.split("+", 1)[0]) < Version(minimum):
        raise SystemExit(f"SAM2 requires {package}>={minimum}; found {found}")
PY
}

verify_torch_runtime_unchanged() {
  local expected="$1"
  local actual=""
  verify_approved_torch_runtime || {
    log "Runtime no longer matches the immutable approved Torch/torchvision/CUDA/SageAttention identity; refusing readiness."
    return 1
  }
  actual="$(capture_torch_runtime_identity)" || return 1
  if [[ "${actual}" != "${expected}" ]]; then
    log "Torch/torchvision/SageAttention runtime identity changed during custom-node installation; refusing readiness."
    return 1
  fi
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
    "${RUNTIME_PYTHON}" --version 2>&1 || true
  } | sha256sum | awk '{print $1}'
}

runtime_environment_fingerprint_material() {
  local resolved_python=""
  resolved_python="$(readlink -f "$(command -v "${RUNTIME_PYTHON}")")"
  printf 'runtime_python=%s\n' "${resolved_python}"
  "${RUNTIME_PYTHON}" - <<'PY'
import importlib.metadata as metadata
import json
import sys
import torch
import torchaudio
import torchvision

print(json.dumps({
    "executable": sys.executable,
    "prefix": sys.prefix,
    "python": sys.version,
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "torchaudio": torchaudio.__version__,
    "cuda": torch.version.cuda,
    "sageattention": metadata.version("sageattention"),
}, sort_keys=True))
PY
  "${RUNTIME_PYTHON}" -m pip freeze --all | LC_ALL=C sort
  if [[ -f /opt/comfy-image/vcs-ref.txt ]]; then
    sha256sum /opt/comfy-image/vcs-ref.txt
  fi
}

compute_comfy_requirements_runtime_fingerprint() {
  local requirements_file="$1"
  {
    compute_file_fingerprint "${requirements_file}"
    runtime_environment_fingerprint_material
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

  runtime_environment_fingerprint_material
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

  runtime_environment_fingerprint_material
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


select_snapshot_generation() {
  local marker_tmp manifest_tmp generation expected_sha actual_sha parsed_marker
  local -a marker_fields=()
  marker_tmp="$(mktemp)"
  manifest_tmp="$(mktemp)"
  if ! rclone_bounded 25 copyto "${COMFY_STATE_ROOT}/snapshot.complete.json" "${marker_tmp}"; then
    rm -f "${marker_tmp}" "${manifest_tmp}"
    if [[ "${ALLOW_LEGACY_SNAPSHOT:-0}" == "1" ]]; then
      log "No completed generation marker; explicitly using legacy shared root for one-time migration."
      ACTIVE_STATE_ROOT="${COMFY_STATE_ROOT}"
      SNAPSHOT_MODE="legacy"
    else
      log "No valid completed snapshot generation; preserving immutable/repository baseline."
      return 0
    fi
  else
    if ! parsed_marker="$("${RUNTIME_PYTHON}" "${SCRIPT_DIR}/snapshot_contract.py" completion "${marker_tmp}")"; then
      rm -f "${marker_tmp}" "${manifest_tmp}"
      log "Snapshot completion marker is malformed; preserving immutable/repository baseline."
      return 0
    fi
    mapfile -t marker_fields <<< "${parsed_marker}"
    if (( ${#marker_fields[@]} != 2 )); then
      rm -f "${marker_tmp}" "${manifest_tmp}"
      log "Snapshot completion marker has invalid fields; preserving immutable/repository baseline."
      return 0
    fi
    generation="${marker_fields[0]}"
    expected_sha="${marker_fields[1]}"
    if ! rclone_bounded 25 copyto "${COMFY_STATE_ROOT}/generations/${generation}/snapshot.manifest.json" "${manifest_tmp}"; then
      rm -f "${marker_tmp}" "${manifest_tmp}"
      log "Completed generation manifest is unavailable; preserving immutable/repository baseline."
      return 0
    fi
    actual_sha="$(sha256sum "${manifest_tmp}" | awk '{print $1}')"
    if [[ "${actual_sha}" != "${expected_sha}" ]] || ! "${RUNTIME_PYTHON}" "${SCRIPT_DIR}/snapshot_contract.py" manifest \
      "${manifest_tmp}" "${generation}" "${expected_sha}"; then
      rm -f "${marker_tmp}" "${manifest_tmp}"
      log "Completed generation manifest failed integrity validation; preserving immutable/repository baseline."
      return 0
    fi
    ACTIVE_STATE_ROOT="${COMFY_STATE_ROOT}/generations/${generation}"
    SNAPSHOT_MODE="generation"
    SELECTED_GENERATION_ID="${generation}"
    SELECTED_MANIFEST_SHA256="${expected_sha}"
    log "Selected completed snapshot generation ${generation}."
  fi
  REMOTE_CUSTOM_NODES="${ACTIVE_STATE_ROOT}/custom_nodes"
  REMOTE_WORKFLOWS="${ACTIVE_STATE_ROOT}/workflows"
  REMOTE_SETTINGS="${ACTIVE_STATE_ROOT}/settings"
  rm -f "${marker_tmp}" "${manifest_tmp}"
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

rclone_bounded() {
  local timeout_seconds="$1"
  shift
  timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" rclone "$@" --contimeout 10s --timeout 25s --retries 1 --low-level-retries 1
}


restore_transactional_generation() {
  local stage_root
  local restore_timeout="${GENERATION_RESTORE_TIMEOUT_SECONDS:-600}"
  [[ "${SNAPSHOT_MODE}" == "generation" ]] || return 0
  if [[ ! "${restore_timeout}" =~ ^[0-9]+$ ]] || (( restore_timeout < 30 || restore_timeout > 900 )); then
    log "Invalid GENERATION_RESTORE_TIMEOUT_SECONDS=${restore_timeout}; expected 30-900."
    return 1
  fi
  stage_root="$(mktemp -d "${WORKSPACE_ROOT}/.snapshot-restore.${SELECTED_GENERATION_ID}.XXXXXX")"
  log "Downloading completed generation into an isolated restore stage (timeout=${restore_timeout}s)."
  if ! rclone_bounded "${restore_timeout}" sync "${ACTIVE_STATE_ROOT}" "${stage_root}" --create-empty-src-dirs; then
    rm -rf "${stage_root}"
    log "Generation download failed; immutable baseline was not modified."
    SNAPSHOT_MODE="none"
    ACTIVE_STATE_ROOT="${COMFY_STATE_ROOT}/unavailable"
    REMOTE_CUSTOM_NODES="${ACTIVE_STATE_ROOT}/custom_nodes"
    REMOTE_WORKFLOWS="${ACTIVE_STATE_ROOT}/workflows"
    REMOTE_SETTINGS="${ACTIVE_STATE_ROOT}/settings"
    return 0
  fi
  if ! "${RUNTIME_PYTHON}" "${SCRIPT_DIR}/snapshot_contract.py" manifest \
      "${stage_root}/snapshot.manifest.json" "${SELECTED_GENERATION_ID}" "${SELECTED_MANIFEST_SHA256}" ||
     ! "${RUNTIME_PYTHON}" "${SCRIPT_DIR}/snapshot_contract.py" verify-stage \
      "${stage_root}" "${stage_root}/snapshot.manifest.json"; then
    rm -rf "${stage_root}"
    log "Generation content failed integrity validation; immutable baseline was not modified."
    SNAPSHOT_MODE="none"
    ACTIVE_STATE_ROOT="${COMFY_STATE_ROOT}/unavailable"
    REMOTE_CUSTOM_NODES="${ACTIVE_STATE_ROOT}/custom_nodes"
    REMOTE_WORKFLOWS="${ACTIVE_STATE_ROOT}/workflows"
    REMOTE_SETTINGS="${ACTIVE_STATE_ROOT}/settings"
    return 0
  fi
  if ! "${RUNTIME_PYTHON}" "${SCRIPT_DIR}/snapshot_activate.py" \
      "${stage_root}" "${stage_root}/snapshot.manifest.json" "${COMFY_ROOT}"; then
    rm -rf "${stage_root}"
    log "Generation activation failed and was rolled back."
    return 1
  fi
  if [[ -f "${stage_root}/custom_nodes_manifest.txt" ]]; then
    install -m 0644 "${stage_root}/custom_nodes_manifest.txt" "${MANIFEST_REMOTE_CACHE}"
  fi
  rm -rf "${stage_root}"
  CUSTOM_NODES_SNAPSHOT_RESTORED=1
  log "Verified generation activated transactionally."
}


restore_workflows() {
  log "Restoring workflows from Backblaze B2 (bounded)."
  if rclone_bounded 60 sync "${REMOTE_WORKFLOWS}" "${WORKFLOWS_DIR}" --create-empty-src-dirs; then
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
    if rclone_bounded 35 copyto "${remote_file}" "${local_file}"; then
      log "Restored setting: ${state_file%%:*}"
    else
      log "Setting unavailable; preserving local/default value: ${state_file%%:*}"
    fi
  done
}

restore_custom_nodes_snapshot() {
  local restored_file_count=0
  local restore_timeout="${CUSTOM_NODES_RESTORE_TIMEOUT_SECONDS:-600}"
  local stage_root=""
  if (( CUSTOM_NODES_SNAPSHOT_RESTORED )); then
    log "Custom nodes already activated from a verified generation."
    return 0
  fi
  if [[ ! "${restore_timeout}" =~ ^[0-9]+$ ]] || (( restore_timeout < 30 || restore_timeout > 900 )); then
    log "Invalid CUSTOM_NODES_RESTORE_TIMEOUT_SECONDS=${restore_timeout}; expected 30-900."
    return 1
  fi

  stage_root="$(mktemp -d "${WORKSPACE_ROOT}/.legacy-custom-nodes.XXXXXX")"
  log "Downloading legacy custom-node snapshot into an isolated stage (timeout=${restore_timeout}s)."
  if ! rclone_bounded "${restore_timeout}" sync "${REMOTE_CUSTOM_NODES}" "${stage_root}/custom_nodes" --create-empty-src-dirs; then
    rm -rf "${stage_root}"
    log "Custom-node snapshot restore failed without mutating the baked baseline; falling back to manifest clones."
    return
  fi

  restored_file_count="$(find "${stage_root}/custom_nodes" -type f | wc -l)"
  if (( restored_file_count == 0 )); then
    rm -rf "${stage_root}"
    log "Custom-node snapshot was empty; falling back to manifest clones."
    return
  fi

  if ! "${RUNTIME_PYTHON}" "${SCRIPT_DIR}/snapshot_activate.py" --legacy-custom-nodes \
      "${stage_root}/custom_nodes" "${COMFY_ROOT}"; then
    rm -rf "${stage_root}"
    log "Legacy custom-node candidate failed safe activation; preserving the baked baseline."
    return 1
  fi
  rm -rf "${stage_root}"
  CUSTOM_NODES_SNAPSHOT_RESTORED=1
  log "Activated complete legacy custom-node snapshot (${restored_file_count} files) transactionally."
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

  if (( CUSTOM_NODES_SNAPSHOT_RESTORED )) && [[ -f "${MANIFEST_REMOTE_CACHE}" ]]; then
    install -m 0644 "${MANIFEST_REMOTE_CACHE}" "${tmp_remote}"
    normalize_manifest_file "${tmp_remote}" "${normalized_remote}" "verified generation"
    remote_count="$(wc -l < "${normalized_remote}")"
    log "Using the custom-node manifest retained from the verified generation."
  else
    : > "${normalized_remote}"
    remote_count=0
    log "No verified generation manifest is active; using the required repo baseline only. Optional legacy repos remain available for Manager/workflow re-download."
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

    if [[ "${trimmed,,}" == *"github.com/comfy-org/comfyui-manager"* ]]; then
      log "Ignoring legacy Manager v3 manifest entry; Manager v4 is pip-pinned."
      continue
    fi

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

  if ! command -v "${RUNTIME_PYTHON}" >/dev/null 2>&1; then
    log "python3 is missing; cannot install node requirements."
    exit 1
  fi
  if ! verify_approved_torch_runtime; then
    log "Approved Torch/torchvision/CUDA/SageAttention runtime preflight failed before custom-node requirements."
    return 1
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
  local torch_runtime_before=""
  local torch_constraints=""
  torch_runtime_before="$(capture_torch_runtime_identity)" || {
    log "WARNING: unable to capture the approved Torch runtime before custom-node dependency installation."
    return 1
  }
  torch_constraints="$(mktemp)"
  write_torch_runtime_constraints "${torch_constraints}"

  for requirements_file in "${requirements_files[@]}"; do
    log "Installing Python requirements from ${requirements_file}"
    if requirements_use_existing_torch_build_env "${requirements_file}"; then
      local filtered_requirements=""
      local sam2_specs_file=""
      local sam2_spec=""
      local sam2_count=0
      filtered_requirements="$(mktemp)"
      sam2_specs_file="$(mktemp)"
      grep -Eiv 'github\.com[/:]facebookresearch/sam2(\.git)?([@#?[:space:]]|$)' "${requirements_file}" > "${filtered_requirements}" || true
      grep -Ei 'github\.com[/:]facebookresearch/sam2(\.git)?([@#?[:space:]]|$)' "${requirements_file}" > "${sam2_specs_file}" || true
      sam2_count="$(grep -Ecve '^[[:space:]]*(#|$)' "${sam2_specs_file}" || true)"
      if [[ "${sam2_count}" != "1" ]]; then
        failed_count=$((failed_count + 1))
        log "WARNING: expected exactly one SAM2 requirement, found ${sam2_count}; refusing ambiguous installation."
        rm -f "${filtered_requirements}" "${sam2_specs_file}"
        continue
      fi
      torch_runtime_before="$(capture_torch_runtime_identity)" || {
        failed_count=$((failed_count + 1))
        rm -f "${filtered_requirements}" "${sam2_specs_file}"
        continue
      }
      write_torch_runtime_constraints "${torch_constraints}"
      if grep -Eqv '^[[:space:]]*(#|$)' "${filtered_requirements}" &&
         ! pip_install_with_fallback install --no-cache-dir -c "${torch_constraints}" -r "${filtered_requirements}"; then
        failed_count=$((failed_count + 1))
        log "WARNING: failed installing non-SAM2 requirements while preserving Torch constraints."
        rm -f "${filtered_requirements}" "${sam2_specs_file}"
        continue
      fi
      if ! verify_existing_torch_build_env; then
        failed_count=$((failed_count + 1))
        log "WARNING: refusing SAM2 installation because the existing CUDA/Torch build environment is incomplete."
        rm -f "${filtered_requirements}" "${sam2_specs_file}"
        continue
      fi
      sam2_spec="$(grep -Eve '^[[:space:]]*(#|$)' "${sam2_specs_file}")"
      log "SAM2 detected; building only SAM2 against the existing constrained Torch runtime."
      if pip_install_with_fallback install --no-cache-dir --no-build-isolation --no-deps -c "${torch_constraints}" "${sam2_spec}" &&
         verify_torch_runtime_unchanged "${torch_runtime_before}"; then
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
        log "WARNING: SAM2 installation or Torch/torchvision/SageAttention identity verification failed."
      fi
      rm -f "${filtered_requirements}" "${sam2_specs_file}"
    elif pip_install_with_fallback install --no-cache-dir -c "${torch_constraints}" -r "${requirements_file}" &&
         verify_torch_runtime_unchanged "${torch_runtime_before}"; then
      success_count=$((success_count + 1))
    else
      failed_count=$((failed_count + 1))
      log "WARNING: failed installing requirements from ${requirements_file} while preserving Torch/torchvision/SageAttention identity."
    fi
  done
  rm -f "${torch_constraints}"

  log "Custom node requirements install summary: total=${#requirements_files[@]} succeeded=${success_count} failed=${failed_count}"
  if (( failed_count == 0 )); then
    current_fingerprint="$(compute_node_requirements_fingerprint | sha256sum | awk '{print $1}')"
    write_stamp "${stamp_file}" "${current_fingerprint}"
  else
    rm -f "${stamp_file}"
    log "WARNING: optional custom-node requirements had failures; invalidated the stamp for retry. Required workflow-node validation remains authoritative."
  fi
  if ! verify_approved_torch_runtime; then
    log "Approved runtime identity drifted during custom-node requirements; refusing readiness."
    return 1
  fi
}

run_custom_node_install_scripts() {
  local -a install_scripts=()
  local current_fingerprint=""
  local current_stamp=""
  local stamp_file="${STATE_DIR}/custom-node-install-scripts.sha256"
  local install_script=""
  local torch_runtime_before=""
  local torch_constraints=""
  local success_count=0
  local failed_count=0

  if ! command -v "${RUNTIME_PYTHON}" >/dev/null 2>&1; then
    log "python3 is missing; cannot run custom node install scripts."
    exit 1
  fi
  if ! verify_approved_torch_runtime; then
    log "Approved Torch/torchvision/CUDA/SageAttention runtime preflight failed before custom-node install scripts."
    return 1
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

  torch_runtime_before="$(capture_torch_runtime_identity)" || {
    log "WARNING: unable to capture the approved Torch runtime before custom-node install scripts."
    return 1
  }
  torch_constraints="$(mktemp)"
  write_torch_runtime_constraints "${torch_constraints}"

  for install_script in "${install_scripts[@]}"; do
    log "Running custom node install script with constrained Torch runtime: ${install_script}"
    if [[ "${install_script}" == *.py ]]; then
      if (cd "$(dirname "${install_script}")" && PATH="$(dirname "${RUNTIME_PYTHON}"):${PATH}" PYTHON="${RUNTIME_PYTHON}" PIP_CONSTRAINT="${torch_constraints}" "${RUNTIME_PYTHON}" "${install_script}") &&
         verify_torch_runtime_unchanged "${torch_runtime_before}"; then
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
        log "WARNING: install script failed or changed Torch/torchvision/SageAttention identity: ${install_script}"
      fi
    else
      if (cd "$(dirname "${install_script}")" && PATH="$(dirname "${RUNTIME_PYTHON}"):${PATH}" PYTHON="${RUNTIME_PYTHON}" PIP_CONSTRAINT="${torch_constraints}" bash "${install_script}") &&
         verify_torch_runtime_unchanged "${torch_runtime_before}"; then
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
        log "WARNING: install script failed or changed Torch/torchvision/SageAttention identity: ${install_script}"
      fi
    fi
  done
  rm -f "${torch_constraints}"

  log "Custom node install script summary: total=${#install_scripts[@]} succeeded=${success_count} failed=${failed_count}"
  if (( failed_count == 0 )); then
    # Stamp only the exact pre-hook scripts/environment that were executed. If a
    # hook mutates itself, requirements, or installed packages, the next launch
    # must observe that drift and rerun the affected phase.
    write_stamp "${stamp_file}" "${current_fingerprint}"
  else
    rm -f "${stamp_file}"
    log "WARNING: optional custom-node install scripts had failures; invalidated the stamp for retry. Required workflow-node validation remains authoritative."
  fi
  if ! verify_approved_torch_runtime; then
    log "Approved runtime identity drifted during custom-node install scripts; refusing readiness."
    return 1
  fi
}

install_comfy_requirements() {
  local comfy_requirements="${COMFY_ROOT}/requirements.txt"
  local current_fingerprint=""
  local current_stamp=""
  local torch_runtime_before=""
  local torch_constraints=""
  local stamp_file="${STATE_DIR}/comfy-requirements.sha256"

  if ! command -v "${RUNTIME_PYTHON}" >/dev/null 2>&1; then
    log "Selected runtime Python is missing; cannot install ComfyUI requirements."
    exit 1
  fi
  if ! verify_approved_torch_runtime; then
    log "Approved Torch/torchvision/CUDA/SageAttention runtime preflight failed before ComfyUI requirements."
    exit 1
  fi

  if [[ -f "${comfy_requirements}" ]]; then
    current_fingerprint="$(compute_comfy_requirements_runtime_fingerprint "${comfy_requirements}")"
    current_stamp="$(read_stamp "${stamp_file}")"
    if [[ "${current_fingerprint}" == "${current_stamp}" ]]; then
      log "ComfyUI core requirements unchanged; skipping reinstall."
      return
    fi

    log "Installing ComfyUI core requirements from ${comfy_requirements} under immutable Torch constraints."
    torch_runtime_before="$(capture_torch_runtime_identity)" || exit 1
    torch_constraints="$(mktemp)"
    write_torch_runtime_constraints "${torch_constraints}"
    if ! pip_install_with_fallback install --no-cache-dir -c "${torch_constraints}" -r "${comfy_requirements}" ||
       ! verify_torch_runtime_unchanged "${torch_runtime_before}"; then
      rm -f "${torch_constraints}"
      log "Failed installing ComfyUI core requirements without runtime identity drift."
      exit 1
    fi
    rm -f "${torch_constraints}"
    current_fingerprint="$(compute_comfy_requirements_runtime_fingerprint "${comfy_requirements}")"
    write_stamp "${stamp_file}" "${current_fingerprint}"
  else
    log "ComfyUI requirements.txt not found at ${comfy_requirements}; skipping core dependency install."
  fi
}

start_autosave_loop() {
  if [[ "${SNAPSHOT_WRITER:-0}" != "1" ]]; then
    log "Autosave disabled: this instance is not the designated snapshot writer."
    return 0
  fi
  if [[ -z "${SNAPSHOT_WRITER_ID:-}" ]]; then
    log "Autosave refused: designated writers require SNAPSHOT_WRITER_ID."
    return 1
  fi
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
    export COMFY_ROOT WORKSPACE_ROOT COMFY_STATE_ROOT CODEX_STATE_ROOT PROVIDER_NAME SNAPSHOT_WRITER SNAPSHOT_WRITER_ID
    while true; do
      bash "${BOOTSTRAP_ROOT}/save_snapshot.sh" || true
      sleep 300
    done
  ) </dev/null >>"${AUTOSAVE_LOG}" 2>&1 &
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


list_loopback_listening_pids_for_port() {
  local port="$1"

  ss -ltnp 2>/dev/null | awk -v port="${port}" '$4 == "127.0.0.1:" port || $4 == "[::1]:" port' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u
}
pid_matches_comfy_root() {
  local pid="$1"
  local cmdline=""
  local cwd=""
  local process_executable=""
  local expected_executable=""

  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  [[ -L "/proc/${pid}/cwd" ]] || return 1
  [[ -L "/proc/${pid}/exe" ]] || return 1

  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
  process_executable="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
  expected_executable="$(readlink -f "$(command -v "${RUNTIME_PYTHON}")" 2>/dev/null || true)"

  [[ -n "${cmdline}" ]] || return 1
  [[ "${cmdline}" == *"main.py"* ]] || return 1
  [[ "${cwd}" == "${COMFY_ROOT}" ]] || return 1
  [[ -n "${expected_executable}" && "${process_executable}" == "${expected_executable}" ]] || return 1
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
  done < <(list_loopback_listening_pids_for_port "${port}")
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

ensure_mcp_panel_pinned() {
  local panel_repo="${MCP_PANEL_REPOSITORY:-${SCRIPT_DIR}/vendor/comfyui-mcp-panel.bundle}"
  local panel_commit="${MCP_PANEL_COMMIT:-889589cf555ef907b3762cb40e21893c8863d0c8}"
  local panel_bundle_sha256="${MCP_PANEL_BUNDLE_SHA256:-c7cf9d0b5253ed3c68cbed6d8b25665c6c123e2d51062e8863cc718f48fbc21c}"
  local panel_dir="${CUSTOM_NODES_DIR}/comfyui-mcp-panel"
  local archive_dir=""
  archive_dir="${BOOTSTRAP_STATE_ROOT}/disabled-custom-nodes/comfyui-mcp-panel-$(date -u '+%Y%m%dT%H%M%SZ')"
  local current_origin="" current_commit=""

  if [[ -d "${panel_dir}/.git" ]]; then
    current_origin="$(git -C "${panel_dir}" remote get-url origin 2>/dev/null || true)"
    current_commit="$(git -C "${panel_dir}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${current_origin}" == "${panel_repo}" && "${current_commit}" == "${panel_commit}" ]] &&
       [[ -f "${panel_dir}/__init__.py" && -f "${panel_dir}/web/js/comfyui-mcp-panel.js" ]] &&
       grep -Fq 'advertise_bridge' "${panel_dir}/__init__.py" &&
       grep -Fq 'bridge_url' "${panel_dir}/__init__.py" &&
       grep -Fq 'model_download_routes' "${panel_dir}/__init__.py" &&
       grep -Fq 'models_download' "${panel_dir}/web/js/comfyui-mcp-panel.js" &&
       grep -Fq 'graph_stage_input_image' "${panel_dir}/web/js/comfyui-mcp-panel.js" &&
       grep -Fq 'graph_stage_input_video' "${panel_dir}/web/js/comfyui-mcp-panel.js"; then
      log "Pinned MCP Panel already present and source markers verified at ${panel_commit}."
      return 0
    fi
  fi

  if [[ -e "${panel_dir}" ]]; then
    mkdir -p "$(dirname "${archive_dir}")"
    mv "${panel_dir}" "${archive_dir}"
    log "Archived non-canonical MCP Panel outside custom_nodes."
  fi
  log "Installing pinned MCP Panel commit ${panel_commit}."
  if [[ -f "${panel_repo}" ]]; then
    if [[ "$(sha256sum "${panel_repo}" | awk '{print $1}')" != "${panel_bundle_sha256}" ]]; then
      log "Vendored MCP Panel bundle checksum mismatch."
      return 1
    fi
    git clone --no-checkout "${panel_repo}" "${panel_dir}"
  else
    git clone --filter=blob:none --no-checkout "${panel_repo}" "${panel_dir}"
    git -C "${panel_dir}" fetch --depth 1 origin "${panel_commit}"
  fi
  git -C "${panel_dir}" checkout --detach "${panel_commit}"
  if ! { [[ -f "${panel_dir}/__init__.py" && -f "${panel_dir}/web/js/comfyui-mcp-panel.js" ]] &&
    grep -Fq 'advertise_bridge' "${panel_dir}/__init__.py" &&
    grep -Fq 'bridge_url' "${panel_dir}/__init__.py" &&
    grep -Fq 'model_download_routes' "${panel_dir}/__init__.py" &&
    grep -Fq 'models_download' "${panel_dir}/web/js/comfyui-mcp-panel.js" &&
    grep -Fq 'graph_stage_input_image' "${panel_dir}/web/js/comfyui-mcp-panel.js" &&
       grep -Fq 'graph_stage_input_video' "${panel_dir}/web/js/comfyui-mcp-panel.js"; }; then
    log "Pinned MCP Panel source markers are missing."
    return 1
  fi
}


ensure_comfyui_manager_v4() {
  local manager_package="comfyui-manager==4.2.2"
  local manager_archive_dir="${BOOTSTRAP_STATE_ROOT}/disabled-custom-nodes"
  local archived_manager_dir="${manager_archive_dir}/ComfyUI-Manager"
  local legacy_manager_dir
  local torch_runtime_before=""
  local torch_constraints=""

  log "Ensuring pip-installed ComfyUI-Manager v4 (${manager_package})."
  if "${RUNTIME_PYTHON}" -c 'import importlib.metadata; raise SystemExit(0 if importlib.metadata.version("comfyui-manager") == "4.2.2" else 1)' 2>/dev/null; then
    log "ComfyUI-Manager 4.2.2 already installed."
  else
    torch_runtime_before="$(capture_torch_runtime_identity)" || return 1
    torch_constraints="$(mktemp)"
    write_torch_runtime_constraints "${torch_constraints}"
    if ! "${RUNTIME_PYTHON}" -m pip install --break-system-packages --no-cache-dir --upgrade -c "${torch_constraints}" "${manager_package}" ||
       ! verify_torch_runtime_unchanged "${torch_runtime_before}"; then
      rm -f "${torch_constraints}"
      log "ComfyUI-Manager installation failed or changed approved runtime identity."
      return 1
    fi
    rm -f "${torch_constraints}"
  fi

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
  local comfy_args_raw="${COMFYUI_ARGS:---listen 127.0.0.1 --port ${DEFAULT_COMFY_PORT}}"
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
  # Shared with the sourced private Tailscale helper so Serve always points at
  # the actual loopback ComfyUI listener, even when a template changes its port.
  COMFYUI_ACTIVE_PORT="${configured_port}"
  export COMFYUI_ACTIVE_PORT
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

  export COMFYUI_MCP_NO_AUTOSPAWN=1
  log "Starting ComfyUI with args: ${comfy_args[*]}"
  launch_pid="$(
    cd "${COMFY_ROOT}"
    nohup "${RUNTIME_PYTHON}" main.py "${comfy_args[@]}" >>"${COMFY_LOG}" 2>&1 &
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

restart_comfy_if_idle() {
  local port="${COMFYUI_ACTIVE_PORT:-${DEFAULT_COMFY_PORT}}"
  local listener_pid=""
  listener_pid="$(find_comfy_listener_pid_for_port "${port}" || true)"
  if [[ -z "${listener_pid}" ]]; then
    ensure_comfy_running
    return 0
  fi
  if ! curl -fsS --max-time 10 "http://127.0.0.1:${port}/queue" | "${RUNTIME_PYTHON}" -c '
import json,sys
q=json.load(sys.stdin)
raise SystemExit(0 if not q.get("queue_running") and not q.get("queue_pending") else 1)
'; then
    log "ComfyUI queue is not idle; deferring state-reload restart."
    return 2
  fi
  log "Restarting idle ComfyUI PID ${listener_pid} to load restored integrations."
  kill -TERM "${listener_pid}"
  local attempts=30
  while kill -0 "${listener_pid}" 2>/dev/null && (( attempts > 0 )); do
    sleep 1
    attempts=$((attempts - 1))
  done
  if kill -0 "${listener_pid}" 2>/dev/null; then
    log "ComfyUI did not stop gracefully; refusing forced termination."
    return 1
  fi
  ensure_comfy_running
}


advertise_hermes_bridge() {
  local bridge_url="${HERMES_PANEL_BRIDGE_URL:-}"
  local port="${COMFYUI_ACTIVE_PORT:-${DEFAULT_COMFY_PORT}}"
  [[ -n "${bridge_url}" ]] || {
    log "HERMES_PANEL_BRIDGE_URL is required for MCP Panel/Hermes control readiness."
    return 1
  }
  [[ "${bridge_url}" == wss://* ]] || {
    log "Refusing non-WSS Hermes panel bridge URL."
    return 1
  }
  if ! HERMES_PANEL_BRIDGE_URL="${bridge_url}" "${RUNTIME_PYTHON}" -c 'import json,os; print(json.dumps({"url":os.environ["HERMES_PANEL_BRIDGE_URL"]}))' |
      curl -fsS --max-time 10 -H 'content-type: application/json' --data-binary @- \
        "http://127.0.0.1:${port}/comfyui_mcp_panel/advertise_bridge" >/dev/null; then
    log "Failed to advertise the private Hermes bridge to MCP Panel."
    return 1
  fi
  if ! HERMES_PANEL_BRIDGE_URL="${bridge_url}" curl -fsS --max-time 10 \
      "http://127.0.0.1:${port}/comfyui_mcp_panel/bridge_url" |
      "${RUNTIME_PYTHON}" -c 'import json,os,sys; assert json.load(sys.stdin).get("url")==os.environ["HERMES_PANEL_BRIDGE_URL"]'; then
    log "MCP Panel did not retain the advertised Hermes bridge URL."
    return 1
  fi
  log "Private WSS Hermes bridge advertised and verified without logging its capability token."
}


validate_workflow_nodes_available() {
  local comfy_args_raw="${COMFYUI_ARGS:---listen 127.0.0.1 --port ${DEFAULT_COMFY_PORT}}"
  local -a comfy_args=()
  local configured_port=""
  local policy="${WORKFLOW_VALIDATION_POLICY:-required}"

  read -r -a comfy_args <<< "${comfy_args_raw}"
  configured_port="$(get_comfy_port_from_args "${DEFAULT_COMFY_PORT}" "${comfy_args[@]}")"
  case "${policy}" in
    report|required|strict) ;;
    *)
      log "Invalid WORKFLOW_VALIDATION_POLICY=${policy}; expected report, required, or strict."
      return 1
      ;;
  esac

  log "Validating workflow node classes against live ComfyUI object_info (policy=${policy})."
  "${RUNTIME_PYTHON}" "${SCRIPT_DIR}/workflow_validation.py" \
    "${WORKFLOWS_DIR}" "${configured_port}" \
    --policy "${policy}" \
    --required "${REQUIRED_RUNTIME_NODES:-}" \
    --report "${WORKSPACE_ROOT}/workflow-node-validation.json"
}

hydrate_runtime_env_allowlist() {
  # Vast can retain account-level configuration only in PID 1 when it forks the
  # user onstart script. Import only named bootstrap values and never print the
  # source environment or any imported value.
  local environ_path="/proc/1/environ"
  [[ -r "${environ_path}" ]] || return 0
  local item name
  while IFS= read -r -d '' item; do
    name="${item%%=*}"
    case "${name}" in
      COMFY_STATE_ROOT)
        (( COMFY_STATE_ROOT_WAS_SET == 1 )) || COMFY_STATE_ROOT="${item#*=}"
        ;;
      CODEX_STATE_ROOT)
        (( CODEX_STATE_ROOT_WAS_SET == 1 )) || CODEX_STATE_ROOT="${item#*=}"
        ;;
      B2_ACCOUNT_ID|B2_APP_KEY|B2_BUCKET|B2_ENDPOINT|TAILSCALE_AUTH_KEY|TAILSCALE_ENABLED|TAILSCALE_PROVIDER|TAILSCALE_COMFY_PORT|TAILSCALE_STATE|TAILSCALE_VAR_ROOT|HERMES_PANEL_BRIDGE_URL|ALLOW_LEGACY_SNAPSHOT|REQUIRED_RUNTIME_NODES|WORKFLOW_VALIDATION_POLICY|TAILSCALE_PROOF_ONLY|SNAPSHOT_WRITER|SNAPSHOT_WRITER_ID)
        [[ -v "${name}" ]] || export "${name}=${item#*=}"
        ;;
    esac
  done < "${environ_path}"
}

finalize_runtime_state_roots() {
  ACTIVE_STATE_ROOT="${COMFY_STATE_ROOT}/unavailable"
  REMOTE_CUSTOM_NODES="${ACTIVE_STATE_ROOT}/custom_nodes"
  REMOTE_WORKFLOWS="${ACTIVE_STATE_ROOT}/workflows"
  REMOTE_SETTINGS="${ACTIVE_STATE_ROOT}/settings"
  REMOTE_CODEX_HOME="${CODEX_STATE_ROOT}"
  readonly COMFY_STATE_ROOT CODEX_STATE_ROOT REMOTE_CODEX_HOME
}

main() {
  hydrate_runtime_env_allowlist
  finalize_runtime_state_roots
  log "Bootstrap starting."
  wait_for_workspace
  install_packages_if_missing
  discover_comfy_root
  initialize_paths
  ensure_approved_torch_runtime

  if [[ "${TAILSCALE_PROOF_ONLY:-0}" == "1" ]]; then
    log "Running bounded Tailnet proof only; skipping B2-dependent state/bootstrap work."
    ensure_directories
    install_comfy_requirements
    ensure_comfy_running
    start_private_tailscale_comfy
    log "Bounded Tailnet proof bootstrap complete."
    return 0
  fi

  configure_rclone
  select_snapshot_generation
  ensure_directories
  case "${SNAPSHOT_MODE}" in
    generation)
      restore_transactional_generation
      ;;
    legacy)
      restore_workflows
      restore_settings
      ;;
    none)
      log "No restorable snapshot selected; retaining immutable/repository baseline."
      ;;
  esac

  install_comfy_requirements
  ensure_node_22
  restore_custom_nodes_snapshot
  fetch_manifest
  sync_custom_nodes
  ensure_mcp_panel_pinned
  ensure_comfyui_manager_v4
  restart_comfy_if_idle
  start_private_tailscale_comfy
  advertise_hermes_bridge

  install_node_requirements
  run_custom_node_install_scripts
  verify_approved_torch_runtime || {
    log "Final approved Torch/torchvision/CUDA/SageAttention gate failed after all custom-node dependency hooks."
    return 1
  }
  if restart_comfy_if_idle; then
    advertise_hermes_bridge
  else
    log "Full custom-node reload was deferred; refusing readiness until the live registry can be validated."
    return 1
  fi
  validate_workflow_nodes_available

  restore_codex_home
  configure_codex_defaults
  install_codex_cli
  start_autosave_loop
  log "Bootstrap complete."
}
main "$@"
