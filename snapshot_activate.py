#!/usr/bin/env python3
"""Activate a verified snapshot with rollback across all live state surfaces."""
from __future__ import annotations

import argparse
import errno
import os
import shutil
import tempfile
from pathlib import Path

from snapshot_contract import verify_stage

SETTINGS = {
    "extra_model_paths.yaml": "extra_model_paths.yaml",
    "comfy.settings.json": "user/default/comfy.settings.json",
    "ComfyUI-Manager-config.ini": "user/default/ComfyUI-Manager/config.ini",
    "manager-config.ini": "user/__manager/config.ini",
}
PRESERVED_BAKED_NODES = ("comfyui-mcp-panel",)


class ActivationError(RuntimeError):
    pass


def _remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


def _prepare_backup(live: Path, backup: Path) -> bool:
    """Prepare a complete backup and report whether ``live`` was moved.

    RunPod can present baked image directories as overlayfs lower-layer entries.
    Renaming such a directory into a newly created transaction directory returns
    EXDEV even though both paths have the same apparent mount. In that specific
    case, materialize the baseline into a private temporary path and atomically
    publish the completed copy as ``backup``. The caller registers rollback
    ownership before removing the still-live lower-layer entry. A failed copy
    therefore cannot turn a partial tree into rollback authority.
    """
    try:
        os.replace(live, backup)
        return True
    except OSError as exc:
        if exc.errno != errno.EXDEV:
            raise

    partial_root = Path(tempfile.mkdtemp(prefix=f".{backup.name}.partial-", dir=backup.parent))
    partial = partial_root / "payload"
    try:
        if live.is_symlink() or live.is_file():
            shutil.copy2(live, partial, follow_symlinks=False)
        elif live.is_dir():
            shutil.copytree(live, partial, symlinks=True)
        else:
            raise ActivationError(f"unsupported live state surface: {live}")
        os.replace(partial, backup)
    finally:
        shutil.rmtree(partial_root, ignore_errors=True)
    return False


def activate(stage_root: str | Path, manifest_path: str | Path, comfy_root: str | Path) -> None:
    stage = Path(stage_root).resolve()
    comfy = Path(comfy_root).resolve()
    verify_stage(stage, manifest_path)
    if not (comfy / "main.py").is_file():
        raise ActivationError(f"invalid ComfyUI root: {comfy}")

    transaction = Path(tempfile.mkdtemp(prefix=".snapshot-activate-", dir=comfy))
    candidates = transaction / "candidates"
    backups = transaction / "backups"
    candidates.mkdir()
    backups.mkdir()
    workflow_live = comfy / "user/default/workflows"
    nodes_live = comfy / "custom_nodes"
    directory_pairs: list[tuple[Path, Path, Path]] = []
    applied_dirs: list[tuple[Path, Path | None]] = []
    applied_files: list[tuple[Path, Path | None]] = []
    fail_after = int(os.environ.get("SNAPSHOT_ACTIVATE_FAIL_AFTER", "0") or "0")
    operations = 0

    cleanup_transaction = True
    try:
        workflow_candidate = candidates / "workflows"
        shutil.copytree(stage / "workflows", workflow_candidate, dirs_exist_ok=True)

        nodes_candidate = candidates / "custom_nodes"
        shutil.copytree(stage / "custom_nodes", nodes_candidate, dirs_exist_ok=True)
        for node_name in PRESERVED_BAKED_NODES:
            source = nodes_live / node_name
            destination = nodes_candidate / node_name
            if source.exists():
                _remove(destination)
                shutil.copytree(source, destination, symlinks=True)

        directory_pairs.extend(
            [
                (workflow_live, workflow_candidate, backups / "workflows"),
                (nodes_live, nodes_candidate, backups / "custom_nodes"),
            ]
        )
        for live, candidate, backup in directory_pairs:
            live.parent.mkdir(parents=True, exist_ok=True)
            if live.exists():
                live_was_moved = _prepare_backup(live, backup)
                applied_dirs.append((live, backup))
                if not live_was_moved:
                    _remove(live)
            else:
                applied_dirs.append((live, None))
            os.replace(candidate, live)
            operations += 1
            if fail_after and operations >= fail_after:
                raise ActivationError("injected activation failure")

        for remote_name, relative_live in SETTINGS.items():
            source = stage / "settings" / remote_name
            if not source.is_file():
                continue
            live = comfy / relative_live
            live.parent.mkdir(parents=True, exist_ok=True)
            candidate = candidates / (remote_name + ".new")
            shutil.copy2(source, candidate)
            backup = backups / (remote_name + ".old") if live.exists() else None
            if backup is not None:
                live_was_moved = _prepare_backup(live, backup)
                applied_files.append((live, backup))
                if not live_was_moved:
                    _remove(live)
            else:
                applied_files.append((live, None))
            os.replace(candidate, live)
            operations += 1
            if fail_after and operations >= fail_after:
                raise ActivationError("injected activation failure")
    except Exception as original_error:
        rollback_errors: list[str] = []
        for live, backup in reversed(applied_files):
            try:
                _remove(live)
                if backup is not None and backup.exists():
                    os.replace(backup, live)
            except Exception as rollback_error:
                rollback_errors.append(f"{live}: {rollback_error}")
        for live, backup in reversed(applied_dirs):
            try:
                _remove(live)
                if backup is not None and backup.exists():
                    os.replace(backup, live)
            except Exception as rollback_error:
                rollback_errors.append(f"{live}: {rollback_error}")
        if rollback_errors:
            cleanup_transaction = False
            raise ActivationError(
                f"activation failed and rollback was incomplete; backups retained at {transaction}: "
                + "; ".join(rollback_errors)
            ) from original_error
        raise
    finally:
        if cleanup_transaction:
            shutil.rmtree(transaction, ignore_errors=True)


def activate_legacy_custom_nodes(candidate_root: str | Path, comfy_root: str | Path) -> None:
    """Atomically activate a completely downloaded legacy custom-node snapshot.

    Legacy state predates signed generation manifests, so this path is available only
    behind the caller's explicit migration flag. It still rejects symlinks, removes
    known archived failure directories, and preserves the baked Panel checkout.
    """
    candidate = Path(candidate_root).resolve()
    comfy = Path(comfy_root).resolve()
    live = comfy / "custom_nodes"
    if not (comfy / "main.py").is_file():
        raise ActivationError(f"invalid ComfyUI root: {comfy}")
    if not candidate.is_dir() or not any(path.is_file() for path in candidate.rglob("*")):
        raise ActivationError("legacy custom-node candidate is empty")
    for path in candidate.rglob("*"):
        if path.is_symlink():
            raise ActivationError(f"legacy candidate contains symlink: {path}")
    for child in tuple(candidate.iterdir()):
        if ".invalid-" in child.name:
            _remove(child)

    for node_name in PRESERVED_BAKED_NODES:
        source = live / node_name
        destination = candidate / node_name
        if source.exists():
            _remove(destination)
            shutil.copytree(source, destination, symlinks=True)

    transaction = Path(tempfile.mkdtemp(prefix=".legacy-nodes-activate-", dir=comfy))
    backup = transaction / "custom_nodes"
    moved_live = False
    candidate_applied = False
    cleanup_transaction = True
    try:
        if live.exists():
            live_was_moved = _prepare_backup(live, backup)
            moved_live = True
            if not live_was_moved:
                _remove(live)
        os.replace(candidate, live)
        candidate_applied = True
    except Exception as original_error:
        try:
            if moved_live or candidate_applied:
                _remove(live)
            if moved_live and backup.exists():
                os.replace(backup, live)
        except Exception as rollback_error:
            cleanup_transaction = False
            raise ActivationError(
                f"legacy activation failed and rollback was incomplete; backup retained at {backup}: "
                f"{rollback_error}"
            ) from original_error
        raise
    finally:
        if cleanup_transaction:
            shutil.rmtree(transaction, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy-custom-nodes", action="store_true")
    parser.add_argument("stage_root")
    parser.add_argument("manifest_or_comfy_root")
    parser.add_argument("comfy_root", nargs="?")
    args = parser.parse_args()
    if args.legacy_custom_nodes:
        if args.comfy_root is not None:
            parser.error("legacy activation takes candidate_root and comfy_root")
        activate_legacy_custom_nodes(args.stage_root, args.manifest_or_comfy_root)
    else:
        if args.comfy_root is None:
            parser.error("generation activation takes stage_root, manifest, and comfy_root")
        activate(args.stage_root, args.manifest_or_comfy_root, args.comfy_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
