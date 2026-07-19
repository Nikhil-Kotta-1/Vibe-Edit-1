"""Single config surface for the media-memory spine.

Only this module reads os.environ (after loading .env). Everything else imports
these getters. Secrets are returned as Optional and never raised at import time,
so every module imports cleanly with zero credentials.
"""
from __future__ import annotations

import os
from pathlib import Path

try:
    from dotenv import load_dotenv

    # Load media-memory/.env regardless of the current working directory, then fall back
    # to the default upward search so a repo-root or CWD .env still works.
    _ENV_FILE = Path(__file__).resolve().parent.parent / ".env"
    load_dotenv(_ENV_FILE if _ENV_FILE.exists() else None)  # idempotent; silent if absent
except ModuleNotFoundError:
    pass  # python-dotenv not installed yet; shell env still works


# --- Redis ---
def redis_url() -> str:
    return os.environ.get("REDIS_URL", "redis://localhost:6379")


INDEX_NAME = "media_memory"

# Recognized media extensions (single source of truth; imported by ingest + pipeline).
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".gif", ".bmp", ".webp"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}
MEDIA_EXTS = IMAGE_EXTS | VIDEO_EXTS


# --- Google Cloud / Vertex AI ---
def gcp_project() -> str | None:
    return os.environ.get("GOOGLE_CLOUD_PROJECT") or None


def gcp_location() -> str:
    return os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")


def gcp_credentials_path() -> str | None:
    return os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") or None


EMBED_MODEL = "multimodalembedding@001"  # image + text share one 1408-d space
EMBED_DIM = 1408

CAPTION_MODEL = "gemini-2.5-flash"


def caption_enabled() -> bool:
    return os.environ.get("CAPTION_PROVIDER", "vertex").strip().lower() != "none"


# --- Local storage (pre-cut clips + thumbnails the agent imports) ---
MM_HOME = Path(os.environ.get("MEDIA_MEMORY_HOME", "~/.media-memory")).expanduser()
THUMBS_DIR = MM_HOME / "thumbs"
CLIPS_DIR = MM_HOME / "clips"
ACCESS_FILE = MM_HOME / "access.json"


def ensure_dirs() -> None:
    THUMBS_DIR.mkdir(parents=True, exist_ok=True)
    CLIPS_DIR.mkdir(parents=True, exist_ok=True)


def default_media_dirs() -> list[str]:
    """Fallback scan roots when Nikhil's access.py isn't present."""
    roots = [str(p) for p in (Path("~/Movies").expanduser(), Path("~/Pictures").expanduser()) if p.is_dir()]
    volumes = Path("/Volumes")
    if volumes.is_dir():
        roots += [str(p) for p in volumes.iterdir() if p.is_dir()]
    return roots
