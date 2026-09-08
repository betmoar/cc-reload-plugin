---
description: Snapshot this session to .reload/session.md and arm an auto-reload across the next /clear or /compact
argument-hint: [--check | optional note to fold into the digest]
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task
---

# Snapshot this session

Write a fresh session digest so the working thread survives a context reset, and arm cc-reload
to rehydrate it automatically on the next `/clear` or `/compact`.

User note (optional): **$ARGUMENTS**

If a cc-repete loop is active (`.repete/loop.local.md` frontmatter has `active: true` in the
first `---` block), STOP — cc-repete owns continuity here; tell the user to use
`/repete-continue` instead and do nothing.

## If `$ARGUMENTS` is `--check`: audit the digest instead of writing one

Every gate in this plugin tests the *transport* — that the digest reaches the next session. None
can test whether it is any **good**, because that needs a reader with no memory of this session.
`--check` is that reader, run while there is still time to fix what it finds.

Do NOT write, arm, or modify anything on this path. Read `.reload/session.md`; if it is missing,
say so and suggest `/snapshot`. Then:

1. Dispatch ONE subagent (model `sonnet`) whose prompt contains **only** the digest's literal text
   and the project directory — no summary of this conversation, no hints, nothing you remember.
   That isolation is the whole experiment: any context you leak makes it pass by cheating.
   Ask it for exactly four things, and tell it to answer only from the digest and the repo:
   - the single next action it would take, concretely;
   - the files it would open first;
   - the original ask (`mission`) in its own words;
   - anything the digest asserts that the repo contradicts, and anything it cannot act on.
2. Compare its answer to what you actually know. Report the **divergences**, not the agreement:
   - a different next action → the *Next concrete step* is ambiguous or stale;
   - it cannot name the files → *In flight* is too vague to resume from;
   - a drifted `mission` → the original ask has eroded across resets;
   - an unresolved item it never mentions → it fell out of a previous snapshot.
3. Recommend concrete edits, then offer to run a plain `/snapshot` to apply them. Do not apply
   them silently — the user asked for an audit.

A clean check is a real result: say the digest reads cleanly and stop. Otherwise:

1. Create `.reload/` if it does not exist, and if `.reload/.gitignore` is missing write it with a
   single line `*` (so this per-session state is never committed to the user's project).
2. Check for a concurrent session before overwriting:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/claim-digest.sh" "$CLAUDE_CODE_SESSION_ID"`
   If it prints a warning, relay it verbatim — another session owns the current digest and it has
   been saved aside. Never skip the write because of this; the incumbent is already preserved.
3. **Read `.reload/session.md` first if it exists.** This write REPLACES it, so anything you do
   not carry over is lost silently. Carry every still-unresolved **Open question** forward
   verbatim; strike only what is demonstrably resolved.
4. Write `.reload/session.md` (replacing it), tight — under ~30 lines — using the template shape
   from `${CLAUDE_PLUGIN_ROOT}/templates/session.md`:
   - frontmatter: `session_id` — run: `echo "$CLAUDE_CODE_SESSION_ID"` — paste that value;
     if empty, use an empty string. Do NOT recall it from memory.
     `mission` (the original ask — copy it verbatim from the existing digest; write it fresh only
     if there is none. It never gets rewritten), `updated_at` (output of
     `date -u +%Y-%m-%dT%H:%M:%SZ`), `head` (run `git rev-parse --short HEAD` and paste it —
     never recall it; omit the line entirely if the command fails or there is no repo), `intent`
     (one line: where the work stands now).
   - sections: **Done this stretch / In flight / Next concrete step / Open questions & risks.**
   Capture only the live working thread — what you'd need to resume cleanly. Fold in `$ARGUMENTS`.
   Quality bar: *In flight* names the files (with line numbers) you are mid-edit in; *Next
   concrete step* is an executable action — a command, or an edit with a path, never "continue
   with X"; record the test baseline (pass/fail before your change) under *Open questions* when
   there is one.
   For the repo facts, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/context-block.sh"` and fold its
   output in under *Done this stretch* — it states branch, HEAD, uncommitted paths and recent
   commits from git rather than from recall. It prints nothing outside a repo; that is fine.
5. Arm the reload, stamping this session as its owner:
   `printf '%s' "$CLAUDE_CODE_SESSION_ID" > .reload/pending`
   (if the variable is empty, `touch .reload/pending` instead — an un-owned arm is better than
   a wrong one).
6. Tell the user in two lines: digest saved, reload armed — run `/clear` (or `/compact`) and the
   session rehydrates automatically; or `/reload` to pull it back manually.
