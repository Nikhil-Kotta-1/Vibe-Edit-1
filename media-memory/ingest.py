"""Assembly line: folders → pipeline → Vertex (embed + caption) → Redis.

Preflight-gated: if embeddings or Redis aren't available it prints the check
report and exits with a one-line reason, never a traceback.

    python ingest.py --check
    python ingest.py --paths ~/Movies/skate2024 --limit 50
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

from memory import config, imaging, preflight

try:
    from memory.pipeline import process_image, process_video  # Nikhil's, when it lands
except ImportError:
    from memory.stub_pipeline import process_image, process_video

IMAGE_EXTS = config.IMAGE_EXTS
VIDEO_EXTS = config.VIDEO_EXTS
MEDIA_EXTS = config.MEDIA_EXTS


def resolve_roots(paths: list[str] | None) -> list[str]:
    if paths:
        return [p for p in paths if os.path.isdir(p) or os.path.isfile(p)]
    try:
        from memory.access import resolve_scan_roots  # Nikhil's, when it lands

        return resolve_scan_roots()
    except ImportError:
        return config.default_media_dirs()


def iter_media_files(roots: list[str]):
    for root in roots:
        if os.path.isfile(root):
            if os.path.splitext(root)[1].lower() in MEDIA_EXTS:
                yield root
            continue
        for dirpath, _dirs, files in os.walk(root):
            for name in sorted(files):
                if os.path.splitext(name)[1].lower() in MEDIA_EXTS:
                    yield os.path.join(dirpath, name)


def _shot_key(source_path: str, t_start: float) -> str:
    return hashlib.sha1(f"{os.path.abspath(source_path)}:{round(float(t_start), 3)}".encode()).hexdigest()[:8]


def file_metadata(path: str) -> tuple[int, str | None]:
    """(created_at epoch seconds, gps 'lon,lat' or None). Images: EXIF date + GPS.
    Videos: container creation_time + location via ffprobe. Falls back to file mtime."""
    if os.path.splitext(path)[1].lower() in IMAGE_EXTS:
        imaging.ensure_heif()
        epoch, gps = _image_exif_epoch(path), _image_exif_gps(path)
    else:
        epoch, gps = _video_creation_epoch(path), _video_gps(path)
    if epoch is None:
        epoch = int(os.path.getmtime(path))
    return epoch, gps


def _image_exif_epoch(path: str) -> int | None:
    try:
        from PIL import ExifTags, Image

        with Image.open(path) as im:
            exif = im.getexif()
        if not exif:
            return None
        tags = {ExifTags.TAGS.get(k, k): v for k, v in exif.items()}
        dt = tags.get("DateTimeOriginal") or tags.get("DateTime")
        if not dt:
            return None
        return int(datetime.strptime(str(dt), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return None


def _image_exif_gps(path: str) -> str | None:
    """'lon,lat' (Redis geo order) from EXIF GPSInfo, or None."""
    try:
        from PIL import Image
        from PIL.ExifTags import GPSTAGS

        with Image.open(path) as im:
            gps_ifd = im.getexif().get_ifd(0x8825)  # GPSInfo IFD
        if not gps_ifd:
            return None
        g = {GPSTAGS.get(k, k): v for k, v in gps_ifd.items()}
        lat = _dms_to_deg(g.get("GPSLatitude"), g.get("GPSLatitudeRef"))
        lon = _dms_to_deg(g.get("GPSLongitude"), g.get("GPSLongitudeRef"))
        return f"{lon},{lat}" if lat is not None and lon is not None else None
    except Exception:
        return None


def _dms_to_deg(dms, ref) -> float | None:
    if not dms or ref is None:
        return None
    try:
        d, m, s = (float(x) for x in dms)
        deg = d + m / 60.0 + s / 3600.0
        return round(-deg if str(ref).upper() in ("S", "W") else deg, 6)
    except Exception:
        return None


def _ffprobe_tag(path: str, tag: str) -> str | None:
    ff = shutil.which("ffprobe")
    if not ff:
        return None
    try:
        out = subprocess.run(
            [ff, "-v", "error", "-show_entries", f"format_tags={tag}", "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=20,
        )
        return out.stdout.strip() or None
    except Exception:
        return None


def _video_creation_epoch(path: str) -> int | None:
    s = _ffprobe_tag(path, "creation_time")
    if not s:
        return None
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except Exception:
        return None


def _video_gps(path: str) -> str | None:
    """Parse a QuickTime ISO-6709 'location' tag (e.g. '+37.75-122.41/') → 'lon,lat'."""
    raw = _ffprobe_tag(path, "location") or _ffprobe_tag(path, "com.apple.quicktime.location.ISO6709")
    if not raw:
        return None
    import re

    m = re.match(r"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)", raw.strip())
    return f"{float(m.group(2))},{float(m.group(1))}" if m else None  # ISO6709 is lat,lon → store lon,lat


def process_file(path: str) -> list[dict]:
    ext = os.path.splitext(path)[1].lower()
    return process_image(path) if ext in IMAGE_EXTS else process_video(path)


def upsert(idx, shot: dict, source_path: str, caption: str, vec, created_at: int, gps: str | None) -> None:
    import numpy as np

    sid = _shot_key(source_path, shot["t_start"])
    record = {
        "asset_path": shot["clip_path"],
        "source_path": os.path.abspath(source_path),
        "caption": caption,
        "transcript": shot.get("transcript", ""),
        "has_speech": "true" if shot.get("has_speech") else "false",
        "t_start": float(shot["t_start"]),
        "t_end": float(shot["t_end"]),
        "duration": float(shot["duration"]),
        "created_at": int(created_at),
        "thumbnail_path": shot["thumb_path"],
        "visual_embedding": np.asarray(vec, dtype="float32").tobytes(),
    }
    if gps:
        record["gps"] = gps
    idx.load([record], keys=[f"{config.INDEX_NAME}:{sid}"])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Build the media memory (folders → Vertex → Redis).")
    ap.add_argument("--check", action="store_true", help="run preflight and exit")
    ap.add_argument("--paths", nargs="*", help="explicit files/folders to ingest")
    ap.add_argument("--limit", type=int, default=0, help="max files (0 = no limit)")
    ap.add_argument("--no-caption", action="store_true", help="skip Gemini captions")
    args = ap.parse_args(argv)

    if args.no_caption:
        os.environ["CAPTION_PROVIDER"] = "none"

    report = preflight.run()
    if args.check:
        print("media-memory preflight:")
        print(report)
        return 0

    if not report.ok_for("vertex_sdk", "gcp_project", "gcp_credentials"):
        print("media-memory preflight:")
        print(report)
        print(
            "\ningest needs an embedding backend (Vertex). Fix the FAILed checks above and re-run.",
            file=sys.stderr,
        )
        return 2
    if not report.ok_for("redis"):
        print("media-memory preflight:")
        print(report)
        print(f"\ningest needs Redis Stack on {config.redis_url()}. Start it and re-run.", file=sys.stderr)
        return 2

    from memory import describe, embed, index

    roots = resolve_roots(args.paths)
    if not roots:
        print("No media folders to scan (pass --paths).", file=sys.stderr)
        return 1
    print(f"Scanning: {', '.join(roots)}")

    idx = index.get_index()
    n_files = n_shots = 0
    for path in iter_media_files(roots):
        if args.limit and n_files >= args.limit:
            break
        n_files += 1
        try:
            shots = process_file(path)
        except Exception as e:
            print(f"  skip (pipeline) {path}: {e}", file=sys.stderr)
            continue
        created_at, gps = file_metadata(path)
        for shot in shots:
            try:
                vec = embed.embed_image(shot["thumb_path"])
                caption = describe.caption_image(shot["thumb_path"])
                upsert(idx, shot, path, caption, vec, created_at, gps)
                n_shots += 1
            except Exception as e:
                print(f"  skip (embed/upsert) {shot.get('clip_path', path)}: {e}", file=sys.stderr)
        print(f"  [{n_files}] {os.path.basename(path)} → {len(shots)} shot(s)")

    print(f"Done: {n_shots} shot(s) from {n_files} file(s) indexed in '{config.INDEX_NAME}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
