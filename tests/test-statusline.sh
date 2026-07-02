#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
# cc-reload statusline segment smoke tests. Run: bash tests/test-statusline.sh
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
seg(){ printf '%s' "$1" | bash "$S/statusline.sh"; }          # segment <- json
# strip ANSI so assertions match on text, not color codes. Use a literal ESC
# byte (BSD/macOS sed does not understand the \x1b escape).
ESC="$(printf '\033')"
plain(){ printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g"; }

echo "== segment: 1M window, low % -> ctx[1M] N%·45 (default budget) =="
OUT="$(plain "$(seg '{"context_window":{"used_percentage":7.3,"context_window_size":1000000}}')")"
ck "renders ctx[1M] 7%·45" '[ "$OUT" = "ctx[1M] 7%·45" ]'

echo "== segment: 200k window tag =="
OUT="$(plain "$(seg '{"context_window":{"used_percentage":20,"context_window_size":200000}}')")"
ck "renders ctx[200k] 20%·45" '[ "$OUT" = "ctx[200k] 20%·45" ]'

echo "== segment: truncates fractional percent (no rounding) =="
OUT="$(plain "$(seg '{"context_window":{"used_percentage":49.9,"context_window_size":1000000}}')")"
ck "49.9 -> 49" '[ "$OUT" = "ctx[1M] 49%·45" ]'

# Build JSON with a known pct for this project dir (avoids deep quote-nesting,
# which mis-parses the embedded $TMP path in some shells).
pj(){ printf '{"context_window":{"used_percentage":%s,"context_window_size":%s},"workspace":{"project_dir":"%s"}}' "$1" "$2" "$TMP"; }

echo "== segment: per-project budget from .reload/config overrides default =="
mkdir -p "$TMP/.reload"; printf 'context_budget_pct: 30\n' > "$TMP/.reload/config"
OUT="$(plain "$(seg "$(pj 12 1000000)")")"
ck "uses budget 30 from config" '[ "$OUT" = "ctx[1M] 12%·30" ]'

echo "== segment: color grades RELATIVE to budget (green < 2/3·budget) =="
# budget 30 -> yellow at 20, red at 30. 12% -> green.
OUT="$(seg "$(pj 12 1000000)")"
ck "12% of budget 30 is green" 'printf "%s" "$OUT" | grep -q "\[32m"'
OUT="$(seg "$(pj 24 1000000)")"
ck "24% of budget 30 is yellow" 'printf "%s" "$OUT" | grep -q "\[33m"'
OUT="$(seg "$(pj 31 1000000)")"
ck "31% over budget 30 is red" 'printf "%s" "$OUT" | grep -q "\[31m"'

echo "== segment: budget=0 (proactive path off) -> no ·suffix, absolute coloring =="
printf 'context_budget_pct: 0\n' > "$TMP/.reload/config"
OUT="$(plain "$(seg "$(pj 50 1000000)")")"
ck "no budget suffix when disabled" '[ "$OUT" = "ctx[1M] 50%" ]'
OUT="$(seg "$(pj 50 1000000)")"
ck "50% absolute is green (disabled)" 'printf "%s" "$OUT" | grep -q "\[32m"'
rm -f "$TMP/.reload/config"

echo "== segment: no context_window -> empty (early session / post-compact) =="
ck "empty on missing context_window" '[ -z "$(seg "{\"workspace\":{\"project_dir\":\"/tmp\"}}")" ]'
echo "== segment: null used_percentage -> empty =="
OUT="$(seg '{"context_window":{"used_percentage":null,"context_window_size":200000}}')"
ck "empty on null pct" '[ -z "$OUT" ]'
echo "== segment: empty stdin -> empty, exit 0 =="
OUT="$(seg '')"; ck "empty stdin no crash" '[ -z "$OUT" ]'
echo "== segment: window size absent -> bare ctx (no tag) but still % =="
OUT="$(plain "$(seg '{"context_window":{"used_percentage":8}}')")"
ck "bare ctx N%·45 when size absent" '[ "$OUT" = "ctx 8%·45" ]'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
