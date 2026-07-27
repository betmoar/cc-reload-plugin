---
description: Snapshot this session to .reload/session.md and arm an auto-reload across the next /clear or /compact
argument-hint: [optional note to fold into the digest]
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Snapshot this session

Write a fresh session digest so the working thread survives a context reset, and arm cc-reload
to rehydrate it automatically on the next `/clear` or `/compact`.

User note (optional): **$ARGUMENTS**

If a cc-repete loop is active (`.repete/loop.local.md` has `active: true`), STOP — cc-repete
owns continuity here; tell the user to use `/repete-continue` instead and do nothing.

Otherwise:

1. Create `.reload/` if it does not exist, and if `.reload/.gitignore` is missing write it with a
   single line `*` (so this per-session state is never committed to the user's project).
2. Check for a concurrent session before overwriting:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/claim-digest.sh" "$CLAUDE_CODE_SESSION_ID"`
   If it prints a warning, relay it to the user verbatim — another session in this directory
   owns the current digest and it has been saved aside. Never skip the write because of this;
   the script has already preserved the incumbent. (This is a courtesy check: the PreToolUse
   hook enforces the same guard on the actual write, so skipping this step loses the early
   warning, not the protection.)
3. Write `.reload/session.md` (overwrite), tight — under ~30 lines — using the template shape
   from `${CLAUDE_PLUGIN_ROOT}/templates/session.md`:
   - frontmatter: `session_id` — run: `echo "$CLAUDE_CODE_SESSION_ID"` — paste that value;
     if empty, use an empty string. Do NOT recall it from memory.
     `updated_at` (output of `date -u +%Y-%m-%dT%H:%M:%SZ`), `intent` (one line).
   - sections: **Done this stretch / In flight / Next concrete step / Open questions & risks.**
   Capture only the live working thread — what you'd need to resume cleanly. Fold in `$ARGUMENTS`.
4. Arm the reload, stamping this session as its owner:
   `printf '%s' "$CLAUDE_CODE_SESSION_ID" > .reload/pending`
   (if the variable is empty, `touch .reload/pending` instead — an un-owned arm is better than
   a wrong one).
5. Tell the user in two lines: digest saved, reload armed — run `/clear` (or `/compact`) and the
   session rehydrates automatically; or `/reload` to pull it back manually.
