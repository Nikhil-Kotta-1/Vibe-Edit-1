"""Lazy, idempotent registration of extra Pillow openers (HEIC/HEIF).

Mac libraries are full of iPhone .heic photos; without this Pillow can't open them.
Import-safe: pillow-heif is imported only when ensure_heif() is first called.
"""
from __future__ import annotations

import logging
from functools import lru_cache

log = logging.getLogger("media-memory.imaging")


@lru_cache(maxsize=1)
def ensure_heif() -> bool:
    """Register the HEIC/HEIF opener so Pillow can read iPhone photos. True if available."""
    try:
        import pillow_heif

        pillow_heif.register_heif_opener()
        return True
    except Exception:
        log.warning("pillow-heif not installed; .heic/.heif images will not decode")
        return False
