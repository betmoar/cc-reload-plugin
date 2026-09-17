# How cc-reload works

The cycle is **budget → snapshot → arm → rehydrate**. This page explains each step, how context
occupancy is measured, and where the measurement can be wrong.

## The cycle

1. **Budget (primary path).** The `Stop` hook runs at the end of every turn and computes the
   context occupancy. When it crosses `context_budget_pct` (default 45), the escalation depends
   on `context_budget_mode`:
   - `notify` (default): one status line asking you to `/snapshot` then `/clear`. It never blocks,
     costs zero model tokens, and is laddered: it fires on the first crossing, then again only when
     occupancy grows another ~10 points.
   - `snapshot`: the hook blocks the turn once and re-injects a brief that makes the model write
     the digest, then arms the reload and asks you to `/clear`. Once armed it never re-forces a
     snapshot; further over-budget turns get the laddered reminder.
2. **Snapshot.** `.reload/session.md` holds the working thread. The budget prompts one, `/snapshot`
   writes one on demand, and the skill keeps it fresh at natural milestones. Each snapshot
   replaces the last, so it is written read-first: unresolved open questions are carried forward
   verbatim and `mission` (the original ask) is copied across unchanged.
3. **Arm.** An arm marker under `.reload/` means "rehydrate on the next reset". Only armed resets
   rehydrate, so a deliberate `/clear` meant to drop context is respected. The marker records the
   arming session's id and process id (see [concurrent-sessions.md](concurrent-sessions.md)).
4. **Rehydrate.** `SessionStart` injects the digest after `/clear`, `/compact` or auto-compaction
   and consumes the arm. The banner reports staleness: *N commits since this digest* (from the
   `head:` sha the digest stamped) and *N days old* (from the file's mtime). Both are advisory and
   stay silent unless the number is measurable.

## The digest

Source of truth: [`templates/session.md`](../templates/session.md). Frontmatter carries
`session_id`, `mission`, `updated_at`, `head` and `intent`; the body has four sections, ~30 lines
in total. `scripts/context-block.sh` prints branch, HEAD, uncommitted paths and recent commits
from git so the model states repo facts instead of recalling them.

`/snapshot --check` is the only test of the digest's *content*: it hands the digest, and nothing
else, to a fresh subagent and asks what it would do next. Divergence from what you know is the
digest's defect, found while there is still time to fix it.

## How occupancy is measured

Claude Code gives hooks no context-percentage signal and no model id on `Stop`. cc-reload bridges
this:

1. `SessionStart` stamps the live model id and its resolved window to `.reload/model`, one line per
   session, when Claude Code supplies a model id (optional field; absent after `/clear`, for
   example, in which case the previous stamp stands).
2. The `Stop` hook reads the last **main-thread** assistant row from a tail window of the
   transcript (subagent rows are skipped, a malformed line is skipped rather than fatal, the whole
   file is read only if the window holds no main-thread row). It takes that row's
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` as the context sent that
   turn and the row's `model` as the live model.
3. If the live model differs from the stamp, the stamp is refreshed, so a mid-session `/model`
   switch is picked up. One exception: the transcript carries the bare API id, never a `[1m]`
   suffix, so a `[1m]` stamp of the *same* model is kept, or a 1M session would be downgraded to
   its 200K base and nagged at ~9% real occupancy.
4. The window is, in order: a valid `context_window` override in `.reload/config`; the stamped
   window; else 1M (optimistic, so a large session is never nagged early). A stamped window under
   1M self-corrects upward once more than 200K tokens have been observed.

Occupancy is `tokens × 100 / window`.

### Window resolution

`model_window()` in `hooks/lib.sh` maps ids to windows with boundary-anchored patterns
(`*opus-4-1` and `*opus-4-1-*`, never a bare `*opus-4-1*` that would catch a future `opus-4-10`).
Current Opus/Sonnet and the 5-series are 1M; Haiku and older non-`[1m]` tiers are 200K; unknown ids
assume 1M.

Non-Claude models routed through the [cc-proxy plugin](https://github.com/betmoar/cc-proxy-plugin)
get their window from cc-proxy itself: `SessionStart` makes one loopback-only, 1-second call to
`GET $ANTHROPIC_BASE_URL/v1/models` (only when the host is `127.0.0.1`, `localhost` or `::1`) and
reads the `context_window` cc-proxy v0.5.1+ publishes. Any failure falls back to the table:
`glm-4.5`/`glm-4.5-air` 128K; `glm-4.6`, `glm-4.7`, `glm-5`, `glm-5-turbo`, `glm-5.1` 200K; everything
else 1M. Pin `context_window` if a proxy model's real window is smaller and the proxy may be down
at session start.

### Caveats

- The transcript `usage` field is **undocumented**. If it disappears the hook falls back to a
  byte/4 estimate that over-counts, which errs early and is safe for "never auto-compact".
- Auto-compaction's own threshold is not disclosed as a percentage, which is why cc-reload drives
  the reset proactively. `SessionStart` fires with `source: "compact"` for both manual and
  automatic compaction (Claude Code hooks reference), so the backstop rehydrate is automatic.
- Claude Code caps every hook output string at 10,000 characters and replaces a longer one with a
  preview and a file path. cc-reload injects the digest in full regardless and warns in the banner
  when it is over the cap; `/reload` reads the file directly.

## Coexistence with cc-repete

`.repete/loop.local.md` with `active: true` in its first `---` frontmatter block means a cc-repete
loop owns the session. Every cc-reload hook and command stands down. The reader mirrors cc-repete's
own (first block only, one optional quote layer on both ends, CR tolerated) so the two never
disagree about whether a loop is live.

## The fail-open rule

The worst thing this plugin can do is interrupt or corrupt a session it was meant to protect. So:
every hook exits 0 when `jq` is missing; the Stop hook never blocks unless the handshake marker it
just wrote is verifiably on disk; every git signal prints nothing rather than a wrong number; and
every ownership check may *warn* but never *gates* a rehydrate.
