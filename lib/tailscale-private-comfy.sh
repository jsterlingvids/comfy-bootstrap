#!/usr/bin/env bash
# Optional private ComfyUI ingress for disposable GPU containers.
# This file deliberately contains no credential values.

install_tailscale_if_missing() {
  command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1 && return 0

  [[ -r /etc/os-release ]] || { log "Tailscale install requires a Debian/Ubuntu-compatible image."; return 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  local distro="${ID:-}" codename="${VERSION_CODENAME:-}"
  if [[ "${distro}" != "ubuntu" && "${distro}" != "debian" ]] || [[ -z "${codename}" ]]; then
    log "Unsupported OS for automatic Tailscale installation: ${distro:-unknown}/${codename:-unknown}."
    return 1
  fi

  log "Installing Tailscale from its signed ${distro}/${codename} package repository."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates gnupg
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/${distro}/${codename}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/${distro}/${codename}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-get install -y tailscale
}

_tailscale_hostname() {
  local raw="${TAILSCALE_HOSTNAME:-}"
  if [[ -z "${raw}" ]]; then
    raw="comfy-${TAILSCALE_PROVIDER:-gpu}-${RUNPOD_POD_ID:-${VAST_INSTANCE_ID:-${CONTAINER_ID:-$(hostname)}}}"
  fi
  printf '%s' "${raw,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//' | cut -c1-63
}

start_private_tailscale_comfy() {
  [[ "${TAILSCALE_ENABLED:-0}" == "1" ]] || { log "Tailscale private ingress disabled (TAILSCALE_ENABLED=${TAILSCALE_ENABLED:-0})."; return 0; }
  require_env "TAILSCALE_AUTH_KEY" || return 1

  local socket="${TAILSCALE_SOCKET:-/run/tailscale/tailscaled.sock}"
  # HTTPS Serve needs a writable certificate/config root. /run is tmpfs inside
  # the disposable container, so this remains non-persistent across teardown
  # while allowing Tailscale to obtain its Tailnet TLS certificate.
  local var_root="${TAILSCALE_VAR_ROOT:-/run/tailscale/state}"
  local state="${TAILSCALE_STATE:-${var_root}/tailscaled.state}"
  local port="${TAILSCALE_COMFY_PORT:-8443}"
  # onstart.sh sets COMFYUI_ACTIVE_PORT after enforcing loopback-only binding.
  # Fall back only for legacy callers that genuinely use the default listener.
  local target_port="${COMFYUI_ACTIVE_PORT:-${DEFAULT_COMFY_PORT:-8188}}"
  local hostname
  hostname="$(_tailscale_hostname)"
  [[ -n "${hostname}" ]] || { log "Could not derive a safe Tailscale hostname."; return 1; }
  [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) || { log "Invalid Tailscale Comfy port."; return 1; }
  [[ "${target_port}" =~ ^[0-9]+$ ]] && (( target_port >= 1 && target_port <= 65535 )) || { log "Invalid loopback ComfyUI target port."; return 1; }

  install_tailscale_if_missing
  install -d -m 0700 "$(dirname "${socket}")" "${var_root}"

  local tun_flag=()
  if [[ ! -c /dev/net/tun ]]; then
    tun_flag=(--tun=userspace-networking)
    log "No /dev/net/tun; using Tailscale userspace networking."
  fi

  if ! tailscale --socket="${socket}" status >/dev/null 2>&1; then
    log "Starting ephemeral Tailscale daemon for private ComfyUI access."
    tailscaled --state="${state}" --statedir="${var_root}" --socket="${socket}" "${tun_flag[@]}" \
      >> "${WORKSPACE_ROOT}/tailscaled.log" 2>&1 &
    local attempt=0
    until [[ -S "${socket}" ]] || (( attempt >= 30 )); do
      sleep 1
      attempt=$((attempt + 1))
    done
    [[ -S "${socket}" ]] || { log "Tailscaled did not create its control socket."; return 1; }
  fi

  # The key is never logged, persisted, or passed beyond `tailscale up`.
  tailscale --socket="${socket}" up \
    --auth-key="${TAILSCALE_AUTH_KEY}" \
    --hostname="${hostname}" \
    --advertise-tags=tag:comfy-gpu \
    --accept-dns=false \
    --accept-routes=false
  unset TAILSCALE_AUTH_KEY

  tailscale --socket="${socket}" serve --bg --https="${port}" http://127.0.0.1:${target_port}
  local dns_name
  dns_name="$(tailscale --socket="${socket}" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName", "").rstrip("."))')"
  [[ -n "${dns_name}" ]] || { log "Tailscale joined but did not report a DNS name."; return 1; }
  log "Private Tailnet ComfyUI ready: https://${dns_name}:${port}/"
}
