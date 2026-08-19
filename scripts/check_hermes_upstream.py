#!/usr/bin/env python3
"""Validate Talaria's pinned Hermes parity authority and detect upstream drift."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "parity" / "hermes-upstream.json"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class CheckError(RuntimeError):
    pass


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot read {path}: {error}") from error

    required = {"schemaVersion", "repository", "ref", "commit", "authorityFiles"}
    missing = sorted(required - manifest.keys())
    if missing:
        raise CheckError(f"manifest is missing: {', '.join(missing)}")
    if manifest["schemaVersion"] != 1:
        raise CheckError(f"unsupported schemaVersion: {manifest['schemaVersion']!r}")
    if not SHA_PATTERN.fullmatch(str(manifest["commit"])):
        raise CheckError("commit must be a lowercase 40-character Git SHA")
    if not isinstance(manifest["authorityFiles"], list) or not manifest["authorityFiles"]:
        raise CheckError("authorityFiles must be a non-empty list")

    seen: set[str] = set()
    for entry in manifest["authorityFiles"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"}:
            raise CheckError("each authorityFiles entry must contain only path and sha256")
        relative = Path(str(entry["path"]))
        if relative.is_absolute() or ".." in relative.parts:
            raise CheckError(f"unsafe authority path: {relative}")
        if str(relative) in seen:
            raise CheckError(f"duplicate authority path: {relative}")
        seen.add(str(relative))
        if not re.fullmatch(r"[0-9a-f]{64}", str(entry["sha256"])):
            raise CheckError(f"invalid sha256 for {relative}")
    return manifest


def git(*arguments: str, cwd: Path | None = None) -> str:
    command = ["git"]
    if cwd is not None:
        command.extend(["-C", str(cwd)])
    command.extend(arguments)
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"{' '.join(command)} failed: {detail.strip()}") from error
    return result.stdout.strip()


def verify_checkout(manifest: dict[str, Any], checkout: Path) -> None:
    actual_commit = git("rev-parse", "HEAD", cwd=checkout)
    expected_commit = manifest["commit"]
    if actual_commit != expected_commit:
        raise CheckError(
            f"Hermes checkout is {actual_commit}; parity is pinned to {expected_commit}"
        )

    for entry in manifest["authorityFiles"]:
        source = checkout / entry["path"]
        if not source.is_file():
            raise CheckError(f"authority file is missing: {entry['path']}")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if digest != entry["sha256"]:
            raise CheckError(
                f"authority file changed at pinned commit: {entry['path']}\n"
                f"expected {entry['sha256']}\nactual   {digest}"
            )


def verify_remote(manifest: dict[str, Any]) -> None:
    output = git("ls-remote", "--exit-code", manifest["repository"], manifest["ref"])
    rows = [line.split() for line in output.splitlines() if line.strip()]
    if len(rows) != 1 or len(rows[0]) != 2 or not SHA_PATTERN.fullmatch(rows[0][0]):
        raise CheckError(f"unexpected ls-remote result for {manifest['ref']!r}: {output!r}")
    actual_commit = rows[0][0]
    expected_commit = manifest["commit"]
    if actual_commit != expected_commit:
        raise CheckError(
            "Hermes upstream moved. Re-audit the changed authority files and update "
            f"parity/hermes-upstream.json.\npinned {expected_commit}\nremote {actual_commit}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--checkout", type=Path, help="verify an exact local Hermes checkout")
    parser.add_argument("--remote", action="store_true", help="compare the pin with the remote ref")
    arguments = parser.parse_args()

    try:
        manifest = load_manifest(arguments.manifest)
        if arguments.checkout:
            verify_checkout(manifest, arguments.checkout.resolve())
        if arguments.remote:
            verify_remote(manifest)
    except CheckError as error:
        print(f"Hermes parity check failed: {error}", file=sys.stderr)
        return 1

    checks = ["manifest"]
    if arguments.checkout:
        checks.append("checkout")
    if arguments.remote:
        checks.append("remote")
    print(f"Hermes parity check passed ({', '.join(checks)}): {manifest['commit']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
