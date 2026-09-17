---
description: Manually rehydrate this session from .reload/session.md
allowed-tools: Read, Bash, Glob, Grep
---

# Reload session

Rebuild working context from disk. Use this after a `/clear` if the auto-reload didn't fire, or
any time you want to re-anchor on the saved thread.

1. If a cc-repete loop is active (`.repete/loop.local.md` frontmatter has `active: true` in the
   first `---` block), STOP — use `/repete-continue` instead; cc-reload defers to the loop.
2. Read `.reload/session.md`. If it is absent, tell the user there's nothing to reload and suggest
   `/snapshot` to start tracking this session.
3. Give a 5-line situation report from the digest: **intent, done, in flight, next concrete step,
   open questions** — lead the user toward the next concrete step.
4. If `.reload/journal` exists, show its last 5 lines (`tail -n 5 .reload/journal`): who
   snapshotted, armed, side-filed or rehydrated, and when. If the newest `snapshot` or `arm` line
   carries a different session id than `echo "$CLAUDE_CODE_SESSION_ID"`, say so — another session
   is sharing this directory (see `docs/concurrent-sessions.md`), and its side-filed thread may be
   at `.reload/session.<id>.md`.
5. Work strictly from the digest and the repo/git, not from any wiped conversation memory. Then
   continue on the next concrete step.
