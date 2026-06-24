#!/usr/bin/env bash
# cc-reload statusline segment + composer smoke tests. Run: bash tests/test-statusline.sh
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

echo "== composer: appends cc-reload segment after a stub proxy renderer =="
# Stub the proxy statusline: a node script that echoes a fixed proxy string.
STUB="$TMP/proxy/scripts"; mkdir -p "$STUB"
printf 'process.stdout.write("claude 5h:12%%")\n' > "$STUB/statusline.js"
JSON='{"context_window":{"used_percentage":7,"context_window_size":1000000},"workspace":{"project_dir":"/tmp"}}'
OUT="$(plain "$(PROXY_PATH="$TMP/proxy/bin/cc-proxy.js" bash -c 'cat | bash '"$S"'/cc-statusline.sh' <<<"$JSON")")"
ck "joins proxy | reload" '[ "$OUT" = "claude 5h:12% | ctx[1M] 7%·45" ]'

echo "== composer: proxy present but reload empty -> proxy only, no trailing sep =="
OUT="$(PROXY_PATH="$TMP/proxy/bin/cc-proxy.js" bash -c 'cat | bash '"$S"'/cc-statusline.sh' <<<'{}')"
OUT="$(plain "$OUT")"
ck "proxy only, no dangling ' | '" '[ "$OUT" = "claude 5h:12%" ]'

echo "== composer: proxy absent -> reload segment only, clean =="
# Redirect HOME so the cache glob finds no cc-proxy, and give a bogus PROXY_PATH.
EMPTYHOME="$TMP/emptyhome"; mkdir -p "$EMPTYHOME/.claude/plugins/cache"
OUT="$(HOME="$EMPTYHOME" PROXY_PATH="/no/such/bin/cc-proxy.js" bash -c 'cat | bash '"$S"'/cc-statusline.sh' <<<"$JSON")"
OUT="$(plain "$OUT")"
ck "reload only when proxy missing" '[ "$OUT" = "ctx[1M] 7%·45" ]'

echo "== composer: both empty -> empty string, exit 0 =="
OUT="$(HOME="$EMPTYHOME" PROXY_PATH="/no/such.js" bash -c 'cat | bash '"$S"'/cc-statusline.sh' <<<'{}')"
ck "both empty -> empty" '[ -z "$OUT" ]'

# --- version-agnostic self-relocation (cache only) ---------------------------
# A composer copy living in .../cc-reload/<ver>/scripts re-execs the NEWEST
# installed version, so a version-pinned settings.json path keeps tracking new
# installs. A copy outside the cache (the dev checkout) must NOT redirect.
echo "== composer: cache copy re-execs the newest installed version =="
OWNER="$TMP/.claude/plugins/cache/betmoar"
mkdir -p "$OWNER/cc-reload/0.0.1/scripts" "$OWNER/cc-reload/9.9.9/scripts"
cp "$S/cc-statusline.sh" "$OWNER/cc-reload/0.0.1/scripts/cc-statusline.sh"   # the OLD copy under test
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf NEWEST\n' > "$OWNER/cc-reload/9.9.9/scripts/cc-statusline.sh"
OUT="$(printf '{}' | bash "$OWNER/cc-reload/0.0.1/scripts/cc-statusline.sh")"
ck "old cache copy hands off to newest" '[ "$OUT" = "NEWEST" ]'

echo "== composer: newest cache copy runs in place (no exec loop) =="
cp "$S/cc-statusline.sh" "$OWNER/cc-reload/9.9.9/scripts/cc-statusline.sh"  # real composer is now newest
cp "$S/statusline.sh"    "$OWNER/cc-reload/9.9.9/scripts/statusline.sh"
JSON='{"context_window":{"used_percentage":5,"context_window_size":1000000},"workspace":{"project_dir":"/tmp"}}'
OUT="$(plain "$(HOME="$EMPTYHOME" PROXY_PATH=/no/such.js bash "$OWNER/cc-reload/9.9.9/scripts/cc-statusline.sh" <<<"$JSON")")"
ck "newest cache copy renders, no loop" '[ "$OUT" = "ctx[1M] 5%·45" ]'

echo "== composer: dev checkout (outside cache) never redirects =="
OUT="$(plain "$(HOME="$EMPTYHOME" PROXY_PATH=/no/such.js bash "$S/cc-statusline.sh" <<<"$JSON")")"
ck "dev checkout runs itself" '[ "$OUT" = "ctx[1M] 5%·45" ]'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
