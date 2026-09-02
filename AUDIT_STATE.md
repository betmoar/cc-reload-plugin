# Audit state — cc-reload-plugin — 2026-09-02

Mode: AUTONOMOUS (principal-architect-audit)
Phase cursor: DONE (P1–P4 complete and self-verified, 2026-09-02; STOP CONDITION 5)
Commit audited: aedcfd5 (0.3.2), branch `claude/principal-audit-autonomous-hq0q7v` (== origin/main at start)
Iteration budget: none set — Phase 2 runs loop-until-dry; anything skipped is logged in AUDIT_LOG.md
Target selection: five repos in the workspace; cc-operator, cc-proxy, cc-repete already carry a DONE cursor from 2026-08-31. cc-reload and cc-status were un-audited; cc-reload chosen first (four hooks, a Stop hook that can BLOCK, writes into user projects, one network call — the larger blast radius). cc-status is the fallback second target.

## Verdict (one line)
Healthy after remediation (was: salvageable-with-work, close to healthy) — the fail-open philosophy and the ownership/lineage design hold up under probing; the defects are in the ONE measurement the plugin makes (the transcript scan: wrong agent, wrong on a bad line, over its own time/memory budget), in a config format the README itself teaches but no reader parses, and in one fail-CLOSED door (a non-regular marker). No architecture-root issue.

## Baseline (captured BEFORE any change, 2026-09-02)
Tests: test-hooks 147/0 · test-statusline 16/0 · test-config 31/0 · test-e2e 62/0 · test-claim-digest 56/0 — 0 failing (one root-only SKIP in claim-digest: chmod-500 case is vacuous as root)
Build: `bash -n` clean on hooks/scripts/tests; JSON valid (plugin, marketplace, statusline, hooks); shellcheck 0.10.0 `-S warning` clean (binary fetched into the session scratchpad, NOT installed system-wide — local `shellcheck` is absent; CI installs an UNPINNED apt version)
Working tree: clean at aedcfd5

## Architecture (Phase 1)
- Entry points: `hooks/hooks.json` → four bash hooks, all `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<x>.sh"`, all sourcing `hooks/lib.sh` first:
  - SessionStart (startup|resume|clear|compact) → `hooks/sessionstart-hook.sh`
  - PreCompact (manual|auto) → `hooks/precompact-hook.sh`
  - Stop (no matcher) → `hooks/stop-hook.sh`
  - PreToolUse (Write|Edit) → `hooks/pretooluse-hook.sh` → `scripts/claim-digest.sh`
  - Slash commands (prompt-code, no validation layer): `commands/{snapshot,reload,reload-budget}.md`; `/reload-budget` shells to `scripts/reload-config.sh`; `/snapshot` shells to `scripts/claim-digest.sh`
  - Statusline renderer `scripts/statusline.sh` (stdin JSON → one segment), discovered by a composer via `.claude-plugin/statusline.json`
- Control flow: the CLAUDE.md control-flow block is ACCURATE against the code (verified line by line: stop-hook.sh:53-88 pass 2, :97-98 loop guard, :101-102 pct gate, :184-190 under-budget, :198-223 pass 1, :225-242 notify ladder; sessionstart-hook.sh:17-28 stamp, :37-39 purge, :52-53 gate, :73-79 coherence+consume, :102 claim, :141-147 inject).
- Data flow: transcript JSONL (undocumented schema) → `jq -rs` slurp of the WHOLE file per Stop (stop-hook.sh:111-117) → USED tokens + LIVE_MODEL; hook stdin JSON → session_id/model/source/tool_input; `.reload/config` (kv lines) → budget/mode/window/owner-window.
- State lives in `$CLAUDE_PROJECT_DIR/.reload/` (per PROJECT, not per session): `session.md` (digest, model-written, UNTRUSTED body), `pending` (arm; content = owner id), `summarizing` (2-pass handshake), `notified` (ladder %), `model` (model+window stamp), `config`, `session.<id>[.<mtime>].md` side-files, `.gitignore` (`*`). Mutators: SessionStart (model, pending consume, session.md frontmatter claim, purge), Stop (summarizing, pending, model, notified), PreCompact (pending, session.md when absent), claim-digest (side-files), reload-config (config), the MODEL via Write (session.md) and via `printf > .reload/pending` (snapshot.md step 4).
- Trust boundaries: (1) hook stdin JSON from Claude Code — trusted shape, defensively parsed; (2) transcript JSONL — CC-written, best-effort schema; (3) `.reload/session.md` body — MODEL-written, untrusted (invariant 8); (4) `.reload/pending` content — read back into a user-facing message; (5) `ANTHROPIC_BASE_URL` env — user/settings-controlled, gates the ONE network call (lib.sh:206-249); (6) `.reload/config` — user/command-written, every value validated at read.
- External deps: bash ≥3.2, jq (hard — every hook exits 0 without it), coreutils (`stat` GNU/BSD divergence handled in claim-digest.sh:60), optional curl (proxy_window). No node/python at runtime.

## Load-bearing inventory (ranked by blast radius)
1. `hooks/stop-hook.sh` pass-1/pass-2 handshake + `stop_hook_active` guard (:53-98, :198-223) — blast: an infinite forced-snapshot loop or a session that can never Stop — why: the ONLY path that emits `decision:"block"`; every guarantee in CLAUDE.md invariants 1, 2, 9 lives in its ordering.
2. `hooks/lib.sh` preamble (:13-24): `set -uo pipefail`, `command -v jq || exit 0` — blast: every hook — why: sourced by all four hooks + claim-digest; the sourced `exit` IS the fail-open contract (documented landmine).
3. `hooks/stop-hook.sh` occupancy pipeline (:104-184): transcript slurp → USED/LIVE_MODEL → restamp → WINDOW → OCCUPANCY — blast: false nudges/blocks (5x if the window is wrong) or silent under-report (auto-compaction fires, the failure the plugin exists to prevent) — why: the only measurement; runs on every Stop; `-s` slurps tens of MB.
4. `hooks/sessionstart-hook.sh` arm gate + consume + claim (:52-103) — blast: wrong thread rehydrated with confidence, or a /clear that never rehydrates (the v0.1.5 bug) — why: the ONLY rehydrate path; invariant 3/11/13.
5. `hooks/lib.sh` `frontmatter_closed`/`digest_owner`/`claim_digest` (:68-141) — blast: body corruption of a model-authored file, or a body line laundered into the owner id shown to the user — why: the only writer that rewrites the digest in place; scoping is the whole defence.
6. `scripts/claim-digest.sh` — blast: silent loss of another session's digest, or a path escape from `.reload/` via the owner id (:75 sanitizer) — why: the comparator both the command and the enforced hook call.
7. `hooks/pretooluse-hook.sh` — blast: fires on EVERY Write/Edit in every session (matcher is tool-name only; path filter is inside) — a non-zero exit here would fail the user's write — why: invariant 11 "always exit 0".
8. `hooks/lib.sh` `model_window()` (:161-186) + `proxy_window()` (:206-249) — blast: a wrong window skews every % — why: the window is the denominator; boundary-anchoring (invariant 6) and the loopback allowlist live here.
9. `hooks/lib.sh` `ensure_reload_dir` (:30-33) — blast: `.reload/` committed into a user's repo — why: every writer path relies on the self-ignoring `.gitignore`.
10. `scripts/reload-config.sh` — blast: a half-written config (mitigated: temp+mv) or an accepted bad value that later divides by zero (mitigated: stop-hook re-validates) — why: the only sanctioned config writer.
11. `hooks/hooks.json` — blast: duplicate-hooks load error (v0.1.2) if plugin.json also declares hooks; a missing/renamed script means the hook silently never runs.
12. `scripts/statusline.sh` — blast: cosmetic only (a wrong tag) — a 2s composer kill yields an empty segment.

## Implicit contracts (assumed, never checked in code)
- IC1 The transcript's last `message.role=="assistant"` entry is the MAIN thread's last turn (no `isSidechain` filter at stop-hook.sh:112). If sub-agent (sidechain) entries share the file, the last one may belong to a subagent: its usage is small (silent under-report) and its `message.model` (e.g. haiku) restamps `.reload/model` to 200K (false 5x nudges). INFERRED, confidence moderate — cc-repete's hook (sibling repo) filters `isSidechain`; to be probed in P2.
- IC2 Every transcript line is valid JSON: `jq -rs` (stop-hook.sh:111) aborts the WHOLE parse on one malformed/partial line, silently degrading to the byte/4 estimate (tens of MB → 1000%+ → a nudge, or in snapshot mode a forced block). cc-repete uses `fromjson?` per line for exactly this reason. INFERRED, moderate.
- IC3 `.reload/{summarizing,pending}` are regular files: every test is `-f`, but the writers are `touch`/`printf >`, which succeed on a directory/other entry. A directory named `summarizing` makes pass 1 block on every ordinary Stop (marker never `-f`, never removed). CONFIRMED by code reading; to be reproduced in P2. Contrived trigger.
- IC4 `$CLAUDE_CODE_SESSION_ID` exists in the model's Bash tool env (snapshot.md steps 2/4, stop-hook REINJECT :210, template). cc-operator's CLAUDE.md states the session id is NOT in the Bash tool env (only hooks get `session_id`). If absent: `/snapshot` writes an un-owned digest and an empty arm, so the ownership guard is dead on the /snapshot path until the first SessionStart claim. To be measured in this session's Bash tool.
- IC5 `ANTHROPIC_BASE_URL`'s authority has no userinfo: the host parse (lib.sh:223-227) cuts at the first `:`/`/`, so `http://127.0.0.1@evil.com/` reads as host `127.0.0.1` and passes the loopback allowlist while curl contacts evil.com. Marginal blast (whoever sets that env already owns the session's API traffic) — the contract "never phone out" is what breaks.
- IC6 Model ids never contain spaces (stop-hook.sh:110 split) — holds for every known id.
- IC7 `session_id` values are UUID-safe: PreCompact interpolates it raw into YAML frontmatter (precompact-hook.sh:34); a `"` would break the fence. Holds for CC ids.
- IC8 `/clear` mints a fresh session id (documented, load-bearing for invariants 3/13); `/compact` and `resume` behaviour is asserted in docs, not measurable here.
- IC9 Second-granularity mtimes: `-nt` freshness (stop-hook.sh:60) and `AGE` (claim-digest.sh:65) — backlog #2 already records it.
- IC10 CI mirrors the local gate by hand: suites are listed by name in `ci.yml`, README and CLAUDE.md (no `tests/run-all.sh`); a new suite added to one site silently never runs in CI (cc-repete documents the identical landmine).
- IC11 The version trio (plugin.json / newest CHANGELOG heading / README status line) agrees by hand — CONFIRMED broken today: plugin.json 0.3.2, CHANGELOG [0.3.2], README "Status: **v0.3.1.**".

## Delta: intended vs. actual
- The ownership guard is documented as covering "both clobbering paths" (spec §4.3) but its owner stamp on the /snapshot path depends on IC4 — INFERRED, confidence moderate until measured.
- "Stop hook reads the last assistant turn" is documented as the main session's occupancy; with sidechains in-file it is whichever agent spoke last — INFERRED, moderate (IC1).
- "Fail open" is true for every code path read, with one contrived exception (IC3) where the handshake fails CLOSED into repeated blocks.
- Everything else read matches its documentation; CLAUDE.md's invariant→test citations were spot-checked and resolve.

## Open decisions
- DECISION-01: shellcheck 0.10.0 (the version cc-operator's audit found CI-equivalent) was downloaded as a static binary into the session scratchpad, not installed system-wide — reversible (delete the scratchpad dir), touches nothing in the repo.
- DECISION-02: commit/push to the designated branch + draft PR are pre-authorized by this session's standing instructions (the COMMIT gate for those three actions only); no other outward action will be taken.

## End state (after remediation)
Tests: test-hooks 172/0 (+25) · test-config 45/0 (+14) · test-release 62/0 (new) · test-statusline 16/0 · test-e2e 62/0 · test-claim-digest 56/0; `bash tests/run-all.sh` ALL GATES GREEN with shellcheck 0.10.0; Stop hook on 57MB: 1.910s → 0.060s (0.983s worst-case fallback).
Findings: 9 (F01–F09); 9 fixed (F01–F06, F08 in code with red-run tests; F07, F09 by tooling + docs); 0 deferred. Mutation pass: 9/10 pins red (M2 vacuous, documented). Version 0.3.3.
Artifacts: tests/run-all.sh, tests/test-release.sh, .github/workflows/ci.yml (pinned), CLAUDE.md (invariants 14–16, playbooks, couplings, landmines, backlog 5–8), docs/audit-2026-09-02-principal.md (handoff + guardrail catalog + residual risks + backlog), CHANGELOG [0.3.3].

## What's left (for the successor — prioritized in docs/audit-2026-09-02-principal.md)
1. Review + squash-merge the draft PR, tag v0.3.3. 2. Subagent-row corpus (backlog 5). 3. Digest size warning (backlog 6). 4. Non-root run of the chmod cases (backlog 7). 5. UTF-8-safe `_truncate` (backlog 4). Second un-audited repo in this workspace: cc-status-plugin (no cursor).
