#!/usr/bin/env bash
#
# Provisions the VibeEdit voice agent on the ElevenLabs Agents Platform.
#
# It creates two CLIENT tools (executed inside VibeEdit) and an agent that uses
# them, then prints the agent_id to paste into Settings → Voice.
#
#   edit_timeline(request)  -> routes a spoken request into the in-app Claude agent
#   describe_timeline()     -> returns a one-line summary of the current timeline
#
# Usage:
#   export ELEVENLABS_API_KEY=sk_...
#   scripts/setup-elevenlabs-agent.sh                 # create a new agent
#   scripts/setup-elevenlabs-agent.sh --update AGENT  # re-point an existing agent
#   scripts/setup-elevenlabs-agent.sh --voice-id VID --llm gemini-2.5-flash
#
# Notes:
#   - Re-running without --update creates a fresh agent (and fresh tools) each time.
#   - Requires: curl, jq.

set -euo pipefail

API="https://api.elevenlabs.io/v1/convai"
VOICE_ID="${VOICE_ID:-cjVigY5qzO86Huf0OWal}"
LLM="${LLM:-gemini-2.5-flash}"
NAME="VibeEdit Voice"
UPDATE_AGENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) UPDATE_AGENT="${2:-}"; shift 2;;
    --voice-id) VOICE_ID="${2:-}"; shift 2;;
    --llm) LLM="${2:-}"; shift 2;;
    --name) NAME="${2:-}"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
: "${ELEVENLABS_API_KEY:?Set ELEVENLABS_API_KEY first}"

api() { # method path body
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "$API$path" -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

create_tool() { # name description params_json expects_response timeout
  local body
  body=$(jq -n \
    --arg name "$1" --arg desc "$2" --argjson params "$3" \
    --argjson expects "$4" --argjson timeout "$5" \
    '{tool_config: {type: "client", name: $name, description: $desc,
       response_timeout_secs: $timeout, expects_response: $expects, parameters: $params}}')
  local resp; resp=$(api POST "/tools" "$body")
  local id; id=$(echo "$resp" | jq -r '.id // .tool_id // empty')
  [[ -n "$id" ]] || { echo "Failed to create tool '$1':" >&2; echo "$resp" | jq . >&2; exit 1; }
  echo "$id"
}

echo "Creating client tools..." >&2

EDIT_PARAMS='{"type":"object","properties":{"request":{"type":"string","description":"The edit, generation, captioning, or organization the user asked for, phrased in plain language."}},"required":["request"]}'
DESCRIBE_PARAMS='{"type":"object","properties":{}}'

EDIT_ID=$(create_tool "edit_timeline" \
  "Perform any timeline edit the user asks for: cut, trim, move, caption, add text, generate video/image/audio, organize media, or undo. Pass the user's intent in plain language; the app figures out the steps and returns a short result to speak back." \
  "$EDIT_PARAMS" true 120)

DESCRIBE_ID=$(create_tool "describe_timeline" \
  "Return a one-line summary of what is currently on the timeline (resolution, fps, duration, tracks, clips). Use for questions like 'what's on my timeline' or 'how long is it'." \
  "$DESCRIBE_PARAMS" true 20)

echo "  edit_timeline   -> $EDIT_ID" >&2
echo "  describe_timeline -> $DESCRIBE_ID" >&2

read -r -d '' PERSONA <<'EOF' || true
You are the voice of VibeEdit, a Mac video editor. The user talks to you while they edit.

How you work:
- For ANY request that changes the project — cut, trim, move, split, caption, add text, generate video/image/audio/music, organize media, or undo — call edit_timeline with `request` set to the user's intent in plain language. Do not describe steps or tool names; just pass the intent and then speak the one-line result you get back.
- For questions about the current project (what's on the timeline, how long it is, how many clips), call describe_timeline.
- Generating media costs money and can't be undone — confirm in one short sentence before calling edit_timeline for a generate request.

How you speak:
- Calm, direct, technical. One or two sentences. Lead with the outcome.
- Never invent features or tool names. Never read long lists aloud. No filler, no marketing.
- If a request is vague about look or intent, ask one focused question.

Current project: {{timeline_summary}}
EOF

AGENT_BODY=$(jq -n \
  --arg name "$NAME" --arg prompt "$PERSONA" --arg llm "$LLM" --arg voice "$VOICE_ID" \
  --arg edit "$EDIT_ID" --arg describe "$DESCRIBE_ID" \
  '{
     name: $name,
     conversation_config: {
       agent: {
         first_message: "VibeEdit here. What are we working on?",
         language: "en",
         prompt: { prompt: $prompt, llm: $llm, tool_ids: [$edit, $describe] },
         dynamic_variables: { dynamic_variable_placeholders: { timeline_summary: "No project is open yet." } }
       },
       tts: { voice_id: $voice }
     }
   }')

if [[ -n "$UPDATE_AGENT" ]]; then
  echo "Updating agent $UPDATE_AGENT..." >&2
  RESP=$(api PATCH "/agents/$UPDATE_AGENT" "$AGENT_BODY")
  AGENT_ID=$(echo "$RESP" | jq -r '.agent_id // empty')
  AGENT_ID="${AGENT_ID:-$UPDATE_AGENT}"
else
  echo "Creating agent..." >&2
  RESP=$(api POST "/agents/create" "$AGENT_BODY")
  AGENT_ID=$(echo "$RESP" | jq -r '.agent_id // empty')
fi

[[ -n "$AGENT_ID" ]] || { echo "Failed to create/update agent:" >&2; echo "$RESP" | jq . >&2; exit 1; }

cat >&2 <<EOF

Done.
  Agent ID: $AGENT_ID
  Voice:    $VOICE_ID
  LLM:      $LLM

Next: open VibeEdit → Settings → Voice, paste this Agent ID and your ElevenLabs API key,
then click the waveform button in the title bar to start talking.
EOF

echo "$AGENT_ID"
