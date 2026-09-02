# Principal-architect audit — cc-reload — 2026-09-02

Mode: AUTONOMOUS. Target: `cc-reload-plugin` at `aedcfd5` (0.3.2). Remediation shipped as 0.3.3
on branch `claude/principal-audit-autonomous-hq0q7v`. The living state and the append-only
event log are `AUDIT_STATE.md` / `AUDIT_LOG.md` at the repo root (the admissible finding ledger,
`lint_findings.py` clean, lives in the log). This file is the handoff: what was found, what was
changed, what guards it now, and what is still open — written to be picked up cold.

## Executive summary

**Verdict: salvageable-with-work, close to healthy — and healthy after this pass.** The
fail-open philosophy and the ownership/lineage design (0.3.0) held up under every probe. The
defects were concentrated in the ONE measurement the plugin makes — the transcript scan — plus a
config format the README teaches but no reader parsed, and one fail-closed door in the marker
handshake. No architecture-root issue; the mental model in CLAUDE.md was verified accurate line by
line and is extended, not replaced.

Top risks found (all fixed unless marked):

| ID | Sev | One line | Outcome |
|---|---|---|---|
| F01 | P2 | Stop hook measured whichever agent spoke last; a subagent row restamped the window (on `[1m]` sessions permanently, 5x) | FIXED — main-thread filter; 5 red-run tests |
| F02 | P2 | One malformed transcript line silently swapped the measurement for a byte estimate (3MB → "75%" at 10% real) | FIXED — per-line parse; 3 tests |
| F03 | P2 | Stop hook 1.91s / 275MB RSS on 57MB, over its own ~1s rule | FIXED — tail window + stream, 0.06s; invocation-pinned |
| F04 | P2 | `# comments` in `.reload/config` dropped every value — the README's own example was unparseable; the `context_window` pin vanished silently | FIXED — four readers strip, parity test, README block is a fixture |
| F05 | P2 | A directory at `.reload/summarizing` blocked EVERY ordinary Stop (fail-closed, invariant 2) | FIXED — writers verify `-f`; arm gate `-e`; honest "NOT armed" |
| F06 | P3 | `ANTHROPIC_BASE_URL` userinfo bypassed the loopback allowlist | FIXED — `@` in the authority ends the lookup |
| F07 | P3 | README said v0.3.1 at 0.3.2; no version gate | FIXED — 0.3.3 trio + `tests/test-release.sh` |
| F08 | P3 | Banner dropped an unquoted `intent` | FIXED — frontmatter-scoped `digest_field()` |
| F09 | P3 | Suites hand-listed in CI; shellcheck unpinned | FIXED — `tests/run-all.sh` globs; CI pins 0.10.0 |

Measured sound (no finding — do not spend successor effort here): `CLAUDE_CODE_SESSION_ID` IS in
the model's Bash env (the ownership stamp contract holds); the real transcript schema on this
machine matches the hook's assumptions; PreToolUse costs 17ms per non-digest Write/Edit; kv() CRLF
handling; the `stop_hook_active` guard ordering; the notify ladder; loopback-prefixed hosts are
rejected; every CLAUDE.md line citation resolved; no embedded instructions in docs/skills/commands.

## Baseline → delta (evidence in AUDIT_LOG.md)

| Suite | Before | After |
|---|---|---|
| tests/test-hooks.sh | 147/0 | **172/0** (+25) |
| tests/test-config.sh | 31/0 | **45/0** (+14) |
| tests/test-release.sh | — (new) | **green** (version trio, hooks.json, CI shape, CLAUDE.md citations) |
| test-statusline / test-e2e / test-claim-digest | 16/0 · 62/0 · 56/0 | unchanged, green |
| shellcheck 0.10.0 -S warning, `bash -n`, 4 JSON files | clean | clean |
| Stop hook on 57MB/100k-line transcript | 1.910s, 275MB RSS | **0.060s** (window), 0.983s (fallback with 2500 trailing subagent rows) |

Red-first: every new case was run against the unfixed code first (19 red in test-hooks, 10 red in
test-config), then green after the fix. Mutation pass on a scratch copy: 9 of 10 pins go red on
their mutation (drop the sidechain filter → 4 red; remove the window → 1; remove the `-f`
verification → 2; arm gate back to `-f` → 1; drop the userinfo reject → 1; drop the comment strip
in each reader → 2/5/1; revert the intent parse → 2). The one vacuous mutation — dropping the `?`
from `fromjson?` — is documented in CLAUDE.md: under `-R` jq already continues past a bad line;
the per-LINE mode is the protection and the pin is red against the real regression (the slurp).

## Guardrail catalog (Phase 4.1)

| Invariant (named) | Where it holds | Enforcement | Artifact |
|---|---|---|---|
| main-thread-only scan | `stop-hook.sh` `TURN_SCAN_JQ` | red-run tests | `tests/test-hooks.sh` "sidechain row last: …", "[1m] stamp survives a sidechain row" |
| bad-line-is-skipped | same | red-run tests | "truncated trailing line: …", "a row whose message is a string …" |
| window-then-fallback (≤1 full read) | same | jq-shim INVOCATION pin | "window path: jq never received the transcript path", "no jq invocation slurps", "fallback path: … exactly once" |
| config-readers-agree + comments-stripped | lib.sh `kv`, reload-config `get`, statusline ×3 | fixture parity | `tests/test-config.sh` "reader PARITY", "… strips the comment …"; `tests/test-hooks.sh` "commented context_window pin is honoured", "README still carries the three-line example" |
| marker-writers-verify-`-f` | stop-hook pass 1/2, precompact | red-run tests | "directory at summarizing: … does not block", "pass 2 with an unwritable arm warns …", "over budget with a directory at pending: no re-block", "PreCompact with an unwritable arm warns" |
| loopback-only lookup (no userinfo) | lib.sh `proxy_window` | test beside the three existing privacy cases | "userinfo in the base URL -> no lookup (privacy guard)" |
| frontmatter-scoped banner fields | lib.sh `digest_field` | tests | "unquoted intent still leads the banner", "a body intent: line never reaches the banner" |
| version-trio-agrees | plugin.json / CHANGELOG / README | release gate | `tests/test-release.sh` |
| hooks.json-paths-exist, no-hooks-in-plugin.json, statusline-render-exists | manifests | release gate | `tests/test-release.sh` |
| CI-runs-run-all, shellcheck-pinned | `.github/workflows/ci.yml` | release gate | `tests/test-release.sh` |
| CLAUDE.md-citations-resolve | CLAUDE.md `file.sh:NN` + quoted test names | release gate (caught one paraphrase on its first run) | `tests/test-release.sh` |
| every-suite-runs | `tests/run-all.sh` globs `tests/test-*.sh` | CI calls run-all | `tests/run-all.sh` |

Every guardrail above was RUN green in this session (`bash tests/run-all.sh` → ALL GATES GREEN).

## Tool-level leverage (Phase 4.3)

- `tests/run-all.sh` — one command = what CI runs; globs suites; shellcheck absent → LOUD warning
  with the exact version to install, never a silent pass; `SHELLCHECK=` override.
- `tests/test-release.sh` — the release checklist as code; its failure messages name the exact
  drift (which version, which citation, which CI line).
- Stop hook: honest failure text for an unwritable arm ("reload NOT armed … remove whatever is
  at .reload/pending") instead of a success claim.

## Context transfer (Phase 4.4)

`CLAUDE.md` is the canonical handoff and was extended in place: control-flow diagram updated;
invariants 14–16 with their named tests; the "why a windowed per-line stream" decision with
rejected alternatives; seven couplings rows (scan program, four config readers, marker writes,
version trio, new suites, CLAUDE.md citations); four playbooks (transcript scan, config reader,
marker, releasing); four landmines (subagent-row location varies by version; `tail` is a suffix and
that is the correctness argument; the comment strip is in four places on purpose; `fromjson?`'s
`?` is hygiene); backlog items 5–8.

## Residual risks (known, not fixed)

| Risk | Sev | Conf | Why not fixed | Mitigation in place |
|---|---|---|---|---|
| Subagent-row layout varies by Claude Code version; no corpus here to size `WINDOW_LINES` | P3 | moderate | needs real transcripts from users' versions | filter correct on both layouts; full-file fallback keeps the answer right at the old cost; backlog 5 |
| Rehydrate injects the whole digest, no size cap | P3 | high | a silent truncation would be worse; needs a warning design | template + skill say ~30 lines; backlog 6 |
| `_truncate` byte-slices UTF-8 (bash 3.2, or any bash with `LANG` unset) | P3 | high (measured) | cosmetic; awk fix documented | backlog 4 |
| chmod-based fail-open cases SKIP as root locally | P3 | high | container had no non-root user | CI runs them as a normal user; backlog 7 |
| `SessionStart(resume)` consumes an armed digest into a session that kept its context | P3 | high | accepted trade-off (stamp needed on resume) | documented landmine; backlog 8 |
| Transcript `message.usage` schema is undocumented | P2 | — | outside the plugin's control | byte/4 fallback over-counts (safe direction); documented |

## Backlog (prioritized, pickup-able cold) — also in CLAUDE.md "Backlog"

1. **Release 0.3.3** — context: everything is on the branch; PR is draft — first step: review the
   PR, squash-merge, tag `v0.3.3` on main — done-when: the tag exists and `bash tests/run-all.sh`
   is green on main.
2. **Subagent-row corpus** (CLAUDE.md backlog 5) — first step: from ≥3 real transcripts on the
   versions you run, `jq -r .isSidechain <sid>.jsonl | sort | uniq -c` and `ls <sid>/subagents` —
   done-when: a version→layout table is in CLAUDE.md and `WINDOW_LINES` is justified by it.
3. **Digest size warning** (backlog 6) — first step: a `test-hooks.sh` case with a 200KB digest —
   done-when: SessionStart emits a warning above the cap and still injects in full.
4. **Run the chmod cases as non-root once** (backlog 7) — done-when: `test-claim-digest.sh`
   prints no SKIP under `runuser`.
5. **UTF-8-safe `_truncate`** (backlog 4) — done-when: a banner with multibyte intent renders no
   mojibake under `LC_ALL=C bash`.

## Provenance

Findings F01–F09 are this audit's ids; the 2026-07 audit's F01–F05 cited in CHANGELOG 0.1.9/0.2.1
and CLAUDE.md invariants are a different series. Every claim in this document traces to a command
and its output recorded in `AUDIT_LOG.md`; anything not run is marked as such there ("NOT covered").
