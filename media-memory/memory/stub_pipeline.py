"""TEMPORARY stand-in for Nikhil's memory/pipeline.py (§5.2).

Lets the spine run end-to-end with NO credentials and NO ffmpeg: it treats the
whole file as a single "shot" and writes a thumbnail with Pillow. Recall quality
is meaningless here (placeholder thumbnails for video) — this is for plumbing
only. Swap to the real pipeline by importing memory.pipeline instead; ingest.py
already prefers it when present.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess

from memory import config, imaging

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff", ".gif", ".bmp", ".webp"}
_STUB_VIDEO_DURATION = 5.0  # nominal; used only when ffprobe is unavailable


def _shot_id(abs_source: str, t_start: float) -> str:
    return hashlib.sha1(f"{abs_source}:{t_start}".encode()).hexdigest()[:8]


def _probe_duration(path: str) -> float | None:
    ff = shutil.which("ffprobe")
    if not ff:
        return None
    try:
        out = subprocess.run(
            [ff, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
            capture_output=True,
            text=True,
            timeout=20,
        )
        return float(out.stdout.strip())
    except Exception:
        return None


def _placeholder_thumb(dst: str, label: str) -> None:
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (640, 360), (32, 36, 44))
    ImageDraw.Draw(img).text((20, 20), "stub thumbnail\n" + label[:48], fill=(210, 214, 222))
    img.save(dst, "JPEG", quality=85)


def _image_thumb(src: str, dst: str) -> bool:
    try:
        from PIL import Image

        with Image.open(src) as im:
            im = im.convert("RGB")
            im.thumbnail((640, 640))
            im.save(dst, "JPEG", quality=85)
        return True
    except Exception:
        return False


def process_image(source_path: str) -> list[dict]:
    config.ensure_dirs()
    imaging.ensure_heif()
    abs_src = os.path.abspath(source_path)
    sid = _shot_id(abs_src, 0.0)
    thumb = str(config.THUMBS_DIR / f"{sid}.jpg")
    if not _image_thumb(abs_src, thumb):
        _placeholder_thumb(thumb, os.path.basename(abs_src))
    return [
        {
            "t_start": 0.0,
            "t_end": 0.0,
            "duration": 0.0,
            "clip_path": abs_src,
            "thumb_path": thumb,
            "transcript": "",
            "has_speech": False,
        }
    ]


def process_video(source_path: str) -> list[dict]:
    config.ensure_dirs()
    abs_src = os.path.abspath(source_path)
    sid = _shot_id(abs_src, 0.0)
    thumb = str(config.THUMBS_DIR / f"{sid}.jpg")
    _placeholder_thumb(thumb, os.path.basename(abs_src))
    duration = round(_probe_duration(abs_src) or _STUB_VIDEO_DURATION, 3)
    return [
        {
            "t_start": 0.0,
            "t_end": duration,
            "duration": duration,
            "clip_path": abs_src,
            "thumb_path": thumb,
            "transcript": "",
            "has_speech": False,
        }
    ]
