# Design note — cc-reload: the digest is a singleton slot

**Status:** proposal, unimplemented. **Against:** cc-reload 0.2.0.
**Origin:** observed in the field 2026-07-25, two Claude Code sessions in one working tree of
`layerprocgen-babylon`. Claims below verified against installed 0.2.0 source; line numbers are that
source.
**Revised 2026-07-27** after a review panel — see the Clarifications section and
`.review-panel/concurrent-sessions.md`.

---

## 1. What happened

Session A ran `/cc-reload:snapshot` and wrote `.reload/session.md` (session-id
`faead16c-…`, Axes 3+4 spec work). Roughly 30 minutes later, session B — a different session in the
same directory — wrote its own digest to the same path.

Session A's digest was **gone.** Not merged, not backed up: overwritten. The file now read
`session_id: "ab942eff-…"` with entirely different content. Session A discovered this only
incidentally, when the file's frontmatter contradicted its own memory.

If session A had then hit `/clear` with a reload armed, it would have rehydrated **session B's
working thread** and resumed with confident, wrong context — the exact failure the plugin exists to
prevent, delivered by the plugin.

## 2. Root cause

The digest path is a single per-project slot with no session dimension:

- `lib.sh:15-17`
  ```sh
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  RELOAD_DIR="$PROJECT_DIR/.reload"
  DIGEST="$RELOAD_DIR/session.md"
  ```
- Both **agent-facing** write paths target it unconditionally: the `/snapshot` command
  (`commands/snapshot.md:21`, "overwrite") and the Stop-hook pass-1 REINJECT brief
  (`stop-hook.sh:156-172`, "write .reload/session.md (overwrite it)"). Note that **no hook writes
  the digest itself** — `grep -n DIGEST hooks/*.sh` shows Stop only reads it (`stop-hook.sh:50,52`);
  pass 1 touches `SUMMARIZING` and emits `{decision:"block"}`, and the *model* does the write on
  the next turn. The detector must therefore sit where the model can be made to call it, not
  where the hook happens to run.
- The PreCompact mechanical fallback is **not** a clobber risk: `precompact-hook.sh:24` is
  `if [ ! -f "$DIGEST" ]`, so it writes only when no digest exists. It is, however, the *only*
  writer that stamps a real `session_id` (`precompact-hook.sh:19,29`) — see §4.2.
- `PENDING`, `SUMMARIZING`, `NOTIFIED`, `MODELFILE` are single slots on the same basis. `PENDING`
  is the sharpest of these: `sessionstart-hook.sh:40-44` consumes whatever arm it finds, so a
  cross-session arm rehydrates the wrong thread outright.

One project, one digest. Two sessions, last writer wins, silently.

## 3. The constraint: session id cannot be the key here

The obvious fix — key the digest by `session_id` — **does not work for cc-reload**, and the plugin
already knows why. `sessionstart-hook.sh:35-39`:

> We do NOT also gate on session id: /clear (and resume) mint a fresh session id every time, so the
> armed digest is always stamped with the PRIOR id and an id-equality check would suppress the
> banner on its primary trigger 100% of the time.

That reasoning is correct and was learned the hard way (the staleness guard was removed in v0.1.5;
the comment recording it now lives in `precompact-hook.sh:15-17`, not in SessionStart where the
guard itself was). It also rules out the natural extension:

**Multi-slot storage (`.reload/sessions/<session-id>.md`) hits the same wall.** After `/clear`, the
new session has a new id and *no link to its predecessor*. It cannot know which slot is its own
lineage. You would need a successor→predecessor mapping that Claude Code does not provide.

Precisely: no *automatic* mapping. cc-operator 0.4.0 solves the same rotation problem with
`ops-adopt.sh` — the successor re-stamps its own id onto specific artifacts by **explicit id**, with
no "adopt everything" because "a bulk sweep in a shared tree is a takeover of another session's
tasks by another name" (`ops-adopt.sh:10-11`). That works there because the operator is already
running a recovery protocol and can name its tasks. It does **not** transfer here: the whole value
of cc-reload is that rehydration is automatic and requires nothing of a user whose context was just
wiped. Requiring a post-`/clear` "adopt your digest" step reintroduces the manual handoff the plugin
exists to remove. So multi-slot storage stays rejected — but on ergonomics, not impossibility.

So session id is the wrong key for cc-reload — the opposite conclusion from cc-operator, where
sentinels never need to outlive the session and session id is exactly right. Same symptom, same
root shape (unowned shared state), different correct answer.

## 4. Proposal

### 4.1 The real fix is cwd scoping — which already works

`PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"` means a **per-worktree `.reload/` isolates for free
today** (and where `CLAUDE_PROJECT_DIR` is unset the `$PWD` fallback gives the same answer).
`.reload/` is untracked and self-ignoring (`ensure_reload_dir`, `lib.sh:30-33`), so a new worktree
starts with an empty one. No code change needed for the isolation itself.

**The invariant to state explicitly in the README: one session per working directory.** cc-reload
is a per-*session* continuity tool storing state in a per-*project* location; the mismatch is
inherent, and the only clean resolution is that the two coincide. Today that invariant is
undocumented, so users violate it without knowing there is a rule.

The README deliverable, concretely — a "Known limitations" entry reading roughly:

> **One session per working directory.** `.reload/` is per-directory, not per-session: a second
> Claude Code session in the same tree shares the same digest and the same arm marker. Run
> concurrent sessions in separate worktrees. Since 0.3 the plugin detects and warns on a
> cross-session overwrite rather than losing the digest silently, but the isolation itself is
> yours to arrange.

Worth noting a subtlety if you document worktrees: Claude Code's `EnterWorktree` creates worktrees
under **`.claude/worktrees/`**. A project whose `.gitignore` lists `.worktrees/` (the more common
hand-rolled convention) does **not** match that path, so the worktrees land untracked-but-unignored.
Name the exact path in the README so readers ignore the right one.

### 4.2 Make the violation loud instead of silent (the actual code change)

Isolation-by-convention still needs a detector, because the failure is invisible. Cheapest sufficient
version: **stamp an owner and refuse to clobber a foreign live digest.**

#### 4.2.1 Identity is per-write, never a directory-global marker

An earlier revision of this note proposed a shared `.reload/owner` marker stamped by SessionStart.
**That design is wrong and is rejected here**, because a directory-global slot has the same defect
as the digest it was meant to protect: with A and B in one tree, B's SessionStart overwrites
`owner=A` with `owner=B` *before* either session writes. The marker then identifies neither the
incumbent nor the current writer, so the side-file gets attributed to the wrong session — or the
overwrite goes undetected entirely. Replacing an unowned singleton with a second unowned singleton
is not a fix.

Identity must therefore be **carried by each write**, and read back **from the artifact**, never
from shared mutable state.

**This is not speculative — cc-operator 0.4.0 shipped exactly this shape** for the companion defect
(§6). Its sentinels went from empty files to bodies stamping `session_id: <id>`
(`ops-task.sh:1-15`), owner read back from the artifact at Stop time
(`ops-stop-hook.sh:146`), and it explicitly refuses a directory-global owner for the reason above.
Two-session coverage is fixture-driven (`tests/fixtures/stop-session-{a,b}.json`), which also
settles that a bash harness can express this. Adopt the mechanism; the divergence is only in the
fail direction (§4.2.2).

Every writer can obtain its own real id:

| writer | can clobber? | identity source | available? |
|---|---|---|---|
| `/snapshot` command (`commands/snapshot.md:21-23`) | yes | `$CLAUDE_CODE_SESSION_ID` env var | **yes** — see the correction below |
| Stop pass-1 / pass-2 (`stop-hook.sh:43-69`, `:149-172`) | yes | `.session_id` on `HOOK_INPUT` | **yes** — `HOOK_INPUT` is read at `stop-hook.sh:34`, before pass 2; the hook simply does not parse the field today. `basename "$transcript_path" .jsonl` is an equivalent fallback (verified: the transcript filename *is* the session id) |
| PreCompact fallback (`precompact-hook.sh:24-37`) | no (absence-gated) | `.session_id` on hook input | **yes** — already parsed (`precompact-hook.sh:19`) |

**Correction — the env var exists under a different name.** Both this note and cc-operator recorded
that Bash tool subprocesses get no session id: `ops-task.sh:14` states "`CLAUDE_SESSION_ID` is NOT
set in the Bash tool environment", probed directly in the affected session. That probe used a
variable name that does not exist. The documented name is **`CLAUDE_CODE_SESSION_ID`**, and it *is*
set — verified in a Bash tool call, returning this session's id, matching the transcript basename.
Claude Code documents it as set in "Bash and PowerShell tool subprocesses, hook command subprocesses,
and stdio MCP server subprocesses", matching the hook payload's `session_id` and **updated on
`/clear`**. cc-operator's `--owner` plumbing (which routes the id through injected SessionStart
context instead) is therefore sound but more indirect than it needed to be; worth a follow-up there.

So the earlier claim that "`session_id` is unavailable on the clobbering paths" was wrong: it is
available on all three. What was true is that the *digest frontmatter* field is unreliable, because
both agent-facing writers are told "use it if known, else `\"\"`" (`commands/snapshot.md:23`,
`stop-hook.sh:161`) — a model-supplied value, not a runtime-supplied one.

The fix is to stop asking the model. **Every writer stamps its own id from the runtime**, and the
frontmatter `session_id` becomes runtime-written rather than model-written:

- `commands/snapshot.md` and the Stop pass-1 brief both instruct: set `session_id` from
  `$CLAUDE_CODE_SESSION_ID` (a shell substitution, not a recollection). If the variable is empty,
  write `""` — and that digest is then explicitly **undetectable**, per below.
- Stop parses `.session_id` from `HOOK_INPUT` (one added `jq` extraction at `stop-hook.sh:34`),
  falling back to the transcript basename.
- The **arm marker carries its owner as content**: `PENDING` stops being an empty `touch` and holds
  the arming session's id. Writer and artifact stay together; nothing else can overwrite it out of
  band.

**Un-owned is explicitly undetectable, not "assumed safe".** A digest with `session_id: ""` or no
frontmatter, or an arm with empty content, means the runtime did not supply an id on that path. The
detector then proceeds silently — fail-open per `CLAUDE.md` — and §4.4 states the resulting coverage
limit plainly rather than implying the guard is universal.

**Deliberate divergence from cc-operator on the fail direction.** There, an unowned sentinel
**blocks every session** (`ops-task.sh:10`, "omitted when unknown → unowned → blocks every
session") — fail-closed, because its sentinel is a *gate* and a gate that silently opens is the
whole defect. Here the equivalent choice would be to refuse the snapshot, which is strictly worse
than the data loss it prevents: cc-reload's failure mode is "the user loses a digest they can
rewrite", cc-operator's is "the completion guarantee is silently disarmed". A blocked snapshot also
violates `CLAUDE.md`'s standing rule that a broken hook must degrade to "plugin does nothing", never
to "session unusable". Same mechanism, opposite fail direction, for a reason that should survive
someone later noticing the inconsistency and "fixing" it.

#### 4.2.2 The check

The incumbent's id is read **from the digest's own frontmatter** (`session_id`), the writer's from
the runtime (§4.2.1). Before overwriting, if the incumbent carries a **non-empty** id that differs
from the writer's and the digest's **filesystem mtime** is within the freshness window:

- warn via `systemMessage` on hook paths — the mechanism is already in use throughout
  `stop-hook.sh` — and via ordinary visible output on the command path (a slash command cannot
  emit hook JSON; see §4.3);
- side-file the incumbent as `.reload/session.<other-id>.md` before writing. If that name already
  exists, append the incumbent's mtime (`.reload/session.<other-id>.<epoch>.md`) so nothing is
  ever lost to a repeat collision;
- proceed with the write (never block the user's snapshot). If the side-file copy itself fails
  (read-only `.reload`, disk full), **still warn, still proceed** — the user's snapshot is never
  sacrificed to preserve someone else's.

**Recency is filesystem mtime, not the frontmatter `updated_at`.** The precedent is
`stop-hook.sh:50` (`[ "$DIGEST" -nt "$SUMMARIZING" ]`), and mtime is written by the filesystem
rather than by a model that may omit or staledate the field. The known cost is `CLAUDE.md` backlog
item 2 — 1s mtime granularity — which here degrades to "warn slightly too often", the safe direction.

**The window is configurable:** a `context_owner_window` key in `.reload/config` (seconds, default
`14400` = 4h; `0` disables the check entirely, matching the `context_budget_pct: 0` convention).
Both `.reload/config` readers must learn it — `stop-hook.sh`'s `cfg` and `scripts/reload-config.sh`
validation.

Side-files are **never garbage-collected**. `.reload/.gitignore` is a lone `*` (`lib.sh:32`) so they
stay untracked, they are small, and they exist precisely because something went wrong — deleting
them on a schedule would discard the only copy of the evidence. Document the accumulation.

This keeps the arm/rehydrate contract untouched — `PENDING` remains the sole gate on the
*rehydrate* path, `/clear` keeps working — while converting a silent data loss into a visible one.
Note the honest limit: the side-file is **manually** recoverable, not automatically.
`sessionstart-hook.sh:41-44` reads only `$DIGEST`, so a subsequent `/clear` still rehydrates the
*winning* digest; recovering the loser means a human copying the side-file back. Teaching
SessionStart to offer side-files when armed is possible but is deliberately out of scope here.

Deliberately **not** proposed: gating rehydration on id equality (breaks `/clear`, see §3), or
locking the digest (a snapshot that fails because another session holds a lock is worse than a
warned overwrite).

#### 4.2.3 The same check for `PENDING`

The digest is the visible loss; `PENDING` is the dangerous one. `sessionstart-hook.sh:40-44`
consumes whatever arm it finds and injects whatever digest sits beside it — so a cross-session arm
does not merely lose work, it *rehydrates the wrong thread with confidence*, which is the failure
§1 describes.

So the arm carries its owner **as marker content** — `printf '%s' "$id" > "$PENDING"` instead of
`touch "$PENDING"` — for the same reason as §4.2.1: identity travels with the artifact, so nothing
can overwrite it out of band.

**What that content must be compared against is the correction below.** This section originally
said `SessionStart` compares the arm's owner to **its own** incoming id, and asserted that "ids
match ⇒ **no new gate on the happy path**." That assertion is false, and it contradicts this
spec's own §3: `/clear` mints a fresh session id every time, so the arm's owner and the consuming
session's id **never** match on the plugin's primary trigger. Shipped literally, it warned on 100%
of ordinary `/clear` rehydrations for a single user in a single directory, and — via §4.2.2's
comparator seeing an inherited digest as foreign — cut an unbounded side-file on every reset.
Both were caught by whole-branch review and reproduced live before release.

The error was comparing **identity** where the system needs **lineage**. A session id names one
session; what the guard must recognise is the chain S1→S2→S3 that one user produces by pressing
`/clear`. Two rules give us that:

**Claim on rehydrate.** Once `SessionStart` has injected the digest, this session *is* the one
carrying that working thread. It rewrites the digest's frontmatter `session_id` to its own id
(frontmatter-scoped — the body is model-written and untrusted; atomic temp-then-`mv`; silent and
non-fatal on any failure). "Inherited" becomes "mine", so §4.2.2's comparator is correctly silent
on the next snapshot. A genuinely foreign write — one that never passed through this handoff —
still collides and is still side-filed.

**Warn on incoherence, not on inequality.** The real signal is whether the arm and the digest
*agree*: whoever armed should also be who wrote the digest.

- `ARM_OWNER == DIGEST_OWNER` ⇒ a coherent handoff — the ordinary `/clear`, or a second session
  that armed its own snapshot. Rehydrate exactly as today, silently.
- `ARM_OWNER != DIGEST_OWNER`, both non-empty ⇒ **incoherent**: session A armed, then session B
  overwrote the digest beside that arm. The arm now points at a thread its armer never wrote —
  which is precisely the §1 failure. Still rehydrate (the v0.1.5 lesson holds — never suppress the
  banner), but prepend a warning naming both ids.
- Either side empty ⇒ silent (pre-0.3 arm, or a path with no runtime id; §4.4 limit 1).

This is strictly *more* precise than an id comparison, not weaker: it fires on a state that cannot
arise from a single session, and stays quiet on the state that arises at every reset. Neither
comparison involves the consuming session's own id, and the freshness window does not apply here —
an arm is one-shot and short-lived by construction.

The invariant is: the owner check may **add warnings**, never **subtract rehydrations**. §5
criterion 3 is the regression guard.

> **Lesson for the next revision of this document.** Any check that compares a session id against
> something that survives a reset will fire on every `/clear`. Before specifying such a comparison,
> state explicitly which side rotates — §3 already knew, and §4.2.3 did not consult it.

#### 4.2.4 Cost

The added work per write is one `awk` over ≤30 lines of frontmatter, one `stat` for mtime, and a
conditional `cp` of that same small file. Against `CLAUDE.md`'s ~1s Stop budget — currently
dominated by a single jq pass over a transcript that can be tens of MB — this is noise. Stated as an
explicit, bounded assumption; §5 criterion 8 makes it assertable.

### 4.3 The agent-facing write must be intercepted, not merely instructed

Both clobbering paths end in the *model* calling `Write` on `.reload/session.md`. Any detector
reached by a documented step — "run this check first" in `commands/snapshot.md` or in the Stop
pass-1 brief — is skippable by the actor it is meant to police, and a skipped step reproduces
exactly the unguarded overwrite of §1. Worse, a script tested directly still passes while the real
path goes unguarded, so the test suite would report green over the live defect.

Putting the logic in a script is necessary but **not sufficient**: it fixes testability and shares
one implementation, it does not fix enforcement. Enforcement needs the runtime to invoke the check.

**A `PreToolUse` hook is that interception point.** It "runs after Claude creates tool parameters
and before processing the tool call", receives `session_id`, `tool_name` and `tool_input` on stdin,
and for `Write` gets `tool_input.file_path` — so it fires before the overwrite lands, with the
writer's real identity in hand. Registering it in `hooks/hooks.json` alongside the existing three:

```json
"PreToolUse": [
  { "matcher": "Write|Edit",
    "hooks": [ { "type": "command",
                 "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/pretooluse-hook.sh\"" } ] }
]
```

`matcher` filters on **tool name only** — path scoping is done inside the hook by reading
`tool_input.file_path` and returning immediately unless it resolves to `$DIGEST`. (The handler-level
`if` field can express `Edit(path)` patterns, but its path-matching guarantee is documented for
`Edit`/`Read` and not for `Write`; doing the check in-script avoids depending on that.) The hook
performs the §4.2 comparison, side-files if warranted, and **permits the call by exiting 0** —
silence leaves the normal permission flow untouched, which is what this needs. It never exits
non-zero and never emits `permissionDecision: "deny"`: §4.2's "never block the user's snapshot"
holds at the mechanism level, not just by convention.

**Verified on this machine (Claude Code 2.1.220), not taken from documentation:**

| claim | evidence |
|---|---|
| `PreToolUse` is a real registerable event | `~/.claude/settings.json` registers it alongside `Stop`, `SessionStart`, `PreCompact` |
| `matcher` filters on tool name | live matchers in that file are `Bash` and `Grep\|Glob` |
| stdin carries `tool_input.<field>` | a working hook reads `jq -r '.tool_input.command'` (`~/.claude/hooks/PreToolUse/block-main-writes.sh:13`) |
| `Write` carries `file_path` | a real `Write` tool_use in this session's transcript has `input_keys: ["content","file_path"]` |
| exit 0 permits, exit 2 blocks | same hook: `exit 0` on the allow paths (`:23`, `:58`), `exit 2` to block (`:29`, `:35`, `:54`) |

The one field taken from documentation rather than observed here is `session_id` on the `PreToolUse`
payload. If it turns out absent, `basename "$transcript_path" .jsonl` is the same fallback §4.2.1
already specifies for Stop — the design does not depend on that single field.

The comparison logic itself lives in **`scripts/claim-digest.sh`**, called by the hook and directly
exercisable by the bash suites (which invoke only `hooks/*.sh` and `scripts/*.sh`). Two callers, one
implementation.

**The residual gap, stated plainly rather than papered over:** a `PreToolUse` hook covers the
model's built-in file tools. It does **not** cover a digest written by a `Bash` heredoc or `cat >`,
and Claude Code documents that `@`-referenced files bypass `PreToolUse` entirely. Nothing short of a
permission `deny` rule or the OS sandbox is unbypassable, and neither is appropriate here — denying
writes to the plugin's own digest would break the feature. So the honest guarantee is: **every write
through `Write`/`Edit` is detected; a write routed around those tools is not.** §5 criterion 2a
asserts the hook path; §4.4 records the limit.

`commands/snapshot.md` still gains the documented step, but as belt-and-braces for the visible
warning, explicitly *not* as the enforcement mechanism.

### 4.4 Coverage limits (what this does not guarantee)

State these in the README next to the §4.1 invariant, so the guard is not mistaken for a solution:

1. **Un-owned writes are undetectable.** If the runtime supplies no session id on some path, that
   write proceeds silently (§4.2.1). This is fail-open by choice.
2. **Non-`Write` writes are uncovered.** A digest written via `Bash` bypasses `PreToolUse` (§4.3).
3. **Recovery is manual.** The side-file is never consulted on rehydrate
   (`sessionstart-hook.sh:41-44`); a human restores it.
4. **The other markers are unguarded.** `SUMMARIZING`, `NOTIFIED`, `MODELFILE` remain shared
   singletons (§2). Only `PENDING` gains an owner (§4.2.3), because only it can rehydrate the wrong
   thread.
5. **This is a detector, not isolation.** The fix for concurrency is §4.1 — one session per working
   directory. §4.2–§4.3 only make a violation of that rule loud.

## 5. Acceptance criteria

Written against the existing bash harness (`tests/test-hooks.sh`, `tests/test-e2e.sh`), which runs
hooks with a per-test `CLAUDE_PROJECT_DIR` (`tests/test-hooks.sh:10-12`) and manipulates mtimes with
`touch -t` (`tests/test-hooks.sh:236,245`). Nothing below needs two live Claude Code sessions.

0. **No regression.** All four existing suites pass unchanged. Every currently-named invariant test
   in `CLAUDE.md` still passes.

1. **Isolation (stands in for "two worktrees").** Two distinct `CLAUDE_PROJECT_DIR` values produce
   two independent `.reload/` trees: a digest + arm written under `$TMP_A` is invisible to every
   hook run under `$TMP_B`, and each SessionStart rehydrates only its own digest. (Directly
   assertable; the "two concurrent sessions" framing was not.)

2. **Detection (unit).** Given a digest whose frontmatter carries `session_id: "S_A"` and whose
   mtime is inside the window, `scripts/claim-digest.sh` invoked with writer id `S_B` creates
   `.reload/session.S_A.md` holding the incumbent's bytes, prints a warning containing `S_A`, and
   exits 0 — leaving the digest itself untouched (the caller does the write).

2a. **Detection (enforced path).** `hooks/pretooluse-hook.sh` fed a synthetic `PreToolUse` payload
   — `{"session_id":"S_B","tool_name":"Write","tool_input":{"file_path":"<TMP>/.reload/session.md"}}`
   — produces the same side-file and **exits 0** (permitting the write); it never exits non-zero and
   never emits `permissionDecision: "deny"`. The same payload with `file_path` pointing anywhere
   else, or `tool_name` of `Read`, produces **no** side-file and no output. This is the criterion
   that proves the guard sits on the real write path rather than only in a script a model may skip.

3. **Rehydration is never suppressed.** Enumerated, not universal — SessionStart injects
   `additionalContext` for every one of: `{armed + clear, armed + compact, armed + resume,
   armed + clear immediately after a side-file event, armed with an arm-owner ≠ the digest's
   owner}`. The first three already have tests (`tests/test-hooks.sh:29-37`,
   `tests/test-hooks.sh:331-333`, `tests/test-e2e.sh` cycle 2.4); the last two are new. Regression
   guard for the v0.1.5 lesson: `grep` of `hooks/sessionstart-hook.sh` finds no id comparison
   governing an `exit`.

4. **An incoherent arm warns; an ordinary `/clear` does not.** Both halves are required — the
   second is what the pre-release revision of §4.2.3 got wrong.
   - *Warns:* `PENDING` containing `S_A` beside a digest owned by `S_B`, SessionStart invoked with
     any incoming id: emits `additionalContext` (criterion 3 holds) **and** a `systemMessage`
     naming both ids. Consumes the marker exactly once, as today.
   - *Silent:* `PENDING` containing `S_1` beside a digest owned by `S_1`, SessionStart invoked with
     a **fresh** id `S_2` — the ordinary `/clear`. No warning, and the digest's frontmatter
     `session_id` reads `S_2` afterwards (the lineage claim). A second cycle `S_2`→`S_3` is likewise
     silent, proving the claim persisted rather than the false positive merely being deferred one
     turn. An **empty** `PENDING` (pre-0.3 arm) rehydrates with no warning and leaves the stamp
     untouched.
   - *Untrusted body:* a digest whose **body** contains a line beginning `session_id:` has only its
     frontmatter rewritten by the claim; the body line survives byte-identical.

4a. **A single-session lifecycle is completely silent.** Through the real hooks:
   snapshot → arm → clear → rehydrate → snapshot again produces **zero** side-files and **zero**
   warnings. This is the end-to-end regression guard for the identity-vs-lineage defect; without it
   a later refactor reintroduces it invisibly, since every unit test can pass while the composed
   path misfires.

5. **Un-owned is silent.** Incumbent `session_id: ""`, or absent, or no frontmatter at all, or an id
   equal to the writer's, or a digest older than the window, or `context_owner_window: 0`: no
   side-file is created and no warning is emitted
   (`! jq -e '.systemMessage|test("different session|side-file")'`). No migration noise for pre-0.3
   state.

6. **Window boundary + config.** With the default 14400s: incumbent mtime 4h−1m ⇒ side-file; 4h+1m
   ⇒ silent. `context_owner_window` set to `60` moves the boundary accordingly;
   `scripts/reload-config.sh` rejects a non-numeric value and leaves the prior config intact.

7. **Never blocks, never fails the write.** `claim-digest.sh` exits 0, the `PreToolUse` hook never
   emits `permissionDecision: "deny"`, and the Stop hook emits no `decision` field
   (`jq -e '.decision == null'`) in every case above — including when `.reload/` is read-only, when
   the side-file target already exists, and when the digest is unreadable. The warning may be lost;
   the user's snapshot may not. (This is the fail-open counterpart to cc-operator's fail-closed
   sentinel; see §4.2.1.)

8. **Budget.** `claim-digest.sh` against a populated `.reload/` completes well inside the ~1s Stop
   budget (`CLAUDE.md`). Asserted as a coarse ceiling, not a benchmark.

9. **`repete_active` stand-down (`lib.sh:36-39`) unchanged** — and now covered for all three hooks,
   not only SessionStart. The current block (`tests/test-hooks.sh:39-45`) exercises SessionStart
   alone; extend it to Stop and PreCompact, and assert `claim-digest.sh` also stands down. cc-repete
   still owns continuity when a loop is live.

Out of band (no automated criterion): the README invariant and worktree-path note (§4.1) — verify
by review, or by a `grep` for the phrase "one session per working directory".

## 6. Relationship to the cc-operator note

Companion note: `cc-operator-plugin` → `docs/spec/concurrent-sessions.md`, **implemented in
cc-operator 0.4.0** (`781c4ae feat: session-owned sentinels + evidence-gate hardening`).

These were found together and share a root shape — **per-session state living in a per-project
location with no owner** — but they need different fixes, and conflating them would produce a wrong
design for one of the two:

| | cc-operator (shipped 0.4.0) | cc-reload (this note) |
|---|---|---|
| shared state | `.operator/pending/<id>` | `.reload/session.md`, `.reload/pending` |
| must outlive `/clear`? | **no** (intra-session by nature) | **yes** (that is the whole point) |
| primary key | **session id** | **cwd / worktree** (§4.1) |
| identity mechanism | `session_id:` stamped in the sentinel body (`ops-task.sh:1-15`) | `session_id` in digest frontmatter + arm-marker content (§4.2.1) |
| id rotation on `/clear` | explicit re-claim (`ops-adopt.sh`) | none — cwd is the lineage key, ids are for detection only |
| unowned artifact | **fail-closed** — blocks every session | **fail-open** — proceeds silently (§4.2.1) |
| enforcement point | the CLI is the only writer | `PreToolUse` on `Write`/`Edit` (§4.3) — the model writes directly |
| failure mode | one session blocks or disarms another's gate | one session's digest silently eaten |

The two bottom rows are where cc-reload cannot simply copy cc-operator. cc-operator owns its write
path — every mutation goes through `ops-task.sh` / `ops-verdict.sh`, so stamping identity there is
total. cc-reload's digest is written by the *model* with the `Write` tool, so identity has to be
injected into instructions and the check has to be intercepted at the tool boundary. That is the
entire reason §4.3 needs a `PreToolUse` hook where cc-operator needed nothing.

The single sentence covering both: *state scoped to a session must be keyed by something that
outlives exactly as long as the session does — session id when the state dies with the session, the
working directory when it must survive the session's own reset* — with the corollary that **the
owner must be stamped into the artifact, never into a shared slot beside it**, since a shared slot
reproduces the original defect one level up.

## Clarifications (2026-07-27)

Answers from a review panel over this note. §2, §4, and §5 above have been rewritten to match them
(and to correct three factual errors about the source — see the run report in
`.review-panel/concurrent-sessions.md`). Recorded here as the decision trail.

**Superseded by the 2026-07-27 adversarial pass:** Q1's answer below was a shared `.reload/owner`
marker. An adversarial review showed that design is broken — a directory-global slot is overwritten
by whichever session starts last, so it identifies neither party. §4.2.1 now stamps identity into
each artifact instead, matching what cc-operator 0.4.0 shipped. Q4's answer (a script) was likewise
necessary but insufficient: a script invoked by a documented step is skippable by the model it
polices, so §4.3 moves enforcement to a `PreToolUse` hook. Q2 and Q3 stand as answered.

- **Q (lens A+B): §4.2's owner stamp is load-bearing, but `session_id` is best-effort on both
  clobbering paths (`commands/snapshot.md:23`, `stop-hook.sh:161` — "if known, else `""`") and
  reliable only in PreCompact (`precompact-hook.sh:19,29`), which never clobbers. `stop-hook.sh`
  does not parse `.session_id` at all. How is the owner established?**
  → **A:** A **hook-stamped owner file.** SessionStart already parses real hook input
  (`sessionstart-hook.sh:12-17`); it writes the true session id to a new `.reload/owner` marker.
  Hooks and the snapshot path both read that instead of trusting the model to know its own id.
  Costs one new marker; reliable on every path.

- **Q (lens A): §2 names `PENDING`, `SUMMARIZING`, `NOTIFIED`, `MODELFILE` as single slots on the
  same basis, but §4 fixes only the digest. Cross-session `PENDING` consumption is the actual
  rehydrate-the-wrong-thread path. What is the scope?**
  → **A:** **Extend the detector to `PENDING`.** A cross-consumed arm silently rehydrates the
  wrong thread, which is the failure §1 describes; the digest fix alone does not close it.

- **Q (lens A+C): §4.2 leaves the side-file mechanics undefined — `< 4h` is hedged, the recency
  source is unstated (filesystem mtime vs frontmatter `updated_at`), and collision behavior for an
  existing `.reload/session.<id>.md` is unspecified.**
  → **A:** **Filesystem mtime, configurable threshold.** Recency from mtime (matching the existing
  precedent at `stop-hook.sh:50`, `-nt`); the window becomes a `.reload/config` key defaulting to
  4h, alongside `context_budget_pct`. Adds a config surface and a couplings-table row.

- **Q (lens B+C): §4.3 puts a parallel detector in `commands/snapshot.md`, but that file is model
  instructions — the bash suite never invokes command files, and a slash command cannot emit a
  hook `systemMessage`. Keep it?**
  → **A:** **Move detection into a hook.** The command shells out to a small
  `scripts/claim-digest.sh` that performs the owner/mtime check and the side-file in bash.
  Testable, enforceable, emits real output; costs a new script and a couplings-table row.
