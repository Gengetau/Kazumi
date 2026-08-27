#!/usr/bin/env python3
"""Reject known upstream branding bytes from source trees and build archives."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from zipfile import BadZipFile, ZipFile


ROOT = Path(__file__).resolve().parents[1]
HASH_FILE = ROOT / "test_distribution" / "forbidden_asset_hashes.json"
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg"}
REQUIRED_SOURCE_ASSETS = (
    "assets/images/logo/logo_android.png",
    "assets/images/logo/logo_ios.png",
    "assets/images/logo/logo_lanczos.ico",
    "assets/images/logo/logo_linux.png",
    "assets/images/logo/logo_rounded.png",
    "assets/images/logo/logo_windows.ico",
    "assets/images/noface.jpeg",
    "windows/runner/resources/app_icon.ico",
)


def _load_forbidden_hashes() -> tuple[set[str], dict[str, list[str]]]:
    try:
        document = json.loads(HASH_FILE.read_text(encoding="utf-8"))
        entries = document["entries"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise RuntimeError(f"cannot read {HASH_FILE}: {error}") from error

    hashes: set[str] = set()
    descriptions: dict[str, list[str]] = {}
    if not isinstance(entries, list):
        raise RuntimeError("forbidden asset manifest entries must be a list")
    for entry in entries:
        if not isinstance(entry, dict):
            raise RuntimeError("forbidden asset manifest entry must be an object")
        digest = str(entry.get("sha256", "")).lower()
        path = str(entry.get("path", "<unknown>"))
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise RuntimeError(f"invalid SHA-256 in forbidden asset manifest: {digest}")
        hashes.add(digest)
        descriptions.setdefault(digest, []).append(path)
    return hashes, descriptions


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _iter_image_files(root: Path):
    if root.is_file():
        if root.suffix.lower() in IMAGE_SUFFIXES:
            yield root
        return
    if not root.is_dir():
        raise FileNotFoundError(root)
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES:
            yield path


def _display_path(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def _check_source_files(
    roots: list[Path], forbidden: set[str], descriptions: dict[str, list[str]]
) -> list[str]:
    findings: list[str] = []
    scanned = 0
    for root in roots:
        for path in _iter_image_files(root):
            scanned += 1
            digest = _sha256_file(path)
            if digest in forbidden:
                original_paths = ", ".join(descriptions.get(digest, []))
                findings.append(
                    f"{_display_path(path)} matches forbidden SHA-256 {digest} "
                    f"({original_paths})"
                )
    print(f"Scanned {scanned} source image files")
    return findings


def _check_archives(
    archives: list[Path], forbidden: set[str], descriptions: dict[str, list[str]]
) -> list[str]:
    findings: list[str] = []
    for archive in archives:
        scanned = 0
        try:
            with ZipFile(archive) as bundle:
                for member in bundle.infolist():
                    if member.is_dir():
                        continue
                    scanned += 1
                    digest = _sha256_bytes(bundle.read(member))
                    if digest in forbidden:
                        original_paths = ", ".join(descriptions.get(digest, []))
                        findings.append(
                            f"{archive}::{member.filename} matches forbidden SHA-256 "
                            f"{digest} ({original_paths})"
                        )
        except (OSError, BadZipFile) as error:
            findings.append(f"{archive}: cannot inspect archive ({error})")
            continue
        print(f"Scanned {scanned} files in {archive}")
    return findings


def _check_required_source_assets() -> list[str]:
    return [
        f"required generated asset is missing: {path}"
        for path in REQUIRED_SOURCE_ASSETS
        if not (ROOT / path).is_file()
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        dest="roots",
        action="append",
        type=Path,
        help="source directory or image file to scan (repeatable)",
    )
    parser.add_argument(
        "--archive",
        dest="archives",
        action="append",
        type=Path,
        help="ZIP/APK archive to scan (repeatable)",
    )
    args = parser.parse_args()

    roots = args.roots
    if roots is None:
        roots = [
            ROOT / "assets",
            ROOT / "android/app/src/main/res",
            ROOT / "windows/runner/resources",
        ]
    archives = args.archives or []

    try:
        forbidden, descriptions = _load_forbidden_hashes()
        findings = _check_source_files(roots, forbidden, descriptions)
        findings.extend(_check_archives(archives, forbidden, descriptions))
        if args.roots is None:
            findings.extend(_check_required_source_assets())
    except (FileNotFoundError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if findings:
        print("Forbidden asset hash matches found:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1

    print("No forbidden asset hashes found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
