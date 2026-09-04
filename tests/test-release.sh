#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
#
# Release + structural contracts. Everything here is a fact that used to be
# kept true BY HAND and drifted (audit 2026-09-02 F07/F09):
#   * the version trio — plugin.json (the plugin CACHE KEY: a bump that misses
#     it ships an update nobody receives), the newest CHANGELOG heading, and
#     the README status line — disagreed at 0.3.2 (README still said 0.3.1).
#   * CI ran a hand-listed set of suites; tests/run-all.sh globs them and CI
#     must call THAT, or a new suite passes locally and never runs in CI.
#   * hooks.json / statusline.json / CLAUDE.md name files and lines that must
#     exist — a renamed hook script means a hook that silently never runs.
# Run: bash tests/test-release.sh   (exit code = #failures)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

echo "== version trio: plugin.json == newest CHANGELOG heading == README status line =="
V_PLUGIN="$(jq -r .version .claude-plugin/plugin.json 2>/dev/null)"
V_CHANGELOG="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | tr -d '#[] ')"
V_README="$(grep -m1 -oE 'Status: \*\*v[0-9]+\.[0-9]+\.[0-9]+' README.md | sed 's/.*v//')"
ck "plugin.json carries a semver version ($V_PLUGIN)" '[[ "$V_PLUGIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
ck "newest CHANGELOG heading is the plugin version ($V_CHANGELOG)" '[ "$V_CHANGELOG" = "$V_PLUGIN" ]'
ck "README status line is the plugin version ($V_README)" '[ "$V_README" = "$V_PLUGIN" ]'
# The newest section must have content: a heading with nothing under it is a
# release with no notes.
BODY="$(awk '/^## \[/{n++} n==1 && !/^## \[/' CHANGELOG.md | grep -cvE '^[[:space:]]*$')"
ck "newest CHANGELOG section has a body" '[ "$BODY" -gt 0 ]'
ck "marketplace.json names the plugin" '[ "$(jq -r ".plugins[0].name" .claude-plugin/marketplace.json)" = "$(jq -r .name .claude-plugin/plugin.json)" ]'

echo "== hooks.json: every command points at a script that exists; plugin.json declares no hooks =="
while IFS= read -r cmd; do
  f="$(printf '%s' "$cmd" | sed -n 's/.*\${CLAUDE_PLUGIN_ROOT}\/\([^"]*\)".*/\1/p')"
  ck "hooks.json command resolves: $f" '[ -n "$f" ] && [ -f "$f" ]'
done < <(jq -r '.hooks[][] | .hooks[] | .command' hooks/hooks.json)
ck "every hook command goes through \${CLAUDE_PLUGIN_ROOT} (a bare path resolves only inside this repo)" '[ "$(jq -r ".hooks[][] | .hooks[] | .command" hooks/hooks.json | grep -vc "CLAUDE_PLUGIN_ROOT")" -eq 0 ]'
ck "plugin.json declares no hooks (duplicate-hooks load error, v0.1.2)" '! jq -e ".hooks" .claude-plugin/plugin.json >/dev/null 2>&1'
ck "statusline.json render path exists" '[ -f "$(jq -r .render .claude-plugin/statusline.json)" ]'
ck "every hook script sources hooks/lib.sh first (jq guard + repete stand-down)" '[ "$(grep -L "^source \"\$(dirname \"\$0\")/lib.sh\"" hooks/*-hook.sh | wc -l)" -eq 0 ]'
ck "commands reach scripts through \${CLAUDE_PLUGIN_ROOT}" '! grep -nE "bash \"?scripts/" commands/*.md >/dev/null'
for s in $(grep -ohE 'scripts/[a-z-]+\.sh' commands/*.md skills/*/SKILL.md | sort -u); do
  ck "command/skill prose names an existing script: $s" '[ -f "$s" ]'
done

echo "== CI runs tests/run-all.sh (the globbing gate), not a hand-kept list =="
ck "ci.yml invokes tests/run-all.sh" 'grep -q "bash tests/run-all.sh" .github/workflows/ci.yml'
ck "ci.yml does not hand-list suites any more" '! grep -qE "bash tests/test-[a-z0-9-]+\.sh" .github/workflows/ci.yml'
ck "ci.yml pins the shellcheck version it runs" 'grep -qE "shellcheck[^ ]*:v?0\.[0-9]+\.[0-9]+" .github/workflows/ci.yml'
ck "run-all.sh globs the suites" 'grep -q "for t in tests/test-\*.sh" tests/run-all.sh'

echo "== release.yml: the tag build gates the trio and runs the same suites =="
ck "release.yml fires on v-tags" 'grep -qE "tags:.*\[.*\"v\*\"" .github/workflows/release.yml'
ck "release.yml runs the release gate script" 'grep -q "release-gate.mjs" .github/workflows/release.yml'
ck "release.yml runs tests/run-all.sh (same gate as ci.yml)" 'grep -q "bash tests/run-all.sh" .github/workflows/release.yml'
ck "release.yml pins the shellcheck version it runs" 'grep -qE "shellcheck[^ ]*:v?0\.[0-9]+\.[0-9]+" .github/workflows/release.yml'
ck "release.yml runs the gate's own node suite" 'grep -q "node --test tests/test-release-gate.mjs" .github/workflows/release.yml'
ck "release.yml publishes from the extracted CHANGELOG notes, never hand-written" 'grep -q -- "--notes-file release-notes.md" .github/workflows/release.yml'
ck "run-all.sh runs the release-gate node suite too" 'grep -q "node --test tests/test-release-gate.mjs" tests/run-all.sh'

echo "== CLAUDE.md: file:line citations resolve, and named tests exist =="
# Every `something.sh:NN` in CLAUDE.md must name a real line; the PENDING row's
# citations must land ON the arm write (a moved line makes the map lie).
while IFS= read -r cite; do
  f="${cite%%:*}"; n="${cite##*:}"
  path="$(find hooks scripts -name "$f" | head -1)"
  ck "citation $cite names a real line" '[ -n "$path" ] && [ "$(wc -l < "$path")" -ge "$n" ]'
done < <(grep -oE '`[a-z-]+\.sh:[0-9]+`' CLAUDE.md | tr -d '`' | sort -u)
while IFS= read -r cite; do
  f="${cite%%:*}"; n="${cite##*:}"; path="$(find hooks scripts -name "$f" | head -1)"
  ck "PENDING row citation $cite is ON the arm write" '[ -n "$path" ] && sed -n "${n}p" "$path" | grep -q "PENDING"'
done < <(grep -E '^\| `PENDING` being a stamped file' CLAUDE.md | grep -oE '`[a-z-]+\.sh:[0-9]+`' | tr -d '`')
# Every quoted test name in an invariant's "(Tests: …)" list must be a real
# `ck` label or `echo "== …"/"-- …"` header somewhere under tests/ (substring,
# case-insensitive; a trailing … is the doc's own abbreviation). The convention
# is "each has a named test" — an unresolvable name is a guard the doc promises
# and nobody can find. Only the text AFTER "(Test" in each numbered item is
# scanned, so prose quotes in the invariant body are not mistaken for names.
# NOTE: no `grep -q` in a pipeline here — under `set -o pipefail` its early
# exit SIGPIPEs the producer and the pipeline reads as FAILED on a match.
INV="$(awk '/^## Load-bearing invariants/{f=1;next} /^## /{f=0} f' CLAUDE.md)"
LABELS="$(grep -rhiE '^[[:space:]]*(ck "|echo "(==|--) )' tests/)"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  prefix="${name%…}"; prefix="${prefix%...}"
  ck "invariant cites a findable test: \"$name\"" '[ -n "$(printf "%s\n" "$LABELS" | grep -iF "$prefix")" ]'
done < <(printf '%s\n' "$INV" | awk '/^[0-9]+\. /{ if (item != "") print item; item="" } { item = item " " $0 } END { print item }' | sed -E 's/[[:space:]]+/ /g' \
         | sed -n 's/.*(Tests\{0,1\}: //p' | grep -oE '"[^"]{6,}"' | tr -d '"' | sort -u)

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
