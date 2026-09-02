# AUDIT_LOG — cc-reload-plugin — principal-architect audit (append-only)

- 2026-09-02 START: mode AUTONOMOUS; workspace holds five repos; cc-operator/cc-proxy/cc-repete cursors read DONE (2026-08-31); cc-reload chosen (un-audited, largest blast radius of the two remaining); cc-status is the fallback second target.
- 2026-09-02 P1: baseline captured BEFORE any change — test-hooks 147/0, test-statusline 16/0, test-config 31/0, test-e2e 62/0, test-claim-digest 56/0; `bash -n` clean; 4 JSON files valid; shellcheck 0.10.0 -S warning clean (scratchpad binary; DECISION-01). Tree clean at aedcfd5.
- 2026-09-02 P1: entry points traced: hooks/hooks.json → sessionstart/precompact/stop/pretooluse hooks (all source hooks/lib.sh); commands → scripts/reload-config.sh + scripts/claim-digest.sh; statusline via .claude-plugin/statusline.json → scripts/statusline.sh.
- 2026-09-02 P1: CLAUDE.md control-flow block verified line-by-line against stop-hook.sh / sessionstart-hook.sh — accurate. Invariant→test citations spot-checked (13 named tests) — all resolve.
- 2026-09-02 P1: load-bearing inventory (12 entries) + implicit contracts IC1–IC11 written to AUDIT_STATE.md. IC11 CONFIRMED broken: README says v0.3.1, plugin.json/CHANGELOG say 0.3.2.
- 2026-09-02 P1: EXIT CRITERIA met (map, inventory with blast radius, contracts, delta). Cursor → P2.

## Phase 2 — probes (all read-only, run in the session scratchpad against the real hooks)

- 2026-09-02 P2: IC4 MEASURED SOUND — `CLAUDE_CODE_SESSION_ID` IS present in this real session's Bash-tool env (value = the session uuid); cc-operator's note concerns a different variable name. /snapshot's owner stamp contract holds. Not a finding.
- 2026-09-02 P2: real transcript schema checked on this machine (`~/.claude/projects/-home-user/<sid>.jsonl`, 153 rows): top-level `isSidechain` on every message row (false/null), assistant rows carry `message.usage.{input_tokens,cache_read_input_tokens,cache_creation_input_tokens}`, 0 malformed lines. A haiku subagent dispatched from this session wrote its rows to `<sid>/subagents/agent-<id>.jsonl`, NOT the main file — so in THIS Claude Code version the IC1 trigger does not occur for Agent-tool subagents; cc-repete carries the same `isSidechain != true` filter (`cc-repete-plugin/hooks/stop-hook.sh:442,450`) and its stop-hook comment (`:384`) cites "500 trailing sidechain lines" as the margin a naive tail-bound must survive. NOTE the provenance: that 500 is cc-repete's stated design margin, NOT a corpus measurement — its "75 real transcripts" figure (`cc-repete-plugin/CLAUDE.md:318`) counts user-row content SHAPES for turn-boundary detection and says nothing about sidechain-row counts. Do not weld the two numbers together.
- 2026-09-02 P2: IC1 REPRODUCED against stop-hook.sh: main 500k (50%) then a sidechain haiku row 20k LAST → hook silent (no nudge) AND `.reload/model` restamped `claude-haiku-4-5-20251001 / 200000`. Escalation reproduced: stamp `claude-sonnet-4-5[1m]`/1M → sidechain haiku row → stamp becomes haiku/200K → next main-thread turn restamps the BARE `claude-sonnet-4-5-20250929` at 200K (the [1m] shield is gone for the rest of the session: 5x inflated occupancy, the F05 downgrade re-entering through a different door).
- 2026-09-02 P2: IC2 REPRODUCED: transcript = one valid 100k row + one truncated row + 3MB padding → hook reports "~75%" (byte/4 fallback) where the real usage was 10%. `jq -rs` aborts the WHOLE parse on one bad line; a per-line `fromjson?` stream reads the valid row (measured: slurp → empty, stream → `500000 claude-opus-4-8`). A row whose `message` is a string also aborts the slurp (`Cannot index string with string "role"`).
- 2026-09-02 P2: PERF measured on a 57MB/100k-line synthetic transcript: `jq -rs` slurp 2.248s, peak RSS 275,160 KB; whole current Stop hook 1.910s (CLAUDE.md budget: "never slower than ~1s"); full-file `jq -R` stream 0.854s; `tail -n 2000 | jq -R` 0.028s. Fixed per-call costs: Stop hook 30ms (tiny transcript), PreToolUse 17ms on a non-digest path / 50ms when the guard fires.
- 2026-09-02 P2: IC3 REPRODUCED: a DIRECTORY at `.reload/summarizing` → three consecutive ORDINARY Stops (no stop_hook_active) each returned `decision: block` (pass 1 re-enters forever: `touch` succeeds on a dir, `-f` never true, `rm -f` never removes it). A directory at `.reload/pending` → SessionStart(clear) with a digest present printed nothing (never rehydrates) while pass 1 keeps blocking.
- 2026-09-02 P2: IC5 REPRODUCED with a logging curl stub: `ANTHROPIC_BASE_URL=http://127.0.0.1:4000@evil.example/` passes the loopback allowlist and curl is invoked with `http://127.0.0.1:4000@evil.example/v1/models`; real curl parses that as userinfo `127.0.0.1:4000` @ host `evil.example` ("Could not resolve host: evil.example" — it tried). `http://localhost@evil.example:80` is (accidentally) rejected because the port-cut runs first.
- 2026-09-02 P2: README config example REPRODUCED unparseable: the three-line block under README "Configuration" (the `context_*` lines) copied verbatim into `.reload/config` reads back as `45       # act at this %…`, `notify  # notify…`, `1000000      # AUTHORITATIVE…` through lib.sh `cfg`, `reload-config.sh get` AND statusline.sh. Consequence measured: `context_window: 200000  # …` pinned, stamp 1M, 150k used (75% of the pin) → hook silent (pin dropped, 15% of 1M).
- 2026-09-02 P2: checked and SOUND (no finding): claim_digest awk `-v` escape class (a session id never carries `\`; recorded as a boundary), PreToolUse latency, kv() CRLF handling, `.stop_hook_active` guard ordering, notify ladder arithmetic, the loopback-prefixed-host case (`127.0.0.1.evil.com` rejected), all CLAUDE.md line-number citations (stop-hook.sh:69 / precompact-hook.sh:24 both hold the PENDING write), no embedded instructions in docs/skills/commands, hooks.json valid, CI suite list == tests/ dir (an earlier diff was my own regex missing the digit in `e2e`).
- 2026-09-02 P2: NOT covered (logged, not silent): no non-root user in this container, so the chmod-based unwritable-dir cases ran as SKIP (CI runs them as a normal user); no live Claude Code UI to observe hook output rendering; no older-Claude-Code transcript corpus to measure how often sidechain rows share the main file today.

## Phase 2 — findings (admissible schema; IDs are this audit's, sequential from F01)

### [F01] The Stop hook reads whichever agent spoke last, not the main thread
- **Location:** hooks/stop-hook.sh:111-117 (`jq -rs '[ .[] | select(.message.role=="assistant") ] | last …'`), consumed at :118-164 (USED, LIVE_MODEL, restamp)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — mechanism reproduced in the scratchpad (P2 log entry "IC1 REPRODUCED"); the FIELD trigger is version-dependent: this session's Claude Code writes subagent rows to `<sid>/subagents/*.jsonl`, while cc-repete filters `isSidechain` in-file (`cc-repete-plugin/hooks/stop-hook.sh:442,450`), its `:384` comment citing "500 trailing sidechain lines" as a design margin (not a corpus measurement — see the P2 log entry)
- **Failure trigger:** any transcript whose last `message.role=="assistant"` row is a subagent's (`isSidechain:true`) — a Stop that follows an Agent-tool dispatch on a Claude Code version that appends sidechain rows to the main transcript
- **Blast radius:** SILENT. (a) occupancy is the subagent's small input count → no nudge/block while the main thread is over budget (auto-compaction fires — the failure the plugin exists to prevent). (b) `.reload/model` is restamped with the subagent's model: a haiku subagent stamps 200K; on a `[1m]`-alias session the shield is then permanently lost (next main turn restamps the bare id at 200K) → 5x inflated occupancy and false nudges/forced snapshots for the rest of the session
- **Evidence:** scratchpad repro: main 500k + sidechain haiku 20k last → output `[]`, `.reload/model` = `claude-haiku-4-5-20251001 / 200000`; escalation: stamp `claude-sonnet-4-5[1m]` → after one sidechain row and one main turn the stamp reads `claude-sonnet-4-5-20250929 / 200000`
- **Fix:** filter the scan to main-thread rows — `select((.message|type)=="object" and .message.role=="assistant" and .isSidechain != true)` (null/absent field keeps the row, so both transcript schemas work). Ships inside the F02/F03 streaming rewrite
- **Guardrail:** tests/test-hooks.sh cases "sidechain row last → main thread still measured" and "[1m] stamp survives a sidechain haiku row" (red on the current code); CLAUDE.md couplings row for the transcript scan program

### [F02] One malformed transcript line silently replaces the measurement with a byte estimate
- **Location:** hooks/stop-hook.sh:111 (`jq -rs` slurps the whole file as one JSON array) → :120-122 (fallback `wc -c / 4`)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced (P2 log entry "IC2 REPRODUCED"); the class is documented as observed in the field by the sibling plugin (`cc-repete-plugin/hooks/stop-hook.sh:340-347`, its v0.1.4 fix)
- **Failure trigger:** a transcript containing one line that is not valid JSON (a partial write read mid-append, a truncated tail) or one row whose `message` is not an object (`Cannot index string with string "role"`)
- **Blast radius:** SILENT wrong measurement: the byte/4 estimate over-counts by an order of magnitude on a large transcript (3MB → "75%" where usage was 10%); in notify mode a false nudge, in snapshot mode a forced snapshot turn (model tokens spent, work interrupted)
- **Evidence:** valid 100k row + truncated row + 3MB padding → `🔔 … context ~75%`; slurp on the same file prints nothing; `jq -rR 'fromjson? | …'` prints `500000 claude-opus-4-8`
- **Fix:** parse per line with `fromjson?` and an object guard on `.message` (jq skips a bad line instead of aborting), take the last matching row. Same change as F03
- **Guardrail:** tests/test-hooks.sh cases "a truncated trailing line does not blank the measurement" and "a row whose message is a string is skipped" (red on the current code)

### [F03] The Stop hook exceeds its own ~1s budget and holds the whole transcript in memory
- **Location:** hooks/stop-hook.sh:111-117 (`-s` slurp); the budget is stated in CLAUDE.md "Never make the Stop hook slower than ~1s on a large transcript"
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — measured (P2 log entry "PERF measured")
- **Failure trigger:** a transcript in the tens of MB — exactly the near-budget session the hook exists to catch (the plugin's own comment at :108: "the transcript is tens of MB near budget")
- **Blast radius:** degraded, not silent-wrong: 1.9s added to EVERY turn end near budget, 275MB peak RSS per Stop; on a slow disk/laptop this is the hook users disable
- **Evidence:** 57MB/100k lines: slurp 2.248s / 275,160 KB RSS, whole hook 1.910s; full-file stream 0.854s; `tail -n 2000 | jq -R` 0.028s
- **Fix:** read a `tail -n 2000` window through the streaming program first; only if it holds no main-thread assistant row, stream the whole file (O(1) memory, still one pass). The window covers cc-repete's documented 500-sidechain-line hazard 4x over; the fallback keeps correctness when it does not
- **Guardrail:** tests/test-hooks.sh case "a window with no main-thread assistant row falls back to the full file" (mechanism pinned by an INVOCATION observable, not wall-clock: the jq program must never see a slurp flag); the perf number is re-measured by hand and recorded in CLAUDE.md, never asserted in CI (flake generator)

### [F04] Inline `# comments` in `.reload/config` silently discard the value — and the README's own example uses them
- **Location:** hooks/lib.sh:44-48 (`kv()`), scripts/reload-config.sh:36-37 (`get`), scripts/statusline.sh:48-49, :55-56, :76-77 (three inline copies; the :55-56 one reads .reload/model, not .reload/config); README "Configuration" (the example block)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced (P2 log entry "README config example REPRODUCED unparseable")
- **Failure trigger:** a user copies the README's `.reload/config` block (or writes `context_window: 200000  # my model`) by hand instead of through `/reload-budget`
- **Blast radius:** SILENT: every key reads as `<value>   # comment`, fails its `^[0-9]+$`/enum validation, and falls back to the default — the `context_window` pin (the documented "precise fix for a brand-new model id") is dropped, `snapshot` mode reverts to notify, a lowered budget reverts to 45. Measured: pin 200k + 150k used → no nudge
- **Evidence:** the three readers each returned `45       # act at this % of the window…` etc. for the verbatim README block; statusline rendered `ctx[200k]` from the payload, ignoring the 1M pin in the same file
- **Fix:** strip `[[:space:]]*#.*$` in every reader (four sites) — values are numbers and enums, `#` is never legitimate content — and keep the README example as-is (it is the natural shape). Add a reader-parity test so the four copies cannot drift
- **Guardrail:** tests/test-config.sh "config reader parity" block: one fixture set read through lib.sh `cfg`, `reload-config.sh get`, and statusline.sh; plus the README block itself fed to the Stop hook (pin honoured → nudge). CLAUDE.md couplings row for the four readers

### [F05] A non-regular entry at `.reload/summarizing` makes pass 1 block on every ordinary Stop (fail-CLOSED)
- **Location:** hooks/stop-hook.sh:204 (`touch "$SUMMARIZING" 2>/dev/null || exit 0` — succeeds on a directory), :53 and :61 (`-f` test / `rm -f` never match a directory); the same shape at :198 (`[ ! -f "$PENDING" ]`) and :69-71 (arm write)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced (P2 log entry "IC3 REPRODUCED"): 3/3 ordinary Stops returned `decision: block`
- **Failure trigger:** a directory (or any non-regular entry) at `.reload/summarizing` — a stray `mkdir`, a tooling mistake, a restored backup; contrived but the repo's own invariant 2 ("Never block without the marker on disk") is what fails
- **Blast radius:** fail-CLOSED in snapshot mode: every ordinary over-budget Stop is a forced snapshot turn (the F01/audit-0.1.9 failure, reached from a different door); with `pending` as a directory the arm can never be written (`printf >` fails, `touch` "succeeds"), SessionStart never rehydrates, and pass 1 keeps blocking. Fails loud in the sense of an unmissable nag, silent about WHY
- **Evidence:** scratchpad repro: `mkdir .reload/summarizing` → three consecutive Stops without `stop_hook_active` each emitted `decision: block`; `mkdir .reload/pending` → SessionStart(clear) printed nothing with a digest present
- **Fix:** (a) pass 1: after `touch`, require `[ -f "$SUMMARIZING" ]` or refuse to block (same fail-open rule as an unwritable marker); (b) pass 1's arm gate uses `-e`, so any existing entry suppresses re-blocking (fail-open); (c) pass 2 and PreCompact verify the arm is a regular file after writing and say so when it is not
- **Guardrail:** tests/test-hooks.sh cases "a directory at summarizing never blocks" and "a directory at pending: no re-block, honest warning" (red on the current code); a one-line rule in CLAUDE.md: every marker WRITER verifies `-f` after writing, because every READER tests `-f`

### [F06] The loopback allowlist can be bypassed with userinfo in `ANTHROPIC_BASE_URL`
- **Location:** hooks/lib.sh:223-231 (host parse cuts at the first `:` or `/`, never at `@`)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced with a logging curl stub and with real curl's resolver attempt (P2 log entry "IC5 REPRODUCED")
- **Failure trigger:** `ANTHROPIC_BASE_URL=http://127.0.0.1:4000@evil.example/` (host parse yields `127.0.0.1`, curl's authority parse yields host `evil.example`)
- **Blast radius:** the plugin's stated contract ("must never phone out" — lib.sh:202-205, README) is violated with one GET of `/v1/models` (no credentials, no project data). Marginal in practice: whoever controls that variable already redirects the session's whole API traffic. Rated P3 for that reason, not for the parse
- **Evidence:** stub log: `http://127.0.0.1:4000@evil.example/v1/models`; real curl: `Could not resolve host: evil.example`
- **Fix:** reject any authority containing `@` before the host parse (`case "$auth" in *@*) return 1;; esac`) — a loopback proxy never needs userinfo
- **Guardrail:** tests/test-hooks.sh case "userinfo in the base URL → no lookup (privacy guard)" beside the existing three privacy-guard cases

### [F07] The version trio disagrees (README still says v0.3.1) and nothing gates it
- **Location:** README.md:13 (`Status: **v0.3.1.**`) vs .claude-plugin/plugin.json (`0.3.2`) vs CHANGELOG.md newest heading (`[0.3.2]`); CLAUDE.md "How to change things safely" names no version gate; .github/workflows/ci.yml has none
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — read directly (P2 sweep "version trio")
- **Failure trigger:** every release: the 0.3.2 bump commit (aedcfd5) touched plugin.json + CHANGELOG and missed the README line
- **Blast radius:** users read a stale version; a future bump that misses plugin.json (the plugin cache key) ships an update nobody receives — the higher-blast half of this drift has no detector either
- **Evidence:** `jq -r .version` → 0.3.2; `grep -m1 '^## \['` → [0.3.2]; README:13 → v0.3.1
- **Fix:** correct README.md:13; add tests/test-release.sh asserting plugin.json version == newest CHANGELOG heading == README status version, wired into run-all + CI
- **Guardrail:** the test itself; CLAUDE.md couplings row "plugin.json version → CHANGELOG heading + README status line (tests/test-release.sh)"

### [F08] The restore banner drops an unquoted `intent` and truncates an escaped one
- **Location:** hooks/sessionstart-hook.sh:108 (`awk -F'"' '/^intent:/{print $2; exit}'`)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced: `intent: unquoted intent` → `[]`; `intent: "has \"inner\" quotes"` → `[has \]`
- **Failure trigger:** a model writes the frontmatter `intent` without quotes (the template shows quotes, the REINJECT brief shows quotes, but neither is enforced) or with an escaped inner quote
- **Blast radius:** cosmetic — the banner's lead phrase is missing/garbled; `additionalContext` still carries the full digest. Also scoped to the whole file, not the frontmatter (a body line `intent:` wins if the frontmatter has none) — untrusted-body class, cosmetic here
- **Evidence:** the three awk probes above (P2 log, "INTENT parse")
- **Fix:** read it with the frontmatter-scoped awk `digest_owner()` already uses, generalised to `digest_field <key>` (strip surrounding quotes only when both are present)
- **Guardrail:** tests/test-hooks.sh cases "unquoted intent still leads the banner" and "a body intent: line never reaches the banner"

### [F09] Adding a test suite requires editing CI by hand, and CI's shellcheck is unpinned
- **Location:** .github/workflows/ci.yml:34-40 (five suites listed by name), :16 (`apt-get install -y … shellcheck`, unpinned); README.md:215 and CLAUDE.md "How to change things safely" repeat the list
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — read directly; the identical landmine is documented in cc-repete's CLAUDE.md couplings table ("a suite missing from CI passes locally and never runs on a tag")
- **Failure trigger:** a contributor adds tests/test-foo.sh and runs it locally; CI never runs it. Separately: a new Ubuntu image ships a newer shellcheck with a new warning → CI goes red on an untouched tree
- **Blast radius:** a guardrail that exists on disk but never runs (the false-signal class this audit exists to remove); workflow friction
- **Evidence:** ci.yml lists `bash tests/test-hooks.sh` … `bash tests/test-claim-digest.sh` literally; no tests/run-all.sh exists; shellcheck version unspecified (local machine had none at all)
- **Fix:** tests/run-all.sh that globs `tests/test-*.sh`, runs shellcheck when available (warns loudly when not), JSON validation and `bash -n`; CI calls it; pin shellcheck to the 0.10.0 release tarball as cc-operator's CI does
- **Guardrail:** run-all.sh globs, so a new suite cannot be forgotten; tests/test-release.sh asserts ci.yml invokes run-all.sh
- 2026-09-02 P2: EXIT CRITERIA met — a further sweep pass (statusline, reload-config, precompact, commands, skill, CI, docs) surfaced nothing new above P3; lint_findings.py: 9 findings, 0 problems; self-verification: all nine reproduced or read directly, none dropped/downgraded. Cursor → P3.
- 2026-09-02 P3: plan — write the locking tests first (red on aedcfd5), then the smallest fix per finding, then green; baseline to beat: hooks 147/0, statusline 16/0, config 31/0, e2e 62/0, claim-digest 56/0.
- 2026-09-02 P3: locking tests written FIRST and run RED on aedcfd5 — test-hooks 153 passed / 19 FAILED (all new cases), test-config 35 / 10 FAILED (all new). Baseline cases untouched.
- 2026-09-02 P3: fixes applied — stop-hook.sh: ONE per-line jq program (`TURN_SCAN_JQ`: `fromjson? | objects`, object-guarded `.message`, `.isSidechain != true`) read through a `tail -n 2000` window with a full-file stream fallback (F01/F02/F03); pass-1 marker verified `-f` after `touch`, arm gate `-e`, pass-2 arm verified `-f` with an honest "reload NOT armed" (F05); precompact-hook.sh arm verified (F05); lib.sh kv() strips `# comments` (F04), proxy_window rejects `@` in the authority (F06), `digest_field()` added and `digest_owner()` delegates (F08); reload-config.sh get + statusline.sh ×3 strip comments (F04); sessionstart-hook.sh INTENT via digest_field (F08).
- 2026-09-02 P3: GREEN after fixes — test-hooks 172/0, test-statusline 16/0, test-config 45/0, test-e2e 62/0, test-claim-digest 56/0; shellcheck 0.10.0 clean; bash -n clean.
- 2026-09-02 P3: VERIFY each fix against its ORIGINAL repro (same scratchpad fixtures): R1 sidechain-last → "context ~50%" nudge, stamp stays `claude-opus-4-8 / 1000000`; R2 truncated line → silent (10% measured, was "~75%"); R3 directory at summarizing → 3/3 ordinary Stops decision=none (was block ×3); R4 userinfo URL → curl NOT called, window 1M (control `http://[::1]:4000` still fires); R5 README block → "context ~75%" nudge (pin honoured); R6 whole Stop hook on 57MB: 0.060s (was 1.910s); fallback with 2500 trailing sidechain rows: 0.983s.
- 2026-09-02 P3: MUTATION pass on a scratch copy (each pin must go red): M1 drop sidechain filter → 6 FAIL (4 named); M2 `fromjson?`→`fromjson` → 0 FAIL (VACUOUS — under -R jq continues past a bad line; the `?` is stderr hygiene, the per-line mode is the protection; the pin IS red against the slurp regression, recorded in CLAUDE.md); M3 remove the window → 1; M4 remove -f verification → 2; M5 arm gate back to -f → 1; M6 drop userinfo reject → 1; M7 drop kv() strip → 2; M8 revert intent parse → 2; M9 reload-config get without strip → 5; M10 statusline first copy without strip → 1. Control (unmutated copy): 172/0, 45/0.
- 2026-09-02 P3: EXIT CRITERIA met — every fix verified green with output above; nothing deferred from F01–F06/F08; F07/F09 land in P4 tooling. Cursor → P4.
- 2026-09-02 P4: tools written — tests/run-all.sh (globs suites; JSON + bash -n + shellcheck-with-loud-WARN + suites; verified: WARN text printed when shellcheck is absent, exit 0 only when all gates pass) and tests/test-release.sh (version trio, CHANGELOG body, marketplace name, hooks.json paths via ${CLAUDE_PLUGIN_ROOT}, no hooks in plugin.json, statusline render exists, every hook sources lib.sh, commands reach scripts via the plugin root and name existing scripts, ci.yml invokes run-all + pins shellcheck + hand-lists nothing, run-all globs, every CLAUDE.md `x.sh:NN` citation resolves and the PENDING row's land ON the arm write, every quoted test name in an invariant's "(Tests: …)" list is a real ck/header label).
- 2026-09-02 P4: test-release.sh first run on the unbumped tree: RED on README 0.3.1, ci.yml ×3, and ONE real CLAUDE.md paraphrase ("unwritable .reload -> no block" vs the header ".reload unwritable -> silent") — corrected in CLAUDE.md. Two matcher defects found and fixed in the gate itself: `grep -q` in a pipeline under `set -o pipefail` reads a MATCH as failure (SIGPIPE upstream) — rewritten to capture output; wrapped doc lines carried indentation into the name — whitespace squeezed.
- 2026-09-02 P4: release-gate self-mutations (must go red): README version → 0.3.9 → red "README status line is the plugin version"; paraphrase "notify never blocks" → red; ci.yml hand-lists a suite → red ×2 (invokes run-all / hand-lists). Each restored byte-identical (git status shows only intended files).
- 2026-09-02 P4: CI rewritten (.github/workflows/ci.yml): jq install; shellcheck 0.10.0 in koalaman/shellcheck-alpine:v0.10.0 (the cc-operator pin) with the version printed; then `bash tests/run-all.sh`. Version bump 0.3.3: plugin.json + CHANGELOG [0.3.3] (full entry) + README status line. README: layout (run-all, test-release), config comments allowed, occupancy paragraph names the main-thread/window read. CLAUDE.md: control flow, invariants 14–16, decision rewrite, 7 couplings rows, 4 playbooks, 4 landmines, backlog 5–8. Handoff doc: docs/audit-2026-09-02-principal.md.
- 2026-09-02 P4: FINAL GATE `SHELLCHECK=<0.10.0> bash tests/run-all.sh` → ALL GATES GREEN, rc=0. Suites: claim-digest 56/0 config 45/0 PASS  tests/test-e2e.sh — RESULT: 62 passed, 0 failed hooks 172/0 release 62/0 statusline 16/0 . shellcheck clean, bash -n clean, 4 JSON valid.
- 2026-09-02 P4: EXIT CRITERIA met — guardrails exist and ran green; playbooks + handoff doc + backlog on disk. Cursor → DONE (STOP CONDITION 5). Next: commit + push to the designated branch + draft PR (pre-authorized, DECISION-02); nothing else outward.

## Review response — maintainer commit 4e0b708 (2026-09-02, after the PR was un-drafted)

### [F10] A mistyped field on the last transcript row silently reported an EARLIER row's occupancy
- **Location:** hooks/stop-hook.sh `TURN_SCAN_JQ` as shipped in 408dbc1 (the F01/F02/F03 rewrite): `(((.message.usage // {}) | (a+b+c)) | tostring) + " " + (.message.model // "")` — one fallible expression for both halves
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — found by the maintainer's review of this audit (commit 4e0b708); reproduced here against the 408dbc1 scan and against the fix (this log entry's "REVIEW-RESPONSE VERIFY")
- **Failure trigger:** the last main-thread assistant row carries a non-string `model` (or a non-numeric `input_tokens`/cache field) while an earlier row is well-formed
- **Blast radius:** SILENT-WRONG: the throwing row is dropped, `tail -n 1` returns the previous row, `USED` is a well-formed number that passes every validity check, so the byte/4 fallback never fires — measured: a 95% session reported as the earlier row's 2%, no nudge. Strictly worse than the 0.3.2 slurp it replaced (which produced NO answer, i.e. the safe over-count). Introduced by this audit's own P3 fix
- **Evidence:** scratchpad: rows [20k opus, 950k `model:123`] → 408dbc1 scan output `[]` (silent, 2% read); 4e0b708 scan → `🔔 cc-reload · context ~95%`. Mutation on a scratch copy of 4e0b708: removing `| numbers` / `| strings` → 2 FAIL ("non-string model on the last row…", "string input_tokens: row skipped…"); control 177/0
- **Fix:** (shipped in 4e0b708) the halves fail independently — usage fields collected `| numbers` and summed, model `| strings // ""`; a row with no numeric usage field is SKIPPED rather than emitted as `0`
- **Guardrail:** tests/test-hooks.sh "non-string model on the last row: its 95% is still measured (not the earlier 2%)", "string input_tokens: row skipped, the last MEASURABLE row (50%) is used", "non-object usage: row skipped…" (each with a no-stderr companion); CLAUDE.md invariant 14 rule four

- 2026-09-02 REVIEW-RESPONSE VERIFY (maintainer's 4e0b708, pulled --ff-only): F10 reproduced on the 408dbc1 scan (output `[]` = silent, earlier 2% row) and confirmed fixed (95% nudge). Full gate on 4e0b708 with shellcheck 0.10.0: ALL GATES GREEN — hooks 177/0 (+5), config 46/0 (+1), release 65/0 (+3), e2e 62/0, claim-digest 56/0, statusline 16/0. Mutations on a scratch copy: F10 guards removed → 2 red; the FIFTH strip (statusline's `.reload/model` `window:` reader) removed → 1 red ("statusline strips the comment on .reload/model's window: line") — the copy this audit's "four readers" count had left unpinned, as the review states. The `ANTHROPIC_BASE_URL` inheritance in tests/test-hooks.sh could NOT be reproduced here (no cc-proxy answering on loopback: 408dbc1 ran 172/0 with `ANTHROPIC_BASE_URL=http://127.0.0.1:9`); the scrub is correct regardless and stays. Own miss recorded: the F03 rewrite introduced F10 — a silent-wrong shape the 0.3.2 slurp did not have — and its 2 new cases (malformed line, message-string row) exercised only shapes where the whole ROW failed, never one where a single FIELD did. Lesson for the successor is in CLAUDE.md invariant 14.
