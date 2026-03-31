# cmux-restore

Resume Claude Code sessions after restarting [cmux](https://cmux.dev). When you quit cmux, all your running Claude sessions die. This saves them and brings them back.

## How it works

1. A **Claude Code hook** (`SessionStart`) records each session's ID and cmux surface UUID as sessions start
2. **`cmux-save`** snapshots all running Claude processes, pairing each with its surface UUID and session ID
3. **`cmux-restore`** sends `claude --resume <id>` into each surface by UUID after cmux restarts

Surface UUIDs persist across cmux restarts, so restore targets each surface directly — no position matching or prompt parsing needed.

### Why not just `claude --continue`?

`--continue` resumes the most recent session per project. If you have multiple Claude sessions in the same directory (common with monorepos or long-running tasks), `--continue` can't distinguish them. The SessionStart hook tracks the exact session ID per surface.

## Install

```bash
git clone https://github.com/STRML/cmux-restore.git
cd cmux-restore
bash install.sh
```

This symlinks `cmux-save` and `cmux-restore` into `~/bin` and installs the hook script.

Then add the hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/session-restore/on-session-start.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code or run `/hooks` to apply.

## Usage

```bash
# Before quitting cmux: snapshot all Claude sessions
cmux-save

# After cmux restarts: resume all sessions
cmux-restore

# Preview without restoring
cmux-restore --dry-run

# Restore even if some Claude sessions are still running
cmux-restore --force
```

## Requirements

- [cmux](https://cmux.dev)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `jq`
- macOS (uses `lsof` and `ps eww` for process inspection)

## How session detection works

The hard part is mapping each Claude process to the right session ID and the right cmux surface.

**Session ID**: Claude Code doesn't keep its transcript file open or expose the session ID in environment variables. Instead, a `SessionStart` hook captures the session ID (passed via stdin JSON) and saves it keyed by `CMUX_SURFACE_ID`. This is accurate even when multiple sessions share a project directory.

**Surface UUID**: Each Claude process inherits `CMUX_SURFACE_ID` from its parent shell. `cmux-save` reads this from the process environment via `ps eww`. These UUIDs persist across cmux restarts, so `cmux-restore` can send commands to the right surface without guessing.

**Live detection**: `cmux-restore` checks for running Claude processes by reading `CMUX_SURFACE_ID` from their environments and comparing against the snapshot. Surfaces with a live Claude process are skipped.

## Files

| File | Purpose |
|------|---------|
| `scripts/on-session-start.sh` | Claude Code `SessionStart` hook — saves session→surface mapping |
| `scripts/save-all.sh` | Snapshots all running Claude sessions + surface UUIDs |
| `scripts/restore-all.sh` | Resumes sessions into cmux surfaces after restart |
| `install.sh` | Symlinks scripts into `~/bin` and installs the hook |

## State files

| File | Written by | Purpose |
|------|-----------|---------|
| `~/.claude/saved-sessions.json` | `on-session-start.sh` | Per-surface session ID mapping (updated on every session start) |
| `~/.claude/cmux-snapshot.json` | `cmux-save` | Snapshot of all running sessions (read by `cmux-restore`) |

## Related

- [cmux PR #1192](https://github.com/manaflow-ai/cmux/pull/1192) — native agent resume feature for cmux (would make this tool unnecessary)

## License

MIT
