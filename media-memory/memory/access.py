"""The permission step (§9.3): on first run, ask which folders to scan.

Yes / Select folders / No. The choice is cached in config.ACCESS_FILE so later runs
don't re-prompt. Meshes with ingest.resolve_roots (calls resolve_scan_roots() no-arg)
and with config (ACCESS_FILE, default_media_dirs(), ensure_dirs).

The osascript folder picker can only be exercised on a real Mac; the rest is pure logic
(unit-testable by faking input()).
"""
from __future__ import annotations

import json
import os
import subprocess

from memory import config


def resolve_scan_roots(force_prompt: bool = False) -> list[str]:
    if not force_prompt and os.path.exists(config.ACCESS_FILE):
        try:
            with open(config.ACCESS_FILE) as f:
                return list(json.load(f).get("roots", []))
        except Exception:
            pass  # corrupt cache → fall through and re-ask

    choice = input("Build media memory from  [Y]es all media / [S]elect folders / [N]o? ").strip().lower()
    if choice.startswith("n"):
        roots: list[str] = []
    elif choice.startswith("s"):
        roots = _pick_folders_macos()
    else:
        roots = config.default_media_dirs()  # already includes mounted /Volumes/*

    config.ensure_dirs()
    os.makedirs(os.path.dirname(config.ACCESS_FILE), exist_ok=True)
    with open(config.ACCESS_FILE, "w") as f:
        json.dump({"roots": roots}, f)
    return roots


def _mounted_volumes() -> list[str]:
    v = "/Volumes"
    return [os.path.join(v, d) for d in os.listdir(v)] if os.path.isdir(v) else []


def _pick_folders_macos() -> list[str]:
    """Native multi-select folder dialog (Juan verifies on the Mac)."""
    script = """set chosen to choose folder with multiple selections allowed
                set out to ""
                repeat with f in chosen
                    set out to out & POSIX path of f & linefeed
                end repeat
                return out"""
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        return [p for p in r.stdout.strip().splitlines() if p]
    except Exception:
        return []
