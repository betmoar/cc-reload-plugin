---
name: maintaining-session-continuity
description: >-
  Use for continuity of a plain (non-looped) Claude Code session across a context reset — both to
  *do* it and to *explain how it works*. Covers cc-reload's snapshot → arm → rehydrate cycle:
  writing/refreshing the `.reload/session.md` digest, arming reload, and rehydrating after `/clear`,
  `/compact`, or auto-compaction. Trigger when the user wants to save where they are before
  clearing/compacting, hand off mid-task so a later session resumes, hold working state as context
  fills, OR asks how any part of that mechanism works, or names cc-reload, `.reload/`, checkpoint,
  rehydrate, or a session digest. This is about carrying the conversation's own progress forward —
  not fixing the model's outputs. Do NOT use for debugging wrong or hallucinated results (bad paths,
  made-up APIs), summarizing code into docs, git squash/rebase, or switching to a larger-window
  model. Stand down while a cc-repete autonomous loop is active — that tool owns continuity there.
---

# Maintaining session continuity

cc-reload preserves an ordinary session's working thread across a context reset. It does **not**
drive work (that's a loop — use cc-repete). It only snapshots the thread to `.reload/session.md`
before a reset and hands it back after. This skill is the judgment for using it well.

## The cycle: budget → snapshot → arm → rehydrate

The point is to **reset before rot, and long before auto-compaction** — keep a manual session well
under the window (≈45% by default, lower per task), never let auto-compact fire.

1. **Budget (primary driver)** — the Stop hook watches context occupancy; when it crosses
   `context_budget_pct` it escalates per `context_budget_mode`: **notify** (default) nudges the
   user to run `/checkpoint` + `/clear` in one status line — never blocks, re-nudges only every
   ~10 further points; **checkpoint** forces the digest-writing turn automatically and arms the
   reload. Tune per task with `/reload-budget <pct>` — drop it to ~30 (or lower) for
   reasoning-heavy or context-sensitive work; `/reload-budget notify|checkpoint` switches mode.
2. **Snapshot** — a fresh `.reload/session.md` digest is written (the budget prompts it;
   `/checkpoint` forces one; you also keep it current as you work).
3. **Arm** — `.reload/pending` is dropped, meaning "rehydrate on the next reset." Only armed
   resets rehydrate, so a deliberate `/clear` you *want* to drop context isn't undone.
4. **Rehydrate** — on the next `/clear` / `/compact`, the SessionStart hook injects the digest and
   consumes the marker. Automatic; no command needed. `/reload` does it manually on demand.

### A note on % of a large window

Occupancy is measured as a % of the *main session model's* window (1M for current large-context
models; SessionStart stamps it, or set `context_window` in `.reload/config`). Remember that
*effective* context — where reasoning stays sharp — degrades well before the raw window fills, so
on a 1M model even 45% is generous: for reasoning-heavy work, prefer a lower `/reload-budget`. Most
200K-window models are subagents returning findings; the budget targets the main session, not them.

## Keep the digest fresh continuously — don't babysit the boundary

Auto-compaction can fire without warning, and a hook can't make you summarize after the fact. So
the snapshot must already be good *before* the reset. Refresh `.reload/session.md` at natural
milestones — finished a sub-task, before a risky step, whenever the next action just became clear.
The fresher it is, the less any reset loses, and the less a surprise auto-compaction hurts.

The digest captures the **delta that isn't on disk yet** — what's in flight and the next step.
Durable facts belong in their normal homes (commits, files); don't re-summarize those here.

## What goes in the digest

Four sections, tight (~30 lines): **Done this stretch / In flight / Next concrete step / Open
questions & risks**, plus a one-line `intent`. Lead the next session toward the *next concrete
step* — that single line is the most valuable thing across a reset.

## Snapshot is lossy — re-read beats trust

A digest is a summary, and summaries lose subtle detail. On rehydrate, treat the digest as a
**pointer back into the work**, not the source of truth: re-read the relevant files and recent git
history, then continue. (This is why cc-reload carries a thin digest rather than trying to compress
the whole conversation — lossless re-read from disk beats summarize-and-continue.)

## Coexistence with cc-repete

If `.repete/loop.local.md` has `active: true`, a cc-repete loop owns this session: cc-reload's
hooks stand down and the commands defer. Use `/repete-continue` for the loop's own rehydrate. The
two never run continuity at the same time — cc-reload fills the *non-looped* gap only.

## Reset paths at a glance

- **Budgeted `/clear`, notify mode (default)** → the nudge fires, the user runs `/checkpoint`
  (digest + arm) and `/clear`, it rehydrates. The user stays in control of the timing.
- **Budgeted `/clear`, checkpoint mode** → you're prompted to write the digest, it arms, you
  `/clear`, it rehydrates. Fully automatic once configured.
- **Manual `/checkpoint` then `/clear`** → deliberate snapshot before a planned reset.
- **`/compact` / auto-compaction** → PreCompact arms + ensures a digest (fresh if you kept it so,
  else a thin fallback); SessionStart rehydrates after.
- **Deliberate `/clear`, nothing armed** → no rehydration. Respected.
