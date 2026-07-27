# Panel run — concurrent-sessions.md  (2026-07-27 15:55)
- **artifact:** docs/spec/concurrent-sessions.md     **reviewer:** glm-review-design     **N:** 3
- **lenses:** A ambiguity · B contradictions/feasibility · C testability
- **per-lens:** A → 14 findings · B → 11 · C → 12   (tokens: A ~28k · B ~26k · C ~40k)
- **buckets:** must-resolve 6 · should-clarify 4 · consider 5 · dropped <50: 12
- **asked:** 4 should-clarify → answers in the artifact's Clarifications section
- **verdict:** Diagnosis (§1–§3) is sound and verified. §4.2's owner check is structurally
  broken as written — the only writer that stamps a real `session_id` is the one that cannot
  clobber. Fix the owner plumbing before this is implementable.

All code claims re-verified by the main model against HEAD (0.2.0), not taken from the agents.

## Findings

### must-resolve

- **[95] §2:36 — PreCompact is NOT an unconditional writer (lens B).** `precompact-hook.sh:24`
  is `if [ ! -f "$DIGEST" ]; then` — it writes the fallback stub only when no digest exists.
  It can never clobber. Listing it beside `/snapshot` as an unconditional writer is factually
  wrong and inflates the blast radius.

- **[95] §2:35 — the Stop hook never writes the digest (lens B).** `grep -n DIGEST hooks/*.sh`
  shows Stop only *reads* it (`stop-hook.sh:50,52`). Lines 149-172 touch `SUMMARIZING` and emit
  `{decision:"block"}` with a REINJECT brief; the *model* writes the digest on the next turn,
  gated on its compliance. §2 should say "every agent-facing write path" — the hook is not a writer.

- **[90] §4.2:82 + §5.4 — the owner check no-ops on exactly the paths it guards (lens A+B).**
  The only writer stamping a real id is PreCompact (`precompact-hook.sh:19,29`) — the one that
  cannot clobber. Both clobbering paths hedge: `commands/snapshot.md:23` ("if known, else `\"\"`")
  and `stop-hook.sh:161` ("if known; else omit"). `stop-hook.sh:34-85` does not parse `.session_id`
  at all, and no test fixture passes one (`grep 'run stop-hook.sh'` over `tests/` → 0 hits with
  session_id). Criterion 4 then classifies the *common* case as "overwrite silently" — restoring
  the original bug under a new name.
  **Resolved →** hook-stamped owner file (see Clarifications Q1).

- **[85] §4.2:91 — "recoverable" overstates it (lens B).** `sessionstart-hook.sh:41-44` reads only
  `$DIGEST` and consumes `$PENDING`; the side-file is never on the rehydrate path. Session A's
  `/clear` still rehydrates B's digest. Say "manually recoverable", or teach SessionStart to
  consult side-files when armed.

- **[80] §5.3 — "rehydrates in **all** cases" is an unbounded universal (lens C).** Not assertable.
  Replace with the finite set {armed+clear, armed+compact, armed+resume, armed+immediately-after-
  side-file}. The first three already have tests: `tests/test-hooks.sh:29-37`, `tests/test-hooks.sh:331-333`,
  `tests/test-e2e.sh` cycle 2.4. Only the side-file case is new.

- **[78] §2:37 vs §4 — markers named as victims, then dropped (lens A).** `PENDING`, `SUMMARIZING`,
  `NOTIFIED`, `MODELFILE` are flagged as single slots, but §4 fixes only the digest. Cross-session
  `PENDING` consumption (`sessionstart-hook.sh:40-44`) is the actual rehydrate-the-wrong-thread
  path — worse than digest clobber. Session B's `/clear` also purges A's in-flight `SUMMARIZING`
  via `sessionstart-hook.sh:31`.
  **Resolved →** extend the detector to `PENDING` (see Clarifications Q2).

### should-clarify  (→ asked)

- **[72] §4.2:80-88 — four operator terms undefined (lens A):** "live", "foreign", "recent"
  (`say < 4h` — the only threshold in the spec, hedged at both `:84` and `:101`), "un-owned".
  Recency source also unstated: filesystem mtime (precedent: `stop-hook.sh:50` uses `-nt`) vs
  the model-written `updated_at` frontmatter. Collision behavior for an existing
  `.reload/session.<id>.md` unspecified.
  → **A:** mtime, configurable threshold (default 4h) as a `.reload/config` key.

- **[70] §4.3:97-102 — the command-level check is unenforceable and untestable (lens B+C).**
  `commands/snapshot.md` is model instructions; the bash suite invokes only `hooks/*.sh` and
  `scripts/*.sh`. A slash command also cannot emit a hook `systemMessage` — only hooks can —
  so §4.2's stated warning mechanism does not exist on that path.
  → **A:** move detection into `scripts/claim-digest.sh`, called by the command.

- **[68] §4.2 — how is the owner established at all (lens A+B).** See must-resolve [90].
  → **A:** SessionStart stamps a `.reload/owner` marker from real hook input.

- **[65] §2:37 / §4 — marker scope (lens A).** See must-resolve [78].
  → **A:** extend the detector to `PENDING`.

### consider

- **[58] §4.2:87 — side-file failure and collision paths (lens A).** Undefined when the id is
  empty, when the target already exists, or when the side-file write itself fails (read-only
  `.reload`, disk full). "Never block the user's snapshot" is stated for the main write only.

- **[55] §4.2:87 — no retention rule (lens A+C).** `.reload/.gitignore` is a lone `*` (`lib.sh:32`),
  so side-files stay untracked forever. No cleanup hook exists today (only `rm -f` of
  summarizing/notified/pending at `sessionstart-hook.sh:31`, `stop-hook.sh:51`). State the rule
  or state the accumulation is accepted.

- **[55] §5 — no criterion for the ~1s Stop budget (lens C).** `CLAUDE.md` sets it; the proposal
  adds a frontmatter parse + `stat` + conditional copy on a hot path. The suite times nothing
  (`grep -n 'time\|date +%s%N' tests/` → no measurements). State the assumption as intentional
  and bounded, or add a timing assertion.

- **[52] §5.5 — repete stand-down is only half-tested (lens C).** `tests/test-hooks.sh:39-45`
  exercises SessionStart alone; Stop and PreCompact standing down under `.repete/loop.local.md`
  are unverified. "Unchanged" needs the block extended to all three hooks.

- **[52] §4.1:74-75 — the worktree sentence is unparseable (lens A+B).** "a project ignoring
  `.worktrees/`" contradicts the preceding clause naming `.claude/worktrees/`; which ignore file
  the reader must edit, and what string goes in it, are both unstated. §4.1's README deliverable
  is likewise named but not drafted.

### dropped (<50)

- §5.1 "two worktrees untestable" (lens C) — the harness pins `CLAUDE_PROJECT_DIR` per `run()`
  (`tests/test-hooks.sh:10-12`); a second `TMP_B` covers it. Rewording is worth doing but the
  claim of untestability is wrong.
- §3 vs §4.2 "session id contradiction" (lens B, self-retracted by the agent) — different paths:
  detection on write vs gating on rehydrate. §4.2 explicitly disclaims the latter.
- Line-number drift: `commands/snapshot.md:23`→`:21` for the "overwrite" quote,
  `sessionstart-hook.sh:35`→`:36`, `lib.sh:31-34`→`:30-33`, `lib.sh:37-40`→`:36-39`. Cosmetic;
  fix in passing.
- `CLAUDE_PROJECT_DIR` worktree resolution (lens B, unverified) — the fallback is `$PWD`
  (`lib.sh:15`), so the isolation argument holds either way.
- Pass-2 `-nt` freshness racing the side-file copy (lens A, unverified) — already documented as
  `CLAUDE.md` backlog item 2; not new.
- 6 further low-signal items across the three reports (mtime feasibility under BSD, "§3 rejection
  incomplete", "state the no-regression criterion", et al).
