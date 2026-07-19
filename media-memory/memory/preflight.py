"""Capability checks for the media-memory spine.

`run()` probes every dependency into a PASS/FAIL/SKIP report and NEVER raises.
This is the credential check to run before any live test.

    python -m memory.preflight           # cheap checks, no API calls
    python -m memory.preflight --live     # also spends ONE embed call to prove Vertex reachable
    python -m memory.preflight --strict   # exit nonzero if any check FAILs
"""
from __future__ import annotations

import argparse
import importlib.util
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

from memory import config

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


@dataclass
class Check:
    name: str
    status: str
    detail: str = ""


@dataclass
class Report:
    checks: list[Check] = field(default_factory=list)

    def add(self, name: str, status: str, detail: str = "") -> None:
        self.checks.append(Check(name, status, detail))

    def get(self, name: str) -> Check | None:
        return next((c for c in self.checks if c.name == name), None)

    def ok_for(self, *names: str) -> bool:
        return all((c := self.get(n)) is not None and c.status == PASS for n in names)

    def has_fail(self) -> bool:
        return any(c.status == FAIL for c in self.checks)

    def __str__(self) -> str:
        width = max((len(c.name) for c in self.checks), default=0)
        icon = {PASS: "✓", FAIL: "✗", SKIP: "–"}
        return "\n".join(
            f"  {icon[c.status]} {c.name.ljust(width)}  {c.status}  {c.detail}".rstrip()
            for c in self.checks
        )


def _short(e: Exception) -> str:
    first = (str(e).strip().splitlines() or [""])[0]
    return (first or type(e).__name__)[:80]


def _spec(name: str) -> bool:
    """True if `name` is importable, without importing it. Never raises."""
    try:
        return importlib.util.find_spec(name) is not None
    except Exception:
        return False


def _check_dotenv(r: Report) -> None:
    if not _spec("dotenv"):
        r.add("dotenv", FAIL, "pip install python-dotenv")
    elif Path(".env").exists():
        r.add("dotenv", PASS, ".env present")
    else:
        r.add("dotenv", SKIP, "no .env; using shell env + defaults")


def _check_vertex_sdk(r: Report) -> None:
    if _spec("vertexai"):
        r.add("vertex_sdk", PASS, "vertexai importable")
    elif _spec("google.genai"):
        r.add("vertex_sdk", PASS, "google-genai importable (port embed/describe; see README)")
    else:
        r.add("vertex_sdk", FAIL, "pip install google-cloud-aiplatform")


def _check_gcp_project(r: Report) -> None:
    project = config.gcp_project()
    r.add("gcp_project", PASS, project) if project else r.add("gcp_project", FAIL, "set GOOGLE_CLOUD_PROJECT")


def _check_gcp_credentials(r: Report) -> None:
    path = config.gcp_credentials_path()
    if path:
        if Path(path).is_file():
            r.add("gcp_credentials", PASS, f"service account: {path}")
        else:
            r.add("gcp_credentials", FAIL, f"file not found: {path}")
        return
    try:
        import google.auth  # type: ignore
    except Exception:
        r.add("gcp_credentials", FAIL, "no google-auth (pip install google-cloud-aiplatform)")
        return
    try:
        google.auth.default()  # resolves ADC without any API call
        r.add("gcp_credentials", PASS, "application default credentials")
    except Exception:
        r.add("gcp_credentials", FAIL, "no ADC; run: gcloud auth application-default login")


def _check_vertex_reachable(r: Report, live: bool) -> None:
    if not live:
        r.add("vertex_reachable", SKIP, "pass --live to spend one embed call")
        return
    if not r.ok_for("vertex_sdk", "gcp_project", "gcp_credentials"):
        r.add("vertex_reachable", SKIP, "prerequisite check failed")
        return
    try:
        from memory import embed

        vec = embed.embed_text("ping")
        r.add("vertex_reachable", PASS, f"dim={len(vec)}")
    except Exception as e:
        r.add("vertex_reachable", FAIL, _short(e))


def _check_redis(r: Report) -> None:
    if not _spec("redis"):
        r.add("redis", FAIL, "pip install redis")
        return
    try:
        import redis as redis_lib

        redis_lib.from_url(config.redis_url(), socket_connect_timeout=2).ping()
        r.add("redis", PASS, config.redis_url())
    except Exception as e:
        r.add("redis", FAIL, _short(e))


def _check_redis_index(r: Report) -> None:
    if not r.ok_for("redis"):
        r.add("redis_index", SKIP, "redis unavailable")
        return
    try:
        from memory import index

        if index.get_index_readonly().exists():
            r.add("redis_index", PASS, f"{config.INDEX_NAME} present")
        else:
            r.add("redis_index", SKIP, f"{config.INDEX_NAME} missing; run ingest.py")
    except Exception as e:
        r.add("redis_index", FAIL, _short(e))


def _check_ffmpeg(r: Report) -> None:
    path = shutil.which("ffmpeg")
    r.add("ffmpeg", PASS, path) if path else r.add(
        "ffmpeg", FAIL, "brew install ffmpeg (only the real pipeline needs it)"
    )


def run(live: bool = False) -> Report:
    r = Report()
    _check_dotenv(r)
    _check_vertex_sdk(r)
    _check_gcp_project(r)
    _check_gcp_credentials(r)
    _check_vertex_reachable(r, live)
    _check_redis(r)
    _check_redis_index(r)
    _check_ffmpeg(r)
    return r


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="media-memory preflight checks")
    ap.add_argument("--live", action="store_true", help="spend one Vertex embed call to prove reachability")
    ap.add_argument("--strict", action="store_true", help="exit nonzero if any check FAILs")
    args = ap.parse_args(argv)
    report = run(live=args.live)
    print("media-memory preflight:")
    print(report)
    return 1 if (args.strict and report.has_fail()) else 0


if __name__ == "__main__":
    sys.exit(main())
