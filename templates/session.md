<!--
  .reload/session.md — the rehydratable digest of the CURRENT session's working thread.

  cc-reload restores this into a fresh context after a /clear, /compact, or auto-compaction
  (when a reload is armed). Keep it tight — under ~30 lines. It captures the live thread, not a
  transcript: what you'd need to resume cleanly. Durable facts belong in their normal homes
  (commits, project files); this is the delta that isn't there yet.

  Keep it fresh as you work (see the maintaining-session-continuity skill) so a surprise
  auto-compaction always has a recent snapshot to fall back on. Overwrite in place.
-->
---
session_id: ""
updated_at: ""
intent: "<one line: what this session is trying to do>"
---

## Done this stretch

<what was just finished, with file paths / commit refs>

## In flight

<what is half-done right now and exactly where you left off>

## Next concrete step

<the single next action to take after the reload>

## Open questions & risks

<anything unresolved the next session must know>
