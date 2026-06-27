# cc-reload

**Session continuity across context resets for Claude Code.** When your context fills and you
`/clear`, `/compact`, or the system auto-compacts, cc-reload snapshots the session's working
thread to `.reload/session.md` *before* the reset and **auto-rehydrates** it after — so an
ordinary session doesn't lose its place.

It is the **non-looped companion to [cc-repete](https://github.com/betmoar/cc-repete-plugin)**.
cc-repete manages context *inside a mission loop*; cc-reload covers *ordinary sessions*. They are
complementary by construction: cc-reload **stands down whenever a cc-repete loop is active**, so
the two never fight.

> Status: **v0.1.7.** The design target is **proactive reset before auto-compaction**:
> keep manual sessions well under the window (≈45% by default, lower per task) so auto-compact
> never fires. The Stop-hook budget is the primary path; auto-compaction handling is a backstop.

## How it works — budget → snapshot → arm → rehydrate

1. **Budget (primary)** — the `Stop` hook watches context occupancy and, when it crosses
   `context_budget_pct` (default **45%**), prompts a checkpoint + `/clear` — so you reset *before*
   rot and long before auto-compaction. Tune per task with `/reload-budget <pct>`.
2. **Snapshot** — `.reload/session.md` holds the working thread (intent / done / in flight / next
   step / open questions). The budget prompts one; `/checkpoint` writes one on demand; the skill
   keeps it fresh as you work.
3. **Arm** — a `.reload/pending` marker means "rehydrate on the next reset." Only *armed* resets
   rehydrate, so a deliberate `/clear` meant to drop context is respected.
4. **Rehydrate** — the `SessionStart` hook injects the digest after `/clear` or `/compact` and
   consumes the marker. Automatic — no command. `/reload` does it manually.

### How occupancy is measured (and its limits)

Claude Code gives hooks **no context-% signal and no model id on `Stop`**. cc-reload bridges this
and **auto-detects each user's window** — nothing is hardcoded to one setup:

1. `SessionStart` stamps the live `model` + resolved window to `.reload/model` when Claude Code
   supplies a model id (an **optional** SessionStart field — best-effort). An unrecognized id is
   assumed to be a large (1M) window.
2. The `Stop` hook gets **no model id**, so it reads the model from the **last assistant turn** in
   the transcript and re-stamps `.reload/model` if it changed (mid-session `/model` switches are
   picked up). It then reads that turn's input tokens (input + cache) and computes occupancy against
   the window. If the window is entirely unknown (no stamp yet, no override) it **assumes a large 1M
   window** — so a 1M session is never nagged before the stamp exists; the trade-off is that a
   genuinely small un-stamped session checkpoints late (PreCompact + auto-compaction still backstop it).
3. If a *stamped* window is too low for an unrecognized large-context model, it **self-corrects
   upward from observed usage** (>200K tokens used ⇒ not a 200K window). This only ever lowers
   occupancy, so it can't cause a premature reset.
4. `context_window` in `.reload/config` overrides everything — the precise fix for a brand-new
   model id.

Caveats: the usage field is **undocumented** (best-effort; if missing, the hook falls back to a
byte estimate that errs early — safe when the goal is to stay low). Auto-compact's own threshold is
not disclosed or configurable as a %, which is exactly why cc-reload drives the reset proactively.

## Commands

| Command          | Purpose                                                                  |
| ---------------- | ------------------------------------------------------------------------ |
| `/reload-budget` | Set the proactive trigger threshold (% of window) for this project; tune per task |
| `/checkpoint`    | Write `.reload/session.md` now and arm a reload across the next reset     |
| `/reload`        | Manually rehydrate from `.reload/session.md` (5-line sitrep, then resume) |

## Hooks

| Hook           | Matcher                     | Does                                                                        |
| -------------- | --------------------------- | --------------------------------------------------------------------------- |
| `Stop`         | —                           | **primary:** at `context_budget_pct`, re-inject "write digest + /clear", then arm |
| `SessionStart` | startup\|resume\|clear\|compact | stamp model+window to `.reload/model`; if armed, inject the digest, clear marker |
| `PreCompact`   | manual\|auto                | **backstop:** arm + ensure a digest exists (mechanical fallback)            |

Every hook's first actions: **fail open if `jq` is missing**, and **stand down if a cc-repete loop
is active** (`.repete/loop.local.md` → `active: true`). See `hooks/lib.sh`.

## Statusline (optional) — context % on the right

Claude Code now hands the statusline a pre-calculated context signal on stdin
(`context_window.used_percentage` + `context_window_size`, CC ≥ 2.1.132). cc-reload ships a tiny
segment that turns it into a budget-aware gauge:

```
ctx[1M] 7%·45
   │    │   └ this project's reload budget (% of window), from .reload/config (45 default)
   │    └──── current occupancy (input + cache), colored GREEN/YELLOW/RED relative to the budget
   └───────── context window size: 1M / 200k
```

It is **read-only** — it does not run the hooks or read the transcript, just renders what Claude
Code already provides. It prints nothing early in a session or right after `/compact` (no signal
yet), so the slot stays clean. With the budget disabled (`context_budget_pct: 0`) it drops the
`·N` suffix and colors on absolute thresholds.

`scripts/statusline.sh` is a native Claude Code statusline renderer — point `statusLine` straight at
it to show cc-reload's context gauge on its own bar. Use an **absolute** path (the command runs
outside plugin context, so `${CLAUDE_PLUGIN_ROOT}` is unavailable):

```json
"statusLine": {
  "type": "command",
  "command": "bash /ABS/PATH/TO/cc-reload/scripts/statusline.sh"
}
```

Claude Code allows only **one** `statusLine`, so to show this alongside other segments you need a
composer in that slot. cc-reload doesn't ship one; it ships the segment manifest
(`.claude-plugin/statusline.json`) that a composer can read:

```json
{ "name": "cc-reload", "render": "scripts/statusline.sh", "order": 20 }
```

A composer discovers every installed plugin that ships such a manifest, fans the session JSON to
each renderer, and joins the non-empty output — so cc-reload's gauge sits next to other plugins'
segments with no per-plugin wiring, and an empty/errored segment drops out with no dangling
separator.

## Coexistence with cc-repete

| | cc-repete | cc-reload |
|---|---|---|
| Scope | continuity inside a mission loop | continuity in ordinary sessions |
| Active when | a loop is running | **no** loop is running |
| State | `.repete/` | `.reload/` |
| Commands | `/repete*` | `/reload`, `/checkpoint` |

Install both; the stand-down check makes it safe.

## Configuration

`.reload/` holds per-session runtime state, not source. The first time cc-reload creates it, it
drops a self-ignoring `.reload/.gitignore` (a single `*`) so the directory is never committed to
your project — no change to your own `.gitignore` needed.

`.reload/config` (per project; all optional):

```
context_budget_pct: 45       # trigger a checkpoint+/clear at this % of the window. 0 = off. Default 45.
context_window: 1000000      # AUTHORITATIVE window override in tokens. Set this for your main model.
```

- **`context_budget_pct`** — the proactive trigger. Set it low for context-sensitive tasks
  (`/reload-budget 30`), higher for more work per session. Default **45**.
- **`context_window`** — overrides window detection and **always wins**. `SessionStart` tries to
  detect it from the live model id, but model ids change (e.g. Sonnet 5's 1M window), and a wrong
  guess would skew the % badly. **Set this once for your main session model** — e.g. `1000000` for
  a 1M-context model — and the budget is exact regardless of id churn. (Most 200K models are now
  subagents returning findings; the budget targets the main session's window.)

## Layout

```
cc-reload/
├── .claude-plugin/plugin.json
├── hooks/{hooks.json, lib.sh, sessionstart-hook.sh, precompact-hook.sh, stop-hook.sh}
├── .claude-plugin/statusline.json    # statusline segment manifest (for a composer)
├── scripts/statusline.sh             # statusline segment renderer (native or via composer)
├── commands/{reload-budget.md, checkpoint.md, reload.md}
├── skills/maintaining-session-continuity/SKILL.md
├── templates/session.md
├── tests/{test-hooks.sh, test-statusline.sh}   # smoke tests (run: bash tests/test-*.sh)
├── .github/workflows/ci.yml       # bash -n + shellcheck + the test suites
└── LICENSE                        # MIT
```

## Open questions (verify on your Claude Code / model version)

- **Transcript token-usage field is undocumented.** The Stop budget reads the last assistant
  turn's `message.usage.{input_tokens,cache_read_input_tokens,cache_creation_input_tokens}` from
  the transcript. It works today but isn't an official schema; if it disappears the hook falls back
  to a byte estimate. Validate occupancy looks right against `/context` after install.
- **Sonnet 5's exact model id + default window.** The resolver maps `*sonnet-5*` → 1M, but confirm
  the real id on launch — or just set `context_window` in `.reload/config` and skip detection.
- **Does `SessionStart` fire with `source: "compact"` on _auto_-compaction, or only `/compact`?**
  Determines whether the backstop rehydrate is automatic. (The primary budget path avoids relying
  on it.)
- **Hook matcher syntax** for `SessionStart`/`PreCompact` may need adjusting per version; the
  scripts also branch on the source/type read from stdin as a safety net.

## Known limitations

- **State is per-project, not per-session.** The `pending`, `summarizing`, and `model` markers live
  in one `.reload/` dir per project. Two Claude Code sessions open in the *same* repo at once can
  step on each other's markers (one arms, another consumes/stamps). The SessionStart staleness
  guard (`session_id` in the digest) protects the *rehydrate* path, but the arming markers
  themselves are shared. Single-session-per-project use — the common case — is unaffected.

See `SPEC.md` (from the design phase) for the full rationale, flows, and phased scope.

## License

MIT — see [`LICENSE`](LICENSE).
