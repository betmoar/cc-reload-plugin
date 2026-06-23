---
description: Set cc-reload's proactive checkpoint threshold (% of context window) for this project
argument-hint: <percent 1-95, or "off"> e.g. 30
allowed-tools: Read, Write, Edit, Bash
---

# Set the reload budget

cc-reload prompts a checkpoint + `/clear` when the context window crosses this percentage, so the
session resets well before auto-compaction. Lower it for context-sensitive tasks; raise it to get
more work per session.

Requested value: **$ARGUMENTS**

1. Parse `$ARGUMENTS`:
   - a number `1`–`95` → that's the new `context_budget_pct`.
   - `off` or `0` → disable the proactive path (`context_budget_pct: 0`).
   - empty/invalid → just report the current setting (read `.reload/config`, default 45) and stop.
2. Write the value to `.reload/config` (create the file/dir if needed; if `.reload/.gitignore` is
   missing, write it with a single line `*` so this state is never committed), setting the
   `context_budget_pct:` line — preserve any other keys already there.
3. Confirm in one line, e.g. "Reload budget → 30% of context window (was 45%). I'll prompt a
   checkpoint + /clear when context crosses ~30%."

Note: this is the per-project default. The effective trigger is best-effort — it reads per-turn
token usage from the transcript against the model's window (stamped at session start); if that
signal is unavailable it falls back to a byte estimate that errs early (safer for staying low).
