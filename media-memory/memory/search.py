"""search_media_memory — the one capability the agent calls (via the MCP wrapper).

Embeds the query with the SAME Vertex model as ingest, runs a RedisVL vector
search with optional filters, and maps each hit to the §5.1 Contract record.
Returns a plain list; serve.py wraps it in {"clips": [...]}.
"""
from __future__ import annotations

from datetime import datetime, timezone

from memory import embed, index


def _iso_to_epoch(s: str | None, end_of_day: bool = False) -> int | None:
    if not s:
        return None
    base = int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp())
    return base + 86399 if end_of_day else base  # 'before' is inclusive of the whole day


def _epoch_to_iso(value) -> str:
    try:
        return datetime.fromtimestamp(int(float(value)), tz=timezone.utc).date().isoformat()
    except Exception:
        return ""


def _f(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def search_media_memory(
    query: str,
    has_speech: bool | None = None,
    after: str | None = None,
    before: str | None = None,
    near_gps: list[float] | None = None,
    limit: int = 8,
) -> list[dict]:
    from redisvl.query import VectorQuery
    from redisvl.query.filter import Geo, GeoRadius, Num, Tag

    vec = embed.embed_text(query)
    vq = VectorQuery(
        vector=vec.tolist(),
        vector_field_name="visual_embedding",
        return_fields=[
            "asset_path", "source_path", "caption", "transcript", "has_speech",
            "t_start", "t_end", "duration", "created_at", "thumbnail_path",
        ],
        num_results=limit,
    )

    expr = None

    def _and(current, clause):
        return clause if current is None else (current & clause)

    if has_speech is not None:
        expr = _and(expr, Tag("has_speech") == ("true" if has_speech else "false"))
    lo = _iso_to_epoch(after)
    if lo is not None:
        expr = _and(expr, Num("created_at") >= lo)
    hi = _iso_to_epoch(before, end_of_day=True)
    if hi is not None:
        expr = _and(expr, Num("created_at") <= hi)
    if near_gps and len(near_gps) == 2:
        lat, lon = near_gps
        expr = _and(expr, Geo("gps") == GeoRadius(lon, lat, 50, "km"))
    if expr is not None:
        vq.set_filter(expr)

    clips = []
    for r in index.get_index_readonly().query(vq):
        distance = _f(r.get("vector_distance"), 1.0)
        clips.append(
            {
                "asset_path": r.get("asset_path", ""),
                "duration": _f(r.get("duration")),
                "caption": r.get("caption", ""),
                "has_speech": str(r.get("has_speech", "false")).lower() == "true",
                "created_at": _epoch_to_iso(r.get("created_at", 0)),
                "source_path": r.get("source_path", ""),
                "t_start": _f(r.get("t_start")),
                "t_end": _f(r.get("t_end")),
                "thumbnail_path": r.get("thumbnail_path", ""),
                "score": round(max(0.0, 1.0 - distance), 4),
            }
        )
    return clips
