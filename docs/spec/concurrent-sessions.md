# Design note — cc-reload: the digest is a singleton slot

**Status:** proposal, unimplemented. **Against:** cc-reload 0.2.0.
**Origin:** observed in the field 2026-07-25, two Claude Code sessions in one working tree of
`layerprocgen-babylon`. Claims below verified against installed 0.2.0 source; line numbers are that
source.

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
- Every writer targets it unconditionally: the `/snapshot` command (`commands/snapshot.md:23`,
  "overwrite"), the Stop-hook snapshot handshake (`stop-hook.sh:149-172`), and the PreCompact
  mechanical fallback (`precompact-hook.sh:24-37`).
- `PENDING`, `SUMMARIZING`, `NOTIFIED`, `MODELFILE` are single slots on the same basis.

One project, one digest. Two sessions, last writer wins, silently.

## 3. The constraint: session id cannot be the key here

The obvious fix — key the digest by `session_id` — **does not work for cc-reload**, and the plugin
already knows why. `sessionstart-hook.sh:35-39`:

> We do NOT also gate on session id: /clear (and resume) mint a fresh session id every time, so the
> armed digest is always stamped with the PRIOR id and an id-equality check would suppress the
> banner on its primary trigger 100% of the time.

That reasoning is correct and was learned the hard way (the staleness guard was removed in v0.1.5 —
`precompact-hook.sh:15-17`). It also rules out the natural extension:

**Multi-slot storage (`.reload/sessions/<session-id>.md`) hits the same wall.** After `/clear`, the
new session has a new id and *no link to its predecessor*. It cannot know which slot is its own
lineage. You would need a successor→predecessor mapping that Claude Code does not provide.

So session id is the wrong key for cc-reload — the opposite conclusion from cc-operator, where
sentinels never need to outlive the session and session id is exactly right. Same symptom, same
root shape (unowned shared state), different correct answer.

## 4. Proposal

### 4.1 The real fix is cwd scoping — which already works

`PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"` means a **per-worktree `.reload/` isolates for free
today**. `.reload/` is untracked and self-ignoring (`ensure_reload_dir`, `lib.sh:31-34`), so a new
worktree starts with an empty one. No code change needed for the isolation itself.

**The invariant to state explicitly in the README: one session per working directory.** cc-reload
is a per-*session* continuity tool storing state in a per-*project* location; the mismatch is
inherent, and the only clean resolution is that the two coincide. Today that invariant is
undocumented, so users violate it without knowing there is a rule.

Worth noting a subtlety if you document worktrees: `EnterWorktree` defaults to
`.claude/worktrees/`, which a project ignoring `.worktrees/` will **not** match. Mention the path.

### 4.2 Make the violation loud instead of silent (the actual code change)

Isolation-by-convention still needs a detector, because the failure is invisible. Cheapest sufficient
version: **stamp an owner and refuse to clobber a foreign live digest.**

On write (`/snapshot` and the Stop handshake), record the writing session's id and mtime. Before
overwriting, if the existing digest carries a **different** `session_id` and was modified recently
(say < 4h), do not silently replace it:

- warn via `systemMessage` — the mechanism is already in use throughout `stop-hook.sh`;
- side-file the incumbent as `.reload/session.<other-id>.md` before writing;
- proceed with the write (never block the user's snapshot).

This keeps the arm/rehydrate contract untouched — `PENDING` remains the sole gate, `/clear` keeps
working — while converting a silent data loss into a visible, recoverable one.

Deliberately **not** proposed: gating rehydration on id equality (breaks `/clear`, see §3), or
locking the digest (a snapshot that fails because another session holds a lock is worse than a
warned overwrite).

### 4.3 Optional: fold the id check into `/snapshot`'s procedure

`commands/snapshot.md` already runs a stand-down check for cc-repete
(`.repete/loop.local.md` → `active: true`). A parallel step — "if `.reload/session.md` exists with a
different `session_id` and a recent `updated_at`, side-file it and tell the user" — puts the
detector in the command as well as the hook, at documentation cost only.

## 5. Suggested acceptance criteria

1. Two sessions, two worktrees: each `/snapshot` writes its own `.reload/session.md`; neither sees
   the other. Each `/clear` rehydrates its own digest.
2. Two sessions, one tree: the second `/snapshot` side-files the incumbent as
   `.reload/session.<id>.md`, emits a `systemMessage`, and still writes successfully.
3. `/clear` with an armed reload rehydrates in **all** cases — including immediately after a
   side-file event. No id-equality gate anywhere on the rehydrate path (regression guard for the
   v0.1.5 lesson).
4. A digest with no `session_id` (pre-0.3 or a hand-written one) is treated as un-owned and
   overwritten without warning — no migration noise.
5. `repete_active` stand-down (`lib.sh:37-40`) unchanged; cc-repete still owns continuity when a
   loop is live.

## 6. Relationship to the cc-operator note

Companion note: `cc-operator-plugin` → `docs/spec/concurrent-sessions.md`.

These were found together and share a root shape — **per-session state living in a per-project
location with no owner** — but they need opposite fixes, and conflating them would produce a wrong
design for one of the two:

| | cc-operator | cc-reload |
|---|---|---|
| shared state | `.operator/pending/<id>` | `.reload/session.md` |
| must outlive `/clear`? | **no** (intra-session by nature) | **yes** (that is the whole point) |
| correct key | **session id** | **cwd / worktree** |
| failure mode | one session blocks or disarms another's gate | one session's digest silently eaten |

The single sentence covering both: *state scoped to a session must be keyed by something that
outlives exactly as long as the session does — session id when the state dies with the session, the
working directory when it must survive the session's own reset.*
