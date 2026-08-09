#!/usr/bin/env python3
"""Fail-closed policy for ComfyUI MCP Panel bridge override settings.

The only durable bridge authority is per-instance advertisement.  Snapshot state
may carry unrelated Comfy settings, but never a manually entered bridge endpoint.
"""
from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path
from typing import Any

POLICY_FILENAME = "panel-bridge-policy.json"
POLICY = {
    "schema": "comfy-panel-bridge-policy-v1",
    "advertised_bridge_discovery": "current-instance",
    "manual_bridge_override": "clear",
}
# The current single-key setting, all historical per-backend settings, and the
# historical local-storage-shaped setting if a Comfy build persisted it.
MANUAL_BRIDGE_OVERRIDE_PREFIXES = (
    "comfyui-mcp.bridgeUrl",
    "comfyui-mcp.panel.bridgeUrl",
)


class PolicyError(ValueError):
    """The policy marker or Comfy settings file is not safe to apply."""


def _load_object(path: str | Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PolicyError(f"invalid {description}") from exc
    if not isinstance(value, dict):
        raise PolicyError(f"{description} must be an object")
    return value


def validate_policy(path: str | Path) -> dict[str, str]:
    value = _load_object(path, "panel bridge policy")
    if value != POLICY:
        raise PolicyError("panel bridge policy shape mismatch")
    return POLICY.copy()


def is_manual_bridge_override_key(key: object) -> bool:
    return isinstance(key, str) and key.startswith(MANUAL_BRIDGE_OVERRIDE_PREFIXES)


def scrub_manual_bridge_overrides(settings: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in settings.items() if not is_manual_bridge_override_key(key)}


def _atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def stage_settings(live_path: str | Path, staged_path: str | Path, policy_path: str | Path) -> None:
    """Create a scrubbed staged copy and fixed policy without modifying ``live_path``."""
    settings = _load_object(live_path, "Comfy settings")
    _atomic_write_json(Path(staged_path), scrub_manual_bridge_overrides(settings))
    _atomic_write_json(Path(policy_path), POLICY)


def apply_policy(settings_path: str | Path, policy_path: str | Path) -> bool:
    """Validate policy before changing settings, returning whether a file was applied."""
    validate_policy(policy_path)
    target = Path(settings_path)
    if not target.exists():
        return False
    if target.is_symlink() or not target.is_file():
        raise PolicyError("Comfy settings must be a regular file")
    settings = _load_object(target, "Comfy settings")
    _atomic_write_json(target, scrub_manual_bridge_overrides(settings))
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("stage")
    stage.add_argument("live_settings")
    stage.add_argument("staged_settings")
    stage.add_argument("policy")
    validate = commands.add_parser("validate")
    validate.add_argument("policy")
    apply = commands.add_parser("apply")
    apply.add_argument("settings")
    apply.add_argument("policy")
    args = parser.parse_args()
    try:
        if args.command == "stage":
            stage_settings(args.live_settings, args.staged_settings, args.policy)
        elif args.command == "validate":
            validate_policy(args.policy)
        else:
            apply_policy(args.settings, args.policy)
    except PolicyError as exc:
        parser.exit(1, f"panel bridge policy rejected: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
