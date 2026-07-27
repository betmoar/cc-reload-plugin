---
description: Set cc-reload's context budget (% of window) and its escalation mode (notify | snapshot) for this project
argument-hint: <percent 1-95 | "off" | "notify" | "snapshot"> e.g. 30
allowed-tools: Read, Write, Edit, Bash
---

# Set the reload budget

When context crosses the budget, cc-reload either **notifies** you to run `/snapshot` + `/clear`
(default — one status line, never interrupts, zero model tokens) or **snapshots automatically**
(`snapshot` mode: forces a digest-writing turn, then asks you to `/clear`). Lower the budget for
context-sensitive tasks; raise it to get more work per session.

Requested value: **$ARGUMENTS**

1. If `$ARGUMENTS` is empty, report the current settings and stop:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/reload-config.sh" get context_budget_pct` (empty → default 45)
   and `... get context_budget_mode` (empty → default `notify`).
2. If `$ARGUMENTS` is `notify` or `snapshot` (or the legacy `checkpoint`), set the mode instead of the percentage:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/reload-config.sh" set context_budget_mode "$ARGUMENTS"`.
3. Otherwise read the old value (same `get`), then set the new one — do NOT hand-edit the file;
   the script validates the value, preserves other keys, and creates `.reload/` safely:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/reload-config.sh" set context_budget_pct "$ARGUMENTS"`
   (accepts `0`–`95` or `off`). If it exits non-zero, relay its stderr message verbatim and stop.
4. Confirm in one line, e.g. "Reload budget → 30% (was 45%), mode notify — I'll nudge you to
   /snapshot + /clear when context crosses ~30%."

Note: per-project default. The trigger is best-effort — per-turn token usage from the transcript
against the model's window (stamped at session start); if unavailable it falls back to a byte
estimate that errs early.

## Configuration keys

- `context_owner_window <seconds | off>` — how recently another session must have written
  `.reload/session.md` for an overwrite to count as a live collision worth side-filing.
  Default `14400` (4h). `off` disables the cross-session check entirely.
