"""The external seam (§5.1): POST /search → {"clips": [...]}.

Always returns an object with a `clips` array — never a 500 — so the agent never
breaks on an empty or failed search. Import-safe; connects to nothing until the
first request.

    uvicorn serve:app --port 8000
    python serve.py --check        # print preflight and exit (binds no port)
"""
from __future__ import annotations

import logging
import sys

from fastapi import FastAPI
from pydantic import BaseModel

from memory.search import search_media_memory

log = logging.getLogger("media-memory.serve")
app = FastAPI(title="media-memory")


class Query(BaseModel):
    query: str
    has_speech: bool | None = None
    after: str | None = None
    before: str | None = None
    near_gps: list[float] | None = None
    limit: int = 8


@app.post("/search")
def search(q: Query) -> dict:
    try:
        return {"clips": search_media_memory(**q.model_dump())}
    except Exception as e:  # never surface a 500 to the agent (§5.1 rule 3)
        log.warning("search failed, returning empty: %s", e)
        return {"clips": []}


@app.get("/health")
def health() -> dict:
    from memory import preflight

    report = preflight.run()
    return {
        "ok": not report.has_fail(),
        "checks": [{"name": c.name, "status": c.status, "detail": c.detail} for c in report.checks],
    }


if __name__ == "__main__":
    if "--check" in sys.argv:
        from memory import preflight

        print("media-memory preflight:")
        print(preflight.run())
        sys.exit(0)
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)
