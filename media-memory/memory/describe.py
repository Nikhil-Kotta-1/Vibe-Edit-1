"""Gemini caption — a one-sentence description to help the agent choose.

Transcription + has_speech live in the pipeline (Nikhil), not here. The Gemini
client is built lazily, so importing this module needs no credentials. When
CAPTION_PROVIDER=none, caption_image returns "" and spends nothing.
"""
from __future__ import annotations

from functools import lru_cache

from memory import config
from memory._retry import with_retry

CAPTION_PROMPT = "Describe what is visible in one concrete sentence: subjects, action, setting. No preamble."


@lru_cache(maxsize=1)
def _gemini():
    import vertexai
    from vertexai.generative_models import GenerativeModel

    vertexai.init(project=config.gcp_project(), location=config.gcp_location())
    return GenerativeModel(config.CAPTION_MODEL)


def caption_image(jpg_path: str) -> str:
    if not config.caption_enabled():
        return ""
    from vertexai.generative_models import Part

    with open(jpg_path, "rb") as f:
        part = Part.from_data(f.read(), mime_type="image/jpeg")
    resp = with_retry(_gemini().generate_content, [part, CAPTION_PROMPT])
    return (resp.text or "").strip()
