#!/usr/bin/env python3
"""Validate restored workflow node classes against a live ComfyUI instance."""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any, Iterable

FRONTEND_KNOWN = {
    "Fast Bypasser (rgthree)",
    "GetNode",
    "MarkdownNote",
    "Mute / Bypass Repeater (rgthree)",
    "Note",
    "Reroute",
    "SetNode",
}
UUID_LIKE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _iter_class_types(obj: Any) -> Iterable[str]:
    """Find API-format class_type keys without treating socket metadata as nodes."""
    if isinstance(obj, dict):
        class_type = obj.get("class_type")
        if isinstance(class_type, str):
            yield class_type
        for value in obj.values():
            yield from _iter_class_types(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from _iter_class_types(item)


def _iter_frontend_node_types(obj: Any) -> Iterable[str]:
    """Find top-level frontend node records under explicit `nodes` arrays."""
    if isinstance(obj, dict):
        nodes = obj.get("nodes")
        if isinstance(nodes, list):
            for node in nodes:
                if isinstance(node, dict):
                    node_type = node.get("type")
                    if isinstance(node_type, str):
                        yield node_type
                    # Subgraph definitions can themselves contain node arrays.
                    yield from _iter_frontend_node_types(node)
        for key, value in obj.items():
            if key != "nodes":
                yield from _iter_frontend_node_types(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from _iter_frontend_node_types(item)


def workflow_node_types(payload: Any) -> set[str]:
    return set(_iter_class_types(payload)) | set(_iter_frontend_node_types(payload))


def collect_workflow_node_types(
    workflows_dir: str | Path,
) -> tuple[set[str], int, list[str]]:
    root = Path(workflows_dir)
    used: set[str] = set()
    count = 0
    errors: list[str] = []
    for workflow_path in sorted(root.rglob("*.json")):
        try:
            with workflow_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except Exception as exc:
            try:
                display_path = workflow_path.relative_to(root)
            except ValueError:
                display_path = workflow_path
            errors.append(f"{display_path}: {exc}")
            continue
        count += 1
        used.update(workflow_node_types(payload))
    return used, count, errors


def classify_missing(used: set[str], available: set[str]) -> tuple[list[str], list[str]]:
    frontend: list[str] = []
    runtime: list[str] = []
    for node in sorted(used - available):
        if node in FRONTEND_KNOWN or UUID_LIKE.match(node):
            frontend.append(node)
        else:
            runtime.append(node)
    return runtime, frontend


def parse_required(raw: str) -> set[str]:
    return {item.strip() for item in re.split(r"[\n,]", raw) if item.strip()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("workflows_dir")
    parser.add_argument("port")
    parser.add_argument("--policy", choices=("report", "required", "strict"), default="report")
    parser.add_argument("--required", default="")
    parser.add_argument("--report")
    args = parser.parse_args()

    used, workflow_count, parse_errors = collect_workflow_node_types(args.workflows_dir)
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{args.port}/object_info", timeout=10) as response:
            object_info = json.load(response)
    except Exception as exc:
        print(f"VALIDATION_ERROR unable to fetch object_info: {exc}")
        return 1

    available = set(object_info.keys())
    runtime_missing, frontend_missing = classify_missing(used, available)
    required = parse_required(args.required)
    required_missing = sorted(required - available)
    report = {
        "schema": 1,
        "workflows": workflow_count,
        "used": len(used),
        "available": len(available),
        "policy": args.policy,
        "required": sorted(required),
        "required_missing": required_missing,
        "parse_errors": parse_errors,
        "runtime_missing": runtime_missing,
        "frontend_missing": frontend_missing,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        "VALIDATION_SUMMARY "
        f"workflows={workflow_count} used={len(used)} available={len(available)} "
        f"runtime_missing={len(runtime_missing)} frontend_missing={len(frontend_missing)} "
        f"required_missing={len(required_missing)} parse_errors={len(parse_errors)} policy={args.policy}"
    )
    for error in parse_errors[:20]:
        print(f"VALIDATION_PARSE_ERROR {error}")
    if len(parse_errors) > 20:
        print(f"VALIDATION_PARSE_ERROR_TRUNCATED {len(parse_errors) - 20}")
    for node in required_missing:
        print(f"VALIDATION_REQUIRED_MISSING {node}")
    for node in runtime_missing[:50]:
        print(f"VALIDATION_RUNTIME_MISSING {node}")
    if len(runtime_missing) > 50:
        print(f"VALIDATION_RUNTIME_MISSING_TRUNCATED {len(runtime_missing) - 50}")

    if parse_errors and args.policy in {"required", "strict"}:
        return 1
    if required_missing:
        return 1
    if args.policy == "strict" and runtime_missing:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
