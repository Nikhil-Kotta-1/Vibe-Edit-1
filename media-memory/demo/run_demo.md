# Demo run sheet

## One-time setup
1. Redis Stack running: `redis-stack-server` (or `brew services start redis-stack`).
2. `.env` filled in (GOOGLE_CLOUD_PROJECT, etc.). `python -m memory.preflight` shows
   `vertex_sdk`, `gcp_project`, `gcp_credentials`, `redis` all PASS.
3. Memory built: `python ingest.py --paths <your footage folders>`.
4. VibeEdit running with the rant project open (its MCP server is at :19789).
5. `uvicorn serve:app --port 8000` running.
6. Agent (Claude Desktop / Claude Code) configured with `demo/claude_desktop_config.json` and the
   system prompt from `demo/system_prompt.md`.

## Live beat
- Prompt: **"add skateboarding b-roll to my rant"**
- The agent runs: `get_timeline` → `get_transcript` → `search_media_memory(has_speech=false)` →
  `import_media` → `add_clips`. Clips land on a video track above the rant.

## Fallback (if live placement flakes)
- The agent still surfaces the clips: "found 6 from your June 2024 skate session." Read the
  `asset_path`s and drag them into VibeEdit by hand. The recall is the wow; placement is mechanical.

## Quick recall sanity check (no VibeEdit needed)
    curl -s localhost:8000/search -H 'content-type: application/json' \
      -d '{"query":"skateboarding","has_speech":false,"limit":5}' | jq
