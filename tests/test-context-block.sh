#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
#
# scripts/context-block.sh — the free-form git caller (invariant 20).
#
# Three sites in the plugin run git: this script, head_drift() in hooks/lib.sh,
# and precompact-hook.sh's head: stamp. This is the only one whose whole purpose
# is git; the other two make one narrowly-scoped call each and are covered by
# the drift/fallback cases further down this file. digest_age_days() reads mtime
# and needs no repo at all.
#
# Everything else here is bash + jq + coreutils. git is a SOFT dependency: the
# script exists so a digest can state what a shell already knows (branch, HEAD,
# dirty paths, recent subjects) instead of asking the model to recall it, and so
# PreCompact's mechanical fallback — the worst path, auto-compaction before any
# agent-authored digest — carries something better than three "(unknown)" lines.
#
# The whole contract is FAIL-OPEN-SILENT, same shape as proxy_window(): no git,
# not a repo, an empty repo, a detached HEAD, a broken .git — print nothing,
# exit 0. A hook that inherits a partial or error-laden block would paste git's
# stderr into the digest it was meant to improve.
#
# Run: bash tests/test-context-block.sh   (exit code = #failures)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="$ROOT/scripts/context-block.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
# Deterministic commits: no user identity, no signing, no hooks, no pager.
git_env(){ GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@"; }
run(){ CLAUDE_PROJECT_DIR="$1" bash "$CB" 2>/dev/null; }

echo "== not a git repo: silent, exit 0 =="
mkdir -p "$TMP/plain"
OUT="$(run "$TMP/plain")"
ck "prints nothing outside a repo" '[ -z "$OUT" ]'
CLAUDE_PROJECT_DIR="$TMP/plain" bash "$CB" >/dev/null 2>&1
ck "exits 0 outside a repo" '[ $? -eq 0 ]'

echo "== git absent from PATH: silent, exit 0 =="
# The dependency is soft. An empty PATH is the strongest form of "no git".
OUT="$(cd "$TMP/plain" && PATH=/nonexistent CLAUDE_PROJECT_DIR="$TMP/plain" bash "$CB" 2>/dev/null)"
ck "prints nothing with no git on PATH" '[ -z "$OUT" ]'

echo "== a real repo: branch, HEAD and subjects are reported =="
R="$TMP/repo"; mkdir -p "$R"
git_env git -C "$R" init -q -b main
printf 'one\n' > "$R/a.txt"; git_env git -C "$R" add a.txt; git_env git -C "$R" commit -qm "MAGIC-SUBJ-first commit"
printf 'two\n' > "$R/b.txt"; git_env git -C "$R" add b.txt; git_env git -C "$R" commit -qm "MAGIC-SUBJ-second commit"
OUT="$(run "$R")"
ck "names the branch" 'printf "%s" "$OUT" | grep -q "main"'
ck "carries the short HEAD sha" 'printf "%s" "$OUT" | grep -qF "$(git_env git -C "$R" rev-parse --short HEAD)"'
ck "lists a recent commit subject" 'printf "%s" "$OUT" | grep -q "MAGIC-SUBJ-second"'
ck "a clean tree is stated, not left ambiguous" 'printf "%s" "$OUT" | grep -qi "clean"'

echo "== a dirty tree: the uncommitted paths are named =="
printf 'edited\n' >> "$R/a.txt"; printf 'new\n' > "$R/untracked.txt"
OUT="$(run "$R")"
ck "names the modified path" 'printf "%s" "$OUT" | grep -q "a.txt"'
ck "names the untracked path" 'printf "%s" "$OUT" | grep -q "untracked.txt"'
ck "no longer claims the tree is clean" '! printf "%s" "$OUT" | grep -qi "tree clean"'
git_env git -C "$R" checkout -q -- a.txt; rm -f "$R/untracked.txt"

echo "== detached HEAD: reported, never an error =="
git_env git -C "$R" checkout -q --detach HEAD
OUT="$(run "$R")"
ck "detached HEAD still produces a block" '[ -n "$OUT" ]'
ck "detached HEAD is named as such, not as a branch" 'printf "%s" "$OUT" | grep -qi "detached"'
ck "detached HEAD block carries no git error text" '! printf "%s" "$OUT" | grep -qi "fatal:"'
git_env git -C "$R" checkout -q main

echo "== an EMPTY repo (no commits yet): silent or clean, never a fatal =="
E="$TMP/empty"; mkdir -p "$E"; git_env git -C "$E" init -q -b main
OUT="$(run "$E")"
ck "empty repo never leaks git's fatal" '! printf "%s" "$OUT" | grep -qi "fatal:"'
ck "empty repo never leaks a HEAD error" '! printf "%s" "$OUT" | grep -qi "unknown revision\|ambiguous argument"'

echo "== output shape: bounded, and safe to embed in a markdown digest =="
OUT="$(run "$R")"
ck "the block is bounded (<= 20 lines — the digest budget is ~30 total)" '[ "$(printf "%s\n" "$OUT" | wc -l)" -le 20 ]'
ck "the block opens no markdown heading (it must not look like a digest section)" '! printf "%s\n" "$OUT" | grep -q "^## "'
ck "no stderr leaks into stdout" '! printf "%s" "$OUT" | grep -qi "fatal:\|error:\|warning:"'

echo "== a BROKEN .git: fail open, never a partial block =="
B="$TMP/broken"; mkdir -p "$B/.git"; printf 'not a repo\n' > "$B/.git/HEAD"
OUT="$(run "$B" 2>/dev/null)"
ck "a corrupt .git prints nothing rather than half a block" '[ -z "$OUT" ] || ! printf "%s" "$OUT" | grep -qi "fatal:"'

echo "== PreCompact's mechanical fallback carries the block (the worst path) =="
# Auto-compaction fired before any agent-authored digest existed. The hook
# cannot write prose, so before 0.4.2 this digest was three literal "(unknown)"
# lines — armed, rehydrated, and useless. It can state where the repo stood.
HOOKS="$ROOT/hooks"
pc(){ printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOKS/precompact-hook.sh" 2>/dev/null; }
printf 'dirty\n' >> "$R/a.txt"
rm -rf "$R/.reload"
pc "$R" '{"session_id":"PC-1","trigger":"auto"}' >/dev/null
D="$R/.reload/session.md"
ck "PreCompact wrote a fallback digest" '[ -f "$D" ]'
ck "it is still honest about being thin" 'grep -q "mechanical fallback" "$D"'
ck "the fallback names the branch and sha" 'grep -qF "$(git_env git -C "$R" rev-parse --short HEAD)" "$D"'
ck "the fallback names the dirty path" 'grep -q "a.txt" "$D"'
ck "the fallback still carries the four sections" '[ "$(grep -c "^## " "$D")" -eq 4 ]'
# The stub is a digest like any other: it must stamp head: too, or the ONE path
# that exists because nobody wrote a digest is also the one path with no
# staleness signal when it is finally rehydrated.
ck "the fallback stamps head: in frontmatter" 'grep -qE "^head: \"[0-9a-f]{7,40}\"$" "$D"'
ck "the stamped head is this repo's real HEAD" 'grep -qF "head: \"$(git_env git -C "$R" rev-parse --short HEAD)\"" "$D"'
ck "the fallback digest stays within the ~30-line budget" '[ "$(wc -l < "$D")" -le 30 ]'
ck "the fallback frontmatter still closes (digest_field depends on it)" '[ "$(grep -c "^---$" "$D")" -eq 2 ]'
ck "no git error text reached the digest" '! grep -qi "fatal:" "$D"'
git_env git -C "$R" checkout -q -- a.txt

echo "-- and OUTSIDE a repo the fallback is exactly what it was before --"
P2="$TMP/plain2"; mkdir -p "$P2"
pc "$P2" '{"session_id":"PC-2","trigger":"auto"}' >/dev/null
ck "non-repo fallback still written" '[ -f "$P2/.reload/session.md" ]'
ck "non-repo fallback still honest" 'grep -q "mechanical fallback" "$P2/.reload/session.md"'
ck "non-repo fallback has no empty repo-state header" '! grep -q "Repo state at snapshot" "$P2/.reload/session.md"'
ck "non-repo fallback still carries the four sections" '[ "$(grep -c "^## " "$P2/.reload/session.md")" -eq 4 ]'

echo "== SessionStart HEAD-drift: measured staleness, and SILENT whenever it is not measurable =="
# A digest that stamped `head:` can be compared to the live HEAD at rehydrate:
# "N commits since this digest" is a MEASURED signal, unlike the mtime -nt
# heuristic. It is advisory only — invariant 11 and the "pointer, not source of
# truth" contract both hold, so it never gates and never blocks.
#
# The failure mode this guards is a CONFIDENT WRONG number. A stamp the model
# invented, a sha from another repo, a shallow clone that cannot count: each
# would produce an authoritative "0 commits behind" over a stale digest, which
# is strictly worse than today's honest silence. So the drift line is emitted
# ONLY on a positive match of two real shas with a countable distance.
ss(){ printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOKS/sessionstart-hook.sh" 2>/dev/null; }
mkdesigest(){ # dir head-value  -> armed digest stamped with that head
  mkdir -p "$1/.reload"
  { printf -- '---\nsession_id: "D1"\nmission: "m"\nupdated_at: "2026-09-08T00:00:00Z"\n'
    [ -n "$2" ] && printf 'head: "%s"\n' "$2"
    printf -- 'intent: "drift probe"\n---\n## Done this stretch\n- d\n## In flight\n- nothing\n## Next concrete step\nstep\n## Open questions & risks\n- none\n'
  } > "$1/.reload/session.md"
  printf 'D1' > "$1/.reload/pending"
}
rm -rf "$R/.reload"
HEAD_NOW="$(git_env git -C "$R" rev-parse --short HEAD)"
mkdesigest "$R" "$HEAD_NOW"
OUT="$(ss "$R" '{"session_id":"D2","source":"clear"}')"
ck "stamp == live HEAD: no drift line (nothing to report)" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commit\")" >/dev/null'
ck "stamp == live HEAD: still rehydrates normally" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'

# Two commits land after the digest was stamped.
OLD="$HEAD_NOW"
printf 'c\n' > "$R/c.txt"; git_env git -C "$R" add c.txt; git_env git -C "$R" commit -qm "drift one"
printf 'd\n' > "$R/d.txt"; git_env git -C "$R" add d.txt; git_env git -C "$R" commit -qm "drift two"
mkdesigest "$R" "$OLD"
OUT="$(ss "$R" '{"session_id":"D3","source":"clear"}')"
ck "2 commits later: the banner reports the drift" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"2 commits\")" >/dev/null'
ck "drift never blocks or gates: the digest still rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'
ck "drift consumed the arm like any other rehydrate" '[ ! -f "$R/.reload/pending" ]'

echo "-- every unmeasurable case is SILENT, never a guessed number --"
mkdesigest "$R" ""                       # no head: stamp at all (pre-0.6 digest)
OUT="$(ss "$R" '{"session_id":"D4","source":"clear"}')"
ck "no head stamp: silent, no invented drift" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
ck "no head stamp: still rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'
mkdesigest "$R" "deadbee"                # a sha this repo has never seen
OUT="$(ss "$R" '{"session_id":"D5","source":"clear"}')"
ck "unknown sha: silent rather than a wrong count" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
ck "unknown sha: still rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'
mkdesigest "$R" 'x"; rm -rf /tmp/nope; echo "'   # untrusted content, never eval'd
OUT="$(ss "$R" '{"session_id":"D6","source":"clear"}')"
ck "a hostile head value is inert (digest content is data, never code)" '[ -n "$OUT" ] && ! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
# The two guards below are each load-bearing, and each was UNPINNED until this
# case existed — removing either left the suite green (measured 2026-09-09).
# A REVISION EXPRESSION is not a sha. `head: "HEAD~2"` resolves happily and
# rev-list counts it: without the anchored hex gate the banner reports a
# confident "2 commits since this digest" derived from untrusted digest text
# rather than from anything the previous session actually stamped.
mkdesigest "$R" "HEAD~2"
OUT="$(ss "$R" '{"session_id":"D8","source":"clear"}')"
ck "a revision EXPRESSION is not a sha: silent, never a count git would happily give" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
# A blob sha is 40 hex characters and passes the gate. `rev-list --count
# <blob>..HEAD` returns a NUMBER with exit 0 (measured: 3 on a 3-commit repo) —
# the arithmetic is meaningless but the output is well-formed, which is the
# silent-wrong shape. Only `^{commit}` rejects it; an unknown sha, by contrast,
# already fails rev-list outright (exit 128), which is why this case needs a
# blob and not a made-up sha.
BLOB="$(git_env git -C "$R" rev-parse HEAD:a.txt)"
mkdesigest "$R" "$BLOB"
OUT="$(ss "$R" '{"session_id":"D9","source":"clear"}')"
ck "a blob sha resolves but is not a commit: silent, not a meaningless count" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
ck "blob sha case still rehydrates normally" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'
mkdesigest "$P2" "$OLD"                  # stamped digest, but NOT a repo
OUT="$(ss "$P2" '{"session_id":"D7","source":"clear"}')"
ck "outside a repo: silent, no drift claim" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
ck "outside a repo: still rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'

echo "== SessionStart: an OLD digest says so, decoupled from occupancy =="
# The digest is only refreshed under budget pressure. A session that never
# crosses the budget can carry a digest for weeks and get no signal at all —
# measured in this very repo on 2026-09-09: .reload/session.md was stamped
# 2026-07-10 and described shipping v0.1.9 while the repo was on v0.4.1. Two
# months stale, and nothing ever said so. Age is read from FILESYSTEM MTIME (the
# same portable idiom as claim-digest.sh:60), never from the frontmatter
# updated_at, which is model-written and can be wrong or invented.
rm -rf "$R/.reload"
mkdesigest "$R" ""
touch -t 202001010000 "$R/.reload/session.md"       # BSD/GNU-portable backdate
OUT="$(ss "$R" '{"session_id":"AGE-1","source":"clear"}')"
ck "a long-stale digest is called out by age" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"days old\")" >/dev/null'
ck "stale-by-age still rehydrates (advisory, never a gate)" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'
mkdesigest "$R" ""                                   # written just now
OUT="$(ss "$R" '{"session_id":"AGE-2","source":"clear"}')"
ck "a fresh digest gets no age line" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"days old\")" >/dev/null'
# THE MTIME TRAP has TWO independent guards, and each needs its own red.
# claim_digest rewrites the digest through a temp file + mv, and the mv stamps a
# brand-new mtime (measured: a file backdated to 2020 reads as `now` the instant
# it is claimed). Two things keep the age signal alive:
#   (a) sessionstart-hook.sh captures the age BEFORE calling claim_digest, and
#   (b) claim_digest RESTORES the original mtime after its mv.
# (b) subsumes (a): with the restore in place, capturing after the claim yields
# the same answer, so a whole-hook case CANNOT discriminate the ordering — a
# review measured exactly that, and an earlier version of this comment claiming
# otherwise was wrong. The ordering is kept as defence in depth (it is the only
# thing standing if the restore ever silently fails, e.g. touch unavailable), so
# it gets a DIRECT unit case below instead of a hook-level one.
mkdesigest "$R" ""
touch -t 202001010000 "$R/.reload/session.md"
OUT="$(ss "$R" '{"session_id":"AGE-3","source":"clear"}')"
ck "a stale digest survives a claim and still reports its age" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"days old\")" >/dev/null'
ck "and the claim did happen (digest now owned by AGE-3)" 'grep -q "^session_id: \"AGE-3\"" "$R/.reload/session.md"'
# ...and capturing early is only half the fix. The claim must also PRESERVE the
# mtime, or the signal decays across sessions instead of within one: every
# rehydrate rejuvenates the file, so a digest that is rehydrated on each /clear
# reads as fresh forever no matter how old its CONTENT is.
#
# Measured on this repo's own digest, 2026-09-09: content stamped 2026-07-10
# describing v0.1.9 with the repo on v0.4.1 — two months stale — but an mtime
# from that same morning, because a SessionStart had claimed it. The one case
# the age signal exists for is the one it would have missed.
#
# mtime must mean "when the content was last written". A claim rewrites the
# OWNER, not the thread.
ck "the claim PRESERVES mtime (or the age signal decays to nothing across sessions)" '[ "$(stat -c %Y "$R/.reload/session.md" 2>/dev/null || stat -f %m "$R/.reload/session.md" 2>/dev/null)" -lt "$(( $(date +%s) - 86400 ))" ]'
OUT="$(ss "$R" '{"session_id":"AGE-4","source":"clear"}')" 2>/dev/null
mkdesigest "$R" ""; touch -t 202001010000 "$R/.reload/session.md"
ss "$R" '{"session_id":"AGE-5","source":"clear"}' >/dev/null       # 1st rehydrate claims it
printf 'AGE-5' > "$R/.reload/pending"
OUT="$(ss "$R" '{"session_id":"AGE-6","source":"clear"}')"          # 2nd still sees it as old
ck "a SECOND rehydrate still reports the true age" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"days old\")" >/dev/null'

echo "-- guard (a) on its own: the ordering, with the restore disabled --"
# Runs LAST in this block, because its `touch` shim would otherwise leak into the
# mtime cases above (measured — it turned the preservation case red for the wrong
# reason). DISABLE the restore with a no-op `touch` (the shape of a real failure:
# a read-only FS, a hardened PATH, a touch that refuses) and the capture ORDER is
# the only thing left holding the signal up. This is what makes the ordering
# load-bearing rather than decorative, and it goes red if the capture moves below
# claim_digest — which a hook-level case CANNOT detect while the restore works.
NOTOUCH="$TMP/notouch"; mkdir -p "$NOTOUCH"
printf '#!/bin/sh\nexit 0\n' > "$NOTOUCH/touch"; chmod +x "$NOTOUCH/touch"
mkdesigest "$R" ""
touch -t 202001010000 "$R/.reload/session.md"
OUT="$(printf '%s' '{"session_id":"AGE-7","source":"clear"}' \
  | PATH="$NOTOUCH:$PATH" CLAUDE_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOKS/sessionstart-hook.sh" 2>/dev/null)"
ck "the shim really did disable the restore (else the next case is vacuous)" '[ "$(stat -c %Y "$R/.reload/session.md" 2>/dev/null || stat -f %m "$R/.reload/session.md" 2>/dev/null)" -gt "$(( $(date +%s) - 86400 ))" ]'
ck "age is captured BEFORE the claim (holds even when the mtime restore cannot run)" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"days old\")" >/dev/null'

echo "== the remaining guards, each pinned on its own (a review found all four unpinned) =="
# Every guard below survived deletion with the suite green until these cases
# existed. An unpinned guard is indistinguishable from a decorative one, and the
# next maintainer tidying "redundant" checks has nothing to stop them.

echo "-- head_drift: the work-tree guard is NOT redundant (a BARE repo resolves shas) --"
# rev-parse --verify and rev-list both succeed against a bare repo's object
# database (measured), so without --is-inside-work-tree, head_drift would report
# drift for a directory that has no working tree at all — a number about a repo
# the session is not editing.
BARE="$TMP/bare.git"; git_env git clone -q --bare "$R" "$BARE"
BARE_OLD="$(git_env git -C "$BARE" rev-parse --short HEAD~1 2>/dev/null)"
mkdesigest "$BARE" "$BARE_OLD"
# Prove the bare repo really CAN answer, else the case passes for the wrong
# reason (an empty bare repo would be silent no matter what the guard does).
ck "the bare repo can resolve the stamp (else the next case is vacuous)" '[ -n "$BARE_OLD" ] && [ "$(git_env git -C "$BARE" rev-list --count "$BARE_OLD..HEAD" 2>/dev/null)" -ge 1 ]'
OUT="$(ss "$BARE" '{"session_id":"BARE-1","source":"clear"}')"
ck "a bare repo yields no drift line (work-tree guard)" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'

echo "-- digest_age_days: a FUTURE mtime is silence, never a negative age --"
# Clock skew, a VM time jump, a file from a machine ahead of this one. A negative
# `days` must never reach the banner. (This is covered by the threshold test, not
# by a separate skew guard — an explicit one was DEAD CODE and was removed:
# deleting it changed no outcome, because days=-1157 already fails `-ge 1`.)
mkdesigest "$R" ""
touch -t 209901010000 "$R/.reload/session.md"     # far future, BSD/GNU portable
OUT="$(ss "$R" '{"session_id":"SKEW-1","source":"clear"}')"
ck "a future mtime reports no age at all" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"days old\")" >/dev/null'
ck "a future mtime never reports a negative age" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"-[0-9]+ days\")" >/dev/null'
ck "skewed digest still rehydrates (advisory, never a gate)" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'

echo "-- head_drift: a DIVERGED stamp is silence, not a well-formed wrong count --"
# The most realistic way to get a confident wrong number, and the one the first
# cut missed. `.reload/` is per-PROJECT and shared across branches by design
# (CLAUDE.md known landmines), so: snapshot on a feature branch, switch to main,
# rehydrate. `rev-list --count <feature-tip>..HEAD` answers happily — measured 2
# — but that is "commits on main absent from feature", NOT "commits landed since
# this digest". The digest's own work is not in that history at all. Only an
# ancestry check can tell the two apart; every other guard passes this input.
DIV="$TMP/diverged"; mkdir -p "$DIV"; git_env git init -q -b main "$DIV"
printf 'a\n' > "$DIV/a"; git_env git -C "$DIV" add a; git_env git -C "$DIV" commit -qm base
git_env git -C "$DIV" checkout -q -b feature
printf 'f\n' > "$DIV/f"; git_env git -C "$DIV" add f; git_env git -C "$DIV" commit -qm "feature work"
FEAT_TIP="$(git_env git -C "$DIV" rev-parse --short HEAD)"
git_env git -C "$DIV" checkout -q main
for i in 1 2; do printf '%s\n' "$i" > "$DIV/m$i"; git_env git -C "$DIV" add "m$i"; git_env git -C "$DIV" commit -qm "main $i"; done
# Prove the raw count is non-empty, or the case passes for the wrong reason.
ck "the diverged stamp DOES yield a raw count (else the next case is vacuous)" '[ "$(git_env git -C "$DIV" rev-list --count "$FEAT_TIP..HEAD" 2>/dev/null)" -ge 1 ]'
mkdesigest "$DIV" "$FEAT_TIP"
OUT="$(ss "$DIV" '{"session_id":"DIV-1","source":"clear"}')"
ck "a stamp that is not an ancestor of HEAD reports no drift" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"commits since\")" >/dev/null'
ck "the diverged digest still rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step\")" >/dev/null'
# ...and the ordinary ancestor case must still report, or the fix is just a mute.
git_env git -C "$DIV" checkout -q feature
ANC="$(git_env git -C "$DIV" rev-parse --short HEAD)"
printf 'g\n' > "$DIV/g"; git_env git -C "$DIV" add g; git_env git -C "$DIV" commit -qm "more feature work"
mkdesigest "$DIV" "$ANC"
OUT="$(ss "$DIV" '{"session_id":"DIV-2","source":"clear"}')"
ck "a true ancestor still reports its drift (the fix is not a blanket mute)" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"1 commits since\")" >/dev/null'

echo "-- context-block: a FAILED git status is never reported as a clean tree --"
# `git status --porcelain` prints nothing on failure (corrupt/locked index, I/O
# error, permission trouble), and the first cut tested `[ -z "$STATUS" ]` — so a
# broken index rendered as "working tree clean" over a genuinely dirty tree.
# Measured: with a deliberately corrupted .git/index the block asserted clean
# while a.txt held uncommitted content. Empty-because-clean and
# empty-because-it-failed must not be the same branch.
CORRUPT="$TMP/corrupt"; mkdir -p "$CORRUPT"; git_env git init -q -b main "$CORRUPT"
printf 'a\n' > "$CORRUPT/a.txt"; git_env git -C "$CORRUPT" add a.txt; git_env git -C "$CORRUPT" commit -qm c1
printf 'UNCOMMITTED\n' >> "$CORRUPT/a.txt"
printf 'garbage, not an index' > "$CORRUPT/.git/index"
ck "the corrupted index really does break git status (else the next case is vacuous)" '! git_env git -C "$CORRUPT" status --porcelain >/dev/null 2>&1'
OUT="$(run "$CORRUPT")"
ck "a failed git status never claims the tree is clean" '! printf "%s" "$OUT" | grep -qi "working tree clean"'
ck "a failed git status leaks no git error text" '! printf "%s" "$OUT" | grep -qi "fatal:\|error:"'

echo "-- digest_age_days: the threshold boundary is >=, not > --"
# A digest exactly at the threshold must report. `-gt` here silently swallows the
# first day of staleness, which is precisely when a nudge is still cheap to act
# on. Backdate to just over 1 day so the integer division lands on exactly 1.
mkdesigest "$R" ""
BOUND="$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null)"
if [ -n "$BOUND" ]; then
  touch -t "$BOUND" "$R/.reload/session.md"
  OUT="$(ss "$R" '{"session_id":"BOUND-1","source":"clear"}')"
  ck "exactly 1 day old still reports (threshold is -ge, not -gt)" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"1 days old\")" >/dev/null'
else
  echo "  SKIP: neither BSD nor GNU date relative form available"
fi

echo "-- PreCompact: an unresolvable HEAD omits the stamp, never writes an empty one --"
# rev-parse --short prints NOTHING on an orphan/empty HEAD (measured: exit 128,
# empty stdout), and the `[ -n "$HEADSHA" ]` test is what omits the line. The sha
# regex beside it is belt-and-braces for a value git is not observed to produce,
# so it is deliberately NOT claimed as pinned — do not read this case as covering
# it. What IS pinned: no `head:` line, and frontmatter that still closes.
ORPH="$TMP/orphan"; mkdir -p "$ORPH"; git_env git init -q -b main "$ORPH"
rm -rf "$ORPH/.reload"
pc "$ORPH" '{"session_id":"ORPH-1","trigger":"auto"}' >/dev/null
ck "an unresolvable HEAD omits the head: line entirely" '! grep -q "^head:" "$ORPH/.reload/session.md"'
ck "and the fallback digest is still written and honest" 'grep -q "mechanical fallback" "$ORPH/.reload/session.md"'
ck "and its frontmatter still closes (an empty stamp would not break the fence)" '[ "$(grep -c "^---$" "$ORPH/.reload/session.md")" -eq 2 ]'

echo "== /snapshot --check: an AUDIT path, structurally unable to write or arm =="
# The one thing no gate in this plugin can test is whether a digest is any GOOD
# — that needs a reader with no memory of the session. --check is that reader,
# run while there is still time to fix what it finds. What IS testable here is
# the command contract: it must be an audit, never a write, and the subagent
# must be given the digest ALONE (leak this session's context into that prompt
# and it passes by cheating — the failure mode that would make the whole path
# theatre).
SNAP="$ROOT/commands/snapshot.md"
CHECK="$(awk '/^## If `\$ARGUMENTS` is `--check`/{f=1} f && /^## /&&!/--check/{f=0} f' "$SNAP")"
ck "--check is documented as its own path" '[ -n "$CHECK" ]'
ck "--check appears in the argument hint" 'grep -q "argument-hint:.*--check" "$SNAP"'
ck "--check can dispatch a subagent (Task is allowed)" 'grep -qE "^allowed-tools:.*Task" "$SNAP"'
ck "--check names an explicit subagent model (never inherits the priciest)" 'printf "%s" "$CHECK" | grep -qE "model .sonnet."'
ck "--check forbids writing on the audit path" 'printf "%s" "$CHECK" | grep -qiE "do not write|never write"'
ck "--check forbids arming on the audit path" 'printf "%s" "$CHECK" | grep -qi "arm"'
# The isolation clause is the load-bearing one: a subagent handed this session's
# summary answers from the summary, not the digest, and --check becomes theatre
# that always passes. A bare grep for "only" is NOT enough — the word appears
# elsewhere in the section, so that assertion stayed green when the clause was
# replaced with "the digest plus your summary of this session" (measured).
# Pin the prohibition itself.
ck "--check demands the subagent get the digest ONLY (no leaked context)" 'printf "%s" "$CHECK" | grep -qE "\*\*only\*\* the digest"'
ck "--check names context leakage as the thing that invalidates it" 'printf "%s" "$CHECK" | grep -qiE "leak|cheating"'
ck "--check forbids passing a summary of this conversation" 'printf "%s" "$CHECK" | grep -qiE "no summary of this conversation|nothing you remember"'
ck "--check reports divergence, not agreement" 'printf "%s" "$CHECK" | grep -qi "divergence"'
ck "--check does not apply its own recommendations silently" 'printf "%s" "$CHECK" | grep -qi "silently"'
# And the ordinary path must still be intact below it — a command file that
# audits but no longer snapshots would pass every case above.
ck "the write path still arms with an owned marker" 'grep -q "CLAUDE_CODE_SESSION_ID\" > .reload/pending" "$SNAP"'
ck "the write path still calls the collision guard" 'grep -q "claim-digest.sh" "$SNAP"'
ck "the write path still names all four sections" '[ "$(grep -c "Done this stretch / In flight / Next concrete step / Open questions & risks" "$SNAP")" -ge 1 ]'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
