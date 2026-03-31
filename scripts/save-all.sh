#!/usr/bin/env bash
# Save all current Claude sessions from cmux for later restoration.
#
# For each running Claude process:
# 1. Reads CMUX_SURFACE_ID from its environment (via `ps eww`)
# 2. Looks up the correct session_id from the SessionStart hook's state file
# 3. Falls back to most-recently-modified .jsonl if hook data is missing
#
# Surface UUIDs persist across cmux restarts, so cmux-restore can target
# each surface directly without position matching or screen parsing.
#
# Output: ~/.claude/cmux-snapshot.json
set -euo pipefail

SNAPSHOT_FILE="$HOME/.claude/cmux-snapshot.json"
STATE_FILE="$HOME/.claude/saved-sessions.json"
NOW=$(date +%s)

# --- Load hook-saved state ---
HOOK_DATA='{}'
if [ -f "$STATE_FILE" ]; then
  HOOK_DATA=$(jq '.by_surface // {}' "$STATE_FILE")
fi

echo "Scanning Claude processes..."

# --- For each Claude PID: get surface UUID, pair with hook-saved session_id ---
ENTRIES='[]'
SEEN_SURFACES=""

for pid in $(ps -eo pid,comm | awk '$2 == "claude" {print $1}'); do
  cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep -A1 "^fcwd" | grep "^n" | sed 's/^n//') || true
  [ -z "$cwd" ] && continue

  surface_uuid=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep "^CMUX_SURFACE_ID=" | cut -d= -f2) || true
  [ -z "$surface_uuid" ] && continue

  # Dedupe by surface UUID
  echo "$SEEN_SURFACES" | grep -qF "$surface_uuid" && continue
  SEEN_SURFACES="$SEEN_SURFACES $surface_uuid"

  # Prefer hook-saved session_id (accurate per-surface)
  session_id=$(echo "$HOOK_DATA" | jq -r --arg uuid "$surface_uuid" '.[$uuid].session_id // empty')

  # Fallback: most recent .jsonl (unreliable with multiple sessions per project)
  if [ -z "$session_id" ]; then
    proj_name=$(echo "$cwd" | sed 's|/|-|g')
    proj_dir="$HOME/.claude/projects/$proj_name"
    session_id=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl 2>/dev/null) || true
  fi

  [ -z "$session_id" ] && continue

  ENTRIES=$(echo "$ENTRIES" | jq \
    --arg uuid "$surface_uuid" \
    --arg cwd "$cwd" \
    --arg sid "$session_id" \
    '. + [{surface_uuid: $uuid, cwd: $cwd, session_id: $sid}]')
done

COUNT=$(echo "$ENTRIES" | jq 'length')
echo "Found $COUNT Claude sessions"

# --- Save snapshot ---
jq -n \
  --argjson ts "$NOW" \
  --argjson entries "$ENTRIES" \
  '{timestamp: $ts, sessions: $entries}' > "$SNAPSHOT_FILE"

echo ""
echo "Snapshot saved to $SNAPSHOT_FILE"
echo ""
echo "$ENTRIES" | jq -r '.[] | "  \(.cwd | split("/") | .[-1])  →  \(.session_id | .[0:8])...  (\(.surface_uuid | .[0:8])...)"'
