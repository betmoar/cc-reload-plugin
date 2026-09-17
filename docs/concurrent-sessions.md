# Two sessions, one directory

`.reload/` is per **project directory**, not per session. Two Claude Code sessions open in the same
tree share the digest slot, the arm, the handshake marker and the model stamp. Until 0.5.0 the
plugin *detected* a cross-session digest overwrite (side-file plus warning) but the arm was a single
unowned slot: whichever session started or `/clear`'d next consumed it, whoever had set it. A
second session opened in the same directory silently took the first session's reload; the first
session's `/clear` then rehydrated nothing.

This page states the rules that replace that, what they guarantee, and where they stop.

## Identities: session vs process

| Identity | Rotates on | Source |
| --- | --- | --- |
| session id | `/clear`, `/compact`, `--resume`, startup, fork | hook stdin `session_id`; `CLAUDE_CODE_SESSION_ID` in the Bash tool (undocumented) |
| process id | startup, `--resume`, `--continue` (a new process) | `CLAUDE_PID`, exported by Claude Code to hooks and to the Bash tool (undocumented, measured on 2.1.274) |

`/clear` mints a fresh session id every time, so any check of "is this artifact mine?" by session
id is false on the plugin's own primary path. That was shipped once (v0.1.5) and removed. The
process id is different: it survives `/clear` and `/compact` and changes exactly when the old
process is gone. It is therefore the lineage key.

A hook's `$PPID` is a throwaway `sh -c` wrapper, not the Claude process, so only `CLAUDE_PID` is
used. When it is absent, every rule below degrades to the pre-0.5 single-slot behaviour.

## Rules

**Arms are per lineage.** `scripts/arm-reload.sh` (used by `/snapshot`) and the `Stop`/`PreCompact`
hooks all write `.reload/pending.<pid>` with the session id on line 1 and `pid: <pid>` on line 2.
Without a pid the legacy bare `.reload/pending` is written.

**SessionStart consumes only what is its own or abandoned.** In order: its own process's arm; then,
newest first, the pid-less arm and every *orphan* (an arm whose process is no longer alive by
`kill -0`, the quit-and-restart case). All of those are removed on consumption, so a dead session
never leaves a one-shot behind for a later deliberate `/clear`. An arm whose process is **alive and
not ours** is left untouched. If that is all there is, the session starts fresh with:

```
🔒 cc-reload (startup): a reload armed by another live session (<id>) was left in place —
this session starts fresh. /reload pulls that digest in on purpose; /snapshot starts your own thread.
```

**Each lineage gets its own thread back.** The arm carries the armer's session id. When
`session.md` is owned by a different session (the other one snapshotted last), the rehydrate looks
for the side-file `claim-digest.sh` kept for the armer (`session.<id>.md`, newest copy) and injects
that instead, saying so in the banner. `session.md` is left untouched and unclaimed; the next
`/snapshot` takes the slot back and side-files the other thread in turn. Only when no side-file
exists does the pre-0.5 behaviour apply: rehydrate `session.md` and warn that the arm and the
digest disagree about who wrote them.

**The handshake marker is owned too.** In `snapshot` mode the Stop hook writes `.reload/summarizing`
with the same sid + pid lines. Another live session's Stop ignores it (no pass 2 on someone else's
handshake), refuses to overwrite it (its own over-budget turn takes the notify path instead), and
another session's startup does not purge it. An orphaned marker is purged and consumed as before.

**The model stamp is per session.** `.reload/model` keeps the legacy `model:`/`window:` pair (the
last stamp) and one `session: <sid> <model> <window>` line per session, capped at 16. The Stop hook
and the status line read their own session's line first. Another session's startup can no longer
move this session's window, which used to strip the `[1m]` shield and nag at ~9% real occupancy.

**The journal takes note.** `.reload/journal` is append-only, hook-written, capped at 200 lines:

```
2026-09-17T10:12:03Z snapshot sid=7039… pid=161 Write
2026-09-17T10:12:05Z arm sid=7039… pid=161 pending.161
2026-09-17T10:20:41Z sidefile sid=b1c2… pid=4021 session.7039….md (incumbent 7039…)
2026-09-17T10:31:00Z rehydrate sid=9e8f… pid=161 clear session.7039….md
2026-09-17T10:31:02Z defer sid=c0de… pid=4021 startup: left 1 live foreign arm(s)
```

Events: `snapshot` (a `Write`/`Edit` of the digest), `arm`, `arm-failed`, `sidefile`, `rehydrate`,
`defer`, `reported`. `/reload` shows the tail. Nothing reads the journal to gate a decision.

## What this guarantees, by scenario

| Scenario | Outcome |
| --- | --- |
| A snapshots and arms; B starts in the same directory | B starts fresh with the notice; A's `/clear` rehydrates A |
| B snapshots while A's digest is live | A's digest is side-filed with a warning to B; A's `/clear` rehydrates A's side-file, B's `/clear` rehydrates B |
| A quits; B starts later | A's arm is an orphan: B rehydrates it (the restart case) |
| Both over budget in `snapshot` mode at once | The first to block owns the handshake; the other gets the notify nudge until it is done |
| No `CLAUDE_PID` in the environment | Pre-0.5 behaviour: one shared arm, first come first served |

## Limits

- **Liveness is `kill -0`.** A recycled pid, or two machines sharing a directory over a network
  filesystem, can make a dead session look alive. The consequence is a deferred rehydrate with the
  notice above, recoverable with `/reload`, never a lost digest.
- **The digest guard sits on `Write`/`Edit`.** A digest written through a Bash heredoc bypasses the
  side-filing, and its owner id is whatever the model wrote.
- **A digest written without a runtime session id is un-owned** and is overwritten silently.
- **Side-files are never auto-deleted.** Old `session.<id>.md` files accumulate under `.reload/`
  (git-ignored). Remove them when you are done.
- **`notified` is shared.** A second session over budget can reset the first session's nudge
  ladder, costing one extra status line.
- **Detection and lineage are not isolation.** Separate worktrees remain the cleanest setup for
  long-lived parallel sessions. Claude Code's own worktrees live under `.claude/worktrees/`.
