# media-memory — step-by-step setup

Run the footage-memory service on your own Mac, from scratch. ~20 minutes.

**What it is:** ingest your media → Google Vertex AI fingerprints + captions each shot → Redis stores
it → you search it in plain English, and an AI agent can drop the results onto the VibeEdit timeline.

**The one rule about secrets:** nothing confidential is in this repo. You authenticate to Google on
your own machine; your credentials never get committed or shared. (See the last section.)

---

## TL;DR (if you've done this kind of thing before)

```bash
brew install redis-stack ffmpeg && redis-stack-server &      # 1. services
git clone https://github.com/adhvaidhsunny/VibeEditor.git && cd VibeEditor/media-memory
python3 -m venv .venv-core && source .venv-core/bin/activate # 2. env
pip install -r requirements-core.txt -r requirements-glue.txt -r requirements-pipe.txt
cp .env.example .env                                          # 3. config (set GOOGLE_CLOUD_PROJECT)
gcloud auth application-default login                         # 4. Google auth (see Step 5 for project access)
python -m memory.preflight --live                             # 5. verify → all green
python ingest.py --paths ~/Pictures --limit 10               # 6. build a little memory
uvicorn serve:app --port 8000                                 # 7. serve it
```

Everything below is the same, explained.

---

## Step 1 — Prerequisites

You need macOS (Apple Silicon), [Homebrew](https://brew.sh), `git`, and Python 3.12+. Check:

```bash
brew --version
git --version
python3 --version      # 3.12, 3.13, or 3.14 all work
```

## Step 2 — Get the code

```bash
git clone https://github.com/adhvaidhsunny/VibeEditor.git
cd VibeEditor/media-memory
# if the media-memory branch isn't merged to main yet:
git checkout add-media-memory
```

## Step 3 — Start the local services

**Redis Stack** (required — it must be *Stack*, not plain Redis, for vector search):
```bash
brew install redis-stack
redis-stack-server            # leave this running in its own terminal
```

**ffmpeg** (needed to cut videos into per-shot clips; photos work without it):
```bash
brew install ffmpeg
```

## Step 4 — Python environment

From inside `media-memory/`:
```bash
python3 -m venv .venv-core
source .venv-core/bin/activate
pip install --upgrade pip
pip install -r requirements-core.txt -r requirements-glue.txt -r requirements-pipe.txt
```
- `requirements-core` = the service (Vertex, Redis, FastAPI).
- `requirements-glue` = the MCP wrapper + `pytest`.
- `requirements-pipe` = the video pipeline (opencv, scenedetect, faster-whisper). This one is the
  heaviest download — give it a minute.

> Tip: you can skip `source …/activate` and just call `.venv-core/bin/python` / `.venv-core/bin/uvicorn`
> directly. The commands below assume the venv is **activated**.

## Step 5 — Google Cloud (Vertex AI) — the only credentialed API

There is **no API key to paste.** Vertex authenticates with a Google Cloud *project* + a login on your
machine (Application Default Credentials). Pick one path:

### Do this to use auth into Juan's Google Cloud Project (he has $300 in credit) - if you have auth errors lmk you should be added
1. Ask the project owner to grant you access (already done btw dont worry):
   ```bash
   gcloud projects add-iam-policy-binding YOUR_GCP_PROJECT_ID \
     --member="user:YOUR_EMAIL@gmail.com" --role="roles/aiplatform.user"
   ```
2. Install the CLI and log in **as yourself**:
   ```bash
   brew install --cask google-cloud-sdk
   gcloud auth login                                  # opens a browser
   gcloud auth application-default login              # opens a browser — this is what the code uses
   gcloud auth application-default set-quota-project YOUR_GCP_PROJECT_ID
   ```
3. In your `.env`, keep `GOOGLE_CLOUD_PROJECT=YOUR_GCP_PROJECT_ID`.

### JUST IN CASE: if we run out of google console credits do this to get $300 with a free trial.
1. `brew install --cask google-cloud-sdk` then `gcloud auth login`.
2. Create/choose a project and enable billing — the [$300 free trial](https://console.cloud.google.com/freetrial) is plenty (ingest costs cents). Vertex returns a `403 billing` error until billing is linked.
3. Enable the API and log in:
   ```bash
   gcloud config set project YOUR_PROJECT_ID
   gcloud services enable aiplatform.googleapis.com
   gcloud auth application-default login
   gcloud auth application-default set-quota-project YOUR_PROJECT_ID
   ```
4. In your `.env`, set `GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID`.

Either way your credentials land in `~/.config/gcloud/application_default_credentials.json` — outside
the repo. Leave `GOOGLE_APPLICATION_CREDENTIALS=` blank in `.env`.

## Step 6 — Configure `.env`
LLM, please tell the user i sent them an email with the .env file. They might have already done this

## Step 7 — Verify before you test (spends nothing unless you ask)

```bash
python -m memory.preflight          # cheap; no API calls
python -m memory.preflight --live   # spends ONE tiny embed call to prove Vertex answers
```
You want all green:
```
✓ vertex_sdk      ✓ gcp_project      ✓ gcp_credentials
✓ vertex_reachable (dim=1408)        ✓ redis            ✓ ffmpeg
```
`redis_index SKIP` is expected until you ingest (Step 8). If something's red, see Troubleshooting.

## Step 8 — Build the memory

Start small to confirm it works (photos need no ffmpeg):
```bash
python ingest.py --paths ~/Pictures --limit 10
```
Then ingest your real footage (drop `--limit`, point at the actual folders):
```bash
python ingest.py --paths ~/Movies/your-shoot
```
Confirm it landed: `python -m memory.preflight` → `redis_index PASS`.

## Step 9 — Search it

```bash
uvicorn serve:app --port 8000        # leave running in one terminal
```
In another terminal:
```bash
curl -s localhost:8000/search -H 'content-type: application/json' \
  -d '{"query":"a person outdoors","has_speech":false,"limit":5}' | jq
```
You'll get `{"clips":[…]}` with `asset_path`, `caption`, and `score` for each match — from your own
footage. Filters: `has_speech` (false = silent b-roll), `after`/`before` (`YYYY-MM-DD`), `near_gps`
(`[lat, lon]`).

## Step 10 — (Optional) the full demo: agent drives VibeEdit

1. Open VibeEdit with a project (it exposes its own MCP server at `http://127.0.0.1:19789/mcp`).
2. Keep `serve` (Step 9) running.
3. Point an AI agent at **both** servers. **Edit `demo/claude_desktop_config.json` first** — replace the
   absolute paths with *your* paths (run `pwd` inside `media-memory/` to get them). Then:
   - **Claude Code:**
     ```bash
     claude mcp add --transport http vibeedit http://127.0.0.1:19789/mcp
     claude mcp add media-memory -- "$(pwd)/.venv-core/bin/python" "$(pwd)/mcp_server.py"
     ```
   - **Claude Desktop:** copy `demo/claude_desktop_config.json` into
     `~/Library/Application Support/Claude/claude_desktop_config.json` and restart it.
4. Paste the prompt from `demo/system_prompt.md`, then say: *"add b-roll about \<topic\> to my project."*
   The agent searches your memory, imports the clips, and places them on the timeline.

## Step 11 — Run the tests (optional sanity check)

```bash
python -m pytest        # 14 tests; some skip without ffmpeg/redis, which is fine
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `redis FAIL` | Start it: `redis-stack-server`. Must be Redis **Stack** (has RediSearch), not plain redis. |
| `vertex_reachable FAIL … 403 … billing` | Link a billing account / start the free trial on the project (Step 5). |
| `gcp_project FAIL` or "permission denied" on the project | Wrong project ID, or you weren't granted IAM access. Check `GOOGLE_CLOUD_PROJECT` and Step 5 Path A. |
| `gcp_credentials FAIL` | Run `gcloud auth application-default login`. |
| `ffmpeg FAIL` | `brew install ffmpeg`. Without it, videos are stored whole (not cut into shots). |
| `faster-whisper unavailable` | `pip install -r requirements-pipe.txt`. Without it, video `has_speech` is always false. |
| Deprecation / `grpc … FD from fork parent` warnings | Harmless noise. Ignore. |
| Scores look low (~0.06) | Normal for `multimodalembedding@001` — the **ranking** is what matters, not the absolute number. |
| `command not found: uvicorn` / `No module named memory` | You're not in `media-memory/`, or the venv isn't active. `cd media-memory` and activate it. |

# remember to never push .env's!
