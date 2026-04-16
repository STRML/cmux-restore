#!/usr/bin/env bash
# Rotate cmux-snapshot backups with 5-hourly + 5-daily + 2-weekly retention.
#
# Each call:
#   1. Copies ~/.claude/cmux-snapshot.json to ~/.claude/cmux-snapshot-backups/
#   2. Walks existing backups newest-first and keeps a tiered ladder:
#        tier 1: 5 files, each ≥ 1h apart from the previous kept
#        tier 2: 5 files, each ≥ 1d apart
#        tier 3: 2 files, each ≥ 1w apart
#      Everything else is deleted.
#
# Fast enough to run inline from hooks (backgrounded by the caller).
set -euo pipefail

SNAPSHOT="$HOME/.claude/cmux-snapshot.json"
BACKUP_DIR="$HOME/.claude/cmux-snapshot-backups"

[ -f "$SNAPSHOT" ] || exit 0
mkdir -p "$BACKUP_DIR"

NOW=$(date +%s)
cp "$SNAPSHOT" "$BACKUP_DIR/cmux-snapshot-$NOW.json"

# Enumerate backup files, newest first, extracting unix timestamp from name.
mapfile -t files < <(
  ls "$BACKUP_DIR"/cmux-snapshot-*.json 2>/dev/null \
    | sed -E 's|.*/cmux-snapshot-([0-9]+)\.json$|\1\t&|' \
    | grep -E '^[0-9]+\t' \
    | sort -r -n -k1,1
)

# Pick files to keep using tiered intervals.
keep=()
last_kept=""
idx=0

take_tier() {
  local want="$1" interval="$2" taken=0
  while [ "$idx" -lt "${#files[@]}" ] && [ "$taken" -lt "$want" ]; do
    local entry ts
    entry="${files[$idx]}"
    ts="${entry%%	*}"
    if [ -z "$last_kept" ] || [ "$((last_kept - ts))" -ge "$interval" ]; then
      keep+=("$entry")
      last_kept="$ts"
      taken=$((taken + 1))
    fi
    idx=$((idx + 1))
  done
}

take_tier 5 3600      # hourly
take_tier 5 86400     # daily
take_tier 2 604800    # weekly

# Build a newline-delimited set of paths to keep.
keep_paths=""
for e in "${keep[@]}"; do
  keep_paths+="${e#*	}"$'\n'
done

# Delete anything not in the keep set.
for e in "${files[@]}"; do
  path="${e#*	}"
  if ! printf '%s' "$keep_paths" | grep -qxF "$path"; then
    rm -f "$path"
  fi
done
