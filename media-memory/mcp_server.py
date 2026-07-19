"""The media-memory MCP server: exposes search_media_memory to any MCP agent.

Forwards to the HTTP service (serve.py or serve_stub.py). Nothing here changes
when the real serve.py replaces the stub.

    python mcp_server.py        # stdio
"""
from __future__ import annotations

import os

import httpx
from fastmcp import FastMCP

SEARCH_URL = os.environ.get("MEDIA_MEMORY_URL", "http://127.0.0.1:8000/search")

mcp = FastMCP("media-memory")


@mcp.tool()
def search_media_memory(
    query: str,
    has_speech: bool | None = None,
    after: str | None = None,
    before: str | None = None,
    near_gps: list[float] | None = None,
    limit: int = 8,
) -> list[dict]:
    """Search the user's lifetime footage memory for clips matching a description.

    Returns clips with an absolute asset_path (a pre-cut file you import whole) and
    t_start/t_end in SECONDS. Use has_speech=false for b-roll (silent action footage).
    """
    r = httpx.post(
        SEARCH_URL,
        json={
            "query": query,
            "has_speech": has_speech,
            "after": after,
            "before": before,
            "near_gps": near_gps,
            "limit": limit,
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["clips"]


if __name__ == "__main__":
    mcp.run()
