# cc-reload — maintainer handoff

This file is the mental model for anyone (human or agent) changing this plugin. Read it before
touching `hooks/`. The README explains what the plugin does for users; this explains **why the
code is shaped the way it is**, which invariants are load-bearing, and how to change each piece
without breaking the others.

## What this is, in one paragraph

Four bash hooks + three slash commands + one skill that keep a Claude Code session's working
thread alive across context resets. State machine on disk under the user's project at `.reload/`:
a digest (`session.md`), a one-shot arm marker (`pending`, now stamped with its arming session
id when known), a two-pass handshake marker (`summarizing`), a notify ladder (`notified`), a
model/window stamp (`model`), per-project config (`config`), and — since 0.3 — side-filed digests
from a detected cross-session collision (`session.<id>.md`). The fourth hook, `PreToolUse`, is a
same-session enforcement point for that collision guard, not a new continuity mechanism. There is
no daemon, no network, no state anywhere else.

## Control flow (the whole system)

```
Stop hook (every turn end)
  ├─ summarizing marker present?  → PASS 2: consume marker; if digest exists, arm `pending`
  │     (fresh digest → success msg; digest not rewritten this turn → arm anyway, warn honestly;
  │      no digest → do NOT arm, warn)
  ├─ stop_hook_active && no marker? → stand down (broken handshake must never re-block = loop)
  ├─ occupancy < budget?          → clear the `notified` ladder, exit silently
  └─ occupancy ≥ budget           → branch on context_budget_mode (default notify):
        ├─ snapshot mode AND not armed (`pending` absent)   [legacy value `checkpoint` aliases here]
        │   → PASS 1: write `summarizing` marker (or refuse to block),
        │     emit {decision:"block"} re-injecting "write .reload/session.md, then STOP"
        └─ notify mode, OR snapshot mode already armed
            → laddered nudge: {systemMessage} only — never blocks, zero model tokens.
              Fires on first crossing, then only at last-notified +10 points (`notified`
              stores the %). Ladder unwritable → silent (else it would nag every turn).

PreCompact hook (manual /compact or auto-compaction)
  └─ arm `pending`; if no digest exists, write a mechanical fallback stub (honest about being thin)

SessionStart hook (startup|resume|clear|compact)
  ├─ stamp model id + resolved window to .reload/model (Stop gets no model field — this bridges it)
  ├─ startup|clear|compact (NOT resume) → purge leaked `summarizing` + `notified`; a handshake
  │     must not outlive its context (see invariant 10)
  └─ `pending` present? → inject digest as additionalContext + visible systemMessage banner
        (WARNS if `pending`'s stamped owner differs from this session's id — never gates on it);
        consume the marker (one-shot). Not armed → do nothing (a deliberate /clear is respected).

PreToolUse hook (model Write/Edit)
  └─ path == $DIGEST && tool is Write|Edit && payload has session_id?
       → claim-digest.sh: foreign + fresh incumbent -> side-file + warn; ALWAYS exit 0 (permit)
```

Every hook first: **exit 0 if jq is missing** (fail open — sourced `exit` in `lib.sh` exits the
caller) and **exit 0 if a cc-repete loop is active** (`.repete/loop.local.md` → `active: true`).

## Load-bearing invariants (each has a named test; the suite is cited per entry)

1. **Pass 2 always completes.** Once pass 1 blocked, the next Stop must consume `summarizing` and
   settle the arm *before* any budget/transcript gating — disabling the budget or losing the
   transcript mid-snapshot must never strand the marker. (Tests: "pass2 completes even …")
2. **Never block without the marker on disk.** The block/continue loop only terminates because
   pass 2 keys off `summarizing`. If the marker can't be written, or `stop_hook_active` is set
   with no marker, the hook stands down. Violating this = infinite snapshot prompt.
   (Tests: "stop_hook_active suppresses a re-block", "unwritable .reload -> no block")
3. **`pending` is the sole rehydrate gate, and it is one-shot.** No session-id comparison —
   `/clear` mints a fresh id every time, so an id-equality guard suppresses the banner on its
   primary trigger 100% of the time (this shipped as a bug; removed in v0.1.5 — do not
   reintroduce it). (Test: "injects digest despite differing session id")
4. **Never arm an empty reload.** Pass 2 with no digest warns instead of arming; SessionStart
   un-arms if the digest vanished. A stale-but-existing digest IS armed (same floor PreCompact
   provides) but the message says so. (Tests: "pass2 without digest…", "stale digest…")
5. **Unknown window ⇒ assume 1M (optimistic).** A wrong 200K guess on a 1M model nags at ~9% real
   occupancy — far worse than snapshotting a small session late (PreCompact still backstops it).
   Same reason the >200K-observed-usage self-heal only ever *raises* the window. A **valid**
   `context_window` override pins everything; an *invalid* one (0, garbage) must behave exactly
   like no override — it feeds a division and gates the self-heal. The transcript's `message.model`
   is **lossy w.r.t. `[1m]` aliases** (bare API id only): the Stop-hook refresh must never restamp a
   `[1m]`-stamped model with its own bare id — that downgrades a 1M-beta session to its 200K base
   and nags at ~9% real occupancy (audit F05). A genuine family switch (base name absent from the
   live id) still restamps. (Tests: "window UNKNOWN…", "context_window: 0 …", "auto-corrects
   upward…", "[1m] stamp survives…", "does NOT shield a genuine family switch")
6. **Model-id matching is boundary-anchored.** `*opus-4-1|*opus-4-1-*` — never a bare `*opus-4-1*`,
   which would misclassify a future `opus-4-10` as 200K. (Tests: "future opus-4-10…")
7. **`.reload/` never gets committed to the user's project.** `ensure_reload_dir` drops a
   self-ignoring `.gitignore` (a lone `*`) on first creation. Every writer path must go through
   `ensure_reload_dir`. (Test: "self-ignoring .gitignore dropped")
8. **Hooks are silent when they have nothing to say.** No output = no user-visible noise and no
   JSON for Claude Code to parse. Never emit partial/invalid JSON; build all JSON with
   `jq -n --arg` (never string interpolation — digest content is untrusted for quoting purposes).
9. **Over budget never blocks when a reload is already armed — and never blocks at all in notify
   mode (the default).** Pre-v0.1.9, pass 1 ignored `pending`: once over budget, every second turn
   became a forced snapshot turn until the user /clear'd (audit F01). The nudge/reminder is
   escalation-laddered (+10 points via `notified`); an unwritable ladder means silence, not
   per-turn nagging. (Tests: "armed reload suppresses re-block", "notify never blocks",
   "ladder suppresses repeats"; e2e cycle 5.)
10. **Markers don't outlive their context.** SessionStart purges `summarizing` + `notified` on
    startup|clear|compact — NOT on resume, where the context (and possibly a mid-flight handshake)
    genuinely persists. Without this, an interrupted snapshot turn followed by /clear left
    `summarizing` behind, and the fresh session's first Stop ran a phantom pass 2 that armed the
    dead session's digest (audit F03). (Tests: "clear purges the leaked handshake", "resume keeps
    a mid-flight handshake"; e2e cycle 6.)
11. **The ownership guard never blocks and never gates.** `claim-digest.sh` and the PreToolUse
    hook exit 0 unconditionally; SessionStart warns on an incoherent arm but always rehydrates. A
    guard that can fail the snapshot it guards is worse than the loss it prevents, and gating
    rehydrate on id equality is the v0.1.5 bug (invariant 3). (Tests: "permits the write"
    (`tests/test-claim-digest.sh`), "incoherent arm STILL rehydrates" (`tests/test-hooks.sh`);
    e2e cycle 7.)
12. **Owner identity lives in the artifact, never in a shared slot.** The digest's `session_id`
    frontmatter and `pending`'s file content carry it. A directory-global owner marker is
    overwritten by whichever session starts last and identifies neither party — the original defect
    one level up (spec §4.2.1, rejected). (Tests: "digest_owner: …" (`tests/test-claim-digest.sh`),
    "arm ownership: …" (`tests/test-hooks.sh`).)
13. **Compare lineage, not identity — and never against this session's own id.** `/clear` mints a
    fresh session id every time, so *any* check of "is this artifact mine?" is false on the
    plugin's own primary path. The first cut of the guard did exactly that and warned on 100% of
    ordinary `/clear` rehydrations while cutting an unbounded side-file per reset (caught in
    whole-branch review, reproduced live, fixed pre-release). Two rules replace it: SessionStart
    **claims** the digest it rehydrates (rewrites frontmatter `session_id` to its own id —
    frontmatter-scoped, atomic, silent on failure), and the arm warning fires on **incoherence**
    (`ARM_OWNER != DIGEST_OWNER`), which cannot arise from one session. Before adding any new id
    comparison, state which side rotates across a reset. (Tests: "coherent arm warns nothing",
    "second clear also silent (false positive does not reappear)", "incoherent arm warns"
    (`tests/test-hooks.sh`); e2e single-session lifecycle cycle. Spec §4.2.3, corrected.)

## Non-obvious decisions and rejected alternatives

- **Why a two-pass Stop handshake instead of summarizing in the hook?** A hook is a shell command;
  the model is not running inside it, so it cannot author a digest. Pass 1 blocks and re-injects
  instructions so the *model* writes the digest on the next turn; pass 2 detects that turn ended
  and arms. PreCompact has the same limitation, hence its mechanical fallback stub.
- **Why read token usage from the transcript?** Claude Code gives Stop hooks no context-% and no
  model id. The last assistant turn's `message.usage` (input + both cache fields) ≈ full context
  sent that turn. This is an **undocumented schema** — treat it as best-effort forever; the byte/4
  fallback deliberately over-counts (triggers early = safe when the goal is "never auto-compact").
- **Why one jq slurp, not two?** The transcript is tens of MB near budget and this runs on every
  Stop. USED and LIVE_MODEL are extracted in a single pass ("tokens<space>model"; model ids never
  contain spaces).
- **Why does the statusline segment not share code with the hooks?** It renders Claude Code's own
  pre-calculated `context_window.used_percentage` from statusline stdin — it must work with zero
  hooks having run, and must never touch the transcript. Only the *budget* is shared, read from
  `.reload/config` by both.
- **Why `set -uo pipefail` but not `-e`?** Fail-open philosophy: a broken hook must degrade to
  "plugin does nothing", never to "session unusable". Guard specific failure points explicitly
  (e.g. `touch … || exit 0`) instead of letting `-e` kill the script at an arbitrary line.
- **Why is notify the default mode (v0.1.9)?** A forced snapshot turn costs ~1–3K model tokens
  and interrupts flow; users who found it invasive disabled the budget entirely (pct 0) and lost
  the safety net — the invasive default undermined the plugin's own purpose. A systemMessage nudge
  costs zero model tokens, and the statusline gauge + PreCompact backstop still cover the
  inattentive case. **Rejected:** re-blocking every +10 points in snapshot mode (re-introduces
  the token cost the mode split exists to remove); per-turn notifications without a ladder
  (trains users to ignore the nudge); a "block once per session" flag instead of keying on
  `pending` (a new marker to leak — `pending` already encodes exactly "the snapshot happened").
- **Why does the notify ladder live in a file, not the message?** A hook is stateless per
  invocation; without `notified` the nudge would fire on every Stop over budget. The ladder is
  cleared when occupancy drops under budget and on any real reset (SessionStart hygiene), so a new
  climb always announces itself.

## Couplings — if you touch X, also update Y

| You changed | You must also check |
|---|---|
| Digest format / section names | `templates/session.md`, the pass-1 REINJECT heredoc in `stop-hook.sh`, `_first_bullet` calls in `sessionstart-hook.sh`, `commands/snapshot.md`, the skill |
| Marker file names/locations (`lib.sh` constants) | both test files, README "Layout" + hook table |
| `model_window()` cases | tests "model_window: …" block, README "How occupancy is measured", the SKILL.md note on windows |
| Hook JSON output shape | Claude Code hook schema (systemMessage / decision:block / hookSpecificOutput.additionalContext) — verify against current CC docs before changing |
| `context_budget_pct` semantics (default 45, 0=off) | `stop-hook.sh`, `scripts/statusline.sh` (independent reader!), `commands/reload-budget.md`, README, SKILL.md |
| `context_budget_mode` semantics (default notify; value `snapshot`, legacy `checkpoint` aliased) or the +10 ladder step | `stop-hook.sh` (mode branch reads `snapshot\|checkpoint` + ladder), `scripts/reload-config.sh` (validation normalizes `checkpoint`→`snapshot`), `commands/reload-budget.md`, README "How it works" + Configuration, SKILL.md cycle step 1, both test files' alias cases |
| Anything in `hooks/hooks.json` | plugin must not ALSO declare hooks in plugin.json (duplicate-hooks load error — v0.1.2 regression) |
| `claim-digest.sh` decision logic | `tests/test-claim-digest.sh`, e2e cycle 7, README "Known limitations" |
| `pretooluse-hook.sh` or its `hooks.json` entry | plugin must not ALSO declare hooks in `plugin.json`; `tests/test-claim-digest.sh` |
| `PENDING` being a stamped file rather than a `touch` | `stop-hook.sh:69`, `precompact-hook.sh:24`, `sessionstart-hook.sh` arm-owner block, both test files |
| `context_owner_window` semantics (default 14400, 0=off) | `lib.sh` `owner_window()`, `scripts/reload-config.sh`, `commands/reload-budget.md`, README, `tests/test-config.sh` |

## How to change things safely

- **Every behavior change gets a test in the same commit.** The suites are plain bash, no
  framework: `bash tests/test-hooks.sh && bash tests/test-statusline.sh && bash
  tests/test-config.sh && bash tests/test-e2e.sh` (exit code = #failures). `test-hooks`/
  `test-statusline`/`test-config` exercise each hook and the config tool in isolation;
  `test-e2e` chains the REAL hooks through one shared `.reload/` and asserts the working-thread
  content round-trips session→reset→session (budget, compaction, unarmed, and stale-floor paths).
  Prefer adding a cross-hook regression there when a change spans the marker handshake or the
  digest→banner contract. CI = JSON validation + `bash -n` + `shellcheck -S warning` on hooks,
  scripts, *and* tests.
- **Keep hooks dependency-free**: bash + jq + coreutils only. `touch -t` not `touch -d`
  (BSD/macOS), literal ESC byte not `\x1b` in sed (BSD), no GNU-only flags.
- **New model id shipped?** Add a boundary-anchored case to `model_window()` + two tests (the id,
  and the nearest colliding future id). Users can always pin `context_window` meanwhile.
- **Never make the Stop hook slower than ~1s** on a large transcript — it runs on every turn end.
  One jq pass over the transcript, no additional full-file reads.
- **When in doubt, fail open and silent.** The worst thing this plugin can do is interrupt or
  corrupt a session it was meant to protect.

## Known landmines

- `lib.sh` is **sourced**, and its `exit 0` (missing jq) intentionally exits the *calling hook*.
  Don't "fix" that into a `return`.
- The markers under `.reload/` are **per-project, not per-session**. As of 0.3 the two that can
  cause real harm are *detected*: a foreign live digest is side-filed with a warning, and a
  foreign arm rehydrates with a warning (never suppressed — invariant 3 still holds; the
  comparison may warn, never gate). `summarizing`, `notified`, and `model` remain shared and
  accepted. Detection is not isolation: the actual fix is one session per working directory
  (README "Known limitations"). Do not gate rehydration on the digest's session id — invariant 3.
- SessionStart fires on `resume` too: an armed digest is injected (and consumed) into a resumed
  session that still has its context. Redundant but harmless; removing `resume` from the matcher
  would drop the model/window stamp on resume, which Stop needs. Accepted trade-off.
- The transcript `message.usage` schema is undocumented; if it disappears the byte/4 fallback
  silently takes over (earlier, noisier triggers). If users report premature snapshots, check
  this first.

## Backlog (prioritized, with context)

1. **Verify `SessionStart source:"compact"` fires on _auto_-compaction** (not just `/compact`) on
   current Claude Code — determines whether the PreCompact backstop rehydrates automatically. If
   it doesn't, the arm survives until the next startup/clear, which is acceptable but worth
   documenting precisely. (Needs a live CC session; can't be unit-tested.)
2. **Marker mtime granularity**: the pass-2 freshness check uses `-nt`; on filesystems with 1s
   granularity a digest written in the same second as the marker reads as "not refreshed"
   (arms + warns — degraded but safe). Only matters if users report spurious stale warnings.
3. **Haiku 5+ ids**: `*haiku*` maps to 200K with no minor split. If a future Haiku ships 1M,
   add boundary-anchored cases before the heuristic misfires (config override covers the gap).
4. **Banner truncation byte-slices UTF-8 under macOS bash 3.2** (`_truncate` in
   `sessionstart-hook.sh` uses `${s:0:n}`, byte-based on bash 3.2 — audit F04, cosmetic). If users
   report mojibake banners, replace with an awk-based char-safe cut:
   `awk -v n=60 '{print substr($0,1,n)}'` (awk substr is char-aware under a UTF-8 locale).
