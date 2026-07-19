"""Fake memory service: one hardcoded §5.1 clip.

Lets the agent loop (mcp_server → HTTP) be tested before real ingest/creds exist.

    uvicorn serve_stub:app --port 8000
"""
from __future__ import annotations

from fastapi import FastAPI

app = FastAPI(title="media-memory-stub")


@app.post("/search")
def search(_: dict) -> dict:
    return {
        "clips": [
            {
                "asset_path": "/tmp/fake_clip.mp4",
                "duration": 6.0,
                "caption": "a person doing a kickflip at an outdoor skatepark",
                "has_speech": False,
                "created_at": "2024-06-11",
                "source_path": "/tmp/fake_src.mp4",
                "t_start": 12.0,
                "t_end": 18.0,
                "thumbnail_path": "/tmp/fake.jpg",
                "score": 0.83,
            }
        ]
    }
