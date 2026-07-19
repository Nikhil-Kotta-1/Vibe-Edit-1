# VibeEdit Memory — Hackathon Plan

**"Cursor for video editing, for everyone."** Speak a request, and the agent finds footage you forgot
you had — even from a shoot a year ago — and assembles the cut for you. Hands-free.

This document is the single source of truth for the build. Read all of it before writing code. The
build only holds if the **two seams** (section 5) are respected exactly: the **external** HTTP Contract
(`/search`) and the **internal** pipeline contract (shot dicts). Lock both on a whiteboard before code.

**Team of two:**
- **Juan** — experienced, owns this repo and the demo machine. Owns the credentialed spine (Vertex,
  Redis, search, serve) **and** the live agent/demo orchestration.
- **Nikhil** — newer to this, working through **Devin** (an autonomous coding agent). Owns the parts that
  are self-contained and testable **offline on a sample file**, with no access to Juan's machine or
  credentials: the ingest **pre-processing pipeline** and the **glue scaffolding** (MCP wrapper, stub,
  configs, tests).

---

## 1. TL;DR

- We add an **aggregated, cross-shoot media memory** to VibeEdit and let an AI agent search it and
  drop clips onto the timeline.
- **Understanding** (captions + embeddings) runs on **Google Vertex AI** (you have $10k credit).
  **Memory** (storage + search) runs on **Redis** (the sponsor track). Clean split: *Vertex feeds Redis.*
- We do **not** modify the Swift app. We build a small Python service + MCP glue + agent config.
- **Juan** owns the **credentialed spine**: Vertex embeddings + Gemini captions, Redis store + search,
  `serve.py`, running the real ingest against real footage — **and** the live orchestration: wiring one
  agent to both MCP servers, tuning the system prompt, and driving the demo.
- **Nikhil (via Devin)** owns the **offline, no-creds** work that anyone can build and test on a single
  sample video without touching Juan's Mac:
  - **Job A — the pre-processing pipeline:** a video file → a list of pre-cut shots (scene split,
    sharpest keyframe, dedup, thumbnail, ffmpeg cut, Whisper transcript). This *feeds* Juan's ingest.
  - **Job B — the glue scaffolding:** the MCP wrapper (`mcp_server.py`), a stub `serve.py`, the agent
    config files, a first draft of the system prompt, and the §10 checkpoints written as real tests.
- **Two seams, both frozen first (section 5):**
  - **External** — `POST /search` JSON shape (§5.1). Nikhil's MCP wrapper + stub are built to it; Juan's
    real `serve.py` returns it.
  - **Internal** — the **shot dict** Nikhil's pipeline hands Juan's ingest (§5.2). Same "lock the seam"
    discipline, one layer down.
- The Vertex switch lives entirely inside Juan's spine — Nikhil's two jobs never see it.
- **Voice** (ElevenLabs) is already partly in the app (`AgentService`). Treat it as a **stretch** beat
  for Juan to wire late; it is **not** Nikhil's job.

---

## 2. The product & why it's not already built

The pitch: *everyone should be able to edit videos.* A person says *"edit my skateboarding rant and add
some b-roll about why skateboarding matters to the economy,"* and the system:

1. Keeps the rant (the **A-roll** — someone talking, already in the project).
2. Goes to its **memory** of everything you've ever recorded, finds skateboarding clips from a year ago
   (**B-roll** — footage with no talking), and
3. Places those clips on a video track above the rant. You never touch a timeline.

**Why VibeEdit can't do this today (verified in the codebase):**

- VibeEdit's media library is **per-project only**. Each `.vibeedit` bundle has its own `media.json` +
  `media/` folder. There is **no global library spanning projects/shoots** (`Models/MediaManifest.swift`,
  `Project/VideoProject.swift`).
- VibeEdit's in-app `searchMedia` only searches the **current project**. Footage from a different shoot a
  year ago is invisible.

**Our wedge:** a lifetime memory across all footage, backed by **Redis**, surfaced to the agent as one
new tool: `search_media_memory`. The novel work is ingestion + memory; VibeEdit already does the editing.

---

## 3. How VibeEdit works (context for the whole team)

VibeEdit is a native macOS app (Swift, SwiftUI/AppKit, AVFoundation). The key fact for us:

> **VibeEdit exposes itself as an MCP server at `http://127.0.0.1:19789/mcp`.** Any MCP-capable agent
> (Claude Desktop, Claude Code, Cursor) can connect and drive the editor with tool calls.

VibeEdit MCP tools we use (verified in `Sources/VibeEdit/Agent/Tools/ToolDefinitions.swift`):

| VibeEdit tool | What it does | Key params |
|---|---|---|
| `getTimeline` | Project settings (**fps**, size), tracks, clips with frame positions. | `startFrame?`, `endFrame?` |
| `getTranscript` | Timeline transcript in project frames (find gaps in the rant). | `startFrame?`, `endFrame?`, `clipId?` |
| `importMedia` | **Imports a local file by absolute path** → returns an asset id. | `source: { path }`, `name?` |
| `addClips` | **Places a clip on the timeline at a frame.** Auto-creates a track. | `entries: [{ mediaRef, startFrame, durationFrames, trackIndex? }]` |
| `setClipProperties` | Trims source so only a sub-segment plays. **Not used in the happy path** — clips arrive pre-cut (§9.2); trim units are source-media frames (see §3 UNITS). | `clipIds`, `trimStartFrame?`, `trimEndFrame?`, `durationFrames?` |

**#1 risk already retired:** the agent *can* import an arbitrary local file and place it at a timeline
position: `importMedia(path)` → asset id → `addClips({mediaRef, startFrame, durationFrames})`. No Swift
changes needed. We deliberately **pre-cut each shot to its own file at ingest** (§9.2) so placement is
just import + `addClips` of the whole file — no source trimming at demo time (see UNITS below for why).

**Critical VibeEdit fact — UNITS (read carefully — this was the plan's worst bug):** VibeEdit is
**frame-based**. `startFrame` and `durationFrames` are integer frames at the **project fps** (read from
`getTimeline`, usually 30). But `trimStartFrame`/`trimEndFrame` in `setClipProperties` are **NOT** project
frames — verified in `ToolDefinitions.swift:195`, they are **SOURCE-media offsets**: frames trimmed off
the *start* and *end* of the source clip, counted at the **source's own fps**. So `round(t_seconds *
project_fps)` is the wrong formula for a trim, and `trimEndFrame` is an amount-trimmed-from-the-end, not an
end position. Rather than make the agent juggle two timebases, we **side-step trimming entirely**: ingest
emits one standalone file per shot, so the agent imports that file and places it whole — `durationFrames =
round(duration * project_fps)`, no trim. Our memory stores **seconds**; that single seconds → frames
conversion is the agent's only unit job (§8.11).

---

## 4. Architecture & data flow

Two halves in **separate processes** talking over localhost HTTP, so Juan's stack (Vertex SDK, Whisper,
OpenCV, RedisVL) never has to coexist with the light MCP stack.

```
  [ingest.py asks: "Build memory from your files?"  Yes / Select folders / No]
            │  (chosen folders)
            ▼
  [SD card / footage folders]
            │  (pre-baked before the demo)
            ▼
  ┌─────────────────────────────┐        ┌──────────────────────────┐
  │  MEMORY SERVICE — JUAN       │ ─────► │  Google Vertex AI        │
  │  ingest.py                   │        │   • Gemini Flash (caption)│
  │   → Redis                    │ ◄───── │   • Multimodal Embeddings │
  │  serve.py (FastAPI :8000)    │        └──────────────────────────┘
  └──────────────┬──────────────┘         (Whisper transcribes locally)
                 │   ▲
                 │   └── shots from NIKHIL's pre-processing pipeline (§5.2)
                 │  HTTP POST /search   ◄── THE EXTERNAL CONTRACT (§5.1)
                 ▼
  ┌─────────────────────────────┐
  │  MCP GLUE                    │   exposes one tool: search_media_memory
  │  mcp_server.py (FastMCP)     │   NIKHIL builds it; JUAN wires it live
  └──────────────┬──────────────┘
                 │  (stdio MCP)
                 ▼
  ┌─────────────────────────────────────────────┐
  │  ONE AGENT (Claude Desktop / Claude Code)    │
  │   • media-memory (ours)  → search clips       │
  │   • vibeedit (:19789)     → import + place     │
  └──────────────┬──────────────────────────────┘
                 │  tool calls                         ▲ text prompt
                 ▼                                      │
  ┌─────────────────────────────┐        [voice → text (ElevenLabs, in-app; stretch)]
  │  VibeEdit (running app)   │
  │  clips land on the timeline  │
  └─────────────────────────────┘
```

Why an **external agent** and not VibeEdit's in-app chat: the in-app chat (`AgentService`) only sends
VibeEdit's *own* tools to Claude and can't load external MCP servers. An external client holding both
servers needs **zero Swift changes**. (Stretch goal in §12 makes it in-app.)

**At query (demo) time** there is exactly one network hop on our side: embedding the user's text query
via Vertex (~200–400 ms), then the actual search is local against Redis. Fast and reliable.

---

## 5. THE CONTRACTS — two seams  ⚠️ build these first, agree on them before anything else

There are **two** places where work meshes. Both are frozen on a whiteboard before any code, and **neither
shape changed when we switched to Vertex** — that's the point of a seam.

### 5.1 External seam — `POST http://127.0.0.1:8000/search` (the HTTP Contract)

This is `serve.py` ⇄ the MCP wrapper. Nikhil builds the wrapper + a stub `serve.py` to this shape; Juan's
real `serve.py` returns it.

**Request:**
```json
{
  "query": "skateboarding street tricks at a skatepark",
  "has_speech": false,          // null = don't care, false = b-roll only, true = talking only
  "after": "2024-01-01",        // ISO date or null — only footage on/after this date
  "before": "2025-12-01",       // ISO date or null — only footage on/before this date
  "near_gps": null,             // [lat, lon] or null — footage near this point
  "limit": 8
}
```

**Response — `200 OK`:**
```json
{
  "clips": [
    {
      "asset_path":     "/Users/juan/.media-memory/clips/ab12cd34.mp4",
      "duration":       6.0,
      "caption":        "a person doing a kickflip on a skateboard at an outdoor skatepark",
      "has_speech":     false,
      "created_at":     "2024-06-11",
      "source_path":    "/Users/juan/footage/skate_2024.mp4",
      "t_start":        12.0,
      "t_end":          18.0,
      "thumbnail_path": "/Users/juan/.media-memory/thumbs/ab12cd34.jpg",
      "score":          0.83
    }
  ]
}
```

**Field rules (these are what make the agent and the service mesh):**

| Field | Type | Units / format | Notes |
|---|---|---|---|
| `asset_path` | string | **absolute** path | The **pre-cut shot file** (§9.2). The agent passes it verbatim to `importMedia` and places it whole — no trim. Must exist on disk. |
| `duration` | number | **seconds** (float) | Length of the pre-cut clip. Agent: `durationFrames = round(duration * fps)`. The *only* field that converts to frames. |
| `caption` | string | English, one sentence | From Gemini. Helps the agent choose. |
| `has_speech` | boolean | — | `false` ⇒ usable as b-roll. |
| `created_at` | string | ISO `YYYY-MM-DD` | Numeric (epoch) form lives only in Redis. |
| `source_path` | string | absolute path | The original file the shot was cut from. Provenance/debug; **not** imported. |
| `t_start`, `t_end` | number | **seconds** into `source_path` | Where the shot came from in the original. Provenance/debug only — **not** used for placement. |
| `thumbnail_path` | string | absolute jpg path | Debug/preview; not required by the agent. |
| `score` | number | 0–1, higher = better | Ranking only. |

**Three things that silently break the demo (read twice):**

1. **Seconds vs frames.** `serve.py` returns `duration` in seconds; the agent multiplies by project fps for
   `durationFrames`. The service never returns frames, and the agent never trims the source (clips are
   pre-cut; `t_start`/`t_end` are provenance only).
2. **`asset_path` is absolute and currently exists** (it's the pre-cut shot file), or `importMedia` fails.
3. **Response is always `{ "clips": [...] }`**, an object with a `clips` array, even when empty.

### 5.2 Internal seam — pipeline → ingest (Nikhil → Juan)

This is the handoff **inside** the memory service: Nikhil's `process_video()` returns a list of **shot
dicts**, and Juan's `ingest.py` consumes each one (adds the Vertex embedding, the Gemini caption, the
date/GPS, and the Redis write). It is the exact same idea as §5.1, applied one layer down — so the two of
you can build in parallel without ever blocking on each other.

**The shot dict — one per shot (a video yields a list; an image yields a 1-element list):**
```json
{
  "t_start":    12.0,
  "t_end":      18.0,
  "duration":   6.0,
  "clip_path":  "/Users/juan/.media-memory/clips/ab12cd34.mp4",
  "thumb_path": "/Users/juan/.media-memory/thumbs/ab12cd34.jpg",
  "transcript": "so anyway skateboarding really matters because",
  "has_speech": false
}
```

**Field rules (what makes Nikhil's pipeline and Juan's ingest mesh):**

| Field | Type | Units / format | Notes |
|---|---|---|---|
| `t_start`, `t_end` | number | **seconds** into the source video | From scene detection. |
| `duration` | number | **seconds** = `t_end - t_start` | Pre-computed so Juan doesn't recompute. Images: `0`. |
| `clip_path` | string | **absolute** path, **must exist** | The ffmpeg-cut shot file (`~/.media-memory/clips/<id>.mp4`). For images, this is the image itself. |
| `thumb_path` | string | **absolute** jpg, **must exist** | The sharpest keyframe. Juan's `embed`/`caption` **read this file**, so it has to be on disk. |
| `transcript` | string | plain text, `""` if silent | Only the words spoken **inside** `[t_start, t_end]`. |
| `has_speech` | boolean | — | `true` if any speech in the window. |

**Rules that keep it clean:**
- **Seconds everywhere; no frames anywhere** in this struct. (Frames are the agent's problem, far away.)
- **Stable id:** `id = sha1(f"{abs_source_path}:{t_start}").hexdigest()[:8]`. Use it for both `clip_path`
  and `thumb_path` filenames so re-running ingest **overwrites** instead of duplicating.
- **Nikhil never touches** Vertex, Redis, `created_at`, `gps`, or `score`. Those are Juan's. Nikhil's
  pipeline does **no network calls** and needs **no credentials** — that's exactly why Devin can build and
  test it.
- Paths must be **absolute and already written to disk** before the dict is returned.

---

## 6. Repository layout

One new directory, standalone Python. Not compiled into the Swift app. Owner tags: **[J]** = Juan,
**[N]** = Nikhil (via Devin).

```
~/VibeEditor/media-memory/
├── README.md                  # [J] pins both contracts (§5)
├── requirements-core.txt      # [J] Vertex SDK, redisvl, fastapi…
├── requirements-pipe.txt      # [N] scenedetect, opencv, imagehash, Pillow, faster-whisper
├── requirements-glue.txt      # [N] fastmcp, httpx, pytest
├── memory/
│   ├── config.py              # [J] shared constants (Redis, GCP project, model ids, dirs)
│   ├── pipeline.py            # [N] video → list[shot dict]  ◄── THE INTERNAL SEAM (§5.2)
│   ├── access.py              # [N] the Yes / Select folders / No permission step (Juan tests it)
│   ├── embed.py               # [J] Vertex multimodal embeddings (image + text, shared space)
│   ├── describe.py            # [J] Gemini caption  (Whisper transcript lives in pipeline.py, [N])
│   ├── index.py               # [J] RedisVL schema + get_index()
│   └── search.py              # [J] search_media_memory(...) -> list[dict]
├── ingest.py                  # [J] CLI: access → pipeline (N) → Vertex → Redis
├── serve.py                   # [J] FastAPI POST /search   <-- THE EXTERNAL SEAM (§5.1)
├── serve_stub.py              # [N] hardcoded one-clip /search, so glue is buildable before serve.py
├── mcp_server.py              # [N] FastMCP wrapper -> HTTP -> serve.py
├── tests/                     # [N] §10 checkpoints as pytest (sample video + fake JSON)
└── demo/
    ├── claude_desktop_config.json   # [N] draft both MCP servers; [J] fills real paths
    ├── system_prompt.md             # [N] first draft; [J] tunes live
    └── run_demo.md                  # [N] draft script; [J] finalizes + fallback
```

---

## 7. Setup (do this together, first)

**Redis Stack (needs RediSearch — plain Redis won't do vector search):**
```bash
brew tap redis-stack/redis-stack && brew install redis-stack
redis-stack-server      # leave running on :6379
# OR: docker run -d -p 6379:6379 redis/redis-stack:latest
```

**Google Cloud / Vertex AI (Juan):**
```bash
gcloud auth login                          # run this yourself (interactive)
gcloud config set project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
gcloud auth application-default login       # gives the Python SDK credentials
export GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID
export GOOGLE_CLOUD_LOCATION=us-central1
```
Cost: captioning + embedding a whole library is single-digit dollars against your $10k. Non-issue.

**Python envs (separate, on purpose):**
```bash
cd ~/VibeEditor/media-memory
python3.12 -m venv .venv-core && source .venv-core/bin/activate && pip install -r requirements-core.txt  # [J]
python3.12 -m venv .venv-pipe && source .venv-pipe/bin/activate && pip install -r requirements-pipe.txt  # [N] pipeline
python3.12 -m venv .venv-glue && source .venv-glue/bin/activate && pip install -r requirements-glue.txt  # [N] glue
```
- `requirements-core.txt` [J]: `google-cloud-aiplatform redis redisvl fastapi uvicorn` *(no torch/CLIP — embeddings are Vertex now)*
- `requirements-pipe.txt` [N]: `scenedetect[opencv] opencv-python imagehash Pillow faster-whisper`
- `requirements-glue.txt` [N]: `fastmcp httpx pytest`
- **ffmpeg** (system binary, used by `cut_shot` in §9.2): `brew install ffmpeg` (Devin's sandbox: `apt-get install ffmpeg`).

---

## 8. JUAN — the memory spine + live orchestration

**Goal:** turn Nikhil's shot dicts into a searchable Redis index, serve it over HTTP in the Contract
shape, then point one agent at both that service and VibeEdit and drive the whole edit live. You can build
and verify the spine with `serve.py` + `curl` **before** wiring the agent.

### 8.0 `memory/config.py` — shared constants (write first; everything imports from here)

```python
import os
REDIS_URL  = os.environ.get("REDIS_URL", "redis://localhost:6379")
INDEX_NAME = "media_memory"

GCP_PROJECT   = os.environ["GOOGLE_CLOUD_PROJECT"]
GCP_LOCATION  = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
EMBED_MODEL   = "multimodalembedding@001"   # Vertex: image + text (+ video) share ONE space
EMBED_DIM     = 1408                          # must equal the RedisVL vector dims exactly
CAPTION_MODEL = "gemini-2.5-flash"           # verify exact id in Vertex Model Garden

THUMBS_DIR  = os.path.expanduser("~/.media-memory/thumbs")
CLIPS_DIR   = os.path.expanduser("~/.media-memory/clips")   # pre-cut shot files (what the agent imports)
ACCESS_FILE = os.path.expanduser("~/.media-memory/access.json")
DEFAULT_MEDIA_DIRS = [os.path.expanduser("~/Movies"), os.path.expanduser("~/Pictures")]  # + /Volumes/* at runtime
```
Hand `THUMBS_DIR` / `CLIPS_DIR` / the id rule (§5.2) to Nikhil so his `pipeline.py` writes to the same place.

### 8.2 `memory/embed.py` — Vertex multimodal embeddings (the meaning-fingerprint)

Vertex's `multimodalembedding@001` maps an **image** and the **text** "skateboarding" into the *same*
number-space, so they land near each other — that's how a text query finds an untagged clip. **The image
encoder (ingest) and text encoder (query) must be this same model**, or the vectors live in different
spaces and search returns garbage.

```python
import vertexai, numpy as np
from vertexai.vision_models import MultiModalEmbeddingModel, Image as VImage
from memory.config import GCP_PROJECT, GCP_LOCATION, EMBED_MODEL, EMBED_DIM

vertexai.init(project=GCP_PROJECT, location=GCP_LOCATION)
_model = MultiModalEmbeddingModel.from_pretrained(EMBED_MODEL)

def embed_image(jpg_path: str) -> np.ndarray:     # ingest time — reads Nikhil's thumb_path
    e = _model.get_embeddings(image=VImage.load_from_file(jpg_path), dimension=EMBED_DIM)
    return np.array(e.image_embedding, dtype="float32")

def embed_text(text: str) -> np.ndarray:          # query time — SAME model, SAME space
    e = _model.get_embeddings(contextual_text=text, dimension=EMBED_DIM)
    return np.array(e.text_embedding, dtype="float32")
```
*Upgrade (optional):* this model can embed a **video segment natively** (better for action b-roll), but
that needs the clip in a Cloud Storage bucket. Start frame-based (above); add video later if time.

### 8.3 `memory/describe.py` — Gemini caption (Whisper lives in Nikhil's pipeline)

```python
import vertexai
from vertexai.generative_models import GenerativeModel, Part
from memory.config import GCP_PROJECT, GCP_LOCATION, CAPTION_MODEL

vertexai.init(project=GCP_PROJECT, location=GCP_LOCATION)
_gemini = GenerativeModel(CAPTION_MODEL)
CAPTION_PROMPT = "Describe what is visible in one concrete sentence: subjects, action, setting. No preamble."

def caption_image(jpg_path: str) -> str:           # reads Nikhil's thumb_path
    part = Part.from_data(open(jpg_path, "rb").read(), mime_type="image/jpeg")
    return _gemini.generate_content([part, CAPTION_PROMPT]).text.strip()
```
Transcription + the speech-window logic is in `pipeline.py` (Nikhil) — the shot dict already arrives with
`transcript` and `has_speech` filled in, so you don't redo it here.

### 8.4 `ingest.py` — the assembly line (folders → Nikhil's pipeline → Vertex → Redis)

Your `ingest.py` is thin: it walks folders, calls Nikhil's pipeline per file, then enriches and upserts.

```
roots = access.resolve_scan_roots()                 # Step 0: the permission step (Nikhil's access.py)
for each media file under roots:
    shots = pipeline.process_video(path)            # ◄── Nikhil's pipeline returns shot dicts (§5.2)
    for s in shots:                                  #     (images return a 1-element list)
        vec        = embed.embed_image(s["thumb_path"])     # Vertex fingerprint
        caption    = describe.caption_image(s["thumb_path"])# Gemini caption
        created_at, gps = metadata(path)                    # date + GPS from EXIF/AVFoundation
        upsert_record(                                       # into Redis (8.5)
            asset_path=s["clip_path"], source_path=path,
            t_start=s["t_start"], t_end=s["t_end"], duration=s["duration"],
            caption=caption, transcript=s["transcript"], has_speech=s["has_speech"],
            created_at=created_at, gps=gps,
            thumbnail_path=s["thumb_path"], visual_embedding=vec)
```
**While Nikhil's pipeline doesn't exist yet (Block 1),** stub it: a 3-line `process_video` that copies one
sample mp4 into `CLIPS_DIR`, grabs one frame as the thumb, and returns a single shot dict. That lets you
build embed/caption/Redis/serve end-to-end before his real pipeline lands — then you just swap the import.

### 8.5 `memory/index.py` — the Redis schema (`dims` must equal `EMBED_DIM` = 1408)

```python
from redisvl.index import SearchIndex
from memory.config import REDIS_URL, INDEX_NAME, EMBED_DIM

SCHEMA = {
  "index": {"name": INDEX_NAME, "prefix": "clip:", "storage_type": "hash"},
  "fields": [
    {"name": "asset_path",     "type": "text"},          # pre-cut shot file (what the agent imports)
    {"name": "source_path",    "type": "text"},          # original file the shot came from (provenance)
    {"name": "t_start",        "type": "numeric"},        # seconds into source_path (provenance)
    {"name": "t_end",          "type": "numeric"},        # seconds into source_path (provenance)
    {"name": "caption",        "type": "text"},          # BM25 keyword search
    {"name": "transcript",     "type": "text"},          # BM25 keyword search
    {"name": "has_speech",     "type": "tag"},            # "true" / "false"
    {"name": "created_at",     "type": "numeric"},        # epoch seconds (range filters)
    {"name": "duration",       "type": "numeric"},
    {"name": "gps",            "type": "geo"},            # "lon,lat", optional
    {"name": "thumbnail_path", "type": "text"},
    {"name": "visual_embedding","type": "vector",
       "attrs": {"dims": EMBED_DIM, "distance_metric": "cosine",
                 "algorithm": "hnsw", "datatype": "float32"}},
  ],
}
def get_index():
    idx = SearchIndex.from_dict(SCHEMA, redis_url=REDIS_URL); idx.create(overwrite=False); return idx
```

### 8.6 `memory/search.py` — `search_media_memory(...)`

1. Embed the **query** with `embed.embed_text` (Vertex — same space as `visual_embedding`).
2. RedisVL `VectorQuery` over `visual_embedding` (upgrade to hybrid RRF over `caption`+`transcript` if
   proper nouns matter). Return fields: `asset_path, duration, caption, has_speech, created_at,
   source_path, t_start, t_end, thumbnail_path` + vector distance.
3. **Filters** (`filter_expression`): `Tag("has_speech")=="false"` for b-roll; `Num("created_at")` for
   `after`/`before` (convert ISO → epoch here); `Geo` radius for `near_gps`.
4. Map each hit to the **Contract** record: `score = 1 - distance`, epoch → `YYYY-MM-DD`. Return a
   `list[dict]` (unwrapped; `serve.py` wraps it).

### 8.7 `serve.py` — the seam (FastAPI)

```python
from fastapi import FastAPI
from pydantic import BaseModel
from memory.search import search_media_memory
app = FastAPI()
class Q(BaseModel):
    query: str; has_speech: bool | None = None; after: str | None = None
    before: str | None = None; near_gps: list[float] | None = None; limit: int = 8
@app.post("/search")
def search(q: Q):
    return {"clips": search_media_memory(**q.model_dump())}   # always {"clips": [...]}
```
Run: `uvicorn serve:app --port 8000`.

### 8.8 Spine definition of done
```bash
python ingest.py                 # prompts Yes/Select/No, then fills Redis
curl -s localhost:8000/search -H 'content-type: application/json' \
  -d '{"query":"skateboarding","has_speech":false,"limit":5}' | jq
```
Returns the Contract shape, sensible clips **including one you never tagged** (proves semantic recall);
every `asset_path` is an absolute, existing **pre-cut clip file**, and `duration` is in seconds.

---

Now the **live orchestration** (this was "Person A" in the old plan — it's the highest-judgment, demo-day
work, so it stays with you).

### 8.9 Connect ONE agent to BOTH servers (VibeEdit must be running)
- **Claude Desktop** — `demo/claude_desktop_config.json` (Nikhil drafts it; you fill real paths):
  ```json
  { "mcpServers": {
      "media-memory": { "command": "/abs/.venv-glue/bin/python", "args": ["/abs/media-memory/mcp_server.py"] },
      "vibeedit":  { "command": "npx", "args": ["mcp-remote", "http://127.0.0.1:19789/mcp"] } } }
  ```
- **Claude Code** — `claude mcp add --transport http vibeedit http://127.0.0.1:19789/mcp`, plus
  `media-memory` as stdio. (Claude Code is easier to feed text into for the voice handoff.)

### 8.10 The orchestration brain (`demo/system_prompt.md` — Nikhil drafts, you tune live)

> You have a **memory** of the user's entire footage library (`search_media_memory`) and **VibeEdit**,
> the editor (`getTimeline`, `getTranscript`, `importMedia`, `addClips`). The memory returns **pre-cut
> clip files**, so you place each one whole — you never trim the source.
> To add b-roll about a topic:
> 1. `getTimeline` → read **fps** and tracks. `getTranscript` → find where the rant covers the topic
>    (gives timeline frame ranges to cover).
> 2. `search_media_memory(query=<visual topic>, has_speech=false, limit=8)`; pick best by caption.
> 3. For each chosen clip:
>    a. `importMedia(source={path: <asset_path>})` → read the **asset id**. (`asset_path` is the pre-cut
>       shot file; import it as-is.)
>    b. `dur_frames = round(duration * fps)`; choose a `startFrame` over the relevant rant span.
>    c. `addClips(entries=[{mediaRef: <id>, startFrame, durationFrames: dur_frames, trackIndex: <video
>       track above the rant audio>}])` → read the **clip id**. Done — the whole clip is the b-roll, so
>       **no `setClipProperties` trim is needed**.
> 4. Never overwrite the rant's audio. Place b-roll on a video track above it.

Tuning this against the live agent + running VibeEdit is the real work — expect several iterations.

### 8.11 The seconds→frames math (own this — risk #1, now mostly retired)
- `fps` from `getTimeline` (don't hardcode 30).
- **One conversion, that's it:** `durationFrames = round(duration * fps)`. Because ingest pre-cuts each
  shot to its own file (§9.2), the agent imports + `addClips` the whole file and **never calls
  `setClipProperties` to trim**. This is the rock-solid path.
- **Why no trim:** verified in `ToolDefinitions.swift:195` — `trimStartFrame`/`trimEndFrame` are
  **SOURCE-media** offsets at the *source's* fps (and `trimEndFrame` is frames trimmed *off the end*, not
  an end position). `round(t_seconds * project_fps)` would be wrong on both counts. Pre-cutting sidesteps it.
- **Only if you ever place an original (un-cut) file** (stretch, or if a cut fails): the correct trim is
  `trimStartFrame = round(t_start * source_fps)` and `trimEndFrame = round((source_duration - t_end) *
  source_fps)` — and you'd need `source_fps`, which the Contract does not carry. Don't go here for the demo.

### 8.12 Demo script + fallback (`demo/run_demo.md`)
- Optional opening beat: show the **Yes / Select folders / No** access prompt, then "memory built."
- Happy path: VibeEdit open on the rant project → *"add skateboarding b-roll to my rant"* → agent
  searches, imports, places clips.
- **Fallback** if live placement flakes: agent still surfaces the clips ("found 6 from your June 2024
  skate session") and you drag them in.

### 8.13 Curate the recall set
Pick / pre-ingest a strong "year ago" b-roll set so the semantic-recall moment lands reliably on stage.

### 8.14 Your definition of done
With your real `serve.py` running and VibeEdit open, one natural-language prompt puts b-roll on a track
above the rant — or, fallback, surfaces the right clips.

---

## 9. NIKHIL — your two jobs (built with Devin, tested offline)

Hi Nikhil 👋 — this section is written for you. You don't need to know Swift, Vertex, Redis, or anything
about Juan's Mac. **Everything you own runs on a single sample video file and a bit of fake JSON, in
Devin's own sandbox.** You build it, test it, and hand Juan pull requests; he plugs them into the live
system.

### 9.0 How to work with Devin (read this first)

Devin is an autonomous coding agent. It's great at **one well-scoped task with a clear spec and a way to
test it**, and bad at fuzzy "figure out the whole system" asks. So your loop is:

1. **Pick one small function** from the list below (e.g. "split a video into shots").
2. **Give Devin a tight prompt:** what the function is called, what it takes in, what it returns, and
   *how to test it*. Paste the relevant spec (§5.2 and the step below) right into Devin.
3. **Make Devin test it** in its sandbox: download one sample video (e.g. a Creative-Commons skate clip),
   `apt-get install ffmpeg`, `pip install -r requirements-pipe.txt`, run the function, print the result.
4. **Read the diff yourself** before accepting. You're the reviewer — Devin is the typist.
5. **Open a PR to Juan.** He runs it against the real footage + credentials on his Mac.

**What Devin/you can NOT do** (so don't try, and don't let Devin pretend it did): touch Juan's Mac, his
Google Cloud account, his footage, the running VibeEdit app, or his local Redis. If a task needs any of
those, it's Juan's, not yours. Your code must run with **zero credentials and zero network calls**.

You have **two jobs**. Job A is the bigger one; do it first.

### 9.1 The mental model (what you're actually building)

Juan is building a "memory" of all of someone's video. Before any AI can understand a video, the video has
to be **chopped into short clips and a still frame pulled out of each one**. That chopping is **Job A** —
your pipeline. Then there's a thin **MCP wrapper** that lets the AI agent call the memory — that's **Job
B**. Neither job needs the AI parts; you're the prep cook, Juan's the chef.

---

### 9.2 JOB A — the pre-processing pipeline (`memory/pipeline.py`)

**The one function Juan calls:**
```python
def process_video(source_path: str) -> list[dict]:   # returns a list of "shot dicts" (§5.2)
    ...
def process_image(source_path: str) -> list[dict]:   # a still: returns a 1-element list
    ...
```
**Input:** an absolute path to one video (or image) file.
**Output:** a list of **shot dicts** in the exact §5.2 shape. Read §5.2 now — it is your contract with
Juan, and Devin should be given it verbatim.

Build it as **six small helper functions**, one at a time, each tested on its own. Here's what each does
and *why*:

**Step 1 — `split_into_shots(path) -> list[(t_start, t_end)]`**
*What:* find where the camera cuts, so each "shot" becomes its own clip. Use the `scenedetect` library's
`ContentDetector`. *Why:* a 10-minute video is useless as one blob; the agent wants a 6-second skate
trick, not the whole tape. Times are in **seconds** (floats).
*Test:* run on a sample video, print the list of (start, end) — eyeball that the count looks like the
number of visible cuts.

**Step 2 — `pick_sharpest(path, t_start, t_end) -> "frame.jpg"`**
*What:* sample a handful of frames inside the shot and keep the **least blurry** one (the "variance of the
Laplacian" trick — OpenCV: `cv2.Laplacian(gray, cv2.CV_64F).var()`, higher = sharper). *Why:* we send one
still image to the AI to describe and fingerprint the shot; a blurry frame gives a bad description.
*Test:* print the variance scores of a few frames and confirm it returns the highest one.

**Step 3 — `phash(jpg) ` + dedup**
*What:* compute a "perceptual hash" (the `imagehash` library) of the keyframe and skip a shot if it looks
almost identical to one already kept this run. *Why:* people film the same thing twice; we don't want ten
near-identical clips. *Test:* hash two copies of the same image (should match) and two different images
(should differ).

**Step 4 — save the thumbnail**
*What:* write the chosen keyframe to `~/.media-memory/thumbs/<id>.jpg` where
`id = sha1(f"{abs_source_path}:{t_start}").hexdigest()[:8]`. *Why:* Juan's AI step reads this file; it's
also a preview. This path goes in the shot dict as `thumb_path`.

**Step 5 — `cut_shot(path, t_start, t_end) -> "~/.media-memory/clips/<id>.mp4"`**
*What:* use **ffmpeg** to cut just that shot into its own little mp4. *Why (important):* this is the trick
that kills the worst bug in the whole project. By making each shot a standalone file, the editor can drop
it in **whole** — nobody has to do fragile "trim from second 12 to second 18" math. The command:
```bash
ffmpeg -ss <t_start> -i <src> -t <t_end - t_start> -c copy ~/.media-memory/clips/<id>.mp4
```
`-c copy` is fast (no re-encode). If cuts look slightly off, swap to `-c:v libx264`. This path goes in the
shot dict as `clip_path`. **Never modify the original file** — you only read it.
*Test:* run it, then check the output file exists and plays and is about `(t_end - t_start)` seconds long.

**Step 6 — transcript + `has_speech` (Whisper, runs locally, free)**
*What:* transcribe the **whole video once** with `faster-whisper` (`WhisperModel("base",
compute_type="int8")`), get word/segment timestamps, then for each shot keep only the words whose
timestamps fall **inside `[t_start, t_end]`**. `has_speech = (that text is non-empty)`. *Why:* this is how
we tell talking ("A-roll", someone speaking) from silent action footage ("B-roll", what we want to add).
```python
def transcribe_file(path):
    segments, _ = WhisperModel("base", compute_type="int8").transcribe(path)
    return [(s.start, s.end, s.text) for s in segments]   # transcribe ONCE per file

def words_in_window(segments, t_start, t_end) -> tuple[str, bool]:
    hits = [text for (s, e, text) in segments if e > t_start and s < t_end]
    joined = " ".join(t.strip() for t in hits).strip()
    return joined, bool(joined)
```
*Test:* feed a clip you know has talking → `has_speech` is `True`; a silent clip → `False`.

**Putting it together — `process_video`:**
```python
def process_video(source_path):
    shots = []
    segments = transcribe_file(source_path)              # Step 6, once
    seen_hashes = []
    for (t_start, t_end) in split_into_shots(source_path):  # Step 1
        jpg = pick_sharpest(source_path, t_start, t_end)    # Step 2
        if is_duplicate(jpg, seen_hashes): continue          # Step 3
        sid = sha1(f"{os.path.abspath(source_path)}:{t_start}".encode()).hexdigest()[:8]
        thumb_path = save_thumb(jpg, sid)                   # Step 4
        clip_path  = cut_shot(source_path, t_start, t_end, sid)  # Step 5
        transcript, has_speech = words_in_window(segments, t_start, t_end)  # Step 6
        shots.append({
            "t_start": t_start, "t_end": t_end, "duration": t_end - t_start,
            "clip_path": clip_path, "thumb_path": thumb_path,
            "transcript": transcript, "has_speech": has_speech,
        })
    return shots
```
For `process_image`: there's no cutting — `clip_path` is the image itself, `thumb_path` a resized copy,
`t_start = t_end = duration = 0`, `transcript = ""`, `has_speech = False`. Return `[that_one_dict]`.

**Job A is done when:** `process_video("sample.mp4")` prints a list of dicts that exactly match §5.2, every
`clip_path`/`thumb_path` exists on disk and plays/opens, and `has_speech` is right on a talking vs. silent
clip — **all in Devin's sandbox, no credentials.**

### 9.3 `memory/access.py` — the permission step (you write it, Juan tests it)

On first run, ingest asks the user which folders it's allowed to read: **Yes / Select folders / No**. Devin
can write all of this; the macOS folder-picker line can only be *tested* on Juan's Mac, so just get the
logic right and let Juan run it.

```python
import json, os, subprocess
from memory.config import ACCESS_FILE, DEFAULT_MEDIA_DIRS

def resolve_scan_roots(force_prompt=False) -> list[str]:
    if not force_prompt and os.path.exists(ACCESS_FILE):
        return json.load(open(ACCESS_FILE))["roots"]
    choice = input("Build media memory from  [Y]es all media / [S]elect folders / [N]o? ").strip().lower()
    if choice.startswith("n"):
        roots = []
    elif choice.startswith("s"):
        roots = _pick_folders_macos()
    else:
        roots = [d for d in DEFAULT_MEDIA_DIRS if os.path.isdir(d)] + _mounted_volumes()
    os.makedirs(os.path.dirname(ACCESS_FILE), exist_ok=True)
    json.dump({"roots": roots}, open(ACCESS_FILE, "w"))
    return roots

def _mounted_volumes() -> list[str]:
    v = "/Volumes"
    return [os.path.join(v, d) for d in os.listdir(v)] if os.path.isdir(v) else []

def _pick_folders_macos() -> list[str]:               # native multi-select folder dialog (Juan tests)
    script = '''set chosen to choose folder with multiple selections allowed
                set out to ""
                repeat with f in chosen
                    set out to out & POSIX path of f & linefeed
                end repeat
                return out'''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return [p for p in r.stdout.strip().splitlines() if p]
```
*Test you can do:* unit-test the **logic** by faking `input()` and `os.path.exists` (does "n" return `[]`?
does a saved `access.json` get reused?). The dialog itself is Juan's to verify on the Mac.

---

### 9.4 JOB B — the glue scaffolding (so Juan can wire the agent fast)

This is the small plumbing that lets an AI agent call Juan's memory service. You build all of it against a
**fake** memory service, so you don't need Juan's Redis or Vertex.

**(a) `serve_stub.py` — a fake memory service.** Returns one hardcoded clip in the §5.1 shape, so you can
build and test the wrapper before Juan's real `serve.py` exists:
```python
from fastapi import FastAPI
app = FastAPI()
@app.post("/search")
def search(_: dict):
    return {"clips": [{
        "asset_path": "/tmp/fake_clip.mp4", "duration": 6.0,
        "caption": "a person doing a kickflip at a skatepark", "has_speech": False,
        "created_at": "2024-06-11", "source_path": "/tmp/fake_src.mp4",
        "t_start": 12.0, "t_end": 18.0, "thumbnail_path": "/tmp/fake.jpg", "score": 0.83,
    }]}
```
Run with `uvicorn serve_stub:app --port 8000`.

**(b) `mcp_server.py` — the MCP wrapper (one tool).** This is what the AI agent actually calls. It just
forwards to the HTTP service (§5.1):
```python
from fastmcp import FastMCP
import httpx
mcp = FastMCP("media-memory")

@mcp.tool()
def search_media_memory(query: str, has_speech: bool | None = None, after: str | None = None,
                        before: str | None = None, near_gps: list[float] | None = None,
                        limit: int = 8) -> list[dict]:
    """Search the user's lifetime footage memory for clips matching a description.
    Returns clips with absolute asset_path and t_start/t_end in SECONDS."""
    r = httpx.post("http://127.0.0.1:8000/search", json={
        "query": query, "has_speech": has_speech, "after": after,
        "before": before, "near_gps": near_gps, "limit": limit}, timeout=30)
    r.raise_for_status()
    return r.json()["clips"]

if __name__ == "__main__":
    mcp.run()   # stdio
```
*Test:* start `serve_stub.py`, then call your tool (or `curl` the stub) and confirm you get the one clip
back. That's the whole proof — when Juan swaps in his real `serve.py`, nothing in your wrapper changes.

**(c) `demo/claude_desktop_config.json`** — draft the two-server config (the JSON in §8.9). Use
placeholder paths; Juan fills the real absolute paths on his machine.

**(d) `demo/system_prompt.md`** — write a **first draft** of the instructions in §8.10 (what the agent
should do, step by step). Juan will tune the wording against the live agent, but a solid draft saves him
time.

### 9.5 Tests (`tests/` — the §10 checkpoints, as real pytest)

Turn the integration checklist (§10) into actual tests so we catch mismatches automatically:
- **Shape test:** the stub `/search` response is `{"clips": [...]}` (an object, not a bare list), even when
  empty.
- **Pipeline contract test:** every dict from `process_video("sample.mp4")` has exactly the §5.2 keys, the
  right types, and `clip_path`/`thumb_path` that exist on disk.
- **Units test:** `duration == t_end - t_start`, and there are **no frame fields anywhere** (seconds only).
- **Speech test:** a known-talking clip → `has_speech True`; a silent clip → `False`.

These all run with no credentials, so Devin can run them in CI / its sandbox.

### 9.6 Your definition of done
1. `process_video("sample.mp4")` returns §5.2-correct shot dicts, files on disk, in Devin's sandbox.
2. `mcp_server.py` returns the stub's clip when `serve_stub.py` is running.
3. The §10 tests pass.
4. PRs are open for Juan to merge into the live system.

### 9.7 Handing off to Juan
Each PR should say, in one line: *what function, how you tested it, what sample file you used.* If Devin
claims something works that needs Juan's Mac/creds (it can't have), flag it as "needs Juan to verify" —
never merge an "it works" you couldn't actually run.

---

## 10. Integration checkpoints (anti-mismatch checklist)
- [ ] **Both contracts frozen** (§5.1 external, §5.2 internal), pinned in the README.
- [ ] **Internal seam round-trip:** a dict from `process_video` (N) drops straight into `ingest.py` (J) with
      no key/type fixups.
- [ ] **Empty result:** nonsense query returns `{"clips": []}`, not `[]`, not a 500.
- [ ] **Path round-trip:** an `asset_path` from `/search` is absolute and `importMedia` accepts it.
- [ ] **Units round-trip:** placed clip length on the timeline matches the clip's `duration` seconds (no trim).
- [ ] **Embedding space sanity:** "skateboarding" ranks a skate clip above unrelated clips (confirms
      image+text both use Vertex `multimodalembedding@001`).
- [ ] **has_speech filter:** `has_speech:false` excludes the talking rant clip.
- [ ] **Two-server agent:** in one chat the agent calls both `search_media_memory` and `getTimeline`.

---

## 11. Build order (parallel from hour one)

| When | Juan (spine + live orchestration) | Nikhil (offline, via Devin) |
|---|---|---|
| **Together, 30 min** | Freeze BOTH contracts (§5.1, §5.2). Redis Stack up. GCP project + Vertex + ADC. Repo skeleton + `config.py`. Walk Nikhil through §5.2 + the Devin workflow (§9.0). | Same kickoff. Get Devin set up, clone the repo, read §5.2 + §9. Grab a sample video. |
| **Block 1** | `embed.py` + `caption` + thin `ingest.py` calling a **fake** `process_video` (one shot) → upsert to Redis (verify `redis-cli`). | **Job A, steps 1–5:** `split_into_shots` → `pick_sharpest` → phash dedup → thumbnail → `cut_shot`. `process_video` returns §5.2 dicts (no transcript yet). Test on the sample. |
| **Block 2** | Swap fake pipeline for Nikhil's real `pipeline.py`. Real `search.py` + `serve.py`; `curl` recall check (§8.8). Wire BOTH MCP servers; tune `system_prompt.md` live against running VibeEdit. | **Job A, step 6:** Whisper transcript + `has_speech`. **Job B:** `mcp_server.py` + `serve_stub.py` + `claude_desktop_config.json` + `system_prompt.md` draft. Prove wrapper→stub. |
| **Block 3** | Full skateboarding loop end-to-end on your Mac; record the fallback (§8.12); curate the "year ago" b-roll set (§8.13). | `access.py` for Juan to test; `tests/` (§10 as pytest); pipeline edge cases (images, silent/odd codecs); draft `run_demo.md`. |
| **Block 4** | Debug recall/placement; (optional) wire voice text → agent. | Hardening: more pipeline tests, dedup tuning; prepare stub data so Juan can demo offline if the live loop flakes. |
| **Stretch** | In-app native tool (§12); auto-ingest on SD insert. | Draft an FSEvents auto-ingest watcher for Juan to test; native video-embedding spike. |

---

## 12. Stretch goals (only after the core demo works)
- **Auto-ingest on SD insert:** watch `/Volumes`; on mount, run `ingest.py` on the new volume — the "it
  just remembers everything" beat. (Pairs naturally with the access step. Nikhil can draft the watcher;
  Juan tests on hardware.)
- **Native video embeddings/captions** via Vertex (clip → GCS) for better action recall.
- **In-app tool (drops the external client):** add `search_media_memory` as a native VibeEdit tool — a
  `ToolName` case + schema in `ToolDefinitions.swift` + a `ToolExecutor+Memory.swift` doing a localhost
  `URLSession` POST to `serve.py`. Only after the external demo is rock-solid. (Juan — Swift.)
- **Hybrid RRF + BM25** in `search.py`; **MMR** if results repeat. (Juan.)
- **Voice:** finish the ElevenLabs speech-to-text → agent handoff (already partly in-app). (Juan, late.)

---

## 13. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Seconds↔frames / trim bug | **Retired:** ingest pre-cuts each shot to its own file (§9.2), so the agent only does `durationFrames = round(duration*fps)` and never trims at the source fps. `trimStartFrame`/`trimEndFrame` are source-media frames (`ToolDefinitions.swift:195`), so the old `round(t*project_fps)` formula was wrong on two counts. |
| `importMedia` rejects a path | Ingest always writes absolute, existing paths; §10 checkpoint. |
| Image & text from different embedders | Single `EMBED_MODEL` (Vertex) in `config.py`; both come from it. |
| Vertex auth / region / model-id drift | `gcloud auth application-default login`; pin `EMBED_DIM`=1408; confirm `CAPTION_MODEL` in Model Garden. (Juan only — Nikhil's code needs no creds.) |
| Vertex SDK deprecation (`vertexai` pkg) | `vertexai.generative_models` / `vertexai.vision_models` is the legacy SDK, being removed (~mid-2026) in favor of the `google-genai` package. **Smoke-test `import vertexai` on a clean env before relying on it;** if gone, port `describe.py`/`embed.py` to `google-genai` (same models, same `multimodalembedding@001` @ 1408 dims). |
| Internal seam drift (pipeline ⇄ ingest) | §5.2 frozen + `tests/` assert exact keys/types; Juan's Block-1 fake pipeline matches §5.2 so the swap is a one-liner. |
| Devin "works" that wasn't actually run | Nikhil's code needs no creds, so it must truly run in the sandbox; PRs state how each piece was tested; anything needing Juan's Mac is flagged, not merged. |
| Ingest slow / Vertex rate limits | It's **pre-baked** before the demo; batch and run ahead; cost is trivial vs $10k. |
| Redis missing RediSearch | Use **Redis Stack**, not plain Redis (§7). |
| Live auto-placement flakes | Fallback: agent surfaces clips, human drags them in (§8.12). |
| macOS file-access prompts | Expected; "Select folders" picker sidesteps broad permissions. |

---

## 14. One-paragraph summary for the team

We're giving VibeEdit a memory of all your footage, built by two people. **Nikhil** (working through Devin)
owns the parts that run on a single sample file with no credentials: a **pre-processing pipeline** that
chops each video into shots, picks the sharpest frame, dedups, cuts each shot into its own little file with
ffmpeg, and transcribes audio with Whisper — plus the **glue scaffolding** (an MCP wrapper, a stub
service, configs, and tests). **Juan** owns the credentialed spine and the live demo: describing each shot
with **Gemini** and fingerprinting it with **Vertex multimodal embeddings**, storing everything in
**Redis**, serving search over HTTP (`serve.py`), and then pointing one agent at both that memory and
VibeEdit's MCP server so a plain-English request becomes `search_media_memory → importMedia → addClips` and
clips land on the timeline. The work meets at exactly **two frozen seams** — the internal shot-dict
(§5.2, Nikhil → Juan) and the external `POST /search` shape (§5.1, service → agent) — so the two of you
build in parallel and snap together at the end. **Voice** (ElevenLabs) is a late stretch beat for Juan.
