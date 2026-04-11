#!/usr/bin/env bash
set -euo pipefail

readonly CUSTOM_NODES_DIR="/workspace/ComfyUI/custom_nodes"
readonly OUTPUT_FILE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/custom_nodes_manifest.txt}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

main() {
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  : > "${OUTPUT_FILE}"

  if [[ ! -d "${CUSTOM_NODES_DIR}" ]]; then
    log "Custom nodes directory not found at ${CUSTOM_NODES_DIR}; wrote empty manifest to ${OUTPUT_FILE}."
    exit 0
  fi

  while IFS= read -r git_dir; do
    local repo_dir remote_url
    repo_dir="$(dirname "${git_dir}")"
    remote_url="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"

    if [[ -n "${remote_url}" ]]; then
      printf '%s\n' "${remote_url}" >> "${OUTPUT_FILE}"
    fi
  done < <(find "${CUSTOM_NODES_DIR}" -mindepth 1 -maxdepth 2 -type d -name .git | sort)

  log "Wrote manifest to ${OUTPUT_FILE}."
}

main "$@"
