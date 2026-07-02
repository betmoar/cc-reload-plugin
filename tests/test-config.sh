#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
# reload-config.sh smoke tests. Run: bash tests/test-config.sh
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
rc(){ CLAUDE_PROJECT_DIR="$TMP" bash "$S/reload-config.sh" "$@"; }

echo "== set: creates .reload/ + self-ignoring .gitignore + config =="
OUT="$(rc set context_budget_pct 30)"
ck "exit-value echoed" '[ "$OUT" = "context_budget_pct: 30" ]'
ck "config line written" 'grep -q "^context_budget_pct: 30$" "$TMP/.reload/config"'
ck ".gitignore is a lone *" '[ "$(cat "$TMP/.reload/.gitignore")" = "*" ]'

echo "== get: reads back; unset key is empty =="
ck "get returns 30" '[ "$(rc get context_budget_pct)" = "30" ]'
ck "unset context_window is empty" '[ -z "$(rc get context_window)" ]'

echo "== set: preserves unrelated keys =="
rc set context_window 1000000 >/dev/null
rc set context_budget_pct 25 >/dev/null
ck "budget updated" '[ "$(rc get context_budget_pct)" = "25" ]'
ck "window preserved" '[ "$(rc get context_window)" = "1000000" ]'
ck "no duplicate budget lines" '[ "$(grep -c "^context_budget_pct:" "$TMP/.reload/config")" = "1" ]'

echo "== set: 'off' maps to 0 =="
rc set context_budget_pct off >/dev/null
ck "off -> 0" '[ "$(rc get context_budget_pct)" = "0" ]'

echo "== validation: bad values rejected, config untouched =="
cp "$TMP/.reload/config" "$TMP/before"
ck "pct 96 rejected (exit 2)" '! rc set context_budget_pct 96 2>/dev/null'
ck "pct garbage rejected" '! rc set context_budget_pct lots 2>/dev/null'
ck "window 0 rejected" '! rc set context_window 0 2>/dev/null'
ck "unknown key rejected" '! rc set who_knows 5 2>/dev/null'
ck "bad mode rejected" '! rc frobnicate context_window 2>/dev/null'
ck "config unchanged after rejections" 'cmp -s "$TMP/before" "$TMP/.reload/config"'
ERR="$(rc set context_budget_pct 96 2>&1 || true)"
ck "rejection message is actionable" 'printf "%s" "$ERR" | grep -q "0-95"'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
