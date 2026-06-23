---
description: Snapshot this session to .reload/session.md and arm an auto-reload across the next /clear or /compact
argument-hint: [optional note to fold into the digest]
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Checkpoint this session

Write a fresh session digest so the working thread survives a context reset, and arm cc-reload
to rehydrate it automatically on the next `/clear` or `/compact`.

User note (optional): **$ARGUMENTS**

If a cc-repete loop is active (`.repete/loop.local.md` has `active: true`), STOP — cc-repete
owns continuity here; tell the user to use `/repete-continue` instead and do nothing.

Otherwise:

1. Create `.reload/` if it does not exist, and if `.reload/.gitignore` is missing write it with a
   single line `*` (so this per-session state is never committed to the user's project).
2. Write `.reload/session.md` (overwrite), tight — under ~30 lines — using the template shape
   from `${CLAUDE_PLUGIN_ROOT}/templates/session.md`:
   - frontmatter: `session_id` (use the current session id if known, else `""`),
     `updated_at` (output of `date -u +%Y-%m-%dT%H:%M:%SZ`), `intent` (one line).
   - sections: **Done this stretch / In flight / Next concrete step / Open questions & risks.**
   Capture only the live working thread — what you'd need to resume cleanly. Fold in `$ARGUMENTS`.
3. Arm the reload: `touch .reload/pending`.
4. Tell the user in two lines: digest saved, reload armed — run `/clear` (or `/compact`) and the
   session rehydrates automatically; or `/reload` to pull it back manually.
