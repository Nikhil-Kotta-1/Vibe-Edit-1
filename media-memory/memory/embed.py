"""Vertex multimodal embeddings — the meaning-fingerprint.

multimodalembedding@001 maps an image and text into the SAME 1408-d space, so a
text query finds an untagged clip. The Vertex client is built lazily on first
use, so importing this module needs no credentials.
"""
from __future__ import annotations

from functools import lru_cache

import numpy as np

from memory import config
from memory._retry import with_retry


@lru_cache(maxsize=1)
def _model():
    import vertexai
    from vertexai.vision_models import MultiModalEmbeddingModel

    vertexai.init(project=config.gcp_project(), location=config.gcp_location())
    return MultiModalEmbeddingModel.from_pretrained(config.EMBED_MODEL)


def embed_image(jpg_path: str) -> np.ndarray:
    """Ingest time: fingerprint a thumbnail (reads the pipeline's thumb_path)."""
    from vertexai.vision_models import Image as VImage

    image = VImage.load_from_file(jpg_path)
    e = with_retry(_model().get_embeddings, image=image, dimension=config.EMBED_DIM)
    return np.array(e.image_embedding, dtype="float32")


def embed_text(text: str) -> np.ndarray:
    """Query time: SAME model, SAME space as embed_image."""
    e = with_retry(_model().get_embeddings, contextual_text=text, dimension=config.EMBED_DIM)
    return np.array(e.text_embedding, dtype="float32")
