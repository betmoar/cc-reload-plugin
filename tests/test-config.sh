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

echo "== context_budget_mode: notify|snapshot accepted, junk rejected =="
rc set context_budget_mode snapshot >/dev/null
ck "mode snapshot set" '[ "$(rc get context_budget_mode)" = "snapshot" ]'
rc set context_budget_mode notify >/dev/null
ck "mode notify set" '[ "$(rc get context_budget_mode)" = "notify" ]'
ck "mode junk rejected (exit 2)" '! rc set context_budget_mode sometimes 2>/dev/null'
ck "mode unchanged after rejection" '[ "$(rc get context_budget_mode)" = "notify" ]'
ERR="$(rc set context_budget_mode sometimes 2>&1 || true)"
ck "mode rejection names both values" 'printf "%s" "$ERR" | grep -q "notify" && printf "%s" "$ERR" | grep -q "snapshot"'

echo "== context_budget_mode: legacy 'checkpoint' aliases to 'snapshot' (back-compat) =="
rc set context_budget_mode checkpoint >/dev/null
ck "checkpoint accepted (exit 0)" 'true'
ck "checkpoint normalized to snapshot on write" '[ "$(rc get context_budget_mode)" = "snapshot" ]'
rc set context_budget_mode notify >/dev/null

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


echo "== inline # comments are stripped by EVERY reader (audit F04) =="
# The README's own example block writes `key: value   # comment`. Four readers
# parse .reload/config (hooks/lib.sh kv/cfg, reload-config.sh get, and three
# inline copies in scripts/statusline.sh); each silently returned the comment
# as part of the value and every validation then fell back to its default.
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
printf 'context_budget_pct: 30       # act at this %% of the window\ncontext_budget_mode: snapshot  # forced digest turn\ncontext_window: 200000      # pinned\ncontext_owner_window: 60 # one minute\n' > "$TMP/.reload/config"
ck "reload-config get strips the comment (pct)" '[ "$(rc get context_budget_pct)" = "30" ]'
ck "reload-config get strips the comment (mode)" '[ "$(rc get context_budget_mode)" = "snapshot" ]'
ck "reload-config get strips the comment (window)" '[ "$(rc get context_window)" = "200000" ]'
libcfg(){ CLAUDE_PROJECT_DIR="$TMP" bash -c 'source "$0/lib.sh"; cfg "$1"' "$H" "$1"; }
ck "lib.sh cfg strips the comment (pct)" '[ "$(libcfg context_budget_pct)" = "30" ]'
ck "lib.sh cfg strips the comment (mode)" '[ "$(libcfg context_budget_mode)" = "snapshot" ]'
ck "lib.sh cfg strips the comment (window)" '[ "$(libcfg context_window)" = "200000" ]'
ck "lib.sh cfg strips the comment (owner window)" '[ "$(libcfg context_owner_window)" = "60" ]'
ESC="$(printf '\033')"
SEG="$(printf '{"context_window":{"used_percentage":12,"context_window_size":1000000},"workspace":{"project_dir":"%s"}}' "$TMP" | bash "$S/statusline.sh" | sed "s/${ESC}\[[0-9;]*m//g")"
ck "statusline strips the comment: pinned 200k tag + budget 30" '[ "$SEG" = "ctx[200k] 12%·30" ]'
echo "-- reader PARITY: the four copies must agree on every fixture line --"
for fixture in 'context_budget_pct: 45' 'context_budget_pct:45' 'context_budget_pct: "45"' 'context_budget_pct: 45 #c' 'context_budget_pct: 45   ' 'context_budget_pct: 45#c'; do
  printf '%s\n' "$fixture" > "$TMP/.reload/config"
  a="$(rc get context_budget_pct)"; b="$(libcfg context_budget_pct)"
  c="$(printf '{"context_window":{"used_percentage":1,"context_window_size":1000000},"workspace":{"project_dir":"%s"}}' "$TMP" | bash "$S/statusline.sh" | sed "s/${ESC}\[[0-9;]*m//g" | sed 's/.*·//')"
  ck "parity on [$fixture]: get=$a cfg=$b bar=$c" '[ "$a" = "45" ] && [ "$b" = "45" ] && [ "$c" = "45" ]'
done
rm -f "$TMP/.reload/config"

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
