#!/usr/bin/env bash
# Claude Code SessionStart hook: save session → surface UUID mapping.
#
# On every session start, records {session_id, cwd, surface_uuid} so that
# cmux-save can later snapshot all running sessions with correct per-surface
# session IDs (even when multiple sessions share the same project directory).
#
# On fresh startup, checks for a previous session in this directory and
# suggests resuming it via context injection.
#
# State file: ~/.claude/saved-sessions.json
set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

[ -z "$SESSION_ID" ] && exit 0
[ -z "$CWD" ] && exit 0

STATE_FILE="$HOME/.claude/saved-sessions.json"
SURFACE_ID="${CMUX_SURFACE_ID:-${ITERM_SESSION_ID:-unknown}}"
WORKSPACE_ID="${CMUX_WORKSPACE_ID:-unknown}"
NOW=$(date +%s)

# --- Read existing state ---
if [ -f "$STATE_FILE" ]; then
  STATE=$(cat "$STATE_FILE")
else
  STATE='{"by_surface":{},"by_cwd":{}}'
fi

# Ensure both keys exist
STATE=$(echo "$STATE" | jq 'if .by_surface then . else {by_surface:{},by_cwd:{}} end')

# --- Check for a previous session in this cwd (before we overwrite) ---
SUGGEST_RESUME=""
if [ "$SOURCE" = "startup" ]; then
  PREV=$(echo "$STATE" | jq -r --arg cwd "$CWD" '.by_cwd[$cwd] // empty')
  if [ -n "$PREV" ]; then
    PREV_SID=$(echo "$PREV" | jq -r '.session_id')
    PREV_TS=$(echo "$PREV" | jq -r '.timestamp')
    AGE=$((NOW - PREV_TS))

    # Only suggest if < 24h old and different session
    if [ "$AGE" -lt 86400 ] && [ "$PREV_SID" != "$SESSION_ID" ]; then
      if [ "$AGE" -lt 60 ]; then
        AGE_STR="${AGE}s ago"
      elif [ "$AGE" -lt 3600 ]; then
        AGE_STR="$((AGE / 60))m ago"
      else
        AGE_STR="$((AGE / 3600))h $((AGE % 3600 / 60))m ago"
      fi
      SUGGEST_RESUME="A previous Claude session exists for this directory (session ${PREV_SID}, from ${AGE_STR}). To resume it, use: /resume ${PREV_SID}"
    fi
  fi
fi

# --- Save current session (by surface for cmux-save, by cwd for resume suggestion) ---
ENTRY=$(jq -n \
  --arg sid "$SESSION_ID" \
  --argjson ts "$NOW" \
  --arg cwd "$CWD" \
  --arg surface "$SURFACE_ID" \
  --arg workspace "$WORKSPACE_ID" \
  '{session_id: $sid, timestamp: $ts, cwd: $cwd, surface_id: $surface, workspace_id: $workspace}')

STATE=$(echo "$STATE" | jq \
  --arg surface "$SURFACE_ID" \
  --arg cwd "$CWD" \
  --argjson entry "$ENTRY" \
  --argjson now "$NOW" \
  '.by_surface[$surface] = $entry | .by_cwd[$cwd] = $entry |
   .by_surface |= (to_entries | map(select(.value.timestamp > ($now - 86400))) | from_entries) |
   .by_cwd |= (to_entries | map(select(.value.timestamp > ($now - 86400))) | from_entries)')

echo "$STATE" > "$STATE_FILE"

# --- Update snapshot for cmux-restore (backgrounded to avoid lag) ---
(
  SNAPSHOT_FILE="$HOME/.claude/cmux-snapshot.json"
  TREE=$(cmux tree --all --json 2>/dev/null) || exit 0
  SURFACES=$(echo "$TREE" | jq '[
    .windows[]?.workspaces[]? |
    {ws_title: .title, ws_ref: .ref} as $ws |
    .panes[]? |
    .surfaces[]? |
    select(.title | test("^\\[")) |
    {ref: .ref, title: .title, workspace: $ws.ws_title, workspace_ref: $ws.ws_ref}
  ]')
  SESSIONS=$(cat "$STATE_FILE" | jq '[.by_surface | to_entries[] | .value | {cwd, session_id}]')
  jq -n \
    --argjson ts "$NOW" \
    --argjson sessions "$SESSIONS" \
    --argjson surfaces "$SURFACES" \
    '{timestamp: $ts, sessions: $sessions, surfaces: $surfaces}' > "$SNAPSHOT_FILE"
) &

# --- Output resume suggestion if applicable ---
if [ -n "$SUGGEST_RESUME" ]; then
  jq -n --arg ctx "$SUGGEST_RESUME" '{
    "hookSpecificOutput": {
      "hookEventName": "SessionStart",
      "additionalContext": $ctx
    }
  }'
fi

exit 0
