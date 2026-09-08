<!--
  .reload/session.md — the rehydratable digest of the CURRENT session's working thread.

  cc-reload restores this into a fresh context after a /clear, /compact, or auto-compaction
  (when a reload is armed). Keep it tight — under ~30 lines. It captures the live thread, not a
  transcript: what you'd need to resume cleanly. Durable facts belong in their normal homes
  (commits, project files); this is the delta that isn't there yet.

  Keep it fresh as you work (see the maintaining-session-continuity skill) so a surprise
  auto-compaction always has a recent snapshot to fall back on. Overwrite in place.

  READ BEFORE YOU WRITE. Each snapshot REPLACES the last one, so anything you don't carry over
  is gone — and nothing warns you. Read the existing digest first, carry every still-unresolved
  Open question forward verbatim, and strike only what is demonstrably resolved.

  session_id is the RUNTIME session id — `echo "$CLAUDE_CODE_SESSION_ID"`, never recalled from
  memory. It is what lets a second session in this directory detect that it is about to
  overwrite someone else's digest.

  mission is the ORIGINAL ask, written once and copied verbatim on every later snapshot. intent
  moves; mission does not. Rewriting it each time turns the north star into a summary of a
  summary of a summary — after three resets nobody can tell what was actually asked for.

  head is the short HEAD sha at snapshot time, RUN not recalled. After a reset cc-reload counts
  the commits that landed since and says so in the banner — a measured staleness signal the
  digest itself cannot provide. A guessed or remembered sha is worse than none: it renders a
  confident, wrong "N commits" over a stale digest. Omit the line if there is no repo.

  The four `##` headings below are the canonical list. Three other places repeat them by hand
  (the REINJECT heredoc in hooks/stop-hook.sh, the fallback stub in hooks/precompact-hook.sh,
  and the banner reader in hooks/sessionstart-hook.sh); tests/test-hooks.sh "digest section
  PARITY" pins them to THIS file. Rename a heading here and those cases go red on purpose.
-->
---
session_id: ""
mission: "<the original ask, verbatim — write once, then copy it forward unchanged>"
updated_at: ""
head: "<output of: git rev-parse --short HEAD — omit the line entirely outside a git repo>"
intent: "<one line: where the work stands now>"
---

## Done this stretch

<what was just finished, with file paths / commit refs>

## In flight

<what is half-done right now and exactly where you left off — name the files, with line numbers>

## Next concrete step

<the single next action after the reload: a command, or an edit with a path. Never "continue with X">

## Open questions & risks

<anything unresolved the next session must know — including the test baseline (pass/fail counts
before your change) when there is one. Carry unresolved items across from the previous digest.>
