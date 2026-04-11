#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
readonly OUTPUT_FILE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/custom_nodes_manifest.txt}"

COMFY_ROOT=""
CUSTOM_NODES_DIR=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
      CUSTOM_NODES_DIR="${COMFY_ROOT}/custom_nodes"
      log "Detected ComfyUI at ${COMFY_ROOT}."
      return
    fi
  done

  candidate="$(find "${WORKSPACE_ROOT}" /opt /app /root -maxdepth 3 -type f -name main.py -path '*/ComfyUI/*' 2>/dev/null | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    COMFY_ROOT="$(dirname "${candidate}")"
    CUSTOM_NODES_DIR="${COMFY_ROOT}/custom_nodes"
    log "Detected ComfyUI at ${COMFY_ROOT}."
    return
  fi

  log "Unable to locate ComfyUI automatically."
  exit 1
}

main() {
  local tmp_output=""
  local sorted_output=""

  discover_comfy_root

  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  tmp_output="$(mktemp)"
  sorted_output="$(mktemp)"
  : > "${tmp_output}"

  if [[ ! -d "${CUSTOM_NODES_DIR}" ]]; then
    install -m 0644 "${tmp_output}" "${OUTPUT_FILE}"
    rm -f "${tmp_output}"
    rm -f "${sorted_output}"
    log "Custom nodes directory not found at ${CUSTOM_NODES_DIR}; wrote empty manifest to ${OUTPUT_FILE}."
    exit 0
  fi

  while IFS= read -r git_dir; do
    local repo_dir remote_url
    repo_dir="$(dirname "${git_dir}")"
    remote_url="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"

    if [[ -n "${remote_url}" ]]; then
      printf '%s\n' "${remote_url}" >> "${tmp_output}"
    fi
  done < <(find "${CUSTOM_NODES_DIR}" -mindepth 1 -maxdepth 2 -type d -name .git | sort)

  sort -u "${tmp_output}" > "${sorted_output}"
  install -m 0644 "${sorted_output}" "${OUTPUT_FILE}"
  rm -f "${tmp_output}"
  rm -f "${sorted_output}"
  log "Wrote manifest to ${OUTPUT_FILE}."
}

main "$@"
