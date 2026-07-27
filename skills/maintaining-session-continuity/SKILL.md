---
name: maintaining-session-continuity
description: >-
  Judgment for using cc-reload — carrying a session's working thread across a context reset via
  `.reload/session.md`: snapshot, arm, rehydrate after `/clear`, `/compact`, or auto-compaction.
  Use when saving state before a reset, handing off mid-task, holding working state as context
  fills, or working with `/snapshot`, `/reload`, `/reload-budget`, `.reload/`, session digests.
  Stand down while a cc-repete loop is active — cc-repete owns continuity then.
---

# Maintaining session continuity

cc-reload preserves an ordinary session's working thread across a context reset. It does not drive
work (that's a loop — use cc-repete); it snapshots the thread to `.reload/session.md` before a
reset and hands it back after.

## The cycle: budget → snapshot → arm → rehydrate

Reset **before rot, and long before auto-compaction** — stay well under the window, never let
auto-compact fire.

1. **Budget** — the Stop hook watches occupancy; crossing `context_budget_pct` (default 45)
   escalates per `context_budget_mode`: **notify** (default) nudges in one status line, never
   blocks, re-nudges only every ~10 further points; **snapshot** forces the digest turn and arms.
   `/reload-budget <pct>` tunes it, `/reload-budget notify|snapshot` switches mode.
2. **Snapshot** — a fresh digest is written (budget prompts it; `/snapshot` forces one).
3. **Arm** — `.reload/pending` means "rehydrate on the next reset". Only armed resets rehydrate,
   so a deliberate `/clear` meant to drop context isn't undone.
4. **Rehydrate** — SessionStart injects the digest and consumes the marker. Automatic; `/reload`
   does it on demand.

## Judgment that isn't obvious from the mechanism

**Lower the budget than you think.** Occupancy is a % of the *main session model's* window (1M on
current large-context models). Effective context — where reasoning stays sharp — degrades well
before the raw window fills, so 45% of 1M is generous: prefer ~30 or lower for reasoning-heavy or
context-sensitive work.

**Keep the digest fresh continuously; don't babysit the boundary.** Auto-compaction fires without
warning and a hook can't make you summarize after the fact, so the snapshot must already be good
*before* the reset. Refresh at natural milestones — sub-task done, before a risky step, whenever
the next action just became clear. On `/compact` or auto-compaction PreCompact arms and guarantees
*a* digest, but if you haven't kept one current it can only write a thin mechanical stub.

**Capture the delta that isn't on disk yet** — what's in flight and the next step. Durable facts
live in commits and files; don't re-summarize those into the digest.

**Treat a rehydrated digest as a pointer, not the source of truth.** Summaries lose subtle detail,
so re-read the relevant files and recent git history before continuing. (This is why cc-reload
carries a thin digest instead of compressing the conversation — lossless re-read beats
summarize-and-continue.)

## The digest

Four sections, ~30 lines: **Done this stretch / In flight / Next concrete step / Open questions &
risks**, plus a one-line `intent`. The next concrete step is the single most valuable line across
a reset — lead with it in mind.

## Coexistence with cc-repete

`.repete/loop.local.md` with `active: true` means a loop owns this session: cc-reload's hooks stand
down and its commands defer to `/repete-continue`. The two never run continuity at once.
