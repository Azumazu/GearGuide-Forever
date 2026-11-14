#!/usr/bin/env python3
"""
Uploads a GearGuide release zip to CurseForge through its author upload API.

Needs (environment variables, or KEY=value lines in the git-ignored .env at the project root):
  CF_API_TOKEN   - CurseForge API token (CurseForge author settings -> API tokens)
  CF_PROJECT_ID  - numeric project ID (shown on the project's page in the author console)

    python upload_curseforge.py --list-versions          # see which game versions match the TOC
    python upload_curseforge.py --dry-run                 # everything except the upload
    python upload_curseforge.py                           # upload releases/GearGuide-<version>.zip

The game versions are matched from the TOC's Interface line (16001 -> "1.60.1"); override with
--game-version-id if CurseForge lists Forever differently. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import package  # noqa: E402

API = "https://wow.curseforge.com/api"
ENV_FILE = HERE.parent / ".env"  # KEY=value lines; git-ignored, never committed


def load_env_file(path: Path = ENV_FILE) -> None:
    """Fills missing environment variables from the project's .env file (real ones win)."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def request(method: str, url: str, token: str, body: bytes | None = None, ctype: str | None = None):
    headers = {"X-Api-Token": token, "User-Agent": "GearGuide-release"}
    if ctype:
        headers["Content-Type"] = ctype
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:500]
        raise SystemExit(f"CurseForge {method} {url} failed: HTTP {e.code} {detail}") from e


def matching_versions(token: str, wanted: list[str]) -> list[dict]:
    versions = request("GET", f"{API}/game/versions", token)
    return [v for v in versions if v.get("name") in wanted]


def multipart(fields: dict[str, str], file_field: str, file_path: Path) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
                  f'filename="{file_path.name}"\r\nContent-Type: application/zip\r\n\r\n').encode())
    parts.append(file_path.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def main() -> int:
    p = argparse.ArgumentParser(description="Upload a GearGuide release to CurseForge.")
    p.add_argument("--zip", type=Path, help="zip to upload (default: releases/GearGuide-<toc version>.zip)")
    p.add_argument("--release-type", choices=["release", "beta", "alpha"], default="release")
    p.add_argument("--game-version-id", type=int, action="append", help="CurseForge game version ID(s)")
    p.add_argument("--list-versions", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    load_env_file()
    token = os.environ.get("CF_API_TOKEN")
    project = os.environ.get("CF_PROJECT_ID")
    if not token:
        print("Set CF_API_TOKEN (CurseForge author settings -> API tokens).", file=sys.stderr)
        return 2

    wanted = package.interface_versions()
    if args.list_versions:
        found = matching_versions(token, wanted)
        print(f"TOC Interface -> game versions {wanted}")
        for v in found:
            print(f"  id {v['id']}: {v['name']} (type {v.get('gameVersionTypeID')})")
        if not found:
            print("  none found; pass --game-version-id with the right ID from CurseForge's upload form")
        return 0

    if not project:
        print("Set CF_PROJECT_ID (your CurseForge project's numeric ID).", file=sys.stderr)
        return 2
    ver = package.version()
    zip_path = args.zip or package.RELEASES / f"GearGuide-{ver}.zip"
    if not zip_path.exists():
        zip_path = package.make_zip(ver)
    ids = args.game_version_id or [v["id"] for v in matching_versions(token, wanted)]
    if not ids:
        print(f"No CurseForge game version named {wanted}. Run --list-versions and pass --game-version-id.",
              file=sys.stderr)
        return 1

    metadata = {
        "changelog": package.changelog_entry(ver),
        "changelogType": "markdown",
        "displayName": f"GearGuide {ver}",
        "gameVersions": ids,
        "releaseType": args.release_type,
    }
    print(f"Uploading {zip_path.name} to project {project} as {args.release_type}, game versions {ids}")
    if args.dry_run:
        print("Dry run, metadata:\n" + json.dumps(metadata, indent=2))
        return 0
    body, ctype = multipart({"metadata": json.dumps(metadata)}, "file", zip_path)
    result = request("POST", f"{API}/projects/{project}/upload-file", token, body, ctype)
    print(f"Uploaded: file id {result.get('id')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
