#!/usr/bin/env bash
# Save all current Claude sessions from cmux for later restoration.
#
# Saves two lists:
# 1. Claude processes: {cwd, session_id} — from ps + lsof + hook state
# 2. Claude surfaces: {title, ref, workspace} — from cmux tree
#
# These are paired at restore time by matching surface titles to surfaces
# in the (possibly restarted) cmux tree.
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

# --- Get cmux tree ---
echo "Reading cmux tree..."
TREE=$(cmux tree --all --json 2>/dev/null) || { echo "cmux not available"; exit 1; }

# All Claude surfaces (title starts with [)
SURFACES=$(echo "$TREE" | jq '[
  .windows[]?.workspaces[]? |
  {ws_title: .title, ws_ref: .ref} as $ws |
  .panes[]? |
  .surfaces[]? |
  select(.title | test("^\\[")) |
  {ref: .ref, title: .title, workspace: $ws.ws_title, workspace_ref: $ws.ws_ref}
]')

echo "Scanning Claude processes..."

# --- Collect sessions ---
SESSIONS='[]'
SEEN=""

for pid in $(ps -eo pid,comm | awk '$2 == "claude" {print $1}'); do
  cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep -A1 "^fcwd" | grep "^n" | sed 's/^n//') || true
  [ -z "$cwd" ] && continue

  uuid=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep "^CMUX_SURFACE_ID=" | cut -d= -f2) || true
  [ -z "$uuid" ] && continue
  echo "$SEEN" | grep -qF "$uuid" && continue
  SEEN="$SEEN $uuid"

  sid=$(echo "$HOOK_DATA" | jq -r --arg u "$uuid" '.[$u].session_id // empty')
  if [ -z "$sid" ]; then
    proj=$(echo "$cwd" | sed 's|/|-|g')
    sid=$(ls -t "$HOME/.claude/projects/$proj"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl 2>/dev/null) || true
  fi
  [ -z "$sid" ] && continue

  SESSIONS=$(echo "$SESSIONS" | jq \
    --arg cwd "$cwd" --arg sid "$sid" \
    '. + [{cwd: $cwd, session_id: $sid}]')
done

COUNT=$(echo "$SESSIONS" | jq 'length')
SURF_COUNT=$(echo "$SURFACES" | jq 'length')
echo "Found $COUNT sessions, $SURF_COUNT Claude surfaces"

jq -n \
  --argjson ts "$NOW" \
  --argjson sessions "$SESSIONS" \
  --argjson surfaces "$SURFACES" \
  '{timestamp: $ts, sessions: $sessions, surfaces: $surfaces}' > "$SNAPSHOT_FILE"

echo ""
echo "Snapshot saved to $SNAPSHOT_FILE"
echo ""
echo "Sessions:"
echo "$SESSIONS" | jq -r '.[] | "  \(.cwd | split("/") | .[-1])  →  \(.session_id | .[0:8])..."'
echo ""
echo "Surfaces:"
echo "$SURFACES" | jq -r '.[] | "  [\(.workspace)] \(.title)"'
