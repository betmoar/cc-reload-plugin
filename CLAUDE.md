# cc-reload — maintainer handoff

This file is the mental model for anyone (human or agent) changing this plugin. Read it before
touching `hooks/`. The README explains what the plugin does for users; this explains **why the
code is shaped the way it is**, which invariants are load-bearing, and how to change each piece
without breaking the others.

## What this is, in one paragraph

Three bash hooks + three slash commands + one skill that keep a Claude Code session's working
thread alive across context resets. State machine on disk under the user's project at `.reload/`:
a digest (`session.md`), a one-shot arm marker (`pending`), a two-pass handshake marker
(`summarizing`), a model/window stamp (`model`), and per-project config (`config`). There is no
daemon, no network, no state anywhere else.

## Control flow (the whole system)

```
Stop hook (every turn end)
  ├─ summarizing marker present?  → PASS 2: consume marker; if digest exists, arm `pending`
  │     (fresh digest → success msg; digest not rewritten this turn → arm anyway, warn honestly;
  │      no digest → do NOT arm, warn)
  ├─ stop_hook_active && no marker? → stand down (broken handshake must never re-block = loop)
  ├─ occupancy < budget?          → exit silently
  └─ occupancy ≥ budget           → PASS 1: write `summarizing` marker (or refuse to block),
        emit {decision:"block"} re-injecting "write .reload/session.md, then STOP"

PreCompact hook (manual /compact or auto-compaction)
  └─ arm `pending`; if no digest exists, write a mechanical fallback stub (honest about being thin)

SessionStart hook (startup|resume|clear|compact)
  ├─ stamp model id + resolved window to .reload/model (Stop gets no model field — this bridges it)
  └─ `pending` present? → inject digest as additionalContext + visible systemMessage banner;
        consume the marker (one-shot). Not armed → do nothing (a deliberate /clear is respected).
```

Every hook first: **exit 0 if jq is missing** (fail open — sourced `exit` in `lib.sh` exits the
caller) and **exit 0 if a cc-repete loop is active** (`.repete/loop.local.md` → `active: true`).

## Load-bearing invariants (each has a named test in tests/test-hooks.sh)

1. **Pass 2 always completes.** Once pass 1 blocked, the next Stop must consume `summarizing` and
   settle the arm *before* any budget/transcript gating — disabling the budget or losing the
   transcript mid-checkpoint must never strand the marker. (Tests: "pass2 completes even …")
2. **Never block without the marker on disk.** The block/continue loop only terminates because
   pass 2 keys off `summarizing`. If the marker can't be written, or `stop_hook_active` is set
   with no marker, the hook stands down. Violating this = infinite checkpoint prompt.
   (Tests: "stop_hook_active suppresses a re-block", "unwritable .reload -> no block")
3. **`pending` is the sole rehydrate gate, and it is one-shot.** No session-id comparison —
   `/clear` mints a fresh id every time, so an id-equality guard suppresses the banner on its
   primary trigger 100% of the time (this shipped as a bug; removed in v0.1.5 — do not
   reintroduce it). (Test: "injects digest despite differing session id")
4. **Never arm an empty reload.** Pass 2 with no digest warns instead of arming; SessionStart
   un-arms if the digest vanished. A stale-but-existing digest IS armed (same floor PreCompact
   provides) but the message says so. (Tests: "pass2 without digest…", "stale digest…")
5. **Unknown window ⇒ assume 1M (optimistic).** A wrong 200K guess on a 1M model nags at ~9% real
   occupancy — far worse than checkpointing a small session late (PreCompact still backstops it).
   Same reason the >200K-observed-usage self-heal only ever *raises* the window. A **valid**
   `context_window` override pins everything; an *invalid* one (0, garbage) must behave exactly
   like no override — it feeds a division and gates the self-heal. (Tests: "window UNKNOWN…",
   "context_window: 0 …", "auto-corrects upward…")
6. **Model-id matching is boundary-anchored.** `*opus-4-1|*opus-4-1-*` — never a bare `*opus-4-1*`,
   which would misclassify a future `opus-4-10` as 200K. (Tests: "future opus-4-10…")
7. **`.reload/` never gets committed to the user's project.** `ensure_reload_dir` drops a
   self-ignoring `.gitignore` (a lone `*`) on first creation. Every writer path must go through
   `ensure_reload_dir`. (Test: "self-ignoring .gitignore dropped")
8. **Hooks are silent when they have nothing to say.** No output = no user-visible noise and no
   JSON for Claude Code to parse. Never emit partial/invalid JSON; build all JSON with
   `jq -n --arg` (never string interpolation — digest content is untrusted for quoting purposes).

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

## Couplings — if you touch X, also update Y

| You changed | You must also check |
|---|---|
| Digest format / section names | `templates/session.md`, the pass-1 REINJECT heredoc in `stop-hook.sh`, `_first_bullet` calls in `sessionstart-hook.sh`, `commands/checkpoint.md`, the skill |
| Marker file names/locations (`lib.sh` constants) | both test files, README "Layout" + hook table |
| `model_window()` cases | tests "model_window: …" block, README "How occupancy is measured", the SKILL.md note on windows |
| Hook JSON output shape | Claude Code hook schema (systemMessage / decision:block / hookSpecificOutput.additionalContext) — verify against current CC docs before changing |
| `context_budget_pct` semantics (default 45, 0=off) | `stop-hook.sh`, `scripts/statusline.sh` (independent reader!), `commands/reload-budget.md`, README, SKILL.md |
| Anything in `hooks/hooks.json` | plugin must not ALSO declare hooks in plugin.json (duplicate-hooks load error — v0.1.2 regression) |

## How to change things safely

- **Every behavior change gets a test in the same commit.** The suites are plain bash, no
  framework: `bash tests/test-hooks.sh && bash tests/test-statusline.sh` (exit code = #failures).
  CI = JSON validation + `bash -n` + `shellcheck -S warning` on hooks, scripts, *and* tests.
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
- The `summarizing`/`pending` markers are **per-project, not per-session**: two concurrent
  sessions in one repo can consume each other's arms. Known, documented, accepted (README
  "Known limitations"). Do not try to fix it with session ids in the digest — see invariant 3.
- SessionStart fires on `resume` too: an armed digest is injected (and consumed) into a resumed
  session that still has its context. Redundant but harmless; removing `resume` from the matcher
  would drop the model/window stamp on resume, which Stop needs. Accepted trade-off.
- The transcript `message.usage` schema is undocumented; if it disappears the byte/4 fallback
  silently takes over (earlier, noisier triggers). If users report premature checkpoints, check
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
