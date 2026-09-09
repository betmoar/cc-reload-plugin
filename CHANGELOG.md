# Changelog

All notable changes to cc-reload are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.2] - 2026-09-09

The digest — the payload the whole plugin exists to carry — had never been improved on its own
merits since v0.1.0. All 460 checks pinned the *transport* (markers, handshake, occupancy scan,
config readers); none pinned the payload. This release pins the format, closes the two ways a
digest silently lost information, gives it repo facts read from `git` instead of recalled, and
lets it report its own staleness. 460 → 605 checks.

### Added
- **Digest section PARITY test** (`tests/test-hooks.sh`, invariant 18) — `templates/session.md` is
  now the declared source of truth for the four section headings, and the three copies that repeat
  them by hand (the pass-1 REINJECT heredoc in `stop-hook.sh`, the mechanical stub in
  `precompact-hook.sh`, the `_first_bullet`/`_first_line` reader in `sessionstart-hook.sh`) are
  pinned to it in both directions: every template heading must appear in the two writers, and every
  heading the banner READS must be one the template defines. Nothing checked this before — a rename
  on either side degraded silently, dropping a line from the banner forever or making it read a
  section no digest would ever have. Same defect class invariant 16 closed for the config readers,
  left open on the payload. Red-verified with four separate mutations.
- **`mission` frontmatter field** — the original ask, written once and copied verbatim on every
  later snapshot, while `intent` tracks where the work stands now. Rewriting the ask on every
  snapshot made it a summary of a summary of a summary; after three resets the north star no longer
  said what was asked for. Free at the parser layer (`digest_field` reads frontmatter generically,
  `claim_digest` already preserves unknown keys) — now pinned by a test that it survives the
  rehydrate claim byte-identical.
- **`scripts/context-block.sh`** — the free-form `git` caller (one of three git call sites — see
  invariant 20): branch, short HEAD, uncommitted
  paths (capped, with a count), `diff --shortstat`, recent commit subjects. Prints **nothing** and
  exits 0 outside a repo, with no `git` on PATH, in an empty repo (no HEAD to resolve), or on a
  broken `.git` — the same fail-open-silent shape as `proxy_window()`. Half a block, or one with
  git's stderr in it, would land in a digest that gets injected into a fresh context as fact.
- **PreCompact's mechanical fallback is now usable.** The worst path in the plugin —
  auto-compaction firing before any agent-authored digest existed — produced three literal
  `(unknown)` lines. It still cannot author prose (no model runs inside a hook), but it now states
  where the repo stood and stamps `head:`, so the one digest that exists *because* nobody wrote one
  is not also the one with no staleness signal.
- **Measured staleness in the rehydrate banner**, two independent axes, both advisory (they never
  gate, never block — invariant 11):
  - `head_drift()` — the digest stamps the short HEAD it was written at; SessionStart counts the
    commits since. A *measured* signal, unlike the mtime `-nt` heuristic.
  - `digest_age_days()` — how long ago the digest was written, from filesystem mtime (never the
    model-written `updated_at`, which is routinely copied forward). This axis has nothing to do
    with occupancy: a session that never crosses the budget is never asked to refresh. Measured in
    this repo: its digest was stamped 2026-07-10 describing v0.1.9 while the repo was on v0.4.1 —
    two months stale, and nothing ever said so.
- **`/snapshot --check`** — an audit path that tests the digest's *content*. Every other gate tests
  the transport: that the digest arrives. Whether it is any **good** cannot be judged from inside
  the session that wrote it, because the author knows what it omits. `--check` dispatches one
  subagent given the digest **alone** — no conversation summary, nothing recalled — and asks what
  it would do next, which files it would open, and what the original ask was. Divergence is the
  defect, surfaced while it can still be fixed. Writes nothing, arms nothing, applies nothing
  silently. The command *contract* is pinned (14 checks), not the verdict: a live subagent is not
  deterministic, so there is no CI fixture suite.
- **`tests/test-context-block.sh`** — 87 checks over real repos built per case (clean, dirty,
  detached HEAD, empty, broken `.git`, non-repo, empty PATH).

### Fixed
- **Every snapshot was a blind overwrite** (invariant 19). `commands/snapshot.md` said "overwrite"
  and never "read the existing digest first", and neither did the REINJECT the model actually sees.
  An Open question raised in one session and untouched in the next died at that next snapshot —
  silently, with nothing left to recover from. All four guidance surfaces (template comment,
  REINJECT, `commands/snapshot.md`, `SKILL.md`) now say: read first, carry unresolved items forward
  verbatim, strike only what is demonstrably resolved. Deliberately instruction rather than
  mechanism — a hook cannot author a digest, and splicing an untrusted model-written body section
  is exactly the corruption `frontmatter_closed` exists to prevent. New e2e cycle 10 pins that the
  instruction is *delivered* at both authoring moments; three of its eight cases were red before.
- **The pass-1 REINJECT gave weaker guidance than the template's own HTML comment.** The text the
  model is actually handed listed four heading names and nothing else, while the template — which
  it may never open — carried the real instructions. The REINJECT now states the quality bar
  directly: *In flight* names files with line numbers, *Next concrete step* is an executable action
  (a command or an edit with a path) and never "continue with X", and the test baseline goes under
  *Open questions & risks* when there is one.
- **The staleness signals refuse to guess.** A confident wrong number is worse than silence: an
  authoritative "0 commits behind" over a badly stale digest is believed by a session that just
  lost its context. Four gates, each found unpinned by mutation testing and each then measured:
  without the anchored hex gate, a `head:` of `HEAD~2` — untrusted digest text — resolves and
  counts as 2; without `^{commit}`, a hex-valid **blob** sha yields `rev-list --count` = 3 with
  exit 0; without `--is-inside-work-tree`, a **bare** repo answers normally and reports drift for a
  directory with no working tree; and without `merge-base --is-ancestor`, a **diverged** stamp
  answers happily. (An unknown sha already fails `rev-list` outright with exit 128, which is why
  pinning the `^{commit}` gate needs a blob and not a made-up sha.)
- **Drift was reported across diverged branches.** `.reload/` is per-project and shared across
  branches by design, so the ordinary sequence — snapshot on a feature branch, switch to main,
  rehydrate — asked `rev-list --count <feature-tip>..HEAD`, which answers happily. Measured: "2
  commits since this digest" for a history the digest's own work is not in at all. The count is
  well-formed and means something else entirely ("commits on HEAD absent from the stamp"), so it
  now requires the stamp to be an **ancestor** of HEAD. Found in review; the first cut's other
  gates all passed this input.
- **`context-block.sh` reported a failed `git status` as a clean tree.** `git status --porcelain`
  prints nothing when it *fails* (corrupt or locked index, I/O error, permissions), and testing
  emptiness alone cannot distinguish that from a genuinely clean tree. Measured with a deliberately
  corrupted `.git/index`: the block asserted "working tree clean" over a tree with uncommitted
  content — a false claim landing in a digest a fresh session is told to trust. Now tests the exit
  status and says the state is unavailable instead. Found in review.
- **Dead code removed:** an explicit clock-skew guard in `digest_age_days()`. A future mtime already
  yields a negative `days` that fails the threshold test (measured: `days=-1157`), so the check
  could not change any outcome — deleting it left every test green, which is the definition of a
  guard that is decorative rather than defensive.
- **The mtime trap, both halves** (invariant 20). `claim_digest` rewrites the digest through a temp
  file + `mv`, and the `mv` stamps a brand-new mtime — measured: a file backdated to 2020 reads as
  `now` immediately after. So the age must be captured *before* the claim (or the signal dies
  within a session), **and** the claim must restore the original mtime afterwards (or it decays
  across sessions: every rehydrate rejuvenates the file, so a digest claimed on each `/clear` reads
  as fresh forever however stale its content). The second half was invisible to the suite and found
  by running the real hook against this repo's own digest — content from 2026-07-10, mtime from
  that morning, because a SessionStart had claimed it. The single case the signal exists for is the
  one it would have missed. Restored with `touch -r` from a reference file, never `date -r` (an
  epoch on BSD, a FILE on GNU — silently wrong on one of the two platforms this runs on).

### Changed
- **`context_owner_window` now measures what it documents.** The collision guard
  (`scripts/claim-digest.sh`) and the new age signal read the SAME number — the digest's mtime — so
  preserving it across a claim moved both. Before 0.4.2 the claim's `mv` restamped it, silently
  renewing the 4h window on every rehydrate: it measured "time since last *claim*". It now measures
  how recently another session *wrote* the digest, which is what the key has always been documented
  to mean. Measured consequence: a digest whose content is older than the window but was rehydrated
  moments ago is no longer side-filed on collision, where before it was. Accepted rather than
  reverted — what goes unprotected there is content nobody has touched in over a window, held in
  the rehydrating session's own context, and its next `/snapshot` restores full protection; the
  case that matters, a session that *wrote* recently, is unchanged. Rejected: widening the default
  (tuning a constant to restore an accident) and a separate "last claimed" marker (drags a
  best-effort guard into the marker discipline of invariant 15). Pinned so the coupling cannot move
  silently again. Found in review.
- `CLAUDE.md` — invariants 18, 19 and 20; an expanded digest-format coupling row naming all four
  guidance surfaces; coupling rows for the git-touching functions and for `/snapshot --check`; and
  decision notes on why the guidance is duplicated across four files (each reaches the model at a
  different moment and none can read the others) and why `mission` is a frontmatter field rather
  than a fifth section (the ~30-line budget is zero-sum, and a section would add a fifth copy to
  everything invariant 18 pins). The same reasoning rejected a standing `## Baseline` section in
  favour of an instruction line.

## [0.4.1] - 2026-09-04

### Added
- **Release workflow (`.github/workflows/release.yml`)** — the tag build now gates and publishes
  itself, the same shape as cc-repete's: a `v<x.y.z>` tag re-runs the full gate
  (`tests/run-all.sh` + the pinned shellcheck container), refuses to ship on any
  tag ≠ `plugin.json` ≠ newest CHANGELOG heading mismatch (`scripts/release-gate.mjs`, ported
  with its 13-case node suite `tests/test-release-gate.mjs`), and publishes the GitHub release
  with that version's CHANGELOG section as the body — release notes are extracted from the
  changelog, never hand-written. `tests/run-all.sh` runs the node suite too (loud skip without
  node, the lint-warning pattern), and `tests/test-release.sh` pins the workflow's shape with
  seven new checks (red-verified: deleting release.yml turns exactly them red).

### Fixed
- **`repete_active()` tolerated a quote per end, diverging from cc-repete's canonical reader
  (issue #14).** cc-repete settled the quote rule in its #30 / PR #31 (v0.2.5): quotes on
  `active:` strip as a both-ends pair or not at all, across all three of its readers. This
  repo's v0.4.0 mirror still matched each end independently, so an asymmetric `active: true"`
  read ACTIVE here while every cc-repete reader read it inactive — cc-reload would stand down
  on a hand edit or torn write against a loop its own engine had exited. No writer emits the
  asymmetric form, so the exposure was hand edits and torn writes only. The regex is now
  `(true|"true")`; the well-formed forms (plain, `"true"`, trailing space, CR) are unchanged,
  and a torn write's bare `active: true` still counts. Two new consumer-side cases, red-first
  (both failed on the v0.4.0 reader) and mutation-verified (reverting the regex turns exactly
  them red).

## [0.4.0] - 2026-09-04

### Fixed
- **A `[1m]`-suffixed or lens-prefixed proxied model stamped a 1M window the vendor does not serve.**
  `proxy_window()` looked up the RAW stamped id in cc-proxy's `/v1/models`, which never carries
  picker spellings (`glm-4.6[1m]`, `qwen:deepseek-v4-pro`) — the exact match missed, the caller
  fell to `model_window()`, and its Claude-oriented `*[1m]* => 1M` rule fired FIRST. A genuinely
  200K proxied id (`glm-4.6[1m]` on Z.ai) was budgeted at 5x the room the vendor serves, so the
  notify/snapshot ladder armed only after the session had already overrun the real limit. Found
  measuring cc-proxy's live `/v1/models` (betmoar/cc-proxy-plugin): cc-proxy strips both the
  variant suffix and the `<provider>:` lens BEFORE the upstream body (Z.ai and the Qwen plan both
  400 a suffixed id), so the vendor always serves the STEM's window — the lookup now resolves the
  same stem (cut at the first `[`, then any `:` prefix). Claude ids are untouched by construction:
  cc-proxy publishes no `context_window` for `claude-*`, the stem lookup misses there too, and the
  F05 `[1m]` 1M-window guard is regression-locked by test. Verified end-to-end against the real
  proxy: `glm-4.6[1m]` → 200000, `glm-5.3[1m]` → 1048576 (previously 1000000 for both via the
  heuristic). Five new stub tests; both strips are mutation-verified (reverting either turns its
  named test red).
- **`repete_active()` read `.repete/loop.local.md` with a bare whole-file grep, wrong in both
  directions (issue #12).** The file is a published contract (declared in cc-repete's CLAUDE.md,
  betmoar/cc-repete-plugin#27): path + `active` key + value `true` in the FIRST frontmatter block,
  with the producer's tolerances. The old grep matched BODY prose quoting `active: true` — a
  torn-down loop whose handoff note still quoted the schema read as LIVE, and cc-reload silently
  stood down forever (no snapshot, no rehydrate) against a loop that was over. It also rejected
  the producer's quoted form `active: "true"` — a live loop read as over, and cc-reload ran
  alongside it, the exact collision the stand-down exists to prevent. The reader now mirrors
  cc-repete's own: first `---` block only, one optional quote layer, one optional trailing CR;
  a torn write (opener, no closer) reads as frontmatter-to-EOF exactly like the producer's
  `fm()`. Eight new cases pin the contract as the consumer reads it; mutation-verified (reverting
  to the bare grep turns the four scope/quote cases red).

## [0.3.3] - 2026-09-02

Principal-architect audit (`docs/audit-2026-09-02-principal.md`): nine findings, seven fixed here
with a red-run test each, two closed by new tooling. A tenth (F10) was found by the review of that
audit and is fixed here too. No behaviour change on the ordinary path.

### Fixed
- **The Stop hook measured whichever agent spoke last, not the main thread** (audit F01). The
  transcript scan took the last `message.role=="assistant"` row with no `isSidechain` filter, so on
  Claude Code versions that append subagent rows to the main transcript a Stop after an Agent
  dispatch read the subagent's tiny usage (no nudge while the main thread was over budget) AND
  restamped `.reload/model` with the subagent's model — a haiku subagent stamped 200K, which on a
  `[1m]`-alias session permanently stripped the invariant-5 shield (5x inflated occupancy from then
  on). Subagent rows are now skipped (`.isSidechain != true` — absent/null keeps the row, so both
  transcript layouts work; current versions write `subagents/*.jsonl` instead).
- **One malformed transcript line silently replaced the measurement with the byte/4 estimate**
  (audit F02). `jq -rs` slurped the file as one array and aborted on a truncated line or a row
  whose `message` is not an object; 3MB of transcript then read as "~75%" where usage was 10%.
  The scan is now per-line (`-R`, `fromjson? | objects`): a bad line is skipped, not fatal.
- **The Stop hook ran over its own ~1s budget on a large transcript** (audit F03). Measured on
  57MB/100k lines: the slurp took 2.25s and 275MB RSS (whole hook 1.91s). The scan now reads a
  `tail -n 2000` window through a stream (0.06s whole hook) and falls back to a full-file stream
  only when the window holds no main-thread row (0.98s worst case measured with 2500 trailing
  subagent rows). A tail window is a suffix, so its last main-thread row is the file's — the
  answer is identical to a full read. The mechanism is pinned by invocation (a `jq` shim), never
  by wall-clock.
- **Inline `# comments` in `.reload/config` silently discarded the value — including in the
  README's own example** (audit F04). Every reader (`hooks/lib.sh` `kv()`, `reload-config.sh get`,
  three inline copies in `statusline.sh`) returned `45   # act at this %…`, failed validation and
  fell back to the default — a hand-written `context_window` pin was dropped, `snapshot` mode
  reverted to notify. All five readers now strip a trailing comment; a reader-parity test pins the
  three that read `.reload/config` to each other, and the README block itself is fed to the Stop
  hook in the suite. The fifth copy reads `.reload/model` — a different file the parity loop cannot
  reach, so it has its own case; deleting its strip failed no test until this release.
- **One mistyped field on the last transcript row reported an EARLIER row's occupancy** (audit
  F10, found reviewing this release). The scan concatenates `tokens<space>model`, so combining
  them in one fallible expression let a wrong TYPE in either half throw for the whole row;
  `tail -n 1` then returned an earlier row and `USED` was a well-formed number that passed every
  validity check, so the byte/4 fallback never fired — a 95% session measured as 2% and nothing
  nudged. Silent-wrong, and strictly worse than the 0.3.2 slurp it replaced (which produced NO
  answer, i.e. the safe over-count). The halves now fail independently (`| numbers`, `| strings`);
  a row with no numeric usage field at all is skipped rather than emitted as `0`.
- **A directory where `.reload/summarizing` should be made pass 1 block on EVERY ordinary Stop**
  (audit F05, fail-closed — invariant 2). `touch` succeeds on a directory, `-f` never matches it,
  `rm -f` never removes it (measured 3/3 blocks). Pass 1 now verifies the marker with `-f` after
  writing it or refuses to block; the arm gate is `-e` so any entry at `.reload/pending` suppresses
  a re-block; pass 2 and PreCompact verify the arm with `-f` and say "reload NOT armed" instead of
  claiming success over an arm that can never rehydrate.
- **`ANTHROPIC_BASE_URL` with userinfo bypassed the loopback allowlist** (audit F06, P3).
  `http://127.0.0.1:4000@evil.example/` parsed as host `127.0.0.1` while curl contacts
  `evil.example`. Any `@` in the authority now ends the lookup — a loopback proxy never needs
  credentials in its URL.
- **The restore banner dropped an unquoted `intent` and truncated an escaped one** (audit F08).
  Read through the new frontmatter-scoped `digest_field()` (quoted or not; a body `intent:` line
  is never read — invariant 8).

### Added
- **`tests/run-all.sh`** — the one local gate: JSON validity, `bash -n`, shellcheck (loud warning
  when absent; CI enforces a pinned 0.10.0), then every `tests/test-*.sh` by glob. CI calls it, so
  a new suite can no longer pass locally and never run in CI (audit F09).
- **`tests/test-release.sh`** — release and structural contracts: the version trio
  (`plugin.json` == newest CHANGELOG heading == README status line — the README said 0.3.1 at
  0.3.2, audit F07), the newest CHANGELOG section has a body, every `hooks.json` command resolves
  through `${CLAUDE_PLUGIN_ROOT}` to an existing script, `plugin.json` declares no hooks, the
  statusline manifest's render path exists, CI invokes `run-all.sh` with a pinned shellcheck, and
  every `file.sh:NN` citation and quoted test name in CLAUDE.md resolves (it caught one paraphrase
  on its first run).
- `hooks/lib.sh` `digest_field <key>` — frontmatter-scoped field read; `digest_owner()` is now
  `digest_field session_id`.

### Changed
- CI pins shellcheck 0.10.0 (container) instead of whatever `ubuntu-latest` ships, and runs
  `tests/run-all.sh` instead of a hand-kept suite list.
- CLAUDE.md: the transcript-scan decision rewritten (windowed stream, not a slurp), three new
  invariants (14–16), couplings rows for the scan program / the config readers / marker
  writers / the version trio, per-component playbooks, and a refreshed backlog.
- `tests/test-hooks.sh` scrubs `ANTHROPIC_BASE_URL` before invoking a hook. It was inherited, so on
  a machine running cc-proxy (the maintainer's) `proxy_window()` answered the `model_window()` table
  cases for real and the suite went red on an untouched tree — while CI, with no proxy on the
  runner, stayed green. The one documented gate lied exactly where the code is written.
- CLAUDE.md and `hooks/lib.sh` count the config readers correctly: THREE read `.reload/config` (the
  parity loop's reach), a fifth strip reads `.reload/model`. The old "four readers" wording hid that
  the `.reload/model` copy was pinned by nothing.
- The "500 trailing sidechain lines" figure is attributed as cc-repete's stated design margin, not
  a corpus measurement; its "75 real transcripts" figure counts user-row shapes for turn-boundary
  detection and is no longer welded to it.
- The `tokens<space>model` output contract is pinned at the seam. The consumer's "no space at all"
  branch reads as dead code — `TURN_SCAN_JQ` always emits the trailing space — but `${LAST_TURN#* }`
  returns the string UNCHANGED without one, so a tokens-only line would flow on as a model id and
  stamp `.reload/model` with `model: 500000` (measured), destroying window resolution and the `[1m]`
  shield for the session. It is a contract guard, not dead code, and is now labelled and tested as
  one.
- The scan's performance numbers are labelled: `stop-hook.sh` quotes SCAN-ONLY timings (slurp 2.25s,
  full-file stream 0.85s, window 0.03s) while CLAUDE.md invariant 14 quotes WHOLE-HOOK timings for
  the same run (1.91s → 0.06s, 0.98s fallback). Both were correct and neither said which it was.

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
