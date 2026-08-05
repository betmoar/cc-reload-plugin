# Changelog

All notable changes to cc-reload are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2026-08-05

### Fixed
- **Statusline shows the real context window for proxy-routed models.** Previously the statusline
  tag trusted the live harness payload's `context_window.context_window_size` verbatim, which
  reports a conservative `200k` default for any model id outside Claude Code's curated table — so a
  model with a 1M window served through a loopback cc-proxy (e.g. `deepseek-v4-flash-0731`) rendered
  as `200k`, disagreeing with both the proxy and the plugin's own `.reload/model` stamp, and
  ignoring a `context_window` override the Stop hook already honors. The tag is now resolved with the
  same precedence the Stop hook uses: a valid `context_window` override in `.reload/config` wins,
  then the window stamped to `.reload/model` by SessionStart (which holds the proxy-resolved window
  for non-Claude ids), and only then the live payload size. Occupancy (`used_percentage`) still comes
  solely from the payload. Invalid overrides fall through, matching `stop-hook.sh`. (Issue #9)

## [0.3.1] - 2026-08-04

### Added
- **`proxy_window()` learns a model's context window live from cc-proxy.** cc-proxy v0.5.1+
  publishes `context_window` on `GET /v1/models` for every id it curates (entries it hasn't
  curated OMIT the field, never `null`). `SessionStart` now tries this first — one loopback-only
  HTTP call (`--max-time 1`), fired once per session, never on the Stop hook's per-turn path — and
  falls back to the hard-coded `model_window()` table on ANY failure: no `ANTHROPIC_BASE_URL`, a
  non-loopback host, no `curl`, timeout, non-200, malformed JSON, or a missing/non-positive
  `context_window`. `model_window()` is now the offline/no-proxy fallback, not dead weight — kept
  and still exercised directly by its own tests. Precedence unchanged and now three-tiered:
  `.reload/config`'s `context_window` override (checked downstream in `stop-hook.sh`) > live
  cc-proxy lookup > curated table. Verified the F05 guard still holds with the proxy reachable:
  `claude-opus-5[1m]` still stamps `1000000`, since cc-proxy publishes no window for any `claude-*`
  id, so the proxy leg returns empty and the table's `[1m]` case resolves it as before.

### Fixed
- **`model_window()` learns cc-proxy (non-Claude) model windows.** Every proxy model id (GLM,
  DeepSeek, Qwen, routed through the cc-proxy plugin) previously fell through to the optimistic 1M
  default, so e.g. a `glm-4.5` session (real window 128K) was budgeted 8x too generously and the
  notify ladder never fired before auto-compaction. Added boundary-anchored cases for
  `glm-4.5`/`glm-4.5-air` (128K) and `glm-4.6`/`glm-4.7`/`glm-5`/`glm-5-turbo`/`glm-5.1` (200K).
  `glm-5.2`, DeepSeek-v4, Qwen3.x-max/plus/flash, and OpenRouter-prefixed ids
  (`deepseek/deepseek-v4-pro`, `qwen/qwen3.7-max`, etc.) are deliberately left unrecognized —
  they already resolve correctly via the existing 1M default (invariant 5), and cc-proxy publishes
  no distinct window for the OpenRouter forms.

## [0.3.0] - 2026-07-27

### Added
- **Concurrent-session digest guard.** Two Claude Code sessions in one working directory share one
  `.reload/`, and until now the second silently overwrote the first's digest — and could consume
  its arm marker, rehydrating the *wrong* working thread into a fresh context with full confidence.
  The plugin now detects both, loudly, and never blocks anything:
  - `scripts/claim-digest.sh` — the comparator. When the digest on disk belongs to a **different**
    session and was written recently, it is copied aside to `.reload/session.<id>.md` before the
    overwrite lands, with a warning naming the incumbent. Exits 0 unconditionally: a guard that can
    fail the snapshot it guards is worse than the loss it prevents.
  - A **`PreToolUse` hook** (`matcher: "Write|Edit"`, path-scoped to the digest by resolved path) is
    the enforcement point. Both clobbering paths end in the model calling `Write`, so a check
    reached only by a documented step is skippable by the actor it polices — and its unit tests
    would pass green over the unguarded live path.
  - **The arm marker carries its owner.** `.reload/pending` holds the arming session's id instead of
    being an empty `touch`. An arm whose owner disagrees with the digest's owner is flagged on
    rehydrate. It is never suppressed — rehydration proceeds every time (see 0.1.5).
  - **`/snapshot` stamps a runtime id** from `$CLAUDE_CODE_SESSION_ID` rather than asking the model
    to recall its own session id.
- **`context_owner_window` config key** — seconds (default `14400` = 4h; `0` or `off` disables). How
  recently another session must have written the digest for an overwrite to count as a live
  collision worth preserving.
- **One-session-per-working-directory invariant**, documented in the README with the guard's honest
  coverage limits: an un-owned digest is overwritten silently, a digest written via a `Bash` heredoc
  bypasses the `Write`/`Edit` guard, recovery from a side-file is manual, and only `pending` carries
  an owner. This is a detector, not isolation — separate worktrees remain the actual fix.

### Changed
- **Leaner always-loaded context.** The skill description — billed on every session of every user —
  is roughly halved (~218 → ~122 tokens) by dropping a trigger-keyword dump and a four-item
  NOT-list; the body loses a section that restated the cycle steps a second time (~1360 → ~877
  tokens, billed on invoke). Following Anthropic's Claude 5 context-engineering guidance: simple
  descriptions over repetition, and judgment over enumerated prohibitions. All twelve trigger terms
  are retained; every operational instruction in the commands is unchanged.

### Fixed
- **The enforced collision warning never reached the user.** The `PreToolUse` hook relayed
  `claim-digest.sh`'s plain-text stdout, but Claude Code surfaces hook stdout in the transcript for
  only three events — `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart` — and writes it to
  the debug log for everything else. So on the one path that *cannot* be skipped, the guard
  side-filed the incumbent digest correctly and said nothing, while the skippable `/snapshot`
  courtesy path did warn: exactly backwards. The warning is now wrapped in `{systemMessage}` via
  `jq -n --arg`. No `permissionDecision` is emitted — an explicit `allow` would skip the user's own
  permission prompt, and a guard that quietly widens permissions is not a guard.
- **The `[1m]` restamp shield is boundary-anchored.** It tested whether the stamped model's base
  name appeared anywhere in the live id, so `claude-sonnet-4-5[1m]` would shield a future
  `claude-sonnet-4-50` — pinning a stale stamp and its window indefinitely, the mirror image of the
  F05 downgrade the shield exists to prevent. Now anchored on end-of-id or a literal `-`, the same
  rule `model_window()` already follows (invariant 6). The alias form (`sonnet[1m]`, which matches
  mid-id) is unaffected.
- **An unterminated frontmatter fence is no longer treated as frontmatter running to EOF.**
  `digest_owner()` stopped at the closing `---` but had no rule for a fence that never closes, and
  `claim_digest()` gated only on line 1. On a digest whose closing fence went missing — a model
  writing under a line budget, or a truncated mid-write — the first *body* line matching
  `^session_id:` was read as the owner (and named in the user-facing warning) **and rewritten in
  place**, corrupting model-authored prose. Both now require a complete frontmatter region.
- **The guard no longer fires on ordinary `/clear`.** Its first cut compared **session identity**,
  but `/clear` mints a fresh session id every time — so "the digest belongs to someone else" and
  "this arm isn't mine" were *always* true for a single user in a single directory. Caught by
  whole-branch review and reproduced live before release: every reset printed
  `⚠️ armed by a different session in this directory` and cut a side-file, unbounded, forever.
  Both are fixed by comparing **lineage** instead:
  - `SessionStart` now **claims** the digest it rehydrates, rewriting its frontmatter `session_id`
    to the consuming session's id (frontmatter-scoped, atomic, silent on failure). "Inherited"
    becomes "mine", so the next snapshot is correctly silent; a genuinely foreign write — one that
    never passed through that handoff — still collides and is still preserved.
  - The arm warning now fires on **incoherence** (the arm's owner disagrees with the digest's
    owner: session A armed, session B overwrote the digest beside that arm) rather than on
    inequality, which was merely the definition of `/clear`.
  - `claim-digest.sh` no longer preserves byte-identical content twice, so `/snapshot` reaching the
    comparator via both its courtesy call and the `PreToolUse` hook yields one side-file, not two.
  `docs/spec/concurrent-sessions.md` §4.2.3 has been corrected — the false premise ("ids match ⇒ no
  new gate on the happy path") contradicted the same spec's §3, and is the root the code faithfully
  implemented.

## [0.2.1] - 2026-07-24

### Fixed
- **Stop-hook model refresh no longer downgrades a `[1m]` session to its 200K base window**
  (audit F05). The transcript's `message.model` carries only the bare API id — never the `[1m]`
  alias suffix the session was configured with — so the mid-session refresh restamped e.g.
  `claude-sonnet-4-5[1m]` (1M) as `claude-sonnet-4-5-…` (200K), inflating occupancy 5x and firing
  false budget nudges from ~9% real usage. The refresh now keeps the stamp when the live id is the
  same model as a `[1m]` stamp (its base name appears in the live id); a genuine mid-session
  `/model` switch to a different family still restamps. Current-generation `[1m]` configs
  (`fable-5[1m]`, `opus-4-8[1m]`) were unaffected — their base ids already resolve to 1M.

## [0.2.0] - 2026-07-16

### Added
- **Self-embedded plugin marketplace** (`.claude-plugin/marketplace.json`). The repo now installs
  standalone straight from GitHub — `claude plugin marketplace add betmoar/cc-reload-plugin` then
  `claude plugin install cc-reload@cc-reload-plugin` — with no central marketplace required.
- **`## Install` section** in the README documenting the marketplace flow.
- **Triggering benchmark** for the skill description (`skills/maintaining-session-continuity/evals/trigger-eval.json`),
  20 queries used to opus-benchmark description changes.
- **CHANGELOG.md** (this file).

### Changed
- **Renamed the `/checkpoint` command to `/snapshot`** to avoid colliding with Claude Code's own
  native checkpoint / `/rewind` feature (auto code+conversation restore points). cc-reload's
  command means "write a session digest and arm a reload" — a different operation — and `/snapshot`
  matches the verb the code and docs already use. Rejected `/preload` (reads as "load ahead" and
  collides with the existing `/reload`).
- **Renamed the config mode value `context_budget_mode: checkpoint` to `snapshot`.** The pre-0.2.0
  value `checkpoint` is still accepted as a **back-compat alias** — existing `.reload/config` files
  keep working and are normalized to `snapshot` on the next write.
- **Optimized the `maintaining-session-continuity` skill description** via skill-creator triggering
  evals on `claude-opus-4-8`: held-out accuracy 92% → 100%. Fixed a false-positive (triggered on
  wrong-output/hallucination requests) and an under-trigger ("what is `.reload/session.md` for?").
- CI now validates `marketplace.json` and `statusline.json` alongside `plugin.json` and `hooks.json`.

## [0.1.9] - 2026-07-10

### Added
- **`context_budget_mode: notify` (new default)** — a non-blocking, escalation-laddered
  `systemMessage` nudge (fires at the first budget crossing, then only every ≥10 further occupancy
  points via `.reload/notified`). Zero model tokens, never interrupts. The prior forced-snapshot
  behavior remains available as `context_budget_mode: checkpoint` (renamed to `snapshot` in 0.2.0).

### Fixed
- **F01** — over-budget sessions were forced into a snapshot turn every other turn (pass 1 ignored
  the armed `.reload/pending` state). Pass 1 now gates on the arm; once armed, further over-budget
  turns get the laddered reminder instead of another forced turn.
- **F03** — an interrupted snapshot turn followed by `/clear` leaked the `summarizing` marker into
  the fresh session, where the first Stop armed the dead session's digest. SessionStart now purges
  `summarizing` + `notified` on `startup|clear|compact` (not `resume`).

### Known / deferred
- **F04** — banner truncation byte-slices UTF-8 under macOS bash 3.2 (cosmetic; deferred).

## [0.1.8] - 2026-07-10

### Added
- Audit hardening and an end-to-end test suite chaining the real hooks through one shared
  `.reload/` (budget, compaction, unarmed, and stale-floor paths). Baseline 113 → 151 tests.
