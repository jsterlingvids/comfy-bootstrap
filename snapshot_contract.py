#!/usr/bin/env python3
"""Create and validate fail-closed transactional Comfy snapshot metadata."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any

from panel_bridge_policy import POLICY_FILENAME, PolicyError, validate_policy

GENERATION_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
SURFACE_PATHS = {
    "workflows": "workflows",
    "settings": "settings",
    "custom_nodes": "custom_nodes",
    "custom_nodes_manifest": "custom_nodes_manifest.txt",
}
REQUIRED_SURFACES = set(SURFACE_PATHS)
ALLOWED_STAGE_TOP_LEVEL = set(SURFACE_PATHS.values()) | {"snapshot.manifest.json"}


class ContractError(ValueError):
    """Raised when snapshot state does not satisfy the contract."""


def validate_generation_id(value: Any) -> str:
    if not isinstance(value, str) or not GENERATION_RE.fullmatch(value):
        raise ContractError("invalid generation id")
    return value


def _load_object(path: str | Path) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"invalid JSON file: {path}") from exc
    if not isinstance(value, dict):
        raise ContractError("metadata root must be an object")
    return value


def parse_completion(path: str | Path) -> tuple[str, str]:
    value = _load_object(path)
    if set(value) != {"schema", "generation", "manifest_sha256", "published_at"}:
        raise ContractError("completion marker shape mismatch")
    if value.get("schema") != "comfy-state-completion-v1":
        raise ContractError("invalid completion schema")
    generation = validate_generation_id(value.get("generation"))
    digest = value.get("manifest_sha256")
    if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
        raise ContractError("invalid manifest digest")
    try:
        dt.datetime.fromisoformat(str(value.get("published_at")))
    except ValueError as exc:
        raise ContractError("invalid completion timestamp") from exc
    return generation, digest


def _surface_entries(path: Path) -> list[tuple[str, int, str]]:
    if not path.exists():
        return []
    if path.is_symlink():
        raise ContractError(f"symlink forbidden in snapshot: {path}")
    if path.is_file():
        candidates = [(path.name, path)]
    elif path.is_dir():
        candidates = []
        for current, dirs, files in os.walk(path, followlinks=False):
            current_path = Path(current)
            for name in dirs:
                if (current_path / name).is_symlink():
                    raise ContractError(f"symlink forbidden in snapshot: {current_path / name}")
            for name in files:
                candidate = current_path / name
                if candidate.is_symlink():
                    raise ContractError(f"symlink forbidden in snapshot: {candidate}")
                candidates.append((candidate.relative_to(path).as_posix(), candidate))
    else:
        raise ContractError(f"unsupported snapshot object: {path}")

    entries: list[tuple[str, int, str]] = []
    for relative, candidate in sorted(candidates):
        digest = hashlib.sha256()
        with candidate.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        entries.append((relative, candidate.stat().st_size, digest.hexdigest()))
    return entries


def measure_surface(path: Path) -> dict[str, Any]:
    entries = _surface_entries(path)
    payload = "\n".join(f"{name}\t{size}\t{digest}" for name, size, digest in entries)
    return {
        "files": len(entries),
        "bytes": sum(size for _, size, _ in entries),
        "tree_sha256": hashlib.sha256(payload.encode()).hexdigest(),
    }


def measure_stage(root: str | Path) -> dict[str, dict[str, Any]]:
    stage = Path(root)
    if not stage.is_dir() or stage.is_symlink():
        raise ContractError("snapshot stage must be a real directory")
    unexpected = {entry.name for entry in stage.iterdir()} - ALLOWED_STAGE_TOP_LEVEL
    if unexpected:
        raise ContractError(f"unexpected top-level snapshot objects: {sorted(unexpected)}")
    return {name: measure_surface(stage / relative) for name, relative in SURFACE_PATHS.items()}


def create_manifest(
    stage_root: str | Path,
    generation: str,
    provider: str,
    bootstrap_commit: str,
    output_path: str | Path,
) -> dict[str, Any]:
    validate_generation_id(generation)
    if not provider or any(ch.isspace() for ch in provider):
        raise ContractError("invalid provider identity")
    value = {
        "bootstrap_commit": bootstrap_commit,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "generation": generation,
        "provider": provider,
        "schema": "comfy-state-generation-v1",
        "surfaces": measure_stage(stage_root),
    }
    Path(output_path).write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return value


def validate_manifest(path: str | Path, generation: str, expected_sha256: str) -> dict[str, Any]:
    validate_generation_id(generation)
    if not isinstance(expected_sha256, str) or not SHA256_RE.fullmatch(expected_sha256):
        raise ContractError("invalid expected manifest digest")
    raw = Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha256:
        raise ContractError("manifest digest mismatch")
    value = _load_object(path)
    expected_keys = {"schema", "generation", "provider", "created_at", "bootstrap_commit", "surfaces"}
    if set(value) != expected_keys:
        raise ContractError("generation manifest root shape mismatch")
    if value.get("schema") != "comfy-state-generation-v1":
        raise ContractError("invalid generation manifest schema")
    if value.get("generation") != generation:
        raise ContractError("generation identity mismatch")
    provider = value.get("provider")
    if not isinstance(provider, str) or not provider or any(ch.isspace() for ch in provider):
        raise ContractError("invalid manifest provider identity")
    if not isinstance(value.get("bootstrap_commit"), str) or not value["bootstrap_commit"]:
        raise ContractError("invalid bootstrap commit identity")
    try:
        dt.datetime.fromisoformat(str(value.get("created_at")))
    except ValueError as exc:
        raise ContractError("invalid manifest creation timestamp") from exc
    surfaces = value.get("surfaces")
    if not isinstance(surfaces, dict) or set(surfaces) != REQUIRED_SURFACES:
        raise ContractError("manifest surface set mismatch")
    for name, metadata in surfaces.items():
        if not isinstance(metadata, dict) or set(metadata) != {"files", "bytes", "tree_sha256"}:
            raise ContractError(f"surface {name} metadata shape mismatch")
        files, size, tree = metadata["files"], metadata["bytes"], metadata["tree_sha256"]
        if not isinstance(files, int) or isinstance(files, bool) or files < 0:
            raise ContractError(f"surface {name} has invalid file count")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise ContractError(f"surface {name} has invalid byte count")
        if not isinstance(tree, str) or not SHA256_RE.fullmatch(tree):
            raise ContractError(f"surface {name} has invalid tree digest")
    return value


def verify_stage(stage_root: str | Path, manifest_path: str | Path) -> dict[str, Any]:
    value = _load_object(manifest_path)
    generation = validate_generation_id(value.get("generation"))
    raw = Path(manifest_path).read_bytes()
    validate_manifest(manifest_path, generation, hashlib.sha256(raw).hexdigest())
    try:
        validate_policy(Path(stage_root) / "settings" / POLICY_FILENAME)
    except PolicyError as exc:
        raise ContractError("invalid panel bridge policy") from exc
    measured = measure_stage(stage_root)
    if measured != value["surfaces"]:
        raise ContractError("staged snapshot content does not match manifest")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    completion = commands.add_parser("completion")
    completion.add_argument("path")
    manifest = commands.add_parser("manifest")
    manifest.add_argument("path")
    manifest.add_argument("generation")
    manifest.add_argument("expected_sha256")
    generation = commands.add_parser("generation")
    generation.add_argument("value")
    create = commands.add_parser("create-manifest")
    create.add_argument("stage_root")
    create.add_argument("generation")
    create.add_argument("provider")
    create.add_argument("bootstrap_commit")
    create.add_argument("output")
    verify = commands.add_parser("verify-stage")
    verify.add_argument("stage_root")
    verify.add_argument("manifest")
    args = parser.parse_args()
    try:
        if args.command == "completion":
            value, digest = parse_completion(args.path)
            print(value)
            print(digest)
        elif args.command == "manifest":
            validate_manifest(args.path, args.generation, args.expected_sha256)
        elif args.command == "generation":
            print(validate_generation_id(args.value))
        elif args.command == "create-manifest":
            create_manifest(args.stage_root, args.generation, args.provider, args.bootstrap_commit, args.output)
        else:
            verify_stage(args.stage_root, args.manifest)
    except (ContractError, OSError) as exc:
        parser.exit(1, f"snapshot contract rejected: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
