#!/usr/bin/env bash
# Exact immutable runtime identities shared by provider bootstraps.
# cu130 remains the default so existing certified templates are unchanged.
# Vast's launcher can retain template env only in PID 1. Hydrate just this
# non-secret selector before locking the profile; explicit child values win.
if [[ ! -v COMFY_RUNTIME_PROFILE && -r /proc/1/environ ]]; then
  while IFS= read -r -d '' runtime_item; do
    if [[ "${runtime_item%%=*}" == "COMFY_RUNTIME_PROFILE" ]]; then
      export COMFY_RUNTIME_PROFILE="${runtime_item#*=}"
      break
    fi
  done < /proc/1/environ
fi
case "${COMFY_RUNTIME_PROFILE:-cu130}" in
  cu130)
    COMFY_RUNTIME_PROFILE="cu130"
    APPROVED_TORCH_VERSION="2.9.1+cu130"
    APPROVED_TORCHVISION_VERSION="0.24.1+cu130"
    APPROVED_TORCHAUDIO_VERSION="2.9.1+cu130"
    APPROVED_TORCH_CUDA_VERSION="13.0"
    APPROVED_TORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"
    ;;
  cu128)
    COMFY_RUNTIME_PROFILE="cu128"
    APPROVED_TORCH_VERSION="2.9.1+cu128"
    APPROVED_TORCHVISION_VERSION="0.24.1+cu128"
    APPROVED_TORCHAUDIO_VERSION="2.9.1+cu128"
    APPROVED_TORCH_CUDA_VERSION="12.8"
    APPROVED_TORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"
    ;;
  *)
    printf 'Unsupported COMFY_RUNTIME_PROFILE: %s\n' "${COMFY_RUNTIME_PROFILE}" >&2
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
      exit 64
    fi
    return 64
    ;;
esac
APPROVED_SAGEATTENTION_VERSION="1.0.6"
# Consumed by the sourcing bootstrap; standalone ShellCheck cannot see that use.
# shellcheck disable=SC2034
readonly COMFY_RUNTIME_PROFILE
# shellcheck disable=SC2034
readonly APPROVED_TORCH_VERSION
# shellcheck disable=SC2034
readonly APPROVED_TORCHVISION_VERSION
# shellcheck disable=SC2034
readonly APPROVED_TORCHAUDIO_VERSION
# shellcheck disable=SC2034
readonly APPROVED_TORCH_CUDA_VERSION
# shellcheck disable=SC2034
readonly APPROVED_TORCH_INDEX_URL
# shellcheck disable=SC2034
readonly APPROVED_SAGEATTENTION_VERSION
