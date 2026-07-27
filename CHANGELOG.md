# Changelog

All notable changes to cc-reload are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
