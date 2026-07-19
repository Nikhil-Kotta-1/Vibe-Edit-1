"""Pre-processing pipeline (§5.2): a media file → a list of shot dicts.

Nikhil's Job A. No credentials, no network (except faster-whisper's one-time model
download). Heavy deps (scenedetect, opencv, imagehash, faster-whisper) are imported
*inside* the helpers, so this module imports anywhere; each step degrades with a clear
warning if its dependency — or the ffmpeg binary — is missing, so partial environments
still produce valid output.

Meshes exactly with ingest.py:
  • returns the §5.2 shot dict (seconds only; no frame fields)
  • the stable id `sha1(f"{abspath(source)}:{t_start}")[:8]` equals ingest._shot_key
  • writes thumbnails/clips into config.THUMBS_DIR / config.CLIPS_DIR
"""
from __future__ import annotations

import hashlib
import importlib.util
import logging
import os
import shutil
import subprocess
from functools import lru_cache

from memory import config, imaging

log = logging.getLogger("media-memory.pipeline")

PHASH_DEDUP_THRESHOLD = 5  # hamming distance; ≤ this ⇒ near-duplicate, skip
SHARPNESS_SAMPLES = 7
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "base")


def _round(t: float) -> float:
    return round(float(t), 3)


def _has(mod: str) -> bool:
    try:
        return importlib.util.find_spec(mod) is not None
    except Exception:
        return False


def shot_id(source_path: str, t_start: float) -> str:
    """Stable id — identical formula to ingest._shot_key, so files and Redis keys align."""
    return hashlib.sha1(f"{os.path.abspath(source_path)}:{_round(t_start)}".encode()).hexdigest()[:8]


# --- Step 0: durations --------------------------------------------------------
def _ffprobe_duration(path: str) -> float | None:
    ff = shutil.which("ffprobe")
    if not ff:
        return None
    try:
        out = subprocess.run(
            [ff, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=20,
        )
        return float(out.stdout.strip())
    except Exception:
        return None


def _video_duration(path: str) -> float:
    if _has("cv2"):
        try:
            import cv2

            cap = cv2.VideoCapture(path)
            fps = cap.get(cv2.CAP_PROP_FPS) or 0.0
            frames = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0.0
            cap.release()
            if fps > 0 and frames > 0:
                return _round(frames / fps)
        except Exception:
            pass
    return _round(_ffprobe_duration(path) or 0.0)


# --- Step 1: scene boundaries -------------------------------------------------
def split_into_shots(path: str) -> list[tuple[float, float]]:
    """Scene boundaries in seconds via PySceneDetect; whole-file fallback if unavailable."""
    if not _has("scenedetect"):
        log.warning("scenedetect unavailable; treating whole file as one shot")
        return [(0.0, _video_duration(path))]
    try:
        from scenedetect import ContentDetector, detect

        scenes = detect(path, ContentDetector())
    except Exception as e:
        log.warning("scene detection failed for %s (%s); whole-file fallback", path, e)
        return [(0.0, _video_duration(path))]
    if not scenes:
        return [(0.0, _video_duration(path))]
    return [(_tc_seconds(start), _tc_seconds(end)) for (start, end) in scenes]


def _tc_seconds(tc) -> float:
    """Seconds from a scenedetect FrameTimecode across versions (`.seconds` vs `.get_seconds()`)."""
    s = getattr(tc, "seconds", None)
    return float(s) if s is not None else float(tc.get_seconds())


# --- Step 2: sharpest keyframe ------------------------------------------------
def pick_sharpest(path: str, t_start: float, t_end: float, samples: int = SHARPNESS_SAMPLES):
    """Return the least-blurry frame (BGR ndarray) in [t_start, t_end] by variance of
    the Laplacian, or None if no frame could be read."""
    import cv2

    cap = cv2.VideoCapture(path)
    best, best_score = None, -1.0
    for i in range(samples):
        t = t_start + (t_end - t_start) * (i + 1) / (samples + 1)
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
        ok, frame = cap.read()
        if not ok or frame is None:
            continue
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        score = cv2.Laplacian(gray, cv2.CV_64F).var()
        if score > best_score:
            best, best_score = frame, score
    cap.release()
    return best


# --- Step 3: perceptual-hash dedup -------------------------------------------
def _frame_to_pil(frame_bgr):
    import cv2
    from PIL import Image

    return Image.fromarray(cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB))


def _phash(pil_img):
    if not _has("imagehash"):
        return None  # dedup disabled rather than crash the whole video
    import imagehash

    return imagehash.phash(pil_img)


def is_duplicate(phash_val, seen: list, threshold: int = PHASH_DEDUP_THRESHOLD) -> bool:
    return any((phash_val - h) <= threshold for h in seen)


# --- Step 4: thumbnail --------------------------------------------------------
def _save_pil_thumb(pil_img, sid: str) -> str:
    config.ensure_dirs()
    dst = str(config.THUMBS_DIR / f"{sid}.jpg")
    img = pil_img.convert("RGB")
    img.thumbnail((1024, 1024))
    img.save(dst, "JPEG", quality=90)
    return dst


def _placeholder_thumb(sid: str, label: str) -> str:
    from PIL import Image, ImageDraw

    config.ensure_dirs()
    dst = str(config.THUMBS_DIR / f"{sid}.jpg")
    img = Image.new("RGB", (640, 360), (32, 36, 44))
    ImageDraw.Draw(img).text((20, 20), "no-decoder thumbnail\n" + label[:48], fill=(210, 214, 222))
    img.save(dst, "JPEG", quality=85)
    return dst


# --- Step 5: cut the shot to its own file ------------------------------------
def cut_shot(path: str, t_start: float, t_end: float, sid: str) -> str:
    """ffmpeg-cut the shot to CLIPS_DIR/<id>.mp4. If ffmpeg is missing or fails, fall
    back to the whole source file (still an absolute path that exists, per §5.2)."""
    ff = shutil.which("ffmpeg")
    if not ff:
        log.warning("ffmpeg not found; shot %s not cut — using the whole source file", sid)
        return os.path.abspath(path)
    config.ensure_dirs()
    dst = str(config.CLIPS_DIR / f"{sid}.mp4")
    dur = max(_round(t_end - t_start), 0.0)

    def _ok() -> bool:
        return os.path.exists(dst) and os.path.getsize(dst) > 0

    try:
        subprocess.run([ff, "-y", "-ss", str(t_start), "-i", path, "-t", str(dur), "-c", "copy", dst],
                       capture_output=True, text=True, timeout=120)
        if not _ok():  # stream-copy can fail on odd keyframes; re-encode
            subprocess.run([ff, "-y", "-ss", str(t_start), "-i", path, "-t", str(dur),
                            "-c:v", "libx264", "-c:a", "aac", dst], capture_output=True, text=True, timeout=300)
    except Exception as e:
        log.warning("ffmpeg cut failed for %s (%s); using whole source file", sid, e)
        return os.path.abspath(path)
    return dst if _ok() else os.path.abspath(path)


# --- Step 6: transcript + has_speech -----------------------------------------
@lru_cache(maxsize=1)
def _whisper_model():
    from faster_whisper import WhisperModel

    return WhisperModel(WHISPER_MODEL, compute_type="int8")


def transcribe_file(path: str) -> list[tuple[float, float, str]]:
    """[(start_s, end_s, text)] for the whole file. Empty if faster-whisper is unavailable."""
    if not _has("faster_whisper"):
        log.warning("faster-whisper unavailable; transcripts will be empty / has_speech False")
        return []
    try:
        segments, _ = _whisper_model().transcribe(path)
        return [(s.start, s.end, s.text) for s in segments]
    except Exception as e:
        log.warning("transcription failed for %s (%s)", path, e)
        return []


def words_in_window(segments, t_start: float, t_end: float) -> tuple[str, bool]:
    hits = [text for (s, e, text) in segments if e > t_start and s < t_end]
    joined = " ".join(t.strip() for t in hits).strip()
    return joined, bool(joined)


# --- Assembly -----------------------------------------------------------------
def _whole_file_shot(src: str, reason: str) -> list[dict]:
    log.warning("pipeline degraded for %s (%s); emitting one whole-file shot", src, reason)
    sid = shot_id(src, 0.0)
    thumb = _placeholder_thumb(sid, os.path.basename(src))
    dur = _video_duration(src)
    return [{
        "t_start": 0.0, "t_end": dur, "duration": dur,
        "clip_path": src, "thumb_path": thumb,
        "transcript": "", "has_speech": False,
    }]


def process_video(source_path: str) -> list[dict]:
    config.ensure_dirs()
    src = os.path.abspath(source_path)
    if not _has("cv2"):
        return _whole_file_shot(src, "opencv not installed")

    segments = transcribe_file(src)
    seen: list = []
    shots: list[dict] = []
    for (raw_start, raw_end) in split_into_shots(src):
        ts, te = _round(raw_start), _round(raw_end)
        if te <= ts:
            continue
        frame = pick_sharpest(src, ts, te)
        if frame is None:
            continue
        pil = _frame_to_pil(frame)
        ph = _phash(pil)
        if ph is not None:
            if is_duplicate(ph, seen):
                continue
            seen.append(ph)
        sid = shot_id(src, ts)
        thumb_path = _save_pil_thumb(pil, sid)
        clip_path = cut_shot(src, ts, te, sid)
        transcript, has_speech = words_in_window(segments, ts, te)
        shots.append({
            "t_start": ts, "t_end": te, "duration": _round(te - ts),
            "clip_path": clip_path, "thumb_path": thumb_path,
            "transcript": transcript, "has_speech": has_speech,
        })
    return shots or _whole_file_shot(src, "no shots produced")


def process_image(source_path: str) -> list[dict]:
    config.ensure_dirs()
    imaging.ensure_heif()
    src = os.path.abspath(source_path)
    sid = shot_id(src, 0.0)
    try:
        from PIL import Image

        with Image.open(src) as im:
            thumb_path = _save_pil_thumb(im, sid)
    except Exception as e:
        log.warning("image thumbnail failed for %s (%s)", src, e)
        thumb_path = _placeholder_thumb(sid, os.path.basename(src))
    return [{
        "t_start": 0.0, "t_end": 0.0, "duration": 0.0,
        "clip_path": src, "thumb_path": thumb_path,
        "transcript": "", "has_speech": False,
    }]
