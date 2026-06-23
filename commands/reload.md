---
description: Manually rehydrate this session from .reload/session.md
allowed-tools: Read, Bash, Glob, Grep
---

# Reload session

Rebuild working context from disk. Use this after a `/clear` if the auto-reload didn't fire, or
any time you want to re-anchor on the saved thread.

1. If a cc-repete loop is active (`.repete/loop.local.md` has `active: true`), STOP — use
   `/repete-continue` instead; cc-reload defers to the loop.
2. Read `.reload/session.md`. If it is absent, tell the user there's nothing to reload and suggest
   `/checkpoint` to start tracking this session.
3. Give a 5-line situation report from the digest: **intent, done, in flight, next concrete step,
   open questions** — lead the user toward the next concrete step.
4. Work strictly from the digest and the repo/git, not from any wiped conversation memory. Then
   continue on the next concrete step.
