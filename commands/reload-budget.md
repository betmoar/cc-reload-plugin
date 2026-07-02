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

1. If `$ARGUMENTS` is empty, report the current setting and stop:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/reload-config.sh" get context_budget_pct` (empty output
   means unset → default 45).
2. Otherwise read the old value (same `get`), then set the new one — do NOT hand-edit the file;
   the script validates the value, preserves other keys, and creates `.reload/` safely:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/reload-config.sh" set context_budget_pct "$ARGUMENTS"`
   (accepts `0`–`95` or `off`). If it exits non-zero, relay its stderr message verbatim and stop.
3. Confirm in one line, e.g. "Reload budget → 30% of context window (was 45%). I'll prompt a
   checkpoint + /clear when context crosses ~30%."

Note: this is the per-project default. The effective trigger is best-effort — it reads per-turn
token usage from the transcript against the model's window (stamped at session start); if that
signal is unavailable it falls back to a byte estimate that errs early (safer for staying low).
