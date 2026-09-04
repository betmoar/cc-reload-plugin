#!/usr/bin/env bash
#
# run-all.sh — the ONE local gate. Runs exactly what CI runs, in one command.
#
#   bash tests/run-all.sh            # exit code = number of failing gates
#   SHELLCHECK=/path/to/shellcheck bash tests/run-all.sh
#
# Why this exists (audit 2026-09-02 F09): the suites were listed by name in
# three places (ci.yml, README, CLAUDE.md), so a new tests/test-*.sh passed
# locally and silently never ran in CI. This script GLOBS the suites — a new
# suite cannot be forgotten — and .github/workflows/ci.yml calls this script
# (tests/test-release.sh asserts that), so local and CI can no longer diverge.
#
# Gates, in order: JSON validity, bash -n, shellcheck (0.10.0 is the CI pin; a
# missing shellcheck is a LOUD warning here, never a silent pass — CI enforces
# it in a pinned container), then every tests/test-*.sh.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

fails=0
ok(){ printf 'PASS  %s\n' "$1"; }
bad(){ printf 'FAIL  %s\n' "$1"; fails=$((fails+1)); }

echo "== JSON validity =="
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json .claude-plugin/statusline.json hooks/hooks.json; do
  if jq -e . "$f" >/dev/null 2>&1; then ok "$f"; else bad "$f is not valid JSON"; fi
done

echo "== bash -n =="
for f in hooks/*.sh scripts/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then :; else bad "syntax: $f"; fi
done
ok "hooks/*.sh scripts/*.sh tests/*.sh parse"

echo "== shellcheck -S warning (CI pins 0.10.0) =="
SC="${SHELLCHECK:-}"
[ -n "$SC" ] || SC="$(command -v shellcheck 2>/dev/null || true)"
if [ -n "$SC" ] && [ -x "$SC" ]; then
  "$SC" --version 2>/dev/null | grep -i '^version' || true
  if "$SC" -S warning hooks/*.sh scripts/*.sh tests/*.sh; then ok "shellcheck clean"; else bad "shellcheck reported warnings"; fi
else
  printf 'WARN  shellcheck not found — NOT run locally. CI runs 0.10.0 in a pinned container and WILL fail\n'
  printf '      on anything it finds. Install it (https://github.com/koalaman/shellcheck/releases, v0.10.0)\n'
  printf '      or point SHELLCHECK=/path/to/shellcheck at a binary before claiming a clean lint.\n'
fi

echo "== suites (globbed: every tests/test-*.sh runs; add a file, it is in) =="
for t in tests/test-*.sh; do
  out="$(bash "$t" 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E '^RESULT:' | tail -1)"
  if [ "$rc" -eq 0 ]; then ok "$t — ${line:-exit 0}"; else bad "$t — ${line:-exit $rc}"; printf '%s\n' "$out" | grep -E '^  FAIL' | head -20; fi
done

# Release gate suite (node): the tag-build workflow runs it explicitly; the
# glob above sees only tests/test-*.sh, so wire it in here by hand to keep
# local runs identical to release.yml (node absent locally = LOUD skip, the
# same shape as the lint warning above — never a silent pass).
if command -v node >/dev/null 2>&1; then
  echo "== release gate suite (node --test tests/test-release-gate.mjs) =="
  if out="$(node --test tests/test-release-gate.mjs 2>&1)"; then
    ok "tests/test-release-gate.mjs — $(printf '%s\n' "$out" | grep -E '^# (pass|fail)' | tr '\n' ' ')"
  else
    bad "tests/test-release-gate.mjs"
    printf '%s\n' "$out" | grep -E '^not ok|FAIL' | head -20
  fi
else
  printf 'WARN  node not found — release gate suite NOT run locally. The tag build runs it and WILL fail\n'
  printf '      on anything it finds.\n'
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL GATES GREEN"; else echo "$fails GATE(S) RED"; fi
exit "$fails"
