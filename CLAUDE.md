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
model/window stamp (`model`, one `session:` line per session since 0.5.0), per-project config
(`config`), side-filed digests from a detected cross-session collision (`session.<id>.md`, since
0.3), and — since 0.5.0 — per-lineage arms (`pending.<pid>`, keyed on the Claude Code PROCESS id,
which `/clear` keeps) and an append-only `journal` of every snapshot/arm/side-file/rehydrate. The
fourth hook, `PreToolUse`, is a same-session enforcement point for the collision guard (and the
journal's `snapshot` writer), not a new continuity mechanism. There is no daemon, no state anywhere
else, and no network on the per-turn hot path — SessionStart makes one optional loopback-only
lookup against a local cc-proxy (see the `proxy_window()` decision below), fail-open, never
repeated per-turn. User-facing docs: README (short) + `docs/how-it-works.md`,
`docs/concurrent-sessions.md`, `docs/statusline.md`.

## Control flow (the whole system)

```
Stop hook (every turn end)
  ├─ summarizing marker present AND not another LIVE process's (invariant 22)?
  │     → PASS 2: consume marker; if digest exists, arm THIS lineage's slot (lib.sh arm_reload:
  │     `pending.<CLAUDE_PID>`, else bare `pending`) and VERIFY it with -f
  │     (not a regular file → "reload NOT armed", never "saved")
  │     (fresh digest → success msg; digest not rewritten this turn → arm anyway, warn honestly;
  │      no digest → do NOT arm, warn)
  │  (occupancy below = the last MAIN-THREAD assistant row of a tail window of the transcript,
  │   per-line parsed; full-file stream only if the window holds none — invariant 14)
  ├─ stop_hook_active && no marker? → stand down (broken handshake must never re-block = loop)
  ├─ occupancy < budget?          → clear the `notified` ladder, exit silently
  └─ occupancy ≥ budget           → branch on context_budget_mode (default notify):
        ├─ snapshot mode AND not armed_here (no consumable arm entry; a foreign LIVE arm does
        │   NOT count — F12; a stray directory DOES: -e, invariant 15)   [legacy `checkpoint` aliases here]
        │   → PASS 1: unless another LIVE process's `summarizing` sits there (then notify instead),
        │     write `summarizing` (sid + pid) and VERIFY it with -f (or refuse to block),
        │     emit {decision:"block"} re-injecting "write .reload/session.md, then STOP"
        └─ notify mode, OR snapshot mode already armed_here
            → laddered nudge: {systemMessage} only — never blocks, zero model tokens.
              Fires on first crossing, then only at last-notified +10 points (`notified`
              stores the %). Ladder unwritable → silent (else it would nag every turn).

PreCompact hook (manual /compact or auto-compaction)
  └─ arm this lineage's slot (arm_reload); on failure journal `arm-failed` (CC DISCARDS PreCompact's
     systemMessage — the SessionStart(compact) that follows surfaces it); if no digest exists,
     write a mechanical fallback stub (honest about being thin)

SessionStart hook (startup|resume|clear|compact|fork)
  ├─ stamp model id + resolved window to .reload/model, PER SESSION (`session:` line; Stop gets no
  │     model field — this bridges it; another session's startup never moves this one's window)
  ├─ startup|clear|compact (NOT resume|fork) → purge `notified`, and `summarizing` unless it is
  │     another LIVE process's (invariant 22); a handshake must not outlive its context (invariant 10)
  ├─ arms_here (own `pending.<pid>` first, then bare `pending` + ORPHANS whose pid is dead, newest
  │     first; a foreign LIVE arm is NEVER listed) empty?
  │     ├─ foreign live arm(s) exist → 🔒 notice "left in place, this session starts fresh", journal
  │     │     `defer`, exit — invariant 21
  │     ├─ source=compact and the journal's last event is `arm-failed` → surface it once (F06)
  │     └─ else do nothing (a deliberate /clear is respected)
  └─ else → resolve the digest: session.md, or, when its owner ≠ the arm's sid and a side-file
        `session.<armsid>*.md` exists, that side-file (this lineage's OWN thread — no warning);
        no side-file → session.md + the incoherence WARNING (never gates — invariant 3);
        consume every listed arm (one-shot); claim session.md (only when it is the source);
        inject as additionalContext + visible banner; warn above the 10,000-char hook-output cap
        (F05); journal `rehydrate`

PreToolUse hook (model Write/Edit)
  └─ path == $DIGEST && tool is Write|Edit?
       → journal `snapshot`; with a session_id → claim-digest.sh: foreign + fresh incumbent ->
         side-file (journal `sidefile`) + warn; ALWAYS exit 0 (permit)
```

Every hook first: **exit 0 if jq is missing** (fail open — sourced `exit` in `lib.sh` exits the
caller) and **exit 0 if a cc-repete loop is active** (`.repete/loop.local.md` frontmatter
`active: true`, first `---` block only — a published contract, cc-repete#27; see invariant 17).

## Load-bearing invariants (each has a named test; the suite is cited per entry)

1. **Pass 2 always completes.** Once pass 1 blocked, the next Stop must consume `summarizing` and
   settle the arm *before* any budget/transcript gating — disabling the budget or losing the
   transcript mid-snapshot must never strand the marker. (Tests: "pass2 completes even …")
2. **Never block without the marker on disk.** The block/continue loop only terminates because
   pass 2 keys off `summarizing`. If the marker can't be written, or `stop_hook_active` is set
   with no marker, the hook stands down. Violating this = infinite snapshot prompt.
   (Tests: "stop_hook_active suppresses a re-block", ".reload unwritable -> silent",
   "marker unwritable -> no block emitted", "directory at summarizing: first Stop does not block")
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
14. **The occupancy scan reads the last MAIN-THREAD assistant row, per line, from a tail window,
    and its two halves fail independently.** (audit 2026-09-02 F01/F02/F03, F10.) Four rules, one
    jq program (`TURN_SCAN_JQ` in `stop-hook.sh`):
    `.isSidechain != true` (subagent rows are not the main thread — older Claude Code appends them
    to the main transcript, current versions write `subagents/*.jsonl`; a subagent's tiny usage
    under-reported occupancy AND its model restamped `.reload/model`, which on a `[1m]` session
    stripped invariant 5's shield for good); `-R` + `fromjson? | objects` (one truncated line or a
    non-object `message` skips that LINE — the old `-s` slurp aborted the whole parse and fell to the
    byte/4 estimate: 3MB read as "~75%" at 10% real); and `tail -n 2000` first, full-file stream
    only when the window holds no main-thread row (a tail window is a suffix, so its last main-thread
    row IS the file's; WHOLE-HOOK 1.91s → 0.06s on 57MB, 0.98s worst-case fallback — the
    stop-hook.sh comment quotes the SCAN-ONLY numbers for the same run, which is why 2.25s appears
    there and 1.91s here); and `| numbers` / `| strings` around the two halves, so a mistyped
    field costs only that field. The last rule is the subtle one: the program CONCATENATES tokens and model, so combining them in one fallible
    expression made a wrong type in *either* half throw for the whole row — `tail -n 1` then
    returned an EARLIER row, and `USED` was a well-formed number that passed every validity check,
    so the byte/4 fallback never fired and a 95% session measured as 2%. That is silent-WRONG, and
    strictly worse than the slurp it replaced (which produced NO answer — the safe over-count). A
    row with no numeric usage field at all is SKIPPED rather than emitted as `0`, because a
    trailing `0` becomes the last line and sends the caller to byte/4 for the whole transcript.
    The window mechanism is pinned by INVOCATION (a `jq` shim on PATH: never handed the transcript
    path on the window path, exactly once on the fallback, never a slurp flag) — a wall-clock
    assertion in CI is a flake generator. (Tests: "sidechain row last: main thread's 50% still
    nudges", "[1m] stamp survives a sidechain row", "truncated trailing line: the valid 10% row is
    measured", "non-string model on the last row: its 95% is still measured (not the earlier 2%)",
    "string input_tokens: row skipped, the last MEASURABLE row (50%) is used",
    "window path: jq never received the transcript path", "fallback path: jq received the
    transcript path exactly once", "scan program still emits a space-joined 'tokens model' pair",
    "a bare token count is never stamped as the model id")
15. **Every marker WRITER verifies with `-f`, because every marker READER tests `-f`.** (audit
    2026-09-02 F05.) `touch` and `printf >` "succeed" on a directory that `-f` never matches and
    `rm -f` never removes: a stray `mkdir .reload/summarizing` blocked EVERY ordinary Stop
    (fail-closed, measured 3/3 — the one door invariant 2 had left open). Pass 1 refuses to block
    unless the marker it just wrote is `-f`; pass 2 and PreCompact report "reload NOT armed" when
    the arm is not `-f` (never "digest saved" over an arm that cannot rehydrate); and pass 1's arm
    gate is `-e`, so ANY entry at `pending` suppresses a re-block (fail-open) while SessionStart's
    rehydrate gate stays `-f`. Adding a marker: write it, then test `-f`, or you have added a
    fail-closed door. (Tests: "directory at summarizing: first Stop does not block", "pass 2 with an
    unwritable arm warns instead of claiming success", "over budget with a directory at pending: no
    re-block (fail-open)", "PreCompact with an unwritable arm warns")
16. **Every config reader strips trailing `# comments`, and the ones reading the same file agree.**
    (audit 2026-09-02 F04.) The README's own `.reload/config` example is written
    `key: value   # comment`; `hooks/lib.sh` `kv()`, `scripts/reload-config.sh get` and the inline
    copies in `scripts/statusline.sh` all returned the comment as part of the value, failed
    validation and silently fell back to the default — the documented `context_window` pin was
    dropped. Values are numbers, enums and model ids; `#` is never content. Count them precisely,
    because the count is what decides what the parity test can reach: **three** readers parse
    `.reload/config` (`kv()`, `reload-config.sh get`, and statusline's `context_window:` +
    `context_budget_pct:` greps) and are pinned to each other by the fixture-driven parity loop; a
    **fifth** copy of the same strip reads `.reload/model`'s `window:` line — a different FILE, so
    the loop cannot reach it and it needs its own case. Deleting that one failed no test until
    2026-09-02 F10; the "four readers" wording is what hid it. The copies are deliberate
    (statusline must not source lib.sh's jq-exit; reload-config must not either), and the README
    block itself is fed to the Stop hook. (Tests: "reader PARITY", "the FIFTH strip", "commented
    context_window pin is honoured -> 75% nudges", "README still carries the three-line example")
17. **`.repete/loop.local.md` is a published contract, and `repete_active()` reads it the way the
    producer does.** (issue #12.) The path, the `active` key and the value `true` are an interface
    cc-repete declares (its CLAUDE.md "what a loop publishes", betmoar/cc-repete-plugin#27); the
    payload below the frontmatter is loop prose and must never count. Until 0.4.0 this was a bare
    whole-file grep, wrong in BOTH directions: body prose quoting `active: true` (a handoff note
    after teardown flipped the frontmatter to `active: false`) read as a LIVE loop — every hook
    stood down forever, silently, against a loop that was over; and the producer's quoted form
    `active: "true"` read as NOT active — cc-reload kept running alongside a live loop, the exact
    collision the stand-down exists to prevent. `repete_active()` now mirrors cc-repete's own
    reader: first `---` block only, quotes as a both-ends pair or not at all (cc-repete #30 /
    PR #31 settled that canonical across all three of its readers in its v0.2.5; issue #14
    flipped this side's mirror to match — an asymmetric `true"` is likelier corruption than
    formatting and reads INACTIVE), one optional trailing CR. The
    deliberate cross-repo shape decision: a TORN write (opener, no closer) reads as
    frontmatter-to-EOF, matching the producer's `fm()` — a torn bare `active: true` stands
    cc-reload down until cc-repete rewrites the file; coordinate any change to that with
    cc-repete (the declared contract is the stricter first-block scope — never "fix" a divergence
    by loosening this reader back toward a whole-file grep). If cc-repete renames the key, the
    file, or the value form, these tests go red — that is the pin working: update together, not
    silently.
    (Tests: "plain active: true in block 1 -> active", "body line active: true does NOT count
    (issue #12)", "quoted true counts (producer strips one quote layer)", "asymmetric trailing
    quote reads INACTIVE (cc-repete #30: both ends or neither)", "asymmetric leading quote reads
    INACTIVE (cc-repete #30)", "CRLF form counts",
    "no frontmatter at all -> not active", "torn write: active: true with no closer still counts",
    "torn write: active: false with no closer -> not active", "a SECOND block's active: true does
    not count")
18. **`templates/session.md` is the digest's source of truth, and the three hand-kept copies of
    its heading list are pinned to it.** (0.4.2.) The four section names are written out
    independently in four places: the template, the pass-1 REINJECT heredoc (`stop-hook.sh`), the
    mechanical stub (`precompact-hook.sh`), and the banner reader
    (`sessionstart-hook.sh`'s `_first_bullet`/`_first_line` arguments). Until 0.4.2 NOTHING checked
    they agreed — the same defect class invariant 16 closed for the config readers, left open on
    the payload the whole plugin exists to carry. Drift is silent in BOTH directions: a heading
    renamed in the template while the reader keeps the old name drops that line from the banner
    forever, and a heading renamed in the reader while the template keeps the old one makes the
    banner read a section no digest will ever have. The parity block extracts `^## ` from the
    template and requires each name in the two writers, then requires every name the READER looks
    up to be one the template defines. The `mission` field is the same rule one level down: it is
    the original ask, written once and copied verbatim, so `claim_digest`'s frontmatter rewrite
    must leave it byte-identical — an `intent` that gets rewritten every snapshot is a summary of a
    summary, which is the erosion `mission` exists to stop.
    (Tests: "the template defines the four sections", "REINJECT heredoc names the template
    section", "PreCompact stub names the template section", "banner reads a section the template
    defines", "mission survives the claim byte-identical", "the rehydrated context carries the
    mission"; e2e cycle 10.)
19. **Every snapshot REPLACES the last one, so carry-forward is instruction, not mechanism.**
    (0.4.2.) `commands/snapshot.md` said "overwrite" and never "read the existing digest first":
    an Open question raised in session A and untouched in session B died at B's snapshot, silently,
    with nothing to recover from. The fix cannot be a hook — a hook cannot author a digest, and
    splicing an untrusted model-written body section is exactly the corruption `frontmatter_closed`
    exists to prevent. So the instruction ships in all four guidance surfaces (template comment,
    REINJECT, snapshot.md, SKILL.md) and what is PINNED is delivery: the REINJECT must carry the
    read-first, carry-forward and verbatim-mission rules, and the rehydrate must carry an
    unresolved item and the mission across. Do NOT "strengthen" this into a mechanical splice, and
    do NOT write a test asserting a fixture carried an item forward — such a test passes on the
    pre-fix code, which is worse than no test (it certifies the bug as fixed).
    (Tests: "the REINJECT tells the model to read the existing digest first", "the REINJECT names
    carrying unresolved items forward", "the REINJECT keeps the mission verbatim, never rewritten",
    "the rehydrate carries the unresolved Open question across"; e2e cycle 10.)
20. **git is a SOFT dependency with exactly THREE call sites, and every derived signal is silent
    unless it is MEASURED.** (0.4.2.) Count them precisely, because the count is what tells the
    next maintainer where to look: `scripts/context-block.sh` (the only *free-form* caller — the
    one script whose whole purpose is git), `head_drift()` in `hooks/lib.sh`, and the `head:` stamp
    in `hooks/precompact-hook.sh`. Everything else is bash + jq + coreutils. Adding a fourth means
    auditing all four against this invariant, not just the script — the same reason invariant 16
    counts its config readers out loud. Each site prints NOTHING and exits 0 on no git, not a work
    tree, an empty repo (no HEAD to resolve), or a broken `.git` — the `proxy_window()` shape.
    Half a block, or one with git's stderr in it, lands in a digest that is injected into a fresh
    context as fact. `digest_age_days()` is deliberately NOT one of them: it reads mtime, so the
    age axis keeps working in a directory with no repo at all.
    The staleness signals follow the same rule, and the failure they guard is a CONFIDENT WRONG
    NUMBER, which is strictly worse than today's silence: an authoritative "0 commits behind" over
    a badly stale digest is believed by a session that just lost its context. `head_drift()` emits
    only on a positive match, and its FOUR gates are each load-bearing and each measured
    (2026-09-09): without the anchored hex gate a stamp of `HEAD~2` — untrusted digest text —
    resolves and counts as 2; without `^{commit}` a hex-valid BLOB sha yields `rev-list --count` =
    3 with exit 0; without `--is-inside-work-tree` a BARE repo answers normally (its object
    database resolves shas fine), reporting drift for a directory with no working tree; and without
    `merge-base --is-ancestor` a DIVERGED stamp answers happily — the realistic one, since
    `.reload/` is per-project and shared across branches, so snapshot-on-feature then switch-to-main
    measured "2 commits since this digest" for a history the digest's work is not in at all. An
    unknown sha, by contrast, already fails `rev-list` outright (exit 128), so a made-up sha does
    NOT exercise the `^{commit}` gate — pin that one with a blob.
    `scripts/context-block.sh` has the same shape one level down: `git status --porcelain` prints
    NOTHING when it FAILS, so testing emptiness alone reported "working tree clean" over a dirty
    tree whenever the index was unreadable (measured with a corrupted `.git/index`). Test the EXIT
    STATUS: empty-because-clean and empty-because-it-failed are different answers.
    A guard that cannot be made red is DEAD CODE, not defence: an explicit clock-skew check in
    `digest_age_days()` was deleted for exactly that reason — a future mtime already yields a
    negative `days` that fails the threshold (measured: `days=-1157`), so the check could not change
    any outcome. Before adding a guard here, mutate it and watch a case go red.
    `digest_age_days()` reads FILESYSTEM MTIME, never the frontmatter `updated_at` (model-written,
    and routinely copied forward from the previous digest).
    **The mtime trap, in two halves — both had to be fixed, and the second was found only by
    running the hook against this repo's own digest.** `claim_digest`'s temp-file + `mv` stamps a
    brand-new mtime (measured: a file backdated to 2020 reads as `now` immediately after).
    (a) The age must be captured in `sessionstart-hook.sh` BEFORE the claim, or the signal is dead
    *within* a session. (b) `claim_digest` must RESTORE the mtime afterwards (`touch -r` from a
    reference file taken before the rewrite), or the signal decays *across* sessions: every
    rehydrate rejuvenates the file, so a digest claimed on each `/clear` reads as fresh forever
    however stale its content is.
    **(b) subsumes (a), so each needs its OWN case:** with the restore working, capturing after the
    claim gives the same answer, and a whole-hook test cannot tell the orderings apart — a review
    measured exactly that against an earlier comment here claiming it could. The ordering is kept as
    defence in depth (it is all that stands if the restore ever fails) and is pinned by running the
    hook with a no-op `touch` shim on PATH. Do not "simplify" either half away because the suite
    stays green when you delete it alone. Measured 2026-09-09 on this repo: content from 2026-07-10
    describing v0.1.9 with the repo on v0.4.1 — two months stale — and an mtime from that same
    morning, because a SessionStart had claimed it. The one case the signal exists for is the one
    it would have missed; a unit suite cannot catch this, only running the real hook against a real
    aged digest. Both halves are the v0.1.5 id-equality shape: a check that is false exactly when
    it matters. **mtime means "when the content was last written" — a claim rewrites the OWNER, not
    the thread.** Use `touch -r`, never `date -r`: the latter takes an epoch on BSD and a FILE on
    GNU, i.e. it is silently wrong on one of the two platforms this must run on.
    Every signal is advisory: it never gates, never blocks, and the rehydrate has already happened
    when the banner is assembled (invariant 11, and the "pointer, not source of truth" contract).
    **The digest's mtime now has TWO readers, and they are coupled.** `digest_age_days()` and
    `claim-digest.sh`'s `owner_window()` freshness check read the same number, so preserving mtime
    across a claim changed both. Before 0.4.2 the claim's `mv` restamped it, silently renewing the
    collision window on every rehydrate — it measured "time since last CLAIM". It now measures what
    `context_owner_window` is documented to measure: how recently another session WROTE the digest.
    Measured consequence: a digest whose content is older than the window but was rehydrated a
    moment ago is no longer side-filed on collision, where pre-0.4.2 it was. **Accepted, not a
    regression to undo** — what goes unprotected there is content nobody has touched in over a
    window, held in the rehydrating session's context, and its next `/snapshot` restores full
    protection; the case that matters, a session that WROTE recently, is unchanged. Rejected:
    widening `OWNER_WINDOW_DEFAULT` (tuning a constant to restore an accident) and a separate
    "last claimed" marker (drags a best-effort guard into invariant 15's writer/reader/purge
    discipline). Pinned in `tests/test-claim-digest.sh` so the coupling cannot move silently again.
    (Tests: "prints nothing outside a repo", "prints nothing with no git on PATH", "empty repo
    never leaks git's fatal", "detached HEAD is named as such, not as a branch", "a revision
    EXPRESSION is not a sha", "a blob sha resolves but is not a commit", "stamp == live HEAD: no
    drift line", "age is captured BEFORE the claim", "the claim PRESERVES mtime",
    "a SECOND rehydrate still reports the true age", "the fallback names the branch and sha",
    "a stamp that is not an ancestor of HEAD reports no drift", "a true ancestor still reports its
    drift", "a bare repo yields no drift line", "a failed git status never claims the tree is
    clean", "a future mtime never reports a negative age", "exactly 1 day old still reports",
    "a rehydrate does NOT renew the collision window", "a JUST-WRITTEN foreign digest is still
    protected".)
21. **An arm belongs to a PROCESS lineage; a session consumes its own, the pid-less, and the
    orphaned — never another LIVE process's.** (0.5.0, audit 2026-09-17 F01/F02/F12.) Before this,
    `pending` was one unowned slot and whichever session started or `/clear`'d next consumed it:
    a second Claude Code session opened in the same directory took the first one's reload
    (reproduced), and `/clear` in A injected B's thread. The lineage key is `CLAUDE_PID`, the
    Claude Code process id it exports to hooks and to the Bash tool (measured on 2.1.274 with a
    real SessionStart hook; UNDOCUMENTED). It is the one identity that passes invariant 13's
    question — "which side rotates across a reset?": the session id rotates on EVERY reset, the
    pid only when the process is gone. A hook's `$PPID` is a throwaway `sh -c` wrapper (measured:
    PPID=sh, CLAUDE_PID=claude) and is deliberately not a fallback: absent `CLAUDE_PID`, the arm is
    pid-less and every rule degrades to the pre-0.5 single slot (fail-open, F14). Liveness is
    `kill -0`; a dead owner is an ORPHAN and is consumed (the quit-and-restart case), and every
    orphan is removed on consumption so a dead session never leaves a one-shot behind for a later
    deliberate `/clear`. The rehydrate reader tests `-f` (invariant 15); the pass-1 gate
    `armed_here` also counts a stray directory at the bare or own slot (`-e`, fail-open) but never a
    foreign live arm. Each lineage gets ITS thread back: the arm's sid resolves to the side-file
    `claim-digest.sh` kept when `session.md` is owned by someone else; without a side-file the
    pre-0.5 path applies (rehydrate + warn). Do NOT re-key this on the session id, the transcript
    mtime (a session idle at a prompt writes nothing), or a SessionEnd hook (does not fire on a
    kill; a stale marker would then defer forever). (Tests: "with CLAUDE_PID the arm lands at
    pending.<pid>", "without CLAUDE_PID the arm is the legacy bare pending (F14 fail-open)", "A's
    arm survives B's startup", "A's /clear (new sid, same process) rehydrates A's thread", "B's arm
    survives A's /clear", "orphan arm rehydrates", "own thread wins", "orphan consumed too (dead
    sessions leave no one-shot behind)", "foreign live arm untouched", "bare pending rehydrates",
    "A's /clear injects A's side-filed thread", "no side-file -> falls back to session.md
    (invariant 3)", "B blocks for its own snapshot despite A's arm", "own arm suppresses the
    re-block"; e2e cycle 11.)
22. **The handshake marker is owned the same way, and the per-session model stamp is what keeps
    invariant 5 true with two sessions.** (0.5.0, F03/F04.) `summarizing` carries sid + pid: pass 2
    runs only on a marker that is ours, pid-less or orphaned; pass 1 refuses to OVERWRITE another
    live process's marker (it takes the notify path instead — one slot, and clobbering it strands
    their digest un-armed); startup hygiene purges an orphaned marker but keeps a foreign live one.
    `.reload/model` keeps the legacy `model:`/`window:` pair (= the last stamp) AND one
    `session: <sid> <model> <window>` line per session, capped at 16 (`stamp_model`/`stamped` in
    `lib.sh`, atomic temp+mv); the Stop hook and the statusline read their OWN session's line
    first. Measured pre-fix: A on `sonnet[1m]` was nagged at "45%" while at 9% real occupancy the
    moment B started on opus, because B's startup restamped the shared pair and A's Stop then
    "corrected" itself to the bare id's 200K. Every reader of `.reload/model` with a session id in
    hand must go through `stamped()` (hooks) or the awk lookup in `statusline.sh`, never a bare
    `window:` grep — that grep is the FALLBACK. (Tests: "B's Stop does not run pass 2 on A's
    handshake", "B over budget will not overwrite A's live handshake: no block", "startup keeps a
    foreign LIVE handshake", "startup purges an orphaned handshake", "the owner's Stop completes
    pass 2", "both sessions have a stamp line", "A keeps its [1m] shield after B started: 9% is
    silent", "a real family switch restamps A's own line only", "session lines are capped (no
    unbounded growth across /clear)", "statusline reads ITS session's window, not the last stamp".)
23. **The journal is advisory and append-only; the arm has ONE writer; the 10,000-char hook-output
    cap is warned about, never truncated around.** (0.5.0, F05/F06/F10/F11.) `.reload/journal`
    records `snapshot` (PreToolUse on the digest — BEFORE the session-id gate, so an un-owned
    snapshot is still noted), `arm`, `arm-failed`, `sidefile`, `rehydrate`, `defer`, `reported`,
    each with UTC time, sid and pid, capped at 200 lines (newest kept). Nothing gates on it; it is
    what `/reload` shows and what SessionStart(compact) reads to surface a failed PreCompact arm
    (Claude Code DISCARDS PreCompact's own systemMessage — docs). The arm is written by
    `arm_reload()` only: the hooks call it directly, `/snapshot` through `scripts/arm-reload.sh`
    (which opts out of the jq guard with `CC_RELOAD_NO_JQ_OK=1` because it needs no jq and must
    not skip the arm silently). A command that writes `.reload/pending*` by hand produces a
    pid-less arm and reverts that session to the single slot — `tests/test-release.sh` greps for
    it. Claude Code caps every hook output string at 10,000 chars and replaces a longer one with a
    preview + path: SessionStart injects the digest in FULL anyway and prefixes the banner with a
    warning above 9,500 chars — a silent cut would be worse than the cap. (Tests: "a Write to the
    digest is journaled as a snapshot", "events are in order: snapshot, arm, rehydrate", "the
    journal is capped at 200 lines", "PreCompact journals the failure", "SessionStart(compact)
    surfaces it (PreCompact's own systemMessage is discarded by Claude Code)", "reported once, not
    on every compaction after", "the full digest is still injected (no silent cut)", "the banner
    warns about the 10,000-char cap", "no command writes .reload/pending by hand".)

## Non-obvious decisions and rejected alternatives

- **Why a two-pass Stop handshake instead of summarizing in the hook?** A hook is a shell command;
  the model is not running inside it, so it cannot author a digest. Pass 1 blocks and re-injects
  instructions so the *model* writes the digest on the next turn; pass 2 detects that turn ended
  and arms. PreCompact has the same limitation, hence its mechanical fallback stub.
- **Why read token usage from the transcript?** Claude Code gives Stop hooks no context-% and no
  model id. The last assistant turn's `message.usage` (input + both cache fields) ≈ full context
  sent that turn. This is an **undocumented schema** — treat it as best-effort forever; the byte/4
  fallback deliberately over-counts (triggers early = safe when the goal is "never auto-compact").
- **Why a windowed per-line stream, not a slurp (0.3.3)?** The transcript is tens of MB near
  budget and this runs on every Stop. Until 0.3.2 one `jq -rs` slurp did it in a single pass; the
  audit measured it at 2.25s / 275MB RSS on 57MB (over the ~1s rule below), found it aborted on ONE
  malformed line (silently falling to the byte/4 estimate), and found it took whichever agent spoke
  last (subagent rows). The replacement keeps the single-pass shape — USED and LIVE_MODEL still come
  out of one program as "tokens<space>model" (model ids never contain spaces) — but reads a
  `tail -n 2000` window per line (`-R`, `fromjson? | objects`, main-thread filter) and streams the
  whole file only when the window holds no main-thread row. **Rejected:** a growing window with a
  turn-boundary predicate (cc-repete's shape — needed there because it must find a boundary; here
  one main-thread row is the whole answer, and a suffix's last such row is the file's);
  slurping the tail (`tail | jq -s`) — same one-bad-line abort; asserting the speedup in CI (a
  wall-clock test flakes; the invocation shim pins the mechanism instead). The `?` in `fromjson?`
  is hygiene, not the protection: under `-R` jq already continues past a failing line (exit 5,
  stderr) — the per-LINE mode is what makes a bad line non-fatal, and the test pins the slurp
  regression, not the `?`.
- **Why does the statusline segment not share code with the hooks?** It renders Claude Code's own
  pre-calculated `context_window.used_percentage` from statusline stdin — it must work with zero
  hooks having run, and must never touch the transcript. Only the *budget* is shared, read from
  `.reload/config` by both.
- **Why `set -uo pipefail` but not `-e`?** Fail-open philosophy: a broken hook must degrade to
  "plugin does nothing", never to "session unusable". Guard specific failure points explicitly
  (e.g. `touch … || exit 0`) instead of letting `-e` kill the script at an arbitrary line.
- **Why does `proxy_window()` (0.3.1) contact a network endpoint at all, softening "no network"?**
  The single source of truth for a model's real context window is cc-proxy itself — it knows every
  id it routes and, as of v0.5.1, publishes `context_window` on `GET /v1/models`. Hard-coding a
  second copy of that table in `model_window()` means the two silently drift; the proxy is
  authoritative, the table becomes the offline fallback for when it isn't running. The call is
  scoped tightly enough that it doesn't reopen the daemon/network invariant in spirit: loopback-only
  (never a remote host — checked against `ANTHROPIC_BASE_URL`'s host, never hard-coded), fired once
  per session from `SessionStart` only (never the Stop hook's per-turn path), `--max-time 1`, and
  fail-open-silent on literally anything going wrong (down, no `curl`, timeout, bad JSON, missing or
  non-positive `context_window`) — the `[ -n "$WIN" ] || WIN="$(model_window "$MODEL")"` fallback
  always has a value to use. **Rejected:** polling per-turn from the Stop hook (reintroduces network
  I/O on the hot path CLAUDE.md explicitly protects); trusting the proxy for `claude-*` ids too
  (cc-proxy only routes non-Claude traffic and never publishes a window for `claude-*`, so those ids
  always fall through to the table — this is what keeps the F05 `[1m]` guard, invariant 5, intact
  with the proxy reachable).
- **Why key session ownership on the PROCESS id (0.5.0) — and not on the session id, a
  SessionEnd hook, transcript mtime, or Claude Code's session registry?** The session id rotates on
  every `/clear`, so any "is this mine?" by session id is false on the primary path (invariant 3,
  the v0.1.5 bug). The process id is stable across `/clear` and `/compact` and rotates exactly
  when the old process is gone, and `kill -0` answers liveness with no dependency. **Rejected:**
  a SessionEnd hook marking arms as abandoned — it does not fire on a kill or a crash, so a stale
  marker would defer every later rehydrate forever, and its output channel is discarded anyway;
  transcript mtime as liveness — a session idle at its prompt writes nothing, so a live session
  looks dead after any pause and its arm is stolen again; `~/.claude/sessions/<pid>.json` (a
  per-pid registry with `sessionId`, `cwd`, `status`, seen on 2.1.274) — undocumented AND
  version-specific, where `CLAUDE_PID` + `kill -0` is undocumented but generic; noted in the
  backlog as a refinement for the pid-reuse edge, never as the primary oracle. **Also rejected:**
  a single owned `pending` slot with deferral (B's own `/snapshot` would still overwrite A's arm —
  the user's scenario needs both to keep theirs, hence `pending.<pid>`), and a per-session digest
  file (`session.<sid>.md` as the primary slot) — it would rotate the payload's NAME on every
  `/clear`, break `/reload`, the PreToolUse path match and every reader of `$DIGEST`; the existing
  side-file mechanism already preserves the displaced thread, so the arm only needs to RESOLVE to
  it.
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
- **Why is the digest's quality guidance duplicated across four files instead of centralised
  (0.4.2)?** Each surface reaches the model at a different moment and none can read the others: the
  REINJECT is a JSON string the Stop hook emits (no file access), `commands/snapshot.md` is a
  command body, the template comment is only seen if the model opens the template, and SKILL.md is
  loaded by the skill system. A hook cannot inline the template into the REINJECT without reading a
  file the plugin may not be able to reach at that moment, and a partial read would ship truncated
  instructions. The copies are deliberate; the heading names are pinned to the template by the
  parity test (invariant 18) and the guidance wording is a coupling row. **Rejected:** generating
  the REINJECT from the template at hook time (a file read on the block path, failing open to
  *no instructions at all* — worse than a copy); dropping the template's HTML comment in favour of
  the REINJECT (the template is what a human opens to learn the format).
- **Why is `mission` frontmatter and not a fifth section (0.4.2)?** `digest_field` reads
  frontmatter generically and `claim_digest` preserves unknown keys, so a field costs zero parser
  work and one line of the ~30-line budget. A section would add a fifth hand-kept copy of the
  heading list to every place invariant 18 pins, for prose that is one line by definition.
  Same reasoning rejected a `## Baseline` section: the baseline is an instruction line under
  *Open questions & risks*, present only when there is one, rather than three lines of the budget
  spent in every session including those that ran no tests.

## Couplings — if you touch X, also update Y

| You changed | You must also check |
|---|---|
| Digest format / section names | `templates/session.md` is the SOURCE OF TRUTH; three copies repeat the heading list by hand — the pass-1 REINJECT heredoc in `stop-hook.sh`, the mechanical stub in `precompact-hook.sh`, and the `_first_bullet`/`_first_line` calls in `sessionstart-hook.sh` — plus `commands/snapshot.md` and the skill. The four are pinned to each other by `tests/test-hooks.sh` "digest section PARITY" (invariant 18); rename a heading in the template and those cases go red. Guidance text (not just heading names) lives in FOUR places and must stay consistent: the template's HTML comment, the REINJECT, `commands/snapshot.md` step 3-4, and SKILL.md "The digest" |
| Marker file names/locations (`lib.sh` constants) | both test files, README "Layout" + hook table |
| `model_window()` cases | tests "model_window: …" block, README "How occupancy is measured", the SKILL.md note on windows |
| cc-proxy model windows (GLM/DeepSeek/Qwen ids) | curated against `cc-proxy-plugin/scripts/list-models.js` (`CONTEXT_WINDOW` const) as of 2026-08-04 — re-check that source before adding/editing a proxy case; only add a case when the real window differs from the 1M default (invariant 5). Since 0.3.1 this table is the FALLBACK — cc-proxy v0.5.1+'s `GET /v1/models` `context_window` field (positive integer tokens; curated ids include it, uncurated ids OMIT it — never `null`) is consulted first by `proxy_window()`. If cc-proxy's response shape or the omit-not-null contract changes, `proxy_window()`'s jq extraction in `hooks/lib.sh` must change too |
| `proxy_window()` (`hooks/lib.sh`) | `hooks/sessionstart-hook.sh` (sole caller), `tests/test-hooks.sh` (stub-`curl`-on-PATH seam), README "How occupancy is measured", SKILL.md windows note, CLAUDE.md decision note above |
| `scripts/context-block.sh`, `head_drift()` (`hooks/lib.sh`) or the `head:` stamp in `precompact-hook.sh` — the THREE git call sites (invariant 20); `digest_age_days()` is mtime-only and needs no repo | `tests/test-context-block.sh` (it builds REAL repos: clean, dirty, detached, empty, broken `.git`, non-repo, no-git-on-PATH), `hooks/precompact-hook.sh` (folds the block into the fallback and stamps `head:`), `hooks/sessionstart-hook.sh` (banner — and the age capture must stay ABOVE `claim_digest`, invariant 20), the `head:` line in `templates/session.md` + `commands/snapshot.md` + the REINJECT, README "How it works", SKILL.md. Keep every signal fail-open-SILENT: a wrong number is worse than none |
| Hook JSON output shape | Claude Code hook schema (systemMessage / decision:block / hookSpecificOutput.additionalContext) — verify against current CC docs before changing |
| `context_budget_pct` semantics (default 45, 0=off) | `stop-hook.sh`, `scripts/statusline.sh` (independent reader!), `commands/reload-budget.md`, README, SKILL.md |
| `context_budget_mode` semantics (default notify; value `snapshot`, legacy `checkpoint` aliased) or the +10 ladder step | `stop-hook.sh` (mode branch reads `snapshot\|checkpoint` + ladder), `scripts/reload-config.sh` (validation normalizes `checkpoint`→`snapshot`), `commands/reload-budget.md`, README "How it works" + Configuration, SKILL.md cycle step 1, both test files' alias cases |
| Anything in `hooks/hooks.json` | plugin must not ALSO declare hooks in plugin.json (duplicate-hooks load error — v0.1.2 regression) |
| `claim-digest.sh` decision logic | `tests/test-claim-digest.sh`, e2e cycle 7, README "Known limitations" |
| `/snapshot --check` (`commands/snapshot.md`) | `tests/test-context-block.sh` "== /snapshot --check ==" block, README "Commands". It is an AUDIT: never writes, never arms, and the subagent gets the digest ALONE — leak this session's context into that prompt and it passes by cheating, which makes the whole path theatre. Always pass an explicit subagent model. No CI fixture suite: a live subagent is not deterministic, so what is pinned is the command CONTRACT, not the audit's verdict |
| `repete_active()` (`hooks/lib.sh`) — a cross-REPO contract | cc-repete is the producer and its reader is canonical (its CLAUDE.md "what a loop publishes", betmoar/cc-repete-plugin#27): first `---` block, `active` key, one quote layer + CR tolerance, torn write = frontmatter-to-EOF. This repo's eight consumer-side cases in `tests/test-claim-digest.sh` go red if either side moves — update the two repos together, never "fix" a divergence by loosening this reader back to a whole-file grep (invariant 17). Also: README hook preamble, SKILL.md coexistence note, both command files' stand-down step |
| `pretooluse-hook.sh` or its `hooks.json` entry | plugin must not ALSO declare hooks in `plugin.json`; `tests/test-claim-digest.sh` |
| `PENDING` being a stamped file rather than a `touch` | the ONE writer is `arm_reload()` → `write_marker()` in `hooks/lib.sh`; the slot is chosen at `lib.sh:86` (`arm_path`) and enumerated at `lib.sh:104` (`arms_here`); `sessionstart-hook.sh` arm block; `tests/test-concurrent.sh`, `tests/test-hooks.sh`, `tests/test-e2e.sh` (these two citations are checked by `tests/test-release.sh`: the cited line must contain `PENDING`) |
| The lineage helpers (`our_pid`, `marker_*`, `arm_*`, `arms_here`, `armed_here`, `sidefile_for` in `hooks/lib.sh`) | `sessionstart-hook.sh` (consume/defer/resolve), `stop-hook.sh` (pass-2 ownership, pass-1 gate, notify wording), `precompact-hook.sh`, `scripts/arm-reload.sh`, `commands/snapshot.md` step 5, `docs/concurrent-sessions.md` (the rules table MUST match), README "Two sessions", invariants 21–23, `tests/test-concurrent.sh`, e2e cycle 11. Every pre-existing suite exports `CLAUDE_PID=""` — a hook run under a real Claude Code session inherits the pid and writes `pending.<pid>` where those fixtures expect `pending` |
| `.reload/model` format (`session:` lines + legacy pair) | `stamp_model`/`stamped` (`lib.sh`), `stop-hook.sh` restamp block, `scripts/statusline.sh` awk lookup, `tests/test-config.sh` "the FIFTH strip" (legacy pair), `tests/test-concurrent.sh` "F04" block, `docs/how-it-works.md` "How occupancy is measured" |
| `journal()` events or format | `docs/concurrent-sessions.md` (the example block), `commands/reload.md` step 4, `sessionstart-hook.sh` (`arm-failed` surfacing matches the EVENT field of the last line — a detail string containing the word must not match), `tests/test-concurrent.sh` "F11" + e2e 11.18 (the exact event sequence) |
| `docs/*.md` pages | `tests/test-release.sh` requires every `docs/…md` path cited in hooks/, scripts/, commands/, skills/, README and this file to exist, every README link to resolve, and README to stay under 200 lines |
| `context_owner_window` semantics (default 14400, 0=off) | `lib.sh` `owner_window()`, `scripts/reload-config.sh`, `commands/reload-budget.md`, README, `tests/test-config.sh`. It shares ONE signal — the digest's mtime — with `digest_age_days()`, so a change to what writes or preserves that mtime moves BOTH: see invariant 20's last paragraph before touching `claim_digest` |
| The transcript scan (`TURN_SCAN_JQ`, `WINDOW_LINES` in `stop-hook.sh`) | ONE program, TWO reads (window, then full-file fallback) — keep it one definition. The main-thread filter, the per-line mode and the window are each pinned separately (invariant 14's tests); the `jq` shim test breaks if jq is ever handed the transcript PATH on the window path or a slurp flag anywhere. Re-measure by hand on a ≥50MB transcript after touching it (numbers in invariant 14) — never add a wall-clock assertion |
| Any config-file reader (`lib.sh` `kv()`, `reload-config.sh get`, the three inline greps in `statusline.sh`) | the other FOUR copies — same strip order: comment, trailing whitespace, one layer of quotes. `tests/test-config.sh` "reader PARITY" runs one fixture set through the three that read `.reload/config`; the `.reload/model` grep reads a different file and is pinned by "the FIFTH strip" instead. README "Configuration" states comments are allowed (the example block is a test fixture: `tests/test-hooks.sh` reads the three `context_*` lines under README "Configuration" literally — matched by CONTENT, not line number — so reformatting them breaks the "README still carries the three-line example" case on purpose) |
| A marker write (`touch`/`printf >` to `summarizing`, `pending`) | verify `-f` right after (invariant 15); if you add a marker, its reader tests `-f` and its writer must too, or you have added a fail-closed door. Pass 1's arm gate is `-e` on purpose — do not "tidy" it back to `-f` |
| `plugin.json` `version` | the newest `## [x.y.z]` heading in `CHANGELOG.md` (with a body) AND the README `Status: **vx.y.z.**` line, same commit — `tests/test-release.sh` fails otherwise. `plugin.json` is the plugin CACHE KEY: a bump that misses it ships an update nobody receives |
| A new `tests/test-*.sh` | nothing — `tests/run-all.sh` globs it and CI calls run-all. `tests/test-release.sh` fails if `ci.yml` ever goes back to a hand-kept list, or drops the shellcheck pin |
| A `file.sh:NN` citation or a quoted test name in THIS file | `tests/test-release.sh` resolves every `\`x.sh:NN\`` to a real line (the `PENDING` row's must land ON the arm write) and every quoted name in the invariants section to a `ck`/header line under `tests/` — a paraphrase fails the build (it caught one on its first run) |

## How to change things safely

- **One command, before every commit: `bash tests/run-all.sh`** (exit code = #failing gates). It
  runs what CI runs — JSON validity, `bash -n`, shellcheck (0.10.0 is the CI pin; absent locally it
  WARNS loudly — `SHELLCHECK=/path/to/binary` points it at one), and every `tests/test-*.sh` by
  glob. The suites are plain bash, no framework. `test-hooks`/`test-statusline`/`test-config`/
  `test-claim-digest` exercise each hook and script in isolation; `test-e2e` chains the REAL hooks
  through one shared `.reload/` and asserts the working-thread content round-trips
  session→reset→session; `test-release` holds the release and structural contracts (version trio,
  hooks.json paths, CI shape, this file's citations). Prefer a cross-hook regression in `test-e2e`
  when a change spans the marker handshake or the digest→banner contract.
- **Every behavior change gets a test in the same commit — written RED first.** Write the `ck`
  case, run the suite and watch it fail on the unfixed code, then fix. A pin that has never been
  red is a hypothesis: this audit's mutation pass found one (dropping the `?` from `fromjson?`
  changes nothing under `-R`), and the cc-operator audit found ten. When you add a guard, mutate
  the code it guards on a scratch copy and confirm the case goes red.
- **Keep hooks dependency-free**: bash + jq + coreutils only. `touch -t` not `touch -d`
  (BSD/macOS), literal ESC byte not `\x1b` in sed (BSD), no GNU-only flags.
- **New model id shipped?** Add a boundary-anchored case to `model_window()` + two tests (the id,
  and the nearest colliding future id). Users can always pin `context_window` meanwhile.
- **Never make the Stop hook slower than ~1s** on a large transcript — it runs on every turn end.
  Measured 0.3.3 on 57MB/100k lines: 0.06s whole hook on the window path, 0.98s on the full-file
  fallback (2500 trailing subagent rows), 0.03s fixed cost on a tiny transcript. Re-measure by
  hand after touching the scan (`TURN_SCAN_JQ`/`WINDOW_LINES`); never assert wall-clock in CI.

### Playbooks — how to change each load-bearing piece without breaking it

**Changing the transcript scan (`stop-hook.sh` `TURN_SCAN_JQ` / `WINDOW_LINES`).**
Guarantees: last MAIN-THREAD assistant row; a bad line skips itself; ≤1 full-file read.
Before you touch it: read invariant 14 and the "Why a windowed per-line stream" decision.
To change what is extracted: edit the ONE program; keep the output shape `tokens<space>model`
(the caller splits on the first space and treats "no space" as "no model"). To change the window:
change `WINDOW_LINES` only — the fallback must stay. Never: reintroduce `-s`/`--slurp` (the shim
test fails), drop `.isSidechain != true`, or read the file twice on the window path.
The trap: `select(.message.role==…)` on a row whose `message` is a string is a jq ERROR — keep the
`objects` and `(.message|type)=="object"` guards. Verify: `bash tests/run-all.sh` green, then
re-measure on a ≥50MB transcript and update invariant 14's numbers.

**Changing a `.reload/config` reader (or adding a key).**
Guarantees: the three `.reload/config` copies return the same value for the same line (parity
test); the `.reload/model` copy is pinned separately ("the FIFTH strip").
To add a key: add it to `reload-config.sh`'s known-key list + validation, read it through `cfg`
(`lib.sh`) — never a fresh grep — document it in README "Configuration" and
`commands/reload-budget.md`, and add a `test-config.sh` case. To change the strip: change all FIVE
sites in the same commit and extend the parity fixture list. Never: read the file with a bare
`grep | cut` somewhere new; never assume the parity loop covers a reader of a different file — it
writes `.reload/config` only. Verify: `bash tests/test-config.sh` — every "parity on […]" case
green, plus "the FIFTH strip".

**Adding or renaming a marker under `.reload/`.**
Guarantees: readers test `-f`; writers verify `-f`; `startup|clear|compact` purges transient ones;
`ensure_reload_dir` precedes every write. To add one: constant in `lib.sh`; write via
`ensure_reload_dir` then `touch`/`printf >` then `[ -f ]` or report; decide its purge rule in
`sessionstart-hook.sh`'s hygiene case; README "Layout" + "Known limitations" (it is per-project,
not per-session). Never: gate a block on a marker you did not verify; gate rehydration on an id
comparison (invariant 3). Verify: a `test-hooks.sh` case with a DIRECTORY at the marker's path.

**Changing the lineage rules (arms, the handshake marker, liveness).**
Guarantees: a session never consumes another LIVE process's arm; its own `/clear` always gets its
own thread; absent `CLAUDE_PID` everything is the pre-0.5 single slot.
Before you touch it: read invariants 21–23 and `docs/concurrent-sessions.md`; run
`bash tests/test-concurrent.sh` and read cycle 11 in `tests/test-e2e.sh`.
To add a marker that must be owned: write it with `write_marker`, read its owner with
`marker_sid`/`marker_pid`, gate on `marker_foreign_live`, decide its purge rule in
`sessionstart-hook.sh`'s hygiene case, and add the directory-at-the-path case (invariant 15).
To change what "alive" means: change `pid_alive` ONLY, and add a case for each direction
(a live foreign pid via a background `sleep`, a dead one via a pid beyond pid_max).
Never: compare against the incoming session id (invariant 3); fall back to `$PPID` (it is `sh`);
list a foreign live arm from `arms_here`; delete a side-file automatically; read the journal to
gate anything. The trap: the pre-existing suites inherit `CLAUDE_PID` from the Claude Code session
running them — keep their `export CLAUDE_PID=""` and set the pid per call only in
`test-concurrent.sh`. Verify: `bash tests/run-all.sh` green, then the two-session drill by hand:
two terminals in one directory, `/snapshot` in A, start B (expect the 🔒 notice), `/clear` in A
(expect A's banner).

**Releasing.**
1. `bash tests/run-all.sh` green. 2. Bump `.claude-plugin/plugin.json`, add `## [x.y.z] - date`
newest in CHANGELOG.md WITH a body, set the README `Status: **vx.y.z.**` line — same commit
(`tests/test-release.sh` fails on any two of the three disagreeing). 3. Tag `vx.y.z` on main after
the squash — the tag build (`.github/workflows/release.yml`) re-runs run-all + the node
release-gate suite, refuses any tag ≠ plugin.json ≠ newest CHANGELOG heading
(`scripts/release-gate.mjs`), and publishes the GitHub release with that version's CHANGELOG
section as the body (notes are EXTRACTED, never hand-written — write them in CHANGELOG.md).
Never bump plugin.json alone: it is the plugin cache key, so a bump that misses it ships
an update nobody receives, and a bump that misses CHANGELOG ships a release with no notes.
- **When in doubt, fail open and silent.** The worst thing this plugin can do is interrupt or
  corrupt a session it was meant to protect.

## Known landmines

- `lib.sh` is **sourced**, and its `exit 0` (missing jq) intentionally exits the *calling hook*.
  Don't "fix" that into a `return`. The ONLY opt-out is `CC_RELOAD_NO_JQ_OK=1`, set by
  `scripts/arm-reload.sh` because it needs no jq and must not skip the arm silently; no hook sets it.
- **`CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` are undocumented** (the hooks reference lists neither;
  both measured present on 2.1.274, the pid in a real hook's env via a nested `claude -p` probe).
  Treat them like the transcript `usage` schema: best-effort, every consumer fail-open. If a
  release drops `CLAUDE_PID`, arms become pid-less and two sessions share one slot again — loudly
  documented, silently degraded. A hook's `$PPID` is the `sh -c` wrapper, never the claude process.
- **Run the suites from inside Claude Code and they inherit `CLAUDE_PID`.** Every pre-existing suite
  exports it empty at the top for that reason (the same trap `ANTHROPIC_BASE_URL` set in 0.3.3);
  `test-concurrent.sh` sets it per call. A new suite that runs a hook must do one or the other.
- **Claude Code caps hook output strings at 10,000 chars** and swaps a longer one for a preview +
  path. The rehydrate injects the whole digest regardless and warns above 9,500. Do not truncate.
- **PreCompact's `systemMessage` is discarded by Claude Code** (so is PostCompact's and
  SessionEnd's). A warning that must reach the user from a compaction goes through the journal and
  the SessionStart(compact) that follows.
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
- **Where subagent rows live depends on the Claude Code version.** Measured 2026-09-02: a current
  remote session wrote its Agent-tool subagent to `<sid>/subagents/agent-<id>.jsonl`, not the main
  transcript; cc-repete carries the same in-file `isSidechain` filter, for the same hazard, on
  the maintainer's versions. The filter is correct on both — do not remove it because one version
  "doesn't need it".
- **`tail -n` is a SUFFIX, and that is what makes the window correct.** Any main-thread row the
  window contains is necessarily the file's last one, so the window answer equals a full read. A
  `head`, a byte range, or a "middle" sample would not have that property.
- **The comment strip is in FIVE places, and only THREE of them read `.reload/config`** (`kv()`,
  `reload-config.sh get`, statusline's `context_window:` and `context_budget_pct:` greps — plus
  statusline's `.reload/model` `window:` grep, a different file). They are copies on purpose — the
  statusline and the config tool must not source `lib.sh` (its jq-exit and project-dir resolution)
  — and the parity test is what keeps the three honest. The `.reload/model` one is invisible to
  that loop (it only writes `.reload/config`), so it carries its own case; deleting its strip
  failed no test at all until 2026-09-02 F10. Adding a reader without adding it to the parity
  fixture — or assuming the loop covers a reader of another file — is how F04 comes back.

## Backlog (prioritized, with context)

1. ~~Verify `SessionStart source:"compact"` fires on auto-compaction~~ **Closed 2026-09-17:** the
   hooks reference's SessionStart `source` table reads "`compact` | Auto or manual compaction". The
   backstop rehydrate is automatic. (Docs fact, re-verify on a major CC release.)
2. **Marker mtime granularity**: the pass-2 freshness check uses `-nt`; on filesystems with 1s
   granularity a digest written in the same second as the marker reads as "not refreshed"
   (arms + warns — degraded but safe). Only matters if users report spurious stale warnings.
3. **Haiku 5+ ids**: `*haiku*` maps to 200K with no minor split. If a future Haiku ships 1M,
   add boundary-anchored cases before the heuristic misfires (config override covers the gap).
4. **Banner truncation byte-slices UTF-8 under macOS bash 3.2** (`_truncate` in
   `sessionstart-hook.sh` uses `${s:0:n}`, byte-based on bash 3.2 — 2026-07 audit F04, cosmetic;
   also byte-based on ANY bash when `LANG` is unset, measured 2026-09-02). If users report mojibake
   banners, replace with an awk-based char-safe cut:
   `awk -v n=60 '{print substr($0,1,n)}'` (awk substr is char-aware under a UTF-8 locale).
5. **Measure how often subagent rows share the main transcript on the Claude Code versions users
   run.** The main-thread filter (invariant 14) is correct either way; this decides whether the
   0.3.2 behaviour ever fired in the field and whether `WINDOW_LINES=2000` is generous enough
   (cc-repete cites 500 trailing sidechain lines as its design margin — an unverified
   bound, not a measured maximum). Done-when: a note here with a version → layout
   table from ≥3 real transcripts.
6. ~~The rehydrate injects the WHOLE digest with no size cap~~ **Closed in 0.5.0 (F05):** the banner
   warns above 9,500 chars (Claude Code's cap is 10,000) and the injection stays whole. Pinned by
   `test-concurrent.sh` "the full digest is still injected (no silent cut)".
7. **Local runs as root skip the chmod-based unwritable-dir cases** (`test-claim-digest.sh` prints
   SKIP). CI runs them as a normal user. If you develop as root, run that suite under `runuser`/a
   throwaway user before claiming the fail-open cases green.
8. **`SessionStart` on `resume` consumes an armed digest into a session that still has its context**
   (known, accepted — see landmines). If a "resume keeps context" signal ever appears in the hook
   payload, gate the consume on it and keep the model/window stamp.
9. **Pid reuse and network filesystems make `kill -0` lie in both directions** (invariant 21's
   limit). A recycled pid defers a legit restart's rehydrate (recoverable: the 🔒 notice names
   `/reload`); two machines sharing a directory can consume each other's arms as orphans. Claude
   Code 2.1.274 keeps `~/.claude/sessions/<pid>.json` (`sessionId`, `cwd`, `status`, `procStart`)
   — an undocumented registry that could confirm "that pid is a claude for THIS cwd". Done-when:
   a `pid_alive` refinement that consults the registry when present, with a case per direction,
   and a measured note here on which CC versions write it.
10. **Side-files are never cleaned up.** `session.<sid>.md` and `.<mtime>.md` copies accumulate
    under `.reload/` (git-ignored). A rehydrate from a side-file could offer to remove it; a
    `/reload --prune` could delete copies older than `context_owner_window`. Done-when: a documented
    policy in `docs/concurrent-sessions.md` and a test that the newest copy is never removed.
11. **`notified` is still shared** between sessions (an extra nudge — cosmetic). If it ever matters,
    key it per lineage like the arm (`notified.<pid>`) and purge orphans in SessionStart hygiene.
12. **Run the two-session drill on a real Claude Code** (two terminals, one directory) once per
    minor release and record the CC version here — the whole lineage design rests on `CLAUDE_PID`
    being exported to hooks, which only a live session can confirm. Last measured: 2.1.274,
    2026-09-17, via a nested `claude -p` SessionStart probe.
