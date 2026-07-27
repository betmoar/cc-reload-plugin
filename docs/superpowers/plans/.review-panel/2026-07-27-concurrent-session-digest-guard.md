# Panel run — 2026-07-27-concurrent-session-digest-guard.md  (2026-07-27 16:45)
- **artifact:** docs/superpowers/plans/2026-07-27-concurrent-session-digest-guard.md     **reviewer:** glm-review-design     **N:** 3
- **lenses:** A ambiguity · B contradictions/feasibility · C testability
- **per-lens:** A → 18 findings · B → 21 · C → 15   (tokens: A ~56k · B ~66k · C ~74k)
- **buckets:** must-resolve 7 · should-clarify 4 · consider 4 · dropped <50: 14
- **asked:** 4 should-clarify → answers in the artifact's Clarifications section
- **verdict:** The plan's design is sound and its anchors are (mostly) correct, but its TDD cycle
  is broken — the "verify it fails" step passes for 3+ assertions before any code exists, every
  stated pass-count is wrong, and one task silently defeats the feature on the `/snapshot` path.
  Not executable as written.

Every finding below was re-verified by the main model against HEAD, several by running the
assertions. Reviewer claims that did not survive are in the dropped section.

## Findings

### must-resolve

- **[100] TDD false-greens: the "verify it fails" step lies (lens C).** Confirmed by execution, not
  inspection. I ran Task 1 + Task 2's assertions with no implementation present:
  ```
  PASS: empty id reads empty (SHOULD FAIL pre-impl)
  PASS: claim silent (SHOULD FAIL pre-impl)
  PASS: no side-file (SHOULD FAIL pre-impl)
  FAIL: positive: reads S_A (correctly fails)
  => pass=3 fail=1
  ```
  `digest_owner: command not found` and `No such file or directory` both write to **stderr**,
  leaving stdout empty — so every `[ -z "$(...)" ]` and `[ ! -f ... ]` assertion passes vacuously.
  An implementer following the plan literally sees green and concludes the guard works. Affects
  Task 1 (3 of 8), Task 2 (7 of 14), Task 3 (6 of 11).
  **Fix:** gate the silent-case assertions on the implementation existing, e.g. prepend
  `[ -f "$ROOT/scripts/claim-digest.sh" ] &&`.

- **[100] All four stated pass-counts are wrong (lens C).** Counted directly:
  | Task | plan says | actual `ck` calls |
  |---|---|---|
  | 1 | 9 | **8** |
  | 2 | 24 cumulative | **22** |
  | 3 | 37 cumulative | **33** |
  | 4 | 11 new | **10** |
  A wrong expected count makes every verification step ambiguous — the implementer cannot tell a
  real failure from a miscount.

- **[95] Task 6 never updates `commands/snapshot.md:27`, defeating the feature on the `/snapshot`
  path (lens B).** Verified: that line is still `3. Arm the reload: \`touch .reload/pending\`.`
  Task 4 rewrites the Stop and PreCompact arms to stamp an owner, but the user-driven path keeps
  `touch`, producing a zero-byte arm that Task 4's own SessionStart logic classifies as "pre-0.3 —
  no warning". So every `/snapshot`-armed reload is permanently un-owned. This is the path that
  caused the original field incident (spec §1).

- **[90] `CLAUDE_PLUGIN_ROOT` is unbound in production, breaking the exit-0 contract (lens A).**
  `hooks/pretooluse-hook.sh` calls `bash "$CLAUDE_PLUGIN_ROOT/scripts/claim-digest.sh"` under
  `set -u`. Verified that **no production hook references that variable** — only the test harness
  sets it (`tests/test-hooks.sh:11`, `tests/test-e2e.sh:18`). If Claude Code interpolates it into
  the `command:` string rather than exporting it, the hook dies unbound and returns non-zero, which
  the runtime may read as a block — the one outcome the design forbids.
  **Fix:** use `"$(dirname "$0")/../scripts/claim-digest.sh"`, matching how every existing hook
  sources `lib.sh`.

- **[85] `kv()` is line-anchored, not frontmatter-scoped (lens B).** `hooks/lib.sh:44-48` greps
  `^session_id:` anywhere in the file. A digest whose **body** contains a line starting
  `session_id:` — trivially, an Open-questions bullet quoting one — returns that value as the owner.
  Since digest bodies are model-written and explicitly untrusted for quoting (`CLAUDE.md` invariant
  8), `digest_owner()` can be steered to a wrong owner, misfiring or suppressing the guard.
  **Fix:** scope the read to lines between the two `---` fences.

- **[80] Side-file TOCTOU can truncate the very digest being preserved (lens A+B).** `[ -e "$SIDE" ]`
  then `cp` is not atomic; two sessions racing both pass the check and both write the same path.
  **Resolved →** atomic create via tmp+`mv` (see Clarifications Q1).

- **[78] `claim-digest.sh` does not stand down for cc-repete (lens A+C).** Spec §5 criterion 9 asks
  for exactly this, and the plan defers it as "pre-existing, unrelated". It is neither: the script
  is new, and without `repete_active` it writes into `.reload/` during a live cc-repete loop —
  violating the standing invariant that cc-repete owns continuity.
  **Resolved →** add the guard and extend the tests (see Clarifications Q4).

### should-clarify  (→ asked)

- **[72] Side-file race has no synchronization (lens A+B).** → **A:** atomic tmp+`mv`, no lock.
- **[70] `[ "$FILE" = "$DIGEST" ]` misses symlinked/relative paths (lens A).** → **A:** normalize
  both sides with `cd "$(dirname …)" && pwd -P` (macOS has no `readlink -f`).
- **[65] Empty `SESSION_ID` makes the un-owned arm indistinguishable from a legacy one (lens B).**
  → **A:** only `printf` when non-empty; keep literal `touch` semantics otherwise.
- **[62] Spec criterion 9 deferred without owner (lens A+C).** → **A:** add the guard and the tests.

### consider

- **[58] `session.$INCUMBENT.md` interpolates an unsanitized id into a path (lens B).** A digest
  frontmatter carrying `session_id: "../../x"` writes outside `.reload/`. UUIDs are safe, but the
  field is model-written. cc-operator hit exactly this (`ops-verdict.sh:276` documents a 2026-07-10
  traversal through the same door). Restrict to `[A-Za-z0-9_-]`.

- **[55] `sessionstart-hook.sh:35-39`'s comment goes stale (lens A).** It states "We do NOT also gate
  on session id"; after Task 4 an id comparison *is* performed, for the warning. That comment is the
  living record of the v0.1.5 lesson (`CLAUDE.md` invariant 3) — it must distinguish "warn on
  mismatch" from "gate on equality" or the next reader re-introduces the bug.

- **[55] Spec criterion 6's mtime boundary is untested and unadmitted (lens C).** Task 2 tests only
  an extreme stale case (`202001010000`). Nothing exercises 4h−1m vs 4h+1m at the default window,
  which is the criterion's actual claim. The plan's self-review admits gaps at criteria 8 and 9 but
  not this one.

- **[52] `chmod 500` is a no-op under root, making the unwritable-dir test vacuous in CI (lens C).**
  Passes locally on macOS, silently proves nothing on a root CI runner. Guard with
  `[ "$(id -u)" -ne 0 ]`.

### dropped (<50)

- "Task 1's `libcall` / `$0` in `bash -c` does not work" — traced and executed; `$0` correctly
  resolves to the next argv. Lens B raised then self-retracted it; lens C confirmed it works.
- "`stat -f %m || stat -c %Y` chaining is wrong under `pipefail`" — traced by lens B and found
  correct. BSD runs first; the GNU fallback only fires if it fails.
- "`\"` escaping inside `ck`'s single-quoted eval'd argument is broken" — lens C traced it fully
  and confirmed it evaluates correctly.
- Line-anchor drift claims: `lib.sh:17,21`, `lib.sh:49`, `stop-hook.sh:34`, `:53`, `:161`,
  `sessionstart-hook.sh:68`, README `79/153/181/216` — all verified **correct** as written.
  (`precompact-hook.sh:21` vs `:22` was already fixed pre-panel.)
- "cc-operator's AUDIT_STATE.md does not exist" — it does; the reviewer's glob was scoped to this
  repo only.
- 8 further low-signal items (banner truncation cosmetics, `bash -n` not globbing `tests/`,
  Task 6 edit ordering, et al).
