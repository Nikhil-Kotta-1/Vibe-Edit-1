"""RedisVL schema + index access.

`dims` MUST equal EMBED_DIM (1408) or vector search returns garbage. redisvl is
imported inside the functions, so this module imports without redis installed.
"""
from __future__ import annotations

from functools import lru_cache

from memory import config


def schema_dict() -> dict:
    return {
        "index": {"name": config.INDEX_NAME, "prefix": f"{config.INDEX_NAME}:", "storage_type": "hash"},
        "fields": [
            {"name": "asset_path", "type": "text"},
            {"name": "source_path", "type": "text"},
            {"name": "caption", "type": "text"},
            {"name": "transcript", "type": "text"},
            {"name": "has_speech", "type": "tag"},
            {"name": "t_start", "type": "numeric"},
            {"name": "t_end", "type": "numeric"},
            {"name": "duration", "type": "numeric"},
            {"name": "created_at", "type": "numeric"},
            {"name": "gps", "type": "geo"},
            {"name": "thumbnail_path", "type": "text"},
            {
                "name": "visual_embedding",
                "type": "vector",
                "attrs": {
                    "dims": config.EMBED_DIM,
                    "distance_metric": "cosine",
                    "algorithm": "hnsw",
                    "datatype": "float32",
                },
            },
        ],
    }


@lru_cache(maxsize=1)
def get_index():
    """Connect and ensure the index exists (idempotent)."""
    from redisvl.index import SearchIndex

    idx = SearchIndex.from_dict(schema_dict(), redis_url=config.redis_url())
    idx.create(overwrite=False)
    return idx


def get_index_readonly():
    """Index handle that does NOT auto-create (for preflight/search)."""
    from redisvl.index import SearchIndex

    return SearchIndex.from_dict(schema_dict(), redis_url=config.redis_url())
