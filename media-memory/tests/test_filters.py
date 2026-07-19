"""Tests for the polished search filters + metadata extraction: the date-boundary fix,
geo filtering, score clamping, EXIF GPS math, and HEIC decoding. Redis-backed tests use a
throwaway index and skip cleanly when Redis is down."""
import importlib.util
import os

import pytest

from memory import config

EPOCH_20240611_1430 = 1718115000  # mid-day 2024-06-11 UTC (well after midnight)


def _has(mod: str) -> bool:
    try:
        return importlib.util.find_spec(mod) is not None
    except Exception:
        return False


def _onehot(slot: int = 0):
    import numpy as np

    v = np.zeros(config.EMBED_DIM, dtype="float32")
    v[slot] = 1.0
    return v


@pytest.fixture
def temp_index(redis_up, monkeypatch):
    if not redis_up:
        pytest.skip("redis not available")
    from memory import embed, index

    monkeypatch.setattr(embed, "embed_text", lambda q: _onehot(0))
    monkeypatch.setattr(config, "INDEX_NAME", "media_memory_pytest_filters")
    index.get_index.cache_clear()
    ro = index.get_index_readonly()
    if ro.exists():
        ro.delete(drop=True)
    idx = index.get_index()
    yield idx
    try:
        idx.delete(drop=True)
    finally:
        index.get_index.cache_clear()


def _put(idx, seed, *, created_at, gps=None, has_speech=False, vec=None):
    import ingest

    shot = {
        "t_start": float(seed), "t_end": float(seed) + 1.0, "duration": 1.0,
        "clip_path": f"/tmp/{seed}.mp4", "thumb_path": f"/tmp/{seed}.jpg",
        "transcript": "", "has_speech": has_speech,
    }
    ingest.upsert(idx, shot, f"/tmp/src{seed}.mp4", "cap", vec if vec is not None else _onehot(0), created_at, gps)
    return f"/tmp/{seed}.mp4"


def test_before_includes_boundary_day(temp_index):
    from memory import search

    asset = _put(temp_index, 1, created_at=EPOCH_20240611_1430)
    res = search.search_media_memory("x", before="2024-06-11", limit=5)  # same calendar day
    assert any(c["asset_path"] == asset for c in res), "mid-day clip dropped by `before` boundary"


def test_after_excludes_earlier(temp_index):
    from memory import search

    asset = _put(temp_index, 2, created_at=1700000000)  # 2023-11
    res = search.search_media_memory("x", after="2024-01-01", limit=5)
    assert all(c["asset_path"] != asset for c in res)


def test_geo_filter(temp_index):
    from memory import search

    asset = _put(temp_index, 3, created_at=EPOCH_20240611_1430, gps="-122.4194,37.7749")  # SF, "lon,lat"
    near_sf = search.search_media_memory("x", near_gps=[37.7749, -122.4194], limit=5)  # [lat, lon]
    assert any(c["asset_path"] == asset for c in near_sf)
    near_ny = search.search_media_memory("x", near_gps=[40.7128, -74.0060], limit=5)
    assert all(c["asset_path"] != asset for c in near_ny)


def test_score_never_negative(temp_index):
    from memory import search

    _put(temp_index, 4, created_at=EPOCH_20240611_1430, vec=-_onehot(0))  # anti-correlated → distance ~2
    res = search.search_media_memory("x", limit=5)
    assert res and all(0.0 <= c["score"] <= 1.0 for c in res)


def test_dms_to_deg():
    import ingest

    assert abs(ingest._dms_to_deg((37, 46, 29.64), "N") - 37.7749) < 1e-3
    assert ingest._dms_to_deg((122, 25, 9.84), "W") < 0  # west of Greenwich → negative
    assert ingest._dms_to_deg(None, "N") is None


@pytest.mark.skipif(not _has("pillow_heif"), reason="pillow-heif not installed")
def test_heic_decodes(tmp_path):
    import pillow_heif
    from PIL import Image

    from memory import pipeline

    heic = str(tmp_path / "photo.heic")
    pillow_heif.from_pillow(Image.new("RGB", (64, 48), (10, 120, 200))).save(heic)

    shot = pipeline.process_image(heic)[0]
    assert os.path.exists(shot["thumb_path"])
    with Image.open(shot["thumb_path"]) as t:
        assert t.size != (640, 360)  # a real decode, not the 640x360 gray placeholder
