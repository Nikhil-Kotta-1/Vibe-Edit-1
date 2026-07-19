"""Test fixtures. Sets MEDIA_MEMORY_HOME to a temp dir BEFORE memory.config is imported,
so tests never touch the real ~/.media-memory."""
import importlib.util
import os
import tempfile

os.environ.setdefault("MEDIA_MEMORY_HOME", tempfile.mkdtemp(prefix="mm-test-"))

import pytest


def _has(mod: str) -> bool:
    try:
        return importlib.util.find_spec(mod) is not None
    except Exception:
        return False


HAS_CV2 = _has("cv2")


@pytest.fixture(scope="session")
def sample_image(tmp_path_factory):
    from PIL import Image

    p = tmp_path_factory.mktemp("media") / "photo.jpg"
    Image.new("RGB", (128, 96), (20, 140, 200)).save(str(p), "JPEG")
    return str(p)


@pytest.fixture(scope="session")
def sample_video(tmp_path_factory):
    if not HAS_CV2:
        pytest.skip("opencv not installed")
    import cv2
    import numpy as np

    p = str(tmp_path_factory.mktemp("media") / "clip.mp4")
    writer = cv2.VideoWriter(p, cv2.VideoWriter_fourcc(*"mp4v"), 10.0, (160, 120))
    if not writer.isOpened():
        pytest.skip("opencv VideoWriter cannot open an mp4 encoder here")
    for color in [(0, 0, 200), (200, 0, 0)]:  # red then blue → one hard cut → ~2 shots
        for i in range(20):
            frame = np.full((120, 160, 3), color, dtype=np.uint8)
            frame[:: 3, :: 3] = (i * 5) % 255  # texture so sharpness varies
            writer.write(frame)
    writer.release()
    return p


@pytest.fixture(scope="session")
def redis_up():
    try:
        import redis

        from memory import config

        redis.from_url(config.redis_url(), socket_connect_timeout=1).ping()
        return True
    except Exception:
        return False
