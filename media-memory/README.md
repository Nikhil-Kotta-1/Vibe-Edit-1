# media-memory

A lifetime, cross-shoot **memory** for video footage. Ingest chops footage into shots, fingerprints
each with Vertex multimodal embeddings, captions it with Gemini, and stores it in Redis. An agent
searches that memory and drops b-roll onto a timeline.

The directory holds both halves: the credentialed spine + live-demo glue, and the offline
pre-processing pipeline (`memory/pipeline.py`), the folder-access step (`memory/access.py`), and the
seam tests (`tests/`). `ingest.py` auto-uses the real pipeline when present, falling back to
`memory/stub_pipeline.py`.

## The two frozen contracts

- **External (§5.1)** — `POST /search` → `{"clips": [ {asset_path, duration(sec), caption,
  has_speech, created_at, source_path, t_start, t_end, thumbnail_path, score} ]}`. Always an object
  with a `clips` array; durations in **seconds**; `asset_path` absolute and existing.
- **Internal (§5.2)** — the shot dict the pipeline hands ingest: `{t_start, t_end, duration,
  clip_path, thumb_path, transcript, has_speech}`. Seconds only; paths absolute and on disk.

## Layout

    memory/config.py        one config surface; imports with zero creds
    memory/preflight.py     PASS/FAIL/SKIP capability report — run before any live test
    memory/embed.py         Vertex multimodal embeddings (lazy init)
    memory/describe.py      Gemini caption (lazy; disable with CAPTION_PROVIDER=none)
    memory/index.py         RedisVL schema (1408-d) + index access
    memory/search.py        search_media_memory(...) → §5.1 records
    memory/pipeline.py      §5.2 pipeline: scene-split, sharpest frame, dedup, cut, transcribe
    memory/access.py        the Yes / Select folders / No permission step
    memory/stub_pipeline.py creds-free / ffmpeg-free fallback for the §5.2 seam
    ingest.py               folders → pipeline → Vertex → Redis (preflight-gated)
    serve.py                FastAPI POST /search  (the external seam)
    serve_stub.py           one hardcoded clip (test the agent before creds)
    mcp_server.py           MCP wrapper the agent calls → serve.py
    tests/                  §10 seam checkpoints (skip cleanly without deps/Redis)
    demo/                   agent config, system prompt, run sheet

## Setup

    cd media-memory
    python3 -m venv .venv-core && source .venv-core/bin/activate
    pip install -r requirements-core.txt -r requirements-glue.txt

Live dependencies (needed only to actually ingest/search — not to import code or run preflight):
- **Redis Stack** (needs RediSearch): `brew install redis-stack && redis-stack-server`
- **Vertex AI**: `gcloud auth application-default login` (or set `GOOGLE_APPLICATION_CREDENTIALS`)
- **ffmpeg** (only for the real pipeline): `brew install ffmpeg`

## Check before you test

    python -m memory.preflight           # cheap; no API calls; never throws
    python -m memory.preflight --live     # also spends ONE embed call to prove Vertex reachable

Every live path is gated on this: `ingest.py` exits with a one-line reason (not a traceback) when
embeddings/Redis are missing, and `serve.py` degrades `/search` to `{"clips": []}` rather than 500.

## Build + serve

    python ingest.py --paths ~/Movies/skate2024      # fills Redis
    uvicorn serve:app --port 8000                     # serves /search
    curl -s localhost:8000/search -H 'content-type: application/json' \
      -d '{"query":"skateboarding","has_speech":false,"limit":5}' | jq

## Wire the agent

Point Claude Desktop/Code at both MCP servers (`demo/claude_desktop_config.json`) with the editor
running, then use `demo/system_prompt.md`. Flow: `search_media_memory` → `import_media` → `add_clips`.

## Pipeline + tests (the offline half)

The pre-processing pipeline runs with no credentials. It does need its own deps and the ffmpeg
binary for real cuts; without them it degrades (whole-file shot, empty transcript) rather than failing.

    python3 -m venv .venv-pipe && source .venv-pipe/bin/activate
    pip install -r requirements-pipe.txt        # scenedetect, opencv, imagehash, faster-whisper
    brew install ffmpeg                          # for cut_shot (else whole-file fallback)

Run the seam checkpoints (each skips cleanly when a dep or Redis is absent):

    pip install pytest
    PYTHONPATH=. python -m pytest tests/ -v

`tests/test_seams.py` asserts the two contracts mesh: `pipeline.shot_id == ingest._shot_key`, the
exact §5.2 / §5.1 key sets, seconds-only (no frame fields), and a full round-trip of a real
`process_image` dict through `ingest.upsert` → Redis → `search_media_memory`.

## Notes

- **No-credit behavior.** Nothing here requires credentials to import or to run preflight. Without
  Vertex/Redis you can still run the stub pipeline, boot `serve` (returns empty), and exercise the
  MCP wrapper against `serve_stub.py`.
- **Media robustness.** HEIC/HEIF photos decode via `pillow-heif`; `created_at` + GPS come from EXIF
  (images) and ffprobe `creation_time`/`location` (videos), falling back to file mtime; Vertex
  embed/caption calls retry with exponential backoff on rate limits (`memory/_retry.py`).
- **Date filters are day-inclusive.** `before=YYYY-MM-DD` includes the whole of that day; `score` is
  clamped to `[0, 1]`.
- **Vertex SDK (it's 2026).** The code uses the legacy `vertexai` package (shipped in
  `google-cloud-aiplatform`), slated for removal ~mid-2026. `preflight` reports which SDK is
  importable; if `vertexai` is gone, port the two small functions in `embed.py`/`describe.py` to
  `google-genai` (same `multimodalembedding@001` @ 1408-d and `gemini-2.5-flash`).
- **Python.** This box has 3.14. If a wheel (`redisvl` / `google-cloud-aiplatform`) is unavailable
  there, use a 3.12 venv for the spine; the glue (`fastmcp`/`httpx`) is version-tolerant.
- `mcp_server.py` needs `fastmcp`+`httpx` in the interpreter the agent launches — installing
  `requirements-glue.txt` into `.venv-core` (as above) keeps everything in one venv for solo work.
