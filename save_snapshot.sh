#!/usr/bin/env bash
# Publish an immutable, generation-scoped Comfy snapshot. The completion marker
# is the only authority switch and is written only after frozen-state upload and
# byte-for-byte verification succeed.
set -Eeuo pipefail

readonly WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
readonly DEFAULT_COMFY_ROOT="${COMFY_ROOT:-}"
readonly BOOTSTRAP_NAME="${BOOTSTRAP_NAME:-comfy-bootstrap}"
readonly B2_ROOT="${B2_ROOT:-myb2:comfy-bootstrap}"
readonly COMFY_STATE_ROOT="${COMFY_STATE_ROOT:-${B2_ROOT}}"
readonly PROVIDER_NAME="${PROVIDER_NAME:-vast}"
readonly CODEX_STATE_ROOT="${CODEX_STATE_ROOT:-myb2:comfy-provider-local/${PROVIDER_NAME}/codex-home}"
readonly GENERATION_ID="${SNAPSHOT_GENERATION_ID:-$(date -u '+%Y%m%dT%H%M%SZ')-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')}"
readonly REMOTE_ROOT="${COMFY_STATE_ROOT}/generations/${GENERATION_ID}"
readonly COMPLETION_REMOTE="${COMFY_STATE_ROOT}/snapshot.complete.json"
readonly BOOTSTRAP_ROOT="${BOOTSTRAP_ROOT_OVERRIDE:-${WORKSPACE_ROOT}/${BOOTSTRAP_NAME}}"
readonly MANIFEST_LOCAL="${BOOTSTRAP_ROOT}/custom_nodes_manifest.txt"
readonly CODEX_HOME_DIR="${WORKSPACE_ROOT}/.codex"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-3}"
readonly RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-10}"
readonly SNAPSHOT_LOCK_FILE="${WORKSPACE_ROOT}/.comfy-snapshot.lock"
readonly CUSTOM_NODES_RCLONE_ARGS=(
  --exclude ".git/**"
  --exclude "**/.git/**"
  --exclude "__pycache__/**"
  --exclude "**/__pycache__/**"
  --exclude "*.pyc"
  --exclude "node_modules/**"
  --exclude "**/node_modules/**"
  --exclude "comfyui-mcp-panel/**"
)
readonly CODEX_STABLE_FILES=(auth.json config.toml installation_id version.json)

COMFY_ROOT=""
WORKFLOWS_DIR=""
CUSTOM_NODES_DIR=""
STAGE_ROOT=""

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
require_env() { [[ -n "${!1:-}" ]] || { log "Missing required environment variable: $1"; exit 1; }; }
cleanup() { [[ -z "${STAGE_ROOT}" ]] || rm -rf "${STAGE_ROOT}"; }
trap cleanup EXIT

configure_rclone() {
  require_env B2_ACCOUNT_ID
  require_env B2_APP_KEY
  export RCLONE_CONFIG_MYB2_TYPE=b2
  export RCLONE_CONFIG_MYB2_ACCOUNT="${B2_ACCOUNT_ID}"
  export RCLONE_CONFIG_MYB2_KEY="${B2_APP_KEY}"
}

rclone_run() {
  rclone "$@" --retries "${RCLONE_RETRIES}" --low-level-retries "${RCLONE_LOW_LEVEL_RETRIES}"
}

is_comfy_root() {
  [[ -d "$1" && -f "$1/main.py" && -d "$1/custom_nodes" ]]
}

discover_comfy_root() {
  local candidate
  for candidate in "${DEFAULT_COMFY_ROOT}" "${WORKSPACE_ROOT}/ComfyUI" "${WORKSPACE_ROOT}/comfy/ComfyUI" /opt/ComfyUI /opt/comfyui /app/ComfyUI /ComfyUI /root/ComfyUI; do
    [[ -n "${candidate}" ]] || continue
    if is_comfy_root "${candidate}"; then COMFY_ROOT="${candidate}"; return 0; fi
  done
  log "Unable to locate ComfyUI for snapshot."
  exit 1
}

preflight_snapshot() {
  local port="${COMFYUI_ACTIVE_PORT:-8188}"
  [[ "${SNAPSHOT_WRITER:-0}" == "1" ]] || { log "Refusing snapshot: SNAPSHOT_WRITER=1 is required."; exit 1; }
  require_env SNAPSHOT_WRITER_ID
  [[ "${SNAPSHOT_WRITER_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || { log "Refusing invalid SNAPSHOT_WRITER_ID."; exit 1; }
  python3 "${BOOTSTRAP_ROOT}/snapshot_contract.py" generation "${GENERATION_ID}" >/dev/null
  curl -fsS --max-time 10 "http://127.0.0.1:${port}/system_stats" >/dev/null || { log "Refusing snapshot: ComfyUI unhealthy."; exit 1; }
  curl -fsS --max-time 10 "http://127.0.0.1:${port}/queue" | python3 -c '
import json,sys
q=json.load(sys.stdin)
raise SystemExit(1 if q.get("queue_running") or q.get("queue_pending") else 0)
' || { log "Refusing snapshot: ComfyUI queue is not idle."; exit 1; }
}

build_live_manifest() {
  local generated="${STAGE_ROOT}/custom_nodes_manifest.txt.tmp"
  if [[ -f "${BOOTSTRAP_ROOT}/generate_manifest.sh" ]]; then
    env WORKSPACE_ROOT="${WORKSPACE_ROOT}" COMFY_ROOT="${COMFY_ROOT}" \
      bash "${BOOTSTRAP_ROOT}/generate_manifest.sh" "${generated}"
  else
    : > "${generated}"
  fi
  [[ ! -f "${MANIFEST_LOCAL}" ]] || cat "${MANIFEST_LOCAL}" >> "${generated}"
  sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "${generated}" | LC_ALL=C sort -u > "${STAGE_ROOT}/custom_nodes_manifest.txt"
  rm -f "${generated}"
}

freeze_state() {
  STAGE_ROOT="$(mktemp -d "${WORKSPACE_ROOT}/.snapshot-stage.${GENERATION_ID}.XXXXXX")"
  mkdir -p "${STAGE_ROOT}/workflows" "${STAGE_ROOT}/settings" "${STAGE_ROOT}/custom_nodes"
  rclone_run sync "${WORKFLOWS_DIR}" "${STAGE_ROOT}/workflows" --check-first --create-empty-src-dirs
  rclone_run sync "${CUSTOM_NODES_DIR}" "${STAGE_ROOT}/custom_nodes" --check-first --create-empty-src-dirs "${CUSTOM_NODES_RCLONE_ARGS[@]}"
  [[ ! -f "${COMFY_ROOT}/extra_model_paths.yaml" ]] || install -m 0644 "${COMFY_ROOT}/extra_model_paths.yaml" "${STAGE_ROOT}/settings/extra_model_paths.yaml"
  if [[ -f "${COMFY_ROOT}/user/default/comfy.settings.json" ]]; then
    # Stage an object-validated scrubbed copy; never mutate the live settings file.
    python3 "${BOOTSTRAP_ROOT}/panel_bridge_policy.py" stage \
      "${COMFY_ROOT}/user/default/comfy.settings.json" \
      "${STAGE_ROOT}/settings/comfy.settings.json" \
      "${STAGE_ROOT}/settings/panel-bridge-policy.json"
  else
    python3 "${BOOTSTRAP_ROOT}/panel_bridge_policy.py" stage \
      <(printf '{}\n') "${STAGE_ROOT}/settings/comfy.settings.json" \
      "${STAGE_ROOT}/settings/panel-bridge-policy.json"
  fi
  [[ ! -f "${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini" ]] || install -m 0644 "${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini" "${STAGE_ROOT}/settings/ComfyUI-Manager-config.ini"
  [[ ! -f "${COMFY_ROOT}/user/__manager/config.ini" ]] || install -m 0644 "${COMFY_ROOT}/user/__manager/config.ini" "${STAGE_ROOT}/settings/manager-config.ini"
  build_live_manifest
}

sync_codex_stable_files() {
  local name
  [[ "${ENABLE_CODEX_SNAPSHOT:-0}" == "1" ]] || { log "Skipping provider-local Codex snapshot."; return 0; }
  for name in "${CODEX_STABLE_FILES[@]}"; do
    [[ ! -f "${CODEX_HOME_DIR}/${name}" ]] || rclone_run copyto "${CODEX_HOME_DIR}/${name}" "${CODEX_STATE_ROOT}/${name}"
  done
}

ensure_remote_generation_absent() {
  local existing=""
  if ! existing="$(rclone lsf "${REMOTE_ROOT}" --max-depth 1 2>/dev/null)"; then
    log "Unable to prove generation prefix absence; refusing publication."
    exit 1
  fi
  if [[ -n "${existing}" ]]; then
    log "Generation prefix already contains objects; refusing immutable overwrite: ${GENERATION_ID}"
    exit 1
  fi
}

publish_generation() {
  local bootstrap_commit manifest_sha completion
  ensure_remote_generation_absent
  bootstrap_commit="$(git -C "${BOOTSTRAP_ROOT}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  python3 "${BOOTSTRAP_ROOT}/snapshot_contract.py" create-manifest \
    "${STAGE_ROOT}" "${GENERATION_ID}" "${PROVIDER_NAME}" "${bootstrap_commit}" \
    "${STAGE_ROOT}/snapshot.manifest.json"
  python3 "${BOOTSTRAP_ROOT}/snapshot_contract.py" verify-stage \
    "${STAGE_ROOT}" "${STAGE_ROOT}/snapshot.manifest.json"

  log "Uploading frozen generation ${GENERATION_ID} as designated writer ${SNAPSHOT_WRITER_ID}."
  rclone_run sync "${STAGE_ROOT}" "${REMOTE_ROOT}" --check-first --create-empty-src-dirs
  rclone_run check "${STAGE_ROOT}" "${REMOTE_ROOT}"
  sync_codex_stable_files

  manifest_sha="$(sha256sum "${STAGE_ROOT}/snapshot.manifest.json" | awk '{print $1}')"
  completion="$(mktemp)"
  python3 - "${completion}" "${GENERATION_ID}" "${manifest_sha}" <<'PY'
import datetime,json,sys
out,generation,digest=sys.argv[1:]
with open(out,"w",encoding="utf-8") as f:
    json.dump({"schema":"comfy-state-completion-v1","generation":generation,
               "manifest_sha256":digest,"published_at":datetime.datetime.now(datetime.timezone.utc).isoformat()},
              f,sort_keys=True,separators=(",",":")); f.write("\n")
PY
  rclone_run copyto "${completion}" "${COMPLETION_REMOTE}"
  local remote_completion=""
  remote_completion="$(mktemp)"
  rclone_run copyto "${COMPLETION_REMOTE}" "${remote_completion}"
  cmp -s "${completion}" "${remote_completion}" || { log "Completion marker read-back mismatch."; exit 1; }
  rm -f "${completion}" "${remote_completion}"
  log "Published complete snapshot generation ${GENERATION_ID}."
}

main() {
  exec 9>"${SNAPSHOT_LOCK_FILE}"
  flock -n 9 || { log "Refusing concurrent local snapshot writer."; exit 1; }
  configure_rclone
  discover_comfy_root
  WORKFLOWS_DIR="${COMFY_ROOT}/user/default/workflows"
  CUSTOM_NODES_DIR="${COMFY_ROOT}/custom_nodes"
  preflight_snapshot
  freeze_state
  # The second health/idle gate proves the frozen tree was captured during a
  # quiescent interval rather than racing a generation or workflow edit.
  preflight_snapshot
  publish_generation
}

main "$@"
