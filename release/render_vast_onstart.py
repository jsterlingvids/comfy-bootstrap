#!/usr/bin/env python3
"""Render the immutable Vast onstart loader for one reviewed bootstrap release."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def required_sha(value: str, pattern: re.Pattern[str], name: str) -> str:
    if not pattern.fullmatch(value):
        raise ValueError(f"{name} must be lowercase hexadecimal with the expected length")
    return value


def render(template: str, *, repository: str, bootstrap_commit: str, panel_commit: str, panel_bundle_sha256: str) -> str:
    if not repository.startswith("https://") or any(ch in repository for ch in "\r\n'\""):
        raise ValueError("repository must be a single HTTPS URL")
    values = {
        "@BOOTSTRAP_REPOSITORY@": repository,
        "@BOOTSTRAP_COMMIT@": required_sha(bootstrap_commit, SHA1, "bootstrap commit"),
        "@PANEL_COMMIT@": required_sha(panel_commit, SHA1, "panel commit"),
        "@PANEL_BUNDLE_SHA256@": required_sha(panel_bundle_sha256, SHA256, "panel bundle SHA-256"),
    }
    result = template
    for marker, value in values.items():
        if result.count(marker) != 1:
            raise ValueError(f"template must contain exactly one {marker} marker")
        result = result.replace(marker, value)
    if "@" in result:
        raise ValueError("unresolved template marker")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", type=Path, default=Path(__file__).resolve().parents[1] / "release" / "vast-onstart.sh.tmpl")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--bootstrap-commit", required=True)
    parser.add_argument("--panel-commit", required=True)
    parser.add_argument("--panel-bundle-sha256", required=True)
    args = parser.parse_args()
    rendered = render(
        args.template.read_text(encoding="utf-8"),
        repository=args.repository,
        bootstrap_commit=args.bootstrap_commit,
        panel_commit=args.panel_commit,
        panel_bundle_sha256=args.panel_bundle_sha256,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    args.output.chmod(0o700)


if __name__ == "__main__":
    main()
