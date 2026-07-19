"""The §10 integration checkpoints, as pytest. They prove Nikhil's pipeline meshes with
Juan's ingest/serve. Each test that needs a heavy dep or Redis SKIPS cleanly when absent,
so this suite passes in Devin's sandbox and on Juan's Mac alike."""
import importlib.util
import os

import pytest

from memory import config

SHOT_KEYS = {"t_start", "t_end", "duration", "clip_path", "thumb_path", "transcript", "has_speech"}
S51_KEYS = {"asset_path", "duration", "caption", "has_speech", "created_at",
            "source_path", "t_start", "t_end", "thumbnail_path", "score"}
FRAME_HINTS = ("frame", "Frame", "fps", "startFrame", "durationFrames", "frames")


def _has(mod: str) -> bool:
    try:
        return importlib.util.find_spec(mod) is not None
    except Exception:
        return False


def _onehot(slot: int):
    import numpy as np

    v = np.zeros(config.EMBED_DIM, dtype="float32")
    v[slot] = 1.0
    return v


# --- external seam (§5.1) -----------------------------------------------------
def test_external_seam_shape():
    from fastapi.testclient import TestClient

    import serve_stub

    body = TestClient(serve_stub.app).post("/search", json={"query": "x"}).json()
    assert isinstance(body, dict) and isinstance(body.get("clips"), list)
    assert set(body["clips"][0].keys()) == S51_KEYS


def test_serve_never_500(monkeypatch):
    import serve

    def boom(**kwargs):
        raise RuntimeError("backend down")

    monkeypatch.setattr(serve, "search_media_memory", boom)
    from fastapi.testclient import TestClient

    r = TestClient(serve.app).post("/search", json={"query": "x"})
    assert r.status_code == 200 and r.json() == {"clips": []}


# --- internal seam id contract (§5.2) — the critical mesh guarantee -----------
def test_pipeline_id_matches_ingest():
    import ingest
    from memory import pipeline

    for src, ts in [("/a/b.mp4", 0.0), ("/x/y.mov", 12.04), ("rel/clip.mp4", 3.5), ("/p.mp4", 6.0)]:
        assert pipeline.shot_id(src, ts) == ingest._shot_key(src, ts)


def test_ingest_uses_real_pipeline():
    """Once pipeline.py exists, ingest's try/except resolves to it (not the stub)."""
    import ingest
    from memory import pipeline

    assert ingest.process_video is pipeline.process_video
    assert ingest.process_image is pipeline.process_image


# --- has_speech windowing logic (pure; no model) ------------------------------
def test_words_in_window():
    from memory.pipeline import words_in_window

    segs = [(0.0, 2.0, "hello there"), (5.0, 7.0, "skateboarding rules")]
    text, speaking = words_in_window(segs, 1.0, 3.0)
    assert speaking is True and "hello" in text
    text2, speaking2 = words_in_window(segs, 2.5, 4.5)  # gap with no words
    assert speaking2 is False and text2 == ""


# --- pipeline output contract (§5.2) -----------------------------------------
def _assert_shot(s):
    assert set(s.keys()) == SHOT_KEYS
    assert os.path.isabs(s["clip_path"]) and os.path.exists(s["clip_path"])
    assert os.path.isabs(s["thumb_path"]) and os.path.exists(s["thumb_path"])
    assert abs(s["duration"] - (s["t_end"] - s["t_start"])) < 1e-6
    assert isinstance(s["has_speech"], bool) and isinstance(s["transcript"], str)
    assert all(isinstance(s[k], float) for k in ("t_start", "t_end", "duration"))
    assert not any(k in s for k in FRAME_HINTS)  # seconds only, no frames


def test_process_image_contract(sample_image):
    from memory import pipeline

    shots = pipeline.process_image(sample_image)
    assert isinstance(shots, list) and len(shots) == 1
    _assert_shot(shots[0])
    assert shots[0]["duration"] == 0.0


@pytest.mark.skipif(not _has("cv2"), reason="opencv not installed (pipe deps)")
def test_process_video_contract(sample_video):
    from memory import pipeline

    shots = pipeline.process_video(sample_video)
    assert isinstance(shots, list) and len(shots) >= 1
    for s in shots:
        _assert_shot(s)


# --- internal seam round-trip (§10): real pipeline dict → ingest → Redis → search
def test_internal_seam_roundtrip(sample_image, redis_up, monkeypatch):
    if not redis_up:
        pytest.skip("redis not available")
    import ingest
    from memory import embed, index, pipeline, search

    monkeypatch.setattr(embed, "embed_text", lambda q: _onehot(0))  # no Vertex
    monkeypatch.setattr(config, "INDEX_NAME", "media_memory_pytest")
    index.get_index.cache_clear()
    try:
        ro = index.get_index_readonly()
        if ro.exists():
            ro.delete(drop=True)
        idx = index.get_index()

        shot = pipeline.process_image(sample_image)[0]  # a REAL pipeline dict
        ingest.upsert(idx, shot, sample_image, "a test photo", _onehot(0), 1718064000, None)

        results = search.search_media_memory("anything", limit=5)
        hit = next((c for c in results if c["asset_path"] == shot["clip_path"]), None)
        assert hit is not None, "the ingested shot was not recalled"
        assert set(hit.keys()) == S51_KEYS
        assert 0.0 <= hit["score"] <= 1.0
        assert isinstance(hit["has_speech"], bool)
        idx.delete(drop=True)
    finally:
        index.get_index.cache_clear()
