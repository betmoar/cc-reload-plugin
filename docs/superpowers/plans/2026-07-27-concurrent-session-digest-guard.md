# Concurrent-Session Digest Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a cross-session digest overwrite loud and recoverable instead of silent, by stamping each write with a runtime-supplied session id and intercepting the model's `Write` at the tool boundary.

**Architecture:** Identity travels *with the artifact* — the digest's `session_id` frontmatter and the arm marker's file content — never in a shared marker beside them (a directory-global owner slot reproduces the very defect being fixed; see spec §4.2.1). One shared comparator, `scripts/claim-digest.sh`, is called by a new `PreToolUse` hook that fires on the model's `Write`/`Edit` before the overwrite lands. The guard only ever *adds warnings and side-files*; it never blocks a write, never denies a tool call, and never suppresses a rehydration.

**Tech Stack:** bash 3.2 (macOS default), `jq`, coreutils. No frameworks. Tests are plain bash scripts whose exit code is the failure count.

**Spec:** `docs/spec/concurrent-sessions.md` (committed at `2d32195`). Every task below cites the spec section it implements. Read §4.2.1 before Task 2 — the rejected-alternatives argument there is the reason for the whole design.

## Global Constraints

Copied verbatim from `CLAUDE.md`; these apply to every task.

- **Dependency-free:** bash + jq + coreutils only. No new dependencies.
- **BSD/macOS portable:** `touch -t` not `touch -d`; literal ESC byte not `\x1b` in sed; no GNU-only flags. `test -nt` is second-granularity on bash 3.2.
- **`set -uo pipefail`, never `-e`.** Fail-open: a broken hook degrades to "plugin does nothing", never "session unusable". Guard specific failure points explicitly (`touch … || exit 0`).
- **Hooks are silent when they have nothing to say.** No output = no user-visible noise. Never emit partial/invalid JSON; build all JSON with `jq -n --arg`, never string interpolation — digest content is untrusted for quoting purposes.
- **Stop hook stays under ~1s** on a large transcript. One jq pass over the transcript, no additional full-file reads.
- **Every writer path goes through `ensure_reload_dir`** (`hooks/lib.sh:30-33`) so `.reload/.gitignore` (a lone `*`) always exists.
- **Every behavior change gets a test in the same commit.**
- **Gate (run all four, exit code = failure count):**
  ```bash
  bash tests/test-hooks.sh && bash tests/test-statusline.sh && \
  bash tests/test-config.sh && bash tests/test-e2e.sh
  ```
- **CI additionally runs:** `bash -n` on `hooks/*.sh scripts/*.sh`, and `shellcheck -S warning hooks/*.sh scripts/*.sh tests/*.sh`. New scripts must pass both.
- **Branch:** work on `docs/concurrent-session-digest-scoping` (already checked out) or a fresh `feat/` branch. Never commit on `main`. Stage only files you changed; never blanket `git add <dir>`.

## Baseline (record before changing anything)

Run the gate now and write the numbers down. Every task reports its delta against this.

```bash
cd /Users/redux/Development/repos/cc-reload-plugin
bash tests/test-hooks.sh; echo "hooks exit=$?"
bash tests/test-statusline.sh; echo "statusline exit=$?"
bash tests/test-config.sh; echo "config exit=$?"
bash tests/test-e2e.sh; echo "e2e exit=$?"
```

All four must exit 0 before Task 1. If any suite is already red, stop and report — do not build on a broken baseline.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `hooks/lib.sh` | Modify | Add `OWNER_WINDOW_DEFAULT`, `digest_owner()`, `owner_window()`. Shared readers only — no side effects. |
| `scripts/claim-digest.sh` | Create | The comparator. Takes a writer id, decides side-file-or-not, performs it, prints a human-readable warning. Exit 0 always. Single implementation shared by both callers. |
| `hooks/pretooluse-hook.sh` | Create | The enforcement point. Reads `PreToolUse` payload, filters to `Write`/`Edit` on `$DIGEST`, delegates to `claim-digest.sh`, exits 0 to permit. |
| `hooks/hooks.json` | Modify | Register `PreToolUse` with `matcher: "Write\|Edit"`. |
| `hooks/stop-hook.sh` | Modify | Parse `.session_id` (fallback: transcript basename); write it into `PENDING`; add the id to the pass-1 REINJECT brief. |
| `hooks/sessionstart-hook.sh` | Modify | Compare `PENDING` content to own session id; prepend a warning to the banner on mismatch. Never gate rehydration on it. |
| `hooks/precompact-hook.sh` | Modify | Write its already-known session id into `PENDING`. |
| `commands/snapshot.md` | Modify | Instruct: stamp `session_id` from `$CLAUDE_CODE_SESSION_ID`; run `claim-digest.sh` first (belt-and-braces, not enforcement). |
| `scripts/reload-config.sh` | Modify | Accept and validate the `context_owner_window` key. |
| `tests/test-claim-digest.sh` | Create | Unit tests for the comparator + the `PreToolUse` hook. New suite. |
| `tests/test-hooks.sh` | Modify | Arm-ownership cases for SessionStart/Stop/PreCompact. |
| `tests/test-config.sh` | Modify | Validation cases for the new config key. |
| `tests/test-e2e.sh` | Modify | Cycle 7: two-session collision through the real hooks. |
| `.github/workflows/ci.yml` | Modify | Run the new suite. |
| `README.md` | Modify | The §4.1 invariant, the §4.4 coverage limits, the new config key, the hook table. |
| `CLAUDE.md` | Modify | New invariants + couplings rows. |

**Ordering rationale:** Tasks 1–3 build the comparator bottom-up (shared readers → script → enforcement hook), each independently testable. Task 4 handles arm ownership, which is a separate artifact with separate semantics. Task 5 is config. Tasks 6–7 are the agent-facing instruction changes and the cross-hook e2e. Task 8 is docs. A reviewer can reject any one without unwinding its neighbors.

---

### Task 1: Shared owner readers in `lib.sh`

Implements spec §4.2.1 (identity read back from the artifact) and §4.2.2 (mtime recency, configurable window).

**Files:**
- Modify: `hooks/lib.sh` (append after `cfg()`, which ends at line 49)
- Test: `tests/test-claim-digest.sh` (create)

**Interfaces:**
- Consumes: `kv()` and `cfg()` (`hooks/lib.sh:44-49`), `$DIGEST`, `$CONFIG` (`hooks/lib.sh:17,21`).
- Produces:
  - `digest_owner()` → prints the digest's frontmatter `session_id` value, or empty string when the file, the field, or the value is absent. No arguments.
  - `owner_window()` → prints the freshness window in seconds. `context_owner_window` from config when it is a non-negative integer; `14400` otherwise. No arguments.
  - `OWNER_WINDOW_DEFAULT=14400` — the constant, so tests and `reload-config.sh` messages can cite one source.

- [ ] **Step 1: Write the failing test**

Create `tests/test-claim-digest.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
# claim-digest.sh + pretooluse-hook.sh tests. Run: bash tests/test-claim-digest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.reload"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required (lib.sh exits silently without it, which would false-green this whole suite)"; exit 99; }
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

# A "nothing happened" assertion must not pass merely because the implementation
# is MISSING. `foo: command not found` and `No such file` both go to stderr and
# leave stdout empty, so a bare [ -z "$(...)" ] passes before any code exists —
# which would make the TDD "verify it fails" step lie. Gate those on the
# implementation being present.
have(){ [ -f "$ROOT/$1" ]; }
have_fn(){ grep -q "^$1()" "$ROOT/hooks/lib.sh" 2>/dev/null; }

# Source lib.sh the way a hook does, with the temp dir as the project.
# In `bash -c '<script>' ARG`, $0 is set to ARG — so $0 is $ROOT here, and the
# function name is interpolated from the OUTER function's $1. Do not "fix" this.
libcall(){ # libcall <function-name>   (bare identifier only — it is interpolated)
  CLAUDE_PROJECT_DIR="$TMP" bash -c \
    'source "$0/hooks/lib.sh"; '"$1" "$ROOT"
}

echo "== digest_owner: reads the frontmatter session_id =="
printf -- '---\nsession_id: "S_A"\nupdated_at: "x"\nintent: "i"\n---\n' > "$TMP/.reload/session.md"
ck "reads a quoted id" '[ "$(libcall digest_owner)" = "S_A" ]'

printf -- '---\nsession_id: ""\n---\n' > "$TMP/.reload/session.md"
ck "empty id reads empty" 'have_fn digest_owner && [ -z "$(libcall digest_owner)" ]'

printf -- '## Done this stretch\nno frontmatter at all\n' > "$TMP/.reload/session.md"
ck "no frontmatter reads empty" 'have_fn digest_owner && [ -z "$(libcall digest_owner)" ]'

# The body is UNTRUSTED (CLAUDE.md invariant 8). kv() greps ^session_id: anywhere
# in the file, so a body line starting with it would be read as the owner.
printf -- '---\nsession_id: "S_A"\n---\n## Open questions\nsession_id: NOT-THE-OWNER\n' > "$TMP/.reload/session.md"
ck "body line does NOT override frontmatter" '[ "$(libcall digest_owner)" = "S_A" ]'

rm -f "$TMP/.reload/session.md"
ck "absent digest reads empty" 'have_fn digest_owner && [ -z "$(libcall digest_owner)" ]'

echo "== owner_window: default and override =="
rm -f "$TMP/.reload/config"
ck "default is 14400" '[ "$(libcall owner_window)" = "14400" ]'
printf 'context_owner_window: 60\n' > "$TMP/.reload/config"
ck "override honored" '[ "$(libcall owner_window)" = "60" ]'
printf 'context_owner_window: 0\n' > "$TMP/.reload/config"
ck "zero honored (disables)" '[ "$(libcall owner_window)" = "0" ]'
printf 'context_owner_window: garbage\n' > "$TMP/.reload/config"
ck "garbage falls back to default" '[ "$(libcall owner_window)" = "14400" ]'
rm -f "$TMP/.reload/config"

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-claim-digest.sh`
Expected: **9 FAIL, 0 PASS** — stderr shows `digest_owner: command not found` / `owner_window: command not found` for each.

If any assertion PASSes here, stop: the `have_fn` guard is missing from it. A "nothing happened"
assertion that passes because nothing *exists* is a false-green, and it would make every later
verification step in this plan meaningless.

- [ ] **Step 3: Write minimal implementation**

Append to `hooks/lib.sh`, after `cfg()` (line 49):

```bash
# --- concurrent-session ownership (see docs/spec/concurrent-sessions.md §4.2) ---
#
# Identity lives IN the artifact, never in a shared marker beside it: a
# directory-global owner file is overwritten by whichever session starts last,
# so it identifies neither the incumbent nor the writer — the same defect as the
# unowned digest it would be guarding (spec §4.2.1, rejected alternative).

OWNER_WINDOW_DEFAULT=14400   # 4h, in seconds

# The digest's stamped owner, or "" when absent/empty/un-parseable. An empty
# result means UNDETECTABLE, not "safe" — callers proceed silently (fail-open).
#
# NOT kv(): that greps ^session_id: anywhere in the file, and a digest BODY is
# model-written and untrusted (invariant 8) — an "Open questions" bullet reading
# `session_id: whatever` would be picked up as the owner. Scope to the YAML
# frontmatter: start at the opening ---, stop at the closing one. One awk pass.
digest_owner() {
  [ -f "$DIGEST" ] || return 0
  awk '
    NR==1 && $0 != "---" { exit }          # no frontmatter at all
    NR>1 && $0 == "---"  { exit }          # closing fence: stop before the body
    /^session_id:/ {
      sub(/^session_id:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print; exit
    }
  ' "$DIGEST" 2>/dev/null
}

# Freshness window in seconds. A non-negative integer in config wins; anything
# else (unset, garbage, negative) falls back to the default. 0 disables the
# check entirely, matching the context_budget_pct: 0 convention.
owner_window() {
  local w; w="$(cfg context_owner_window)"
  [[ "$w" =~ ^[0-9]+$ ]] && printf '%s' "$w" || printf '%s' "$OWNER_WINDOW_DEFAULT"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-claim-digest.sh`
Expected: `RESULT: 9 passed, 0 failed`, exit 0. (9 = the 8 original assertions plus the untrusted-body one.)

Then confirm no regression:
```bash
bash tests/test-hooks.sh && bash tests/test-e2e.sh
```
Expected: both exit 0, same pass counts as baseline.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib.sh tests/test-claim-digest.sh
git commit -m "feat(lib): digest_owner + owner_window readers for the ownership guard"
```

---

### Task 2: `scripts/claim-digest.sh` — the comparator

Implements spec §4.2.2. This is the whole decision, in one place, so both callers behave identically.

**Files:**
- Create: `scripts/claim-digest.sh`
- Test: `tests/test-claim-digest.sh` (extend)

**Interfaces:**
- Consumes: `digest_owner()`, `owner_window()`, `ensure_reload_dir()`, `$DIGEST`, `$RELOAD_DIR` from `hooks/lib.sh`.
- Produces: `scripts/claim-digest.sh <writer-session-id>`
  - **Exit code: always 0.** Never non-zero, under any condition. Callers depend on this.
  - **Side-files** the incumbent to `$RELOAD_DIR/session.<incumbent-id>.md` when: incumbent id is non-empty **and** differs from `<writer-session-id>` **and** the writer id is non-empty **and** the digest's mtime is within `owner_window()` seconds of now **and** the window is non-zero.
  - On side-file name collision, appends the incumbent's mtime: `session.<id>.<epoch>.md`.
  - **stdout:** a one-line warning naming the incumbent id and the side-file path, only when a side-file was attempted. Silent otherwise.
  - If the copy itself fails, still warns (text names the failure), still exits 0.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-claim-digest.sh`, immediately before the final `echo; echo "RESULT:..."` line:

```bash
claim(){ CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/scripts/claim-digest.sh" "$@"; }
fresh_digest(){ # fresh_digest <owner-id>  -> a digest owned by <owner-id>, mtime now
  printf -- '---\nsession_id: "%s"\nupdated_at: "x"\nintent: "work by %s"\n---\n## Done this stretch\n- BODY-%s\n' \
    "$1" "$1" "$1" > "$TMP/.reload/session.md"
}
reset_reload(){ rm -f "$TMP"/.reload/session.*.md "$TMP/.reload/session.md" "$TMP/.reload/config"; }

echo "== claim-digest: foreign fresh incumbent is side-filed =="
reset_reload; fresh_digest S_A
OUT="$(claim S_B)"
ck "side-file created" '[ -f "$TMP/.reload/session.S_A.md" ]'
ck "side-file holds the incumbent body" 'grep -q "BODY-S_A" "$TMP/.reload/session.S_A.md"'
ck "warning names the incumbent" 'printf "%s" "$OUT" | grep -q "S_A"'
ck "exit 0" 'claim S_B >/dev/null; [ $? -eq 0 ]'
ck "digest itself untouched (caller writes it)" 'grep -q "BODY-S_A" "$TMP/.reload/session.md"'

echo "== claim-digest: collision appends mtime =="
reset_reload; fresh_digest S_A
claim S_B >/dev/null                      # first side-file
fresh_digest S_A                          # incumbent returns
claim S_B >/dev/null                      # second collision
ck "a second side-file exists" '[ "$(ls "$TMP"/.reload/session.S_A.*.md 2>/dev/null | wc -l)" -ge 1 ]'

echo "== claim-digest: silent when un-owned or self or stale or disabled =="
# NOTE: every "silent" assertion is gated on `have scripts/claim-digest.sh` — a
# missing script also produces empty stdout and no side-file, so an ungated
# assertion here passes BEFORE the implementation exists (false-green).
reset_reload; fresh_digest ""
ck "empty incumbent id -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session..md" ]'

reset_reload; fresh_digest S_B
ck "self-owned -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_B.md" ]'

reset_reload; fresh_digest S_A
ck "empty writer id -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim "")" ]'

reset_reload; fresh_digest S_A
touch -t 202001010000 "$TMP/.reload/session.md"      # far outside any window
ck "stale incumbent -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'

reset_reload; fresh_digest S_A
printf 'context_owner_window: 0\n' > "$TMP/.reload/config"
ck "window 0 disables -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'
reset_reload

echo "== claim-digest: the 4h default-window boundary (spec criterion 6) =="
# The criterion's actual claim is about the DEFAULT window, not an extreme date.
reset_reload; fresh_digest S_A
touch -t "$(date -v-239M +%Y%m%d%H%M 2>/dev/null || date -d '239 minutes ago' +%Y%m%d%H%M)" "$TMP/.reload/session.md"
ck "3h59m old -> side-filed" 'claim S_B >/dev/null; [ -f "$TMP/.reload/session.S_A.md" ]'

reset_reload; fresh_digest S_A
touch -t "$(date -v-241M +%Y%m%d%H%M 2>/dev/null || date -d '241 minutes ago' +%Y%m%d%H%M)" "$TMP/.reload/session.md"
ck "4h01m old -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'
reset_reload

echo "== claim-digest: stands down for a cc-repete loop (spec criterion 9) =="
fresh_digest S_A
mkdir -p "$TMP/.repete"; printf -- '---\nactive: true\n---\n' > "$TMP/.repete/loop.local.md"
ck "repete active -> no side-file" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'
rm -rf "$TMP/.repete"
ck "repete gone -> guard resumes" 'claim S_B >/dev/null; [ -f "$TMP/.reload/session.S_A.md" ]'
reset_reload

echo "== claim-digest: a hostile owner id cannot escape .reload/ =="
# The frontmatter is model-written and untrusted. cc-operator hit exactly this
# (ops-verdict.sh:276 records a 2026-07-10 path traversal through the same door).
reset_reload
printf -- '---\nsession_id: "../../ESCAPED"\nupdated_at: "x"\nintent: "hostile"\n---\n## Done this stretch\n- BODY-EVIL\n' > "$TMP/.reload/session.md"
claim S_B >/dev/null
ck "no file written outside .reload/" '[ ! -e "$TMP/../ESCAPED.md" ] && [ ! -e "$TMP/ESCAPED.md" ]'
reset_reload

echo "== claim-digest: no digest at all -> silent, exit 0 =="
ck "absent digest silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ]'
ck "absent digest exits 0" 'have scripts/claim-digest.sh && { claim S_B >/dev/null; [ $? -eq 0 ]; }'

echo "== claim-digest: unwritable .reload still exits 0 and still warns (fail-open) =="
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP: running as root — chmod 500 does not block root, assertion would be vacuous"
else
  fresh_digest S_A
  chmod 500 "$TMP/.reload"
  OUT="$(claim S_B)"; RC=$?
  chmod 700 "$TMP/.reload"
  ck "unwritable dir still exits 0" '[ "$RC" -eq 0 ]'
  ck "unwritable dir still warns" 'printf "%s" "$OUT" | grep -q "could NOT be saved aside"'
fi
reset_reload
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-claim-digest.sh`
Expected: the 9 Task-1 assertions still pass; **all 18 new ones FAIL** (stderr:
`bash: .../scripts/claim-digest.sh: No such file or directory`).

The `have scripts/claim-digest.sh &&` prefix is what makes that true. Without it the six
"silent" assertions would PASS against a missing script — verified by running them: a missing
script writes to stderr, leaves stdout empty, and creates no side-file, which is byte-identical
to correct silent behavior. If you see any PASS among the new 18, a guard is missing.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/claim-digest.sh`:

```bash
#!/usr/bin/env bash
#
# claim-digest.sh — the concurrent-session guard's comparator.
#
# Called with the WRITING session's id, immediately before something overwrites
# .reload/session.md. If the digest on disk is owned by a DIFFERENT session and
# was written recently, copy it aside so the incumbent's work is recoverable,
# and say so. Then get out of the way: the caller does the actual write.
#
# EXITS 0 UNCONDITIONALLY. This runs in front of the user's snapshot; a guard
# that can fail the write it guards is worse than the data loss it prevents
# (docs/spec/concurrent-sessions.md §4.2.2). cc-operator's equivalent sentinel
# fails CLOSED because it guards a gate; this one fails OPEN because it guards
# a convenience. That divergence is deliberate — see spec §4.2.1.
#
# On "unconditionally": lib.sh is SOURCED and its `command -v jq || exit 0`
# (lib.sh:24) exits THIS script — with 0, which is the contract, not a violation.
# That is the intended landmine (CLAUDE.md "known landmines"): no jq, no guard,
# no noise. Do not "fix" it into a `return`.
#
# Usage: claim-digest.sh <writer-session-id>
set -uo pipefail

source "$(dirname "$0")/../hooks/lib.sh"
repete_active && exit 0    # cc-repete owns continuity while a loop is live

WRITER="${1:-}"

# Nothing to protect, or nothing to compare with: proceed silently. An empty
# writer id means the runtime gave this path no identity — UNDETECTABLE, which
# the spec (§4.4 limit 1) states as a known coverage gap rather than hiding.
[ -f "$DIGEST" ] || exit 0
[ -n "$WRITER" ] || exit 0

INCUMBENT="$(digest_owner)"
[ -n "$INCUMBENT" ] || exit 0                 # un-owned: pre-0.3 or hand-written
[ "$INCUMBENT" != "$WRITER" ] || exit 0       # our own digest

WINDOW="$(owner_window)"
[ "$WINDOW" -gt 0 ] || exit 0                 # explicitly disabled

# Recency from FILESYSTEM MTIME, not the frontmatter updated_at: mtime is
# written by the OS, updated_at by a model that may omit or staledate it. The
# precedent is stop-hook.sh:50 (`-nt`). `stat -f %m` is the BSD/macOS form.
MTIME="$(stat -f %m "$DIGEST" 2>/dev/null || stat -c %Y "$DIGEST" 2>/dev/null)" || exit 0
[ -n "$MTIME" ] || exit 0
NOW="$(date +%s)"
AGE=$(( NOW - MTIME ))
[ "$AGE" -lt "$WINDOW" ] || exit 0             # stale: assume the owner is gone

# A foreign, live digest. Preserve it, then let the caller overwrite.
ensure_reload_dir

# The incumbent id comes from model-written frontmatter and is interpolated into
# a PATH. Anything outside [A-Za-z0-9_-] is stripped, so `../../x` cannot escape
# .reload/ — cc-operator hit exactly this door (ops-verdict.sh:276, the
# 2026-07-10 traversal). A real session id is a UUID and survives untouched.
SAFE_ID="$(printf '%s' "$INCUMBENT" | tr -cd 'A-Za-z0-9_-')"
[ -n "$SAFE_ID" ] || SAFE_ID="unknown"

SIDE="$RELOAD_DIR/session.$SAFE_ID.md"
[ -e "$SIDE" ] && SIDE="$RELOAD_DIR/session.$SAFE_ID.$MTIME.md"

# Two sessions can reach here at the same instant: a bare `[ -e ] && cp` is
# TOCTOU, and both would cp to the same path, truncating the copy that exists to
# prevent exactly this loss. Write to a pid-unique temp, then mv — atomic on
# POSIX within one filesystem, and no lock a fail-open guard could hang on.
TMP_SIDE="$SIDE.tmp.$$"
if cp "$DIGEST" "$TMP_SIDE" 2>/dev/null && mv "$TMP_SIDE" "$SIDE" 2>/dev/null; then
  printf 'cc-reload: .reload/session.md belongs to a different session (%s) and was written %ds ago. Saved it to %s before overwriting. Two sessions are sharing this directory — see README "Known limitations".\n' \
    "$INCUMBENT" "$AGE" "$SIDE"
else
  rm -f "$TMP_SIDE" 2>/dev/null   # never leave a truncated partial behind
  printf 'cc-reload: .reload/session.md belongs to a different session (%s) and is about to be overwritten, but it could NOT be saved aside (%s is unwritable). Proceeding — your snapshot is not blocked.\n' \
    "$INCUMBENT" "$RELOAD_DIR"
fi
exit 0
```

Make it executable: `chmod +x scripts/claim-digest.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-claim-digest.sh`
Expected: `RESULT: 27 passed, 0 failed`, exit 0 (9 from Task 1 + 18 here). One fewer if you are
running as root — the unwritable-dir block prints `SKIP` instead, since `chmod 500` does not
constrain root and the assertion would pass vacuously.

Lint (CI runs these):
```bash
bash -n scripts/claim-digest.sh && shellcheck -S warning scripts/claim-digest.sh
```
Expected: no output, exit 0.

Regression: `bash tests/test-hooks.sh && bash tests/test-e2e.sh` — both exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/claim-digest.sh tests/test-claim-digest.sh
git commit -m "feat(scripts): claim-digest.sh side-files a foreign live digest, never blocks"
```

---

### Task 3: `PreToolUse` hook — the enforcement point

Implements spec §4.3. **This is the task that makes the guard real**: a script invoked by a documented step is skippable by the model it polices, and its own unit tests pass green over the unguarded live path.

**Files:**
- Create: `hooks/pretooluse-hook.sh`
- Modify: `hooks/hooks.json`
- Test: `tests/test-claim-digest.sh` (extend)

**Interfaces:**
- Consumes: `scripts/claim-digest.sh` (Task 2), `$DIGEST` from `lib.sh`.
- Produces: a hook reading a `PreToolUse` JSON payload on stdin with fields `session_id`, `tool_name`, `tool_input.file_path`. Exits 0 always (permits). Emits no JSON.

**Verified contract** (checked against Claude Code 2.1.220 on the author's machine, not taken from docs — spec §4.3 records the evidence):
- `matcher` filters on **tool name only**; path scoping must be done inside the hook.
- A real `Write` tool_use carries `input_keys: ["content","file_path"]`.
- `exit 0` permits the call; `exit 2` blocks it. A working example lives at `~/.claude/hooks/PreToolUse/block-main-writes.sh`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-claim-digest.sh`, before the final `RESULT` line:

```bash
pth(){ # pth <json>  -> run the PreToolUse hook with that payload
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$ROOT/hooks/pretooluse-hook.sh"
}

echo "== PreToolUse: Write to the digest triggers the guard =="
reset_reload; fresh_digest S_A
OUT="$(pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}")"
ck "side-files on the enforced path" '[ -f "$TMP/.reload/session.S_A.md" ]'
ck "permits the write (exit 0)" 'have hooks/pretooluse-hook.sh && { pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" >/dev/null; [ $? -eq 0 ]; }'
ck "never denies" 'have hooks/pretooluse-hook.sh && ! printf "%s" "$OUT" | grep -q "deny"'

echo "== PreToolUse: Edit is covered too =="
reset_reload; fresh_digest S_A
pth "{\"session_id\":\"S_B\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" >/dev/null
ck "Edit side-files" '[ -f "$TMP/.reload/session.S_A.md" ]'

echo "== PreToolUse: unrelated paths and tools are untouched =="
reset_reload; fresh_digest S_A
OUT="$(pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/somewhere-else.md\"}}")"
ck "other path -> no side-file" 'have hooks/pretooluse-hook.sh && [ ! -f "$TMP/.reload/session.S_A.md" ]'
ck "other path -> silent" 'have hooks/pretooluse-hook.sh && [ -z "$OUT" ]'

reset_reload; fresh_digest S_A
OUT="$(pth "{\"session_id\":\"S_B\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}")"
ck "Read -> no side-file" 'have hooks/pretooluse-hook.sh && [ ! -f "$TMP/.reload/session.S_A.md" ]'
ck "Read -> silent" 'have hooks/pretooluse-hook.sh && [ -z "$OUT" ]'

echo "== PreToolUse: a symlinked path still matches (no silent miss) =="
reset_reload; fresh_digest S_A
ln -s .reload "$TMP/linked-reload" 2>/dev/null
pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/linked-reload/session.md\"}}" >/dev/null
ck "symlinked digest path fires the guard" '[ -f "$TMP/.reload/session.S_A.md" ]'
rm -f "$TMP/linked-reload"
reset_reload

echo "== PreToolUse: malformed payload fails open =="
reset_reload; fresh_digest S_A
ck "empty stdin exits 0" 'have hooks/pretooluse-hook.sh && { printf "" | CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/pretooluse-hook.sh" >/dev/null 2>&1; [ $? -eq 0 ]; }'
ck "garbage stdin exits 0" 'have hooks/pretooluse-hook.sh && { printf "not json" | CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/pretooluse-hook.sh" >/dev/null 2>&1; [ $? -eq 0 ]; }'
ck "missing session_id exits 0" 'have hooks/pretooluse-hook.sh && { pth "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" >/dev/null; [ $? -eq 0 ]; }'
# The hook must not reference $CLAUDE_PLUGIN_ROOT: under `set -u` an unexported
# var is a fatal unbound error, and no production hook in this plugin gets it.
ck "does not depend on CLAUDE_PLUGIN_ROOT" '! grep -q "CLAUDE_PLUGIN_ROOT" "$ROOT/hooks/pretooluse-hook.sh"'
reset_reload
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-claim-digest.sh`
Expected: the 27 Task-1+2 assertions pass; **all 13 new ones FAIL**. As in Task 2, the `have
hooks/pretooluse-hook.sh &&` prefix is what forces the silent-case assertions to fail against a
missing hook rather than passing vacuously.

- [ ] **Step 3: Write minimal implementation**

Create `hooks/pretooluse-hook.sh`:

```bash
#!/usr/bin/env bash
#
# cc-reload PreToolUse hook — the enforcement point for the ownership guard.
#
# Fires before the MODEL's Write/Edit is processed. Both paths that can clobber
# the digest end in the model calling Write, so a check reached by a documented
# step ("run this first") is skippable by the actor it polices — and its unit
# tests would pass green over the unguarded live path. This hook is what makes
# the guard unskippable for the built-in file tools.
# See docs/spec/concurrent-sessions.md §4.3 (and §4.4 for what it does NOT cover:
# a digest written via a Bash heredoc bypasses PreToolUse entirely).
#
# ALWAYS exits 0 — permits the write. It must never block a snapshot.
#
source "$(dirname "$0")/lib.sh"
repete_active && exit 0

HOOK_INPUT="$(cat)"

# matcher filters on TOOL NAME only, so path scoping happens here. Anything that
# is not a write to OUR digest is none of our business — leave silently.
FILE="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || exit 0
[ -n "$FILE" ] || exit 0

# Compare RESOLVED paths, not strings. A symlinked .reload/, a symlinked
# worktree, or a relative file_path would all miss a string compare — and a
# guard that silently fails to fire is worse than no guard, since the user
# believes they are covered. `cd … && pwd -P` is the portable resolver;
# macOS has no `readlink -f`.
_resolve() { # _resolve <path> -> absolute, symlinks resolved; empty if the dir is gone
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  d="$(cd "$d" 2>/dev/null && pwd -P)" || return 0
  printf '%s/%s' "$d" "$b"
}
[ "$(_resolve "$FILE")" = "$(_resolve "$DIGEST")" ] || exit 0

TOOL="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac

SID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SID" ] || exit 0    # no runtime identity on this path -> undetectable

# Path via $0, NOT $CLAUDE_PLUGIN_ROOT: under `set -u` an unexported variable is
# a fatal unbound error, which would make this hook exit non-zero — the one
# outcome its contract forbids. No production hook in this plugin references
# that variable; only the test harness sets it. $0 is always defined.
bash "$(dirname "$0")/../scripts/claim-digest.sh" "$SID" 2>/dev/null
exit 0
```

> **Note on `$DIGEST` comparison:** `tool_input.file_path` is absolute, and `$DIGEST` is built from `$CLAUDE_PROJECT_DIR` (`lib.sh:15-17`), so a plain string compare is correct when both are absolute. If field reports show a relative or symlinked `file_path`, normalize both sides — but do not add that complexity speculatively.

Register it in `hooks/hooks.json` — add this entry inside the `"hooks"` object, alongside the existing `SessionStart` / `PreCompact` / `Stop` keys:

```json
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/pretooluse-hook.sh\""
          }
        ]
      }
    ]
```

**Do not** also declare hooks in `plugin.json` — a duplicate declaration is a plugin load error (the v0.1.2 regression, `CLAUDE.md` couplings table).

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test-claim-digest.sh
jq -e . hooks/hooks.json >/dev/null && echo "hooks.json valid"
bash -n hooks/pretooluse-hook.sh && shellcheck -S warning hooks/pretooluse-hook.sh
```
Expected: `RESULT: 40 passed, 0 failed` (9 + 18 + 13; one fewer as root); `hooks.json valid`; lints silent.

Regression: `bash tests/test-hooks.sh && bash tests/test-e2e.sh` — both exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/pretooluse-hook.sh hooks/hooks.json tests/test-claim-digest.sh
git commit -m "feat(hooks): PreToolUse guard intercepts the model's digest write"
```

---

### Task 4: Arm ownership — `PENDING` carries its owner

Implements spec §4.2.3. The digest is the visible loss; the arm is the dangerous one — `sessionstart-hook.sh:40-44` consumes whatever arm it finds and injects whatever digest sits beside it, so a cross-session arm rehydrates the wrong thread *with confidence*.

**The invariant this task must not break:** the check may **add warnings**, never **subtract rehydrations**. Gating rehydration on id equality is the v0.1.5 bug (spec §3, `CLAUDE.md` invariant 3) — `/clear` mints a fresh id every time, so an equality gate suppresses the banner on its primary trigger 100% of the time.

**Files:**
- Modify: `hooks/stop-hook.sh` (line 34 area; line 53; the REINJECT heredoc at 156-172)
- Modify: `hooks/precompact-hook.sh:22`
- Modify: `hooks/sessionstart-hook.sh:40-44` and the `MSG=` assembly at line 68
- Test: `tests/test-hooks.sh`

**Interfaces:**
- Consumes: `$PENDING` (`lib.sh:18`), `HOOK_INPUT` (already read at `stop-hook.sh:34`, `sessionstart-hook.sh:12`, `precompact-hook.sh:18`).
- Produces: `$PENDING` file **content** is now the arming session's id (was an empty `touch`). Empty content = pre-0.3 arm = no warning.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-hooks.sh`, before the final `RESULT` line:

```bash
echo "== Arm ownership: PENDING carries the arming session's id =="
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S1"\nupdated_at: "x"\nintent: "own thread"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"

# PreCompact arms with its own id.
run precompact-hook.sh '{"session_id":"S_PC","trigger":"manual"}' >/dev/null
ck "precompact stamps the arm" '[ "$(cat "$TMP/.reload/pending")" = "S_PC" ]'

# Same-session rehydrate: no warning.
OUT="$(run sessionstart-hook.sh '{"session_id":"S_PC","source":"clear"}')"
ck "own arm rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "own arm warns nothing" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'

# Cross-session arm: STILL rehydrates, but warns.
printf 'S_A' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S_B","source":"clear"}')"
ck "foreign arm STILL rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "foreign arm warns" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'
ck "foreign arm still consumed" '[ ! -f "$TMP/.reload/pending" ]'

# Pre-0.3 empty arm: rehydrates, no warning, no migration noise.
touch "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S_B","source":"clear"}')"
ck "empty arm rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "empty arm warns nothing" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'

echo "== Structural guard: no id-equality condition governs an exit (v0.1.5) =="
# Spec criterion 3's second prong. The behavioral tests above prove rehydration
# happens on the inputs we thought to try; this proves nobody re-introduced the
# gate itself. An id comparison may set a warning flag — it must never reach exit.
ck "no id comparison guards an exit" '! grep -nE "(ARM_OWNER|SESSION_ID).*(&&|\|\|).*exit|exit.*(ARM_OWNER|SESSION_ID)" "$H/sessionstart-hook.sh"'

echo "== Stop pass 2 stamps the arm from its own payload =="
rm -f "$TMP/.reload/pending"
touch -t 202001010000 "$TMP/.reload/summarizing"
touch "$TMP/.reload/session.md"     # fresher than the marker
OUT="$(run stop-hook.sh "{\"session_id\":\"S_STOP\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "stop pass2 stamps the arm" '[ "$(cat "$TMP/.reload/pending")" = "S_STOP" ]'

# Fallback: no session_id field, but a transcript path whose basename is the id.
rm -f "$TMP/.reload/pending"
touch -t 202001010000 "$TMP/.reload/summarizing"; touch "$TMP/.reload/session.md"
printf '{}\n' > "$TMP/S_FALLBACK.jsonl"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/S_FALLBACK.jsonl\"}")"
ck "stop falls back to transcript basename" '[ "$(cat "$TMP/.reload/pending")" = "S_FALLBACK" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hooks.sh`
Expected: baseline assertions still pass; the new ones FAIL — `pending` is empty (the hooks still `touch` it), and no warning text exists.

- [ ] **Step 3: Write minimal implementation**

**3a.** In `hooks/stop-hook.sh`, immediately after `HOOK_INPUT="$(cat)"` (line 34), insert:

```bash
# This session's id, for arm ownership (spec §4.2.3). Stop's payload carries
# session_id; the transcript filename IS the session id (verified), so its
# basename is an equivalent fallback if the field is ever absent. Parsed HERE,
# before pass 2, because pass 2 must not depend on the transcript being readable.
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
if [ -z "$SESSION_ID" ]; then
  _tp="$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)"
  [ -n "$_tp" ] && SESSION_ID="$(basename "$_tp" .jsonl)"
fi
```

**3b.** In `hooks/stop-hook.sh`, replace line 53 (`    touch "$PENDING"`) with:

```bash
    # Stamp the arm's owner when we have one. When we do NOT, fall back to the
    # literal `touch` rather than writing an empty file: an empty arm must keep
    # meaning exactly what it means today (a pre-0.3 / un-owned arm), or the
    # unknown-id case silently becomes the new default and the ownership tests
    # would be asserting the fallback rather than the feature.
    if [ -n "$SESSION_ID" ]; then
      printf '%s' "$SESSION_ID" > "$PENDING" 2>/dev/null || touch "$PENDING" 2>/dev/null
    else
      touch "$PENDING" 2>/dev/null
    fi
```

**3c.** In `hooks/stop-hook.sh`, in the pass-1 REINJECT heredoc, replace the frontmatter line

```
  session_id: "<this session id, if known; else omit>"
```

with

```
  session_id: "<run: echo "$CLAUDE_CODE_SESSION_ID" — paste that value; if empty, use an empty string>"
```

Use this phrasing **verbatim** — Task 6 puts the same sentence in `commands/snapshot.md`, and two
paraphrases of one rule will drift.

**3d.** In `hooks/precompact-hook.sh`, replace line 22 (`touch "$PENDING"   # arm: rehydrate after compaction completes`) with:

```bash
# arm + stamp its owner (same non-empty guard as stop-hook.sh — see 3b)
if [ -n "$SESSION_ID" ]; then
  printf '%s' "$SESSION_ID" > "$PENDING" 2>/dev/null || touch "$PENDING" 2>/dev/null
else
  touch "$PENDING" 2>/dev/null
fi
```

`SESSION_ID` is already extracted at `precompact-hook.sh:19` for the fallback digest's frontmatter,
so no new parse is needed here. Note the existing PreCompact test fixture (`tests/test-hooks.sh:48`)
passes **no** `session_id`, so it exercises the `touch` branch — the new stamping assertion in
Step 1 uses its own payload that does carry one.

**3e.** In `hooks/sessionstart-hook.sh`, insert **after line 41** (`[ -f "$DIGEST" ] || { rm -f "$PENDING"; exit 0; }`) and before line 43's `BODY=` — after, not before, so the arm is only inspected once a digest is known to exist:

```bash
# Arm ownership (spec §4.2.3). WARNS on a foreign arm; NEVER gates on it —
# /clear mints a fresh id every time, so an equality gate would suppress the
# banner on its primary trigger (the v0.1.5 lesson, invariant 3).
ARM_OWNER="$(cat "$PENDING" 2>/dev/null)"
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
FOREIGN_ARM=""
[ -n "$ARM_OWNER" ] && [ -n "$SESSION_ID" ] && [ "$ARM_OWNER" != "$SESSION_ID" ] && FOREIGN_ARM=1
```

**3f.** In `hooks/sessionstart-hook.sh`, amend the standing comment at lines 34-39. It currently
reads "We do NOT also gate on session id …" — after 3e an id comparison *is* performed, and that
comment is the living record of the v0.1.5 lesson (`CLAUDE.md` invariant 3). Leaving it stale is
how the bug comes back. Append to it:

```bash
# (Since 0.3 we DO compare ids — but only to WARN. The gate above is still the
# arm alone. "Warn on mismatch" and "gate on equality" are different things:
# the second is the v0.1.5 bug, the first is what makes a cross-session arm
# visible. Never let the comparison reach an `exit`.)
```

**3g.** In `hooks/sessionstart-hook.sh`, replace line 68 (`MSG="🔄 cc-reload (${SOURCE})"`) with:

```bash
MSG="🔄 cc-reload (${SOURCE})"
[ -n "$FOREIGN_ARM" ] && MSG="⚠️ armed by a different session in this directory ($ARM_OWNER) — verify before trusting it | $MSG"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test-hooks.sh
```
Expected: all baseline assertions plus 11 new ones (10 behavioral + the structural grep) pass; exit 0.

Regression — the whole gate:
```bash
bash tests/test-hooks.sh && bash tests/test-statusline.sh && \
bash tests/test-config.sh && bash tests/test-e2e.sh && \
bash tests/test-claim-digest.sh
```
Expected: all exit 0.

Lints: `for f in hooks/*.sh; do bash -n "$f"; done && shellcheck -S warning hooks/*.sh`

- [ ] **Step 5: Commit**

```bash
git add hooks/stop-hook.sh hooks/precompact-hook.sh hooks/sessionstart-hook.sh tests/test-hooks.sh
git commit -m "feat(hooks): arm marker carries its owner; foreign arm warns but never blocks rehydrate"
```

---

### Task 5: `context_owner_window` config key

Implements spec §4.2.2 (configurable window). `scripts/reload-config.sh` is the only validated writer of `.reload/config`.

**Files:**
- Modify: `scripts/reload-config.sh:29` (known-keys list) and the validation `case` at line 41
- Modify: `commands/reload-budget.md`
- Test: `tests/test-config.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `reload-config.sh set context_owner_window <seconds>` — accepts a non-negative integer, or `off` (normalized to `0`). Rejects anything else with exit 2 and leaves the config untouched. `get` reads it back.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-config.sh`, before its final `RESULT` line:

```bash
echo "== context_owner_window: accepted, validated, normalized =="
OUT="$(rc set context_owner_window 3600)"
ck "sets a numeric window" 'grep -q "^context_owner_window: 3600$" "$TMP/.reload/config"'
ck "reads back" '[ "$(rc get context_owner_window)" = "3600" ]'
ck "off normalizes to 0" 'rc set context_owner_window off >/dev/null; [ "$(rc get context_owner_window)" = "0" ]'
ck "0 is valid (disables)" 'rc set context_owner_window 0 >/dev/null; [ $? -eq 0 ]'
ck "rejects garbage" '! rc set context_owner_window abc 2>/dev/null'
ck "rejects negative" '! rc set context_owner_window -5 2>/dev/null'
rc set context_owner_window 3600 >/dev/null
rc set context_owner_window abc >/dev/null 2>&1
ck "rejected value leaves config intact" '[ "$(rc get context_owner_window)" = "3600" ]'
ck "unrelated keys preserved" 'rc set context_budget_pct 30 >/dev/null; [ "$(rc get context_owner_window)" = "3600" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-config.sh`
Expected: new assertions FAIL — `reload-config.sh` dies with `unknown key 'context_owner_window'`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/reload-config.sh`, extend the known-keys guard (line 29):

```bash
  context_budget_pct|context_budget_mode|context_window|context_owner_window) ;;
  *) die "unknown key '$KEY' (known keys: context_budget_pct, context_budget_mode, context_window, context_owner_window)" ;;
```

And add a validation branch inside the `case "$KEY" in` block at line 41, after the `context_window)` branch:

```bash
  context_owner_window)
    # Seconds. 0 (or `off`) disables the concurrent-session ownership check,
    # matching the context_budget_pct: 0 convention.
    [ "$VAL" = "off" ] && VAL=0
    [[ "$VAL" =~ ^[0-9]+$ ]] \
      || die "context_owner_window must be seconds >= 0 or 'off' (got '$VAL'); default 14400 (4h), 0 disables the cross-session digest check"
    ;;
```

Update the usage comment at the top of the file (line 13-14 area) to list the new key:

```bash
#   reload-config.sh set context_owner_window <seconds | off>   (default 14400)
```

In `commands/reload-budget.md`, add this line alongside the existing budget keys (match the
surrounding bullet style — open the file and mirror whatever prefix the neighbouring keys use):

```markdown
- `context_owner_window <seconds | off>` — how recently another session must have written
  `.reload/session.md` for an overwrite to count as a live collision worth side-filing.
  Default `14400` (4h). `off` disables the cross-session check entirely.
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test-config.sh
bash -n scripts/reload-config.sh && shellcheck -S warning scripts/reload-config.sh
```
Expected: all pass, exit 0; lints silent.

- [ ] **Step 5: Commit**

```bash
git add scripts/reload-config.sh commands/reload-budget.md tests/test-config.sh
git commit -m "feat(config): context_owner_window key for the ownership freshness window"
```

---

### Task 6: `/snapshot` stamps a runtime id

Implements spec §4.2.1 (stop asking the model to recall its id) and §4.3's belt-and-braces clause. `commands/snapshot.md` is model instruction — this is **not** the enforcement point (Task 3 is), and the plan says so on purpose so nobody later deletes the hook believing this covers it.

**Files:**
- Modify: `commands/snapshot.md:21-27`
- Modify: `templates/session.md:13`

**Interfaces:**
- Consumes: `scripts/claim-digest.sh` (Task 2), `$CLAUDE_CODE_SESSION_ID` (verified set in Bash tool subprocesses on CC 2.1.220; equals the transcript basename; re-set on `/clear`).
- Produces: digests whose `session_id` is runtime-supplied rather than model-recalled.

- [ ] **Step 1: Update the command procedure**

In `commands/snapshot.md`, replace step 2's frontmatter bullet (line 23):

```markdown
   - frontmatter: `session_id` — run: `echo "$CLAUDE_CODE_SESSION_ID"` — paste that value;
     if empty, use an empty string. Do NOT recall it from memory.
     `updated_at` (output of `date -u +%Y-%m-%dT%H:%M:%SZ`), `intent` (one line).
```

(Same sentence as the Stop REINJECT brief in Task 4 step 3c, deliberately.)

And insert a new step between the current steps 1 and 2:

```markdown
2. Check for a concurrent session before overwriting:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/claim-digest.sh" "$CLAUDE_CODE_SESSION_ID"`
   If it prints a warning, relay it to the user verbatim — another session in this directory
   owns the current digest and it has been saved aside. Never skip the write because of this;
   the script has already preserved the incumbent. (This is a courtesy check: the PreToolUse
   hook enforces the same guard on the actual write, so skipping this step loses the early
   warning, not the protection.)
```

Renumber the following steps accordingly (the existing 2→3, 3→4, 4→5). **Do the insertion first,
then the line-23 replacement against the shifted position** — otherwise the line numbers move under
you.

- [ ] **Step 1b: Stamp the arm on this path too — do not skip this**

The current `commands/snapshot.md:27` reads:

```markdown
3. Arm the reload: `touch .reload/pending`.
```

Replace it with (it becomes step 4 after the renumber):

```markdown
4. Arm the reload, stamping this session as its owner:
   `printf '%s' "$CLAUDE_CODE_SESSION_ID" > .reload/pending`
   (if the variable is empty, `touch .reload/pending` instead — an un-owned arm is better than
   a wrong one).
```

**Why this step is load-bearing:** Task 4 makes the Stop and PreCompact arms carry an owner, but
`/snapshot` is the *user-driven* path — the one that caused the field incident in spec §1. If it
keeps calling bare `touch`, it writes a zero-byte arm, which Task 4's own SessionStart logic
classifies as "pre-0.3 — no warning". Every `/snapshot`-armed reload would then be permanently
un-owned and the cross-session warning would never fire on the path that needs it most.

- [ ] **Step 2: Update the template comment**

Leave `templates/session.md:13` (`session_id: ""`) exactly as it is — the field and its empty
default are unchanged. Only document its source: insert this line into the HTML comment block,
immediately after line 10 (`  auto-compaction always has a recent snapshot to fall back on. Overwrite in place.`)
and before the closing `-->` on line 11:

```
  session_id is the RUNTIME session id — `echo "$CLAUDE_CODE_SESSION_ID"`, never recalled from
  memory. It is what lets a second session in this directory detect that it is about to
  overwrite someone else's digest.
```

- [ ] **Step 3: Verify the variable is actually set**

Run: `echo "CLAUDE_CODE_SESSION_ID=[${CLAUDE_CODE_SESSION_ID:-<unset>}]"`
Expected: a UUID, not `<unset>`.

If it IS unset in your environment, **stop and report** — the whole `/snapshot` identity path depends on it, and the spec's §4.4 limit 1 (un-owned ⇒ undetectable) becomes the common case rather than an edge case. The `PreToolUse` hook (Task 3) still works, because it reads `session_id` from the hook payload instead.

- [ ] **Step 4: Add greppable guards, then verify no regression**

Prose can silently drift back. Three cheap assertions pin the parts that matter — append to
`tests/test-claim-digest.sh` before its `RESULT` line:

```bash
echo "== command prose carries the runtime-id instructions =="
ck "snapshot.md stamps session_id from the runtime" 'grep -q "CLAUDE_CODE_SESSION_ID" "$ROOT/commands/snapshot.md"'
ck "snapshot.md arms with an owner, not bare touch" '! grep -qE "^[0-9]+\. Arm the reload: .touch" "$ROOT/commands/snapshot.md"'
ck "snapshot.md calls the guard" 'grep -q "claim-digest.sh" "$ROOT/commands/snapshot.md"'
```

Then confirm nothing broke:
```bash
bash tests/test-hooks.sh && bash tests/test-e2e.sh && bash tests/test-claim-digest.sh
```
Expected: all exit 0; `test-claim-digest.sh` now reports 43 passed (40 + 3).

- [ ] **Step 5: Commit**

```bash
git add commands/snapshot.md templates/session.md tests/test-claim-digest.sh
git commit -m "feat(snapshot): stamp session_id and the arm owner from the runtime"
```

---

### Task 7: End-to-end — two sessions colliding through the real hooks

Implements spec §5 criteria 1, 2a, 3, 4. `tests/test-e2e.sh` chains the REAL hooks through one shared `.reload/`; this is where a change spanning the marker handshake or the digest→banner contract earns its regression guard.

**Files:**
- Modify: `tests/test-e2e.sh` (append a new cycle before the final `RESULT` line)

**Interfaces:**
- Consumes: everything from Tasks 1–5. The existing `run()` helper (`tests/test-e2e.sh:17-19`) and `mktx()` (`:20-22`).
- Produces: no new interfaces — this task is pure verification.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-e2e.sh`, before the final `RESULT` line:

```bash
# ── CYCLE 7: two sessions, one tree — collision is loud, rehydrate still works ──
echo "== E2E cycle 7: session B clobbers session A's digest -> side-filed + warned =="
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"

# Session A snapshots (simulating what /snapshot writes, with a runtime id).
cat > "$TMP/.reload/session.md" <<'EOF'
---
session_id: "SESS-A"
updated_at: "2026-07-27T10:00:00Z"
intent: "session A axes 3+4 spec work"
---
## Done this stretch
- MAGIC-A-DONE drafted the ownership section
## In flight
- MAGIC-A-INFLIGHT reviewing the arm semantics
## Next concrete step
MAGIC-A-NEXT finish the acceptance criteria
## Open questions & risks
- none
EOF

# Session B is about to Write the same path. The PreToolUse hook fires FIRST.
OUT="$(printf '%s' "{\"session_id\":\"SESS-B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/pretooluse-hook.sh")"
ck "7.1 A's digest was side-filed" '[ -f "$TMP/.reload/session.SESS-A.md" ]'
ck "7.2 side-file holds A's working thread" 'grep -q "MAGIC-A-NEXT" "$TMP/.reload/session.SESS-A.md"'
ck "7.3 B was warned, naming A" 'printf "%s" "$OUT" | grep -q "SESS-A"'

# B's write then lands (the hook permitted it).
cat > "$TMP/.reload/session.md" <<'EOF'
---
session_id: "SESS-B"
updated_at: "2026-07-27T10:30:00Z"
intent: "session B implementing the guard"
---
## Done this stretch
- MAGIC-B-DONE wrote claim-digest.sh
## In flight
- MAGIC-B-INFLIGHT wiring the PreToolUse hook
## Next concrete step
MAGIC-B-NEXT run the e2e suite
## Open questions & risks
- none
EOF
ck "7.4 B's write succeeded" 'grep -q "MAGIC-B-NEXT" "$TMP/.reload/session.md"'
ck "7.5 A's copy survives alongside it" 'grep -q "MAGIC-A-NEXT" "$TMP/.reload/session.SESS-A.md"'

# B arms and clears: rehydrates B's own thread, no warning.
run precompact-hook.sh '{"session_id":"SESS-B","trigger":"manual"}' >/dev/null
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-B","source":"clear"}')"
ck "7.6 B rehydrates its own thread" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-B-NEXT\")" >/dev/null'
ck "7.7 own arm -> no cross-session warning" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'

# Now A clears against B's arm: STILL rehydrates (invariant), but is warned.
printf 'SESS-A' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-B","source":"clear"}')"
ck "7.8 foreign arm STILL rehydrates (v0.1.5 regression guard)" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-B-NEXT\")" >/dev/null'
ck "7.9 foreign arm warns" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'

echo "== E2E cycle 8: two project dirs are fully isolated =="
# NOTE: this REPLACES the file's existing `trap 'rm -rf "$TMP"' EXIT` (test-e2e.sh:14).
# The replacement still cleans $TMP, so nothing leaks — but if you add a $TMP_C later,
# it must go in this same trap, not a third one.
TMP_B="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP_B"' EXIT
mkdir -p "$TMP_B/.reload"
printf -- '---\nsession_id: "OTHER"\nupdated_at: "x"\nintent: "other tree"\n---\n## Next concrete step\nMAGIC-OTHER-NEXT\n' > "$TMP_B/.reload/session.md"
printf 'OTHER' > "$TMP_B/.reload/pending"
OUT="$(printf '%s' '{"session_id":"OTHER","source":"clear"}' \
  | CLAUDE_PROJECT_DIR="$TMP_B" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/sessionstart-hook.sh")"
ck "8.1 tree B rehydrates its own digest" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-OTHER-NEXT\")" >/dev/null'
ck "8.2 tree A is untouched by tree B" 'grep -q "MAGIC-B-NEXT" "$TMP/.reload/session.md"'
ck "8.3 tree B never saw tree A's side-file" '[ ! -f "$TMP_B/.reload/session.SESS-A.md" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-e2e.sh`
Expected: cycles 1–6 pass; cycle 7–8 assertions FAIL if any of Tasks 1–4 is incomplete.

If all prior tasks are done these pass immediately, so prove the assertions are real with a
**surgical mutation** rather than deleting the script (which would fail 7.1/7.2/7.3/7.5 all at once
and prove only that *something* is wired). Invert the ownership comparison in `claim-digest.sh`:

```bash
# temporarily change:  [ "$INCUMBENT" != "$WRITER" ] || exit 0
# to:                  [ "$INCUMBENT"  = "$WRITER" ] || exit 0
```
Expected: 7.1 and 7.2 flip to FAIL while 7.6–7.9 still pass — localizing the failure to the
comparison itself. Revert the mutation.

- [ ] **Step 3: No implementation needed**

This task adds no production code. If an assertion fails, the defect is in Tasks 1–4 — fix it there, with its own unit test, rather than weakening the e2e assertion.

- [ ] **Step 4: Run the full gate**

```bash
bash tests/test-hooks.sh && bash tests/test-statusline.sh && \
bash tests/test-config.sh && bash tests/test-e2e.sh && \
bash tests/test-claim-digest.sh
echo "gate exit=$?"
```
Expected: `gate exit=0`, and every suite's pass count ≥ its baseline.

- [ ] **Step 5: Commit**

```bash
git add tests/test-e2e.sh
git commit -m "test(e2e): two-session collision and two-tree isolation through the real hooks"
```

---

### Task 8: CI, README, and CLAUDE.md

Implements spec §4.1 (the documented invariant), §4.4 (coverage limits), and the `CLAUDE.md` couplings the earlier tasks create. Docs are part of the deliverable here: the spec's §4.1 fix *is* documentation, and an undocumented invariant is one users violate without knowing there is a rule.

**Files:**
- Modify: `.github/workflows/ci.yml:36-39`
- Modify: `README.md` — "Hooks" table (line 79), "Configuration" (line 153), "Layout" (line 181), "Known limitations" (line 216)
- Modify: `CLAUDE.md` — control-flow diagram, invariants list, couplings table

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: no code interfaces.

- [ ] **Step 1: Wire the new suite into CI**

In `.github/workflows/ci.yml`, add to the test-run block (after line 39's `bash tests/test-e2e.sh`):

```yaml
          bash tests/test-claim-digest.sh
```

The existing `shellcheck` line already globs `tests/*.sh`, so the new suite is covered. The `bash -n`
loop (`ci.yml:29`) globs only `hooks/*.sh scripts/*.sh` — extend it so the new test file gets a
syntax check too:

```yaml
          for f in hooks/*.sh scripts/*.sh tests/*.sh; do bash -n "$f"; done
```

- [ ] **Step 1b: Close the repete stand-down gap (spec criterion 9)**

`tests/test-hooks.sh:39-45` exercises the stand-down for SessionStart only. Extend that block so
all three hooks are covered (Task 2 already added the `claim-digest.sh` case):

```bash
mkdir -p "$TMP/.repete"; printf -- '---\nactive: true\n---\n' > "$TMP/.repete/loop.local.md"
touch "$TMP/.reload/pending"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "Stop stands down under a repete loop" '[ -z "$OUT" ]'
OUT="$(run precompact-hook.sh '{"session_id":"S1","trigger":"manual"}')"
ck "PreCompact stands down under a repete loop" '[ -z "$OUT" ]'
rm -rf "$TMP/.repete"
```

Place it immediately after the existing SessionStart stand-down assertions, before the
`rm -rf "$TMP/.repete"` at line 45 (or replace that line with the block above, which ends with it).

- [ ] **Step 2: Update README**

The cited line numbers were verified as section headings at plan-writing time (`## Hooks` :79,
`## Configuration` :153, `## Layout` :181, `## Known limitations` :216). If the file has drifted,
find them by heading rather than by number.

Add to the **Hooks** table a row for the new hook:

| Hook | Fires on | Does |
|---|---|---|
| `PreToolUse` | `Write` / `Edit` | Before the model overwrites `.reload/session.md`, side-files a *different* session's recent digest and warns. Never blocks the write. |

Add to **Configuration**:

```markdown
- `context_owner_window` — seconds (default `14400` = 4h; `0` or `off` disables). How recently
  another session must have written `.reload/session.md` for an overwrite to be treated as a live
  collision worth side-filing.
```

Add to **Layout**: `.reload/session.<id>.md` (side-filed digests, never auto-deleted) and note that `.reload/pending` now holds the arming session's id.

Add to **Known limitations** — this is the spec §4.1 invariant plus the §4.4 gaps:

```markdown
**One session per working directory.** `.reload/` is per-directory, not per-session: a second
Claude Code session in the same tree shares the same digest and the same arm marker. Run concurrent
sessions in separate worktrees. Note that Claude Code's `EnterWorktree` creates worktrees under
`.claude/worktrees/` — a `.gitignore` listing `.worktrees/` will not match that path.

Since 0.3 the plugin detects a cross-session overwrite rather than losing the digest silently, but
that guard has known limits:

- A digest written without a runtime session id is un-owned and overwritten silently.
- The guard sits on `Write`/`Edit`; a digest written via a `Bash` heredoc bypasses it.
- Recovery is manual — the side-file is never consulted on rehydrate; copy it back yourself.
- Only `pending` carries an owner. `summarizing`, `notified`, and `model` remain shared.
- This is a detector, not isolation. Separate worktrees are the actual fix.
```

- [ ] **Step 3: Update CLAUDE.md**

Add to the control-flow diagram a `PreToolUse` entry:

```
PreToolUse hook (model Write/Edit)
  └─ path == $DIGEST && tool is Write|Edit && payload has session_id?
       → claim-digest.sh: foreign + fresh incumbent -> side-file + warn; ALWAYS exit 0 (permit)
```

Add two invariants to the numbered list:

```markdown
11. **The ownership guard never blocks and never gates.** `claim-digest.sh` and the PreToolUse
    hook exit 0 unconditionally; SessionStart warns on a foreign arm but always rehydrates. A guard
    that can fail the snapshot it guards is worse than the loss it prevents, and gating rehydrate on
    id equality is the v0.1.5 bug (invariant 3). (Tests: "permits the write", "foreign arm STILL
    rehydrates"; e2e cycle 7.8.)
12. **Owner identity lives in the artifact, never in a shared slot.** The digest's `session_id`
    frontmatter and `pending`'s file content carry it. A directory-global owner marker is
    overwritten by whichever session starts last and identifies neither party — the original defect
    one level up (spec §4.2.1, rejected). (Tests: "digest_owner: …", "arm ownership: …")
```

Add couplings rows:

| You changed | You must also check |
|---|---|
| `claim-digest.sh` decision logic | `tests/test-claim-digest.sh`, e2e cycle 7, README "Known limitations" |
| `pretooluse-hook.sh` or its `hooks.json` entry | plugin must not ALSO declare hooks in `plugin.json`; `tests/test-claim-digest.sh` |
| `PENDING` being a stamped file rather than a `touch` | `stop-hook.sh:53`, `precompact-hook.sh:21`, `sessionstart-hook.sh` arm-owner block, both test files |
| `context_owner_window` semantics (default 14400, 0=off) | `lib.sh` `owner_window()`, `scripts/reload-config.sh`, `commands/reload-budget.md`, README, `tests/test-config.sh` |

Replace the "Known landmines" entry at `CLAUDE.md:160-162`, which currently reads:

```markdown
- The `summarizing`/`pending` markers are **per-project, not per-session**: two concurrent
  sessions in one repo can consume each other's arms. Known, documented, accepted (README
  "Known limitations"). Do not try to fix it with session ids in the digest — see invariant 3.
```

with:

```markdown
- The markers under `.reload/` are **per-project, not per-session**. As of 0.3 the two that can
  cause real harm are *detected*: a foreign live digest is side-filed with a warning, and a
  foreign arm rehydrates with a warning (never suppressed — invariant 3 still holds; the
  comparison may warn, never gate). `summarizing`, `notified`, and `model` remain shared and
  accepted. Detection is not isolation: the actual fix is one session per working directory
  (README "Known limitations"). Do not gate rehydration on the digest's session id — invariant 3.
```

- [ ] **Step 3b: Operationalize the README invariant (spec §5, out-of-band note)**

The spec suggests verifying the documented invariant "by review, or by a `grep`". Take the grep —
append to `tests/test-claim-digest.sh` before its `RESULT` line:

```bash
echo "== the documented invariant survives edits =="
ck "README states the one-session rule" 'grep -qi "one session per working directory" "$ROOT/README.md"'
```

- [ ] **Step 4: Run the full gate one final time**

```bash
bash tests/test-hooks.sh && bash tests/test-statusline.sh && \
bash tests/test-config.sh && bash tests/test-e2e.sh && \
bash tests/test-claim-digest.sh
for f in hooks/*.sh scripts/*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
shellcheck -S warning hooks/*.sh scripts/*.sh tests/*.sh
jq -e . hooks/hooks.json >/dev/null && echo "hooks.json valid"
```
Expected: every suite exits 0; no syntax failures; shellcheck silent; `hooks.json valid`.
`test-claim-digest.sh` reports **46 passed** (40 + Task 6's 3 + Task 8's 3; one fewer as root).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml README.md CLAUDE.md
git commit -m "docs: one-session-per-directory invariant, guard coverage limits, CI for the new suite"
```

---

## Deferred — explicitly not in this plan

Each was considered and rejected for a stated reason, so a later reader does not re-litigate them:

- **SessionStart offering side-files when armed.** Would make recovery automatic instead of manual. Spec §4.2.2 puts it out of scope: it changes the rehydrate path, which is the one path with a v0.1.5 scar on it. Revisit only with its own spec section.
- **Owner checks on `SUMMARIZING`, `NOTIFIED`, `MODELFILE`.** Spec §4.4 limit 4. Only `PENDING` can rehydrate the wrong thread; the rest degrade to noise, and each new owner check is a new thing to leak.
- **Side-file garbage collection.** Spec §4.2.2: they are small, untracked (`lib.sh:32`'s lone `*`), and exist precisely because something went wrong. Deleting the only copy of the evidence on a schedule is worse than accumulation.
- **Defaulting `--owner` in cc-operator to `$CLAUDE_CODE_SESSION_ID`.** Different repo. Logged in `../cc-operator-plugin/AUDIT_STATE.md` under "Found after the audit closed".
- **Verifying `SessionStart source:"compact"` fires on _auto_-compaction.** `CLAUDE.md` backlog item 1; needs a live session, unchanged by this work.

## Self-review notes

Checked against `docs/spec/concurrent-sessions.md` at `2d32195`:

- **§4.1** (cwd scoping + README invariant) → Task 8. No code change needed, as the spec says; the deliverable is the documented rule plus e2e cycle 8 proving isolation holds.
- **§4.2.1** (per-write identity) → Tasks 1, 4, 6. The rejected shared-marker design is called out in `lib.sh`'s comment and in `CLAUDE.md` invariant 12 so it cannot quietly return.
- **§4.2.2** (the check, mtime, configurable window, collisions, failure paths) → Tasks 2, 5.
- **§4.2.3** (arm ownership) → Task 4.
- **§4.2.4** (cost) → no dedicated task. The added work is one `awk` over ≤30 lines plus a `stat`; spec criterion 8 asks for a coarse ceiling, and no suite times anything today. **Gap, stated rather than hidden:** if you want the assertion, add it in Task 7 as a `time`-bounded check — but a timing assertion in CI is flaky by nature, which is why it is not planned here.
- **§4.3** (PreToolUse enforcement) → Task 3.
- **§4.4** (coverage limits) → Task 8's README block, verbatim in substance.
- **§5 criteria** → 0: baseline block. 1: e2e cycle 8. 2: Task 2 tests. 2a: Task 3 tests. 3: Task 4 + e2e 7.8 (structural grep guard added in Task 4). 4: Task 4. 5: Task 2's silent cases. 6: Task 2's boundary cases (4h−1m / 4h+1m at the default window) + Task 5's config validation. 7: Task 2 + 3's exit-0 cases. 8: see the §4.2.4 gap above. 9: Task 2 (`repete_active` guard + tests) and Task 8 (extending the stand-down block to Stop and PreCompact).

## Clarifications (2026-07-27)

Answers from a review panel over this plan. The body above has been revised to match; recorded here
as the decision trail. Full run report: `.review-panel/2026-07-27-concurrent-session-digest-guard.md`.

- **Q (lens A+B):** Two sessions can call `claim-digest.sh` at the same instant — both pass the
  `[ -e "$SIDE" ]` check, both `cp` to the same path, and the preserved copy is truncated. No lock.
  → **A: Atomic create, no lock.** Write to `$SIDE.tmp.$$`, then `mv` (atomic on POSIX, same
  filesystem). No lock, so no new way for a fail-open guard to hang — which `CLAUDE.md` forbids.

- **Q (lens A):** `[ "$FILE" = "$DIGEST" ]` is a plain string compare; a symlinked `.reload/`, a
  relative `file_path`, or a symlinked worktree silently misses and the guard never fires.
  → **A: Normalize both sides** with `cd "$(dirname …)" && pwd -P` (macOS has no `readlink -f`).
  A guard that silently does not fire is worse than no guard.

- **Q (lens B):** `printf '%s' "$SESSION_ID" > "$PENDING"` with an empty id writes a zero-byte file,
  making the un-owned case indistinguishable from a legacy pre-0.3 arm.
  → **A: Only `printf` when non-empty**; keep literal `touch` semantics otherwise, so an empty arm
  keeps meaning what it means today and the new tests stay meaningful.

- **Q (lens A+C):** Spec §5 criterion 9 asks that `claim-digest.sh` stand down for cc-repete and
  that the stand-down test cover Stop and PreCompact. The plan deferred it as "pre-existing".
  → **A: Add the guard and the tests.** The script is new and genuinely lacks `repete_active`, so it
  would write into `.reload/` during a live loop — violating the invariant that cc-repete owns
  continuity while a loop is active.
