#!/usr/bin/env bash
# cc-reload hook smoke tests. Run from anywhere: bash tests/test-hooks.sh
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.reload"
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
run(){ # script source-json
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/$1"
}

echo "== SessionStart: armed -> injects digest, clears marker =="
printf -- '---\nsession_id: "S1"\nupdated_at: "x"\nintent: "do thing"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
touch "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S1","source":"clear","hook_event_name":"SessionStart"}')"
ck "injects additionalContext" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "pending marker consumed" '[ ! -f "$TMP/.reload/pending" ]'
# A visible systemMessage must accompany the (silent) additionalContext, else the
# auto-reload looks like it never fired and users reach for a manual /reload.
ck "emits a visible cc-reload systemMessage" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"cc-reload\")" >/dev/null'
ck "systemMessage surfaces the digest intent" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"do thing\")" >/dev/null'

echo "== SessionStart: not armed -> no-op =="
OUT="$(run sessionstart-hook.sh '{"session_id":"S1","source":"clear"}')"
ck "no output when unarmed" '[ -z "$OUT" ]'

echo "== SessionStart: /clear mints a NEW session id -> still injects + consumes (regression: id guard removed) =="
# Real /clear mints a fresh session id every time, so the armed digest (stamped
# with the PRIOR id) will never match the current one. The arm (.reload/pending),
# not session identity, is the gate. A differing id must NOT suppress the banner.
touch "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"NEW-CLEAR-ID","source":"clear"}')"
ck "injects digest despite differing session id" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "consumes the one-shot marker" '[ ! -f "$TMP/.reload/pending" ]'
rm -f "$TMP/.reload/pending"

echo "== Stand-down: cc-repete loop active -> hooks no-op =="
mkdir -p "$TMP/.repete"; printf -- '---\nactive: true\n---\n' > "$TMP/.repete/loop.local.md"
touch "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S1","source":"clear"}')"
ck "SessionStart stands down (no output)" '[ -z "$OUT" ]'
ck "did not consume marker while stood down" '[ -f "$TMP/.reload/pending" ]'
rm -rf "$TMP/.repete"

echo "== PreCompact: arms + ensures a digest =="
rm -f "$TMP/.reload/pending" "$TMP/.reload/session.md"
run precompact-hook.sh '{"compaction_type":"auto","hook_event_name":"PreCompact"}' >/dev/null
ck "armed pending" '[ -f "$TMP/.reload/pending" ]'
ck "fallback digest created" '[ -f "$TMP/.reload/session.md" ]'
ck "self-ignoring .gitignore dropped" '[ -f "$TMP/.reload/.gitignore" ]'
ck ".gitignore contents are a lone *" '[ "$(cat "$TMP/.reload/.gitignore")" = "*" ]'

echo "== PreCompact: fallback digest records the session id in its frontmatter =="
rm -f "$TMP/.reload/pending" "$TMP/.reload/session.md"
run precompact-hook.sh '{"session_id":"S9","trigger":"auto","hook_event_name":"PreCompact"}' >/dev/null
ck "fallback stamped with session id" 'grep -q "session_id: \"S9\"" "$TMP/.reload/session.md"'

# transcript helper: last assistant message carries message.usage.input_tokens
mktx(){ # used_tokens -> $TMP/t.jsonl
  printf '{"message":{"role":"assistant","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1" > "$TMP/t.jsonl"
}

echo "== SessionStart stamps model + window =="
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-sonnet-5"}' >/dev/null
ck "model file written" '[ -f "$TMP/.reload/model" ]'
ck "sonnet-5 resolves to 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'

echo "== Stop budget: under threshold -> no trigger =="
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
mktx 100000   # 100k of 1M = 10%
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "10% of 1M -> no output" '[ -z "$OUT" ]'

echo "== Stop budget: pct=0 -> disabled =="
printf 'context_budget_pct: 0\n' > "$TMP/.reload/config"
mktx 900000
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pct=0 -> inert" '[ -z "$OUT" ]'

echo "== Stop budget: over threshold -> pass1 block, pass2 arm =="
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
mktx 500000   # 500k of 1M = 50% >= 45%
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass1 blocks + asks for digest" 'printf "%s" "$OUT" | jq -e ".decision==\"block\" and (.reason|test(\"session.md\"))" >/dev/null'
ck "pass1 reports a percentage" 'printf "%s" "$OUT" | jq -r .reason | grep -q "50%"'
ck "summarizing marker set" '[ -f "$TMP/.reload/summarizing" ]'
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass2 arms reload" '[ -f "$TMP/.reload/pending" ]'
ck "pass2 clears summarizing" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop budget: pass2 completes even if occupancy dips below budget (no stranded marker) =="
printf 'context_budget_pct: 45\ncontext_window: 1000000\n' > "$TMP/.reload/config"
mktx 100000   # 10% of 1M -> UNDER budget, but summarizing is already set (pass 1 ran)
rm -f "$TMP/.reload/pending"; touch "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass2 arms despite under-budget occupancy" '[ -f "$TMP/.reload/pending" ]'
ck "pass2 clears summarizing despite under-budget occupancy" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop budget: pass2 completes even when the budget was disabled mid-checkpoint =="
printf 'context_budget_pct: 0\n' > "$TMP/.reload/config"
rm -f "$TMP/.reload/pending"; touch "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass2 arms despite pct=0" '[ -f "$TMP/.reload/pending" ]'
ck "pass2 clears summarizing despite pct=0" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop budget: pass2 completes even when the transcript is missing =="
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
rm -f "$TMP/.reload/pending"; touch "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh '{"transcript_path":"/nonexistent/path.jsonl"}')"
ck "pass2 arms despite missing transcript" '[ -f "$TMP/.reload/pending" ]'
ck "pass2 clears summarizing despite missing transcript" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop budget: window auto-corrects upward from observed usage =="
printf 'model: mystery\nwindow: 200000\n' > "$TMP/.reload/model"
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"   # no context_window override
mktx 300000   # 300k: 150% of 200k (would trigger) but 30% of auto-1M (should NOT)
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "auto-corrected to 1M -> 30% -> no trigger" '[ -z "$OUT" ]'

echo "== Stop budget: context_window override wins (pins 200k) =="
printf 'context_budget_pct: 45\ncontext_window: 200000\n' > "$TMP/.reload/config"
mktx 300000   # pinned 200k -> 150% -> must trigger despite usage>200k
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "override pins window -> triggers" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Stop budget: context_window: 0 (invalid) -> no crash, falls back to a safe window =="
# A literal 0 window would be a division-by-zero in the occupancy math. It must be
# treated as invalid and fall back (no stamp here -> 1M), so 100k -> 10% -> no trigger.
# Capture stderr to a file: the div-by-zero regression prints to stderr while leaving
# stdout empty, so asserting empty stdout alone would NOT catch it — assert clean stderr.
rm -f "$TMP/.reload/model"
printf 'context_budget_pct: 45\ncontext_window: 0\n' > "$TMP/.reload/config"
mktx 100000
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>"$TMP/err.txt")"
ck "context_window:0 does not trigger" '[ -z "$OUT" ]'
ck "context_window:0 emits no stderr (no division-by-zero)" '[ ! -s "$TMP/err.txt" ]'
ck "context_window:0 leaves no stranded summarizing marker" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop budget: invalid context_window: 0 does not disable the >200K self-heal =="
# An invalid override must be treated as 'no pin'. With a 200K stamp and >200K usage,
# the window self-heals to 1M (30%) and must NOT trigger. The bug left it at 200K
# (150% -> block) because cfg returned a non-empty "0" and gated out the self-heal.
printf 'model: claude-haiku-4-5\nwindow: 200000\n' > "$TMP/.reload/model"
printf 'context_budget_pct: 45\ncontext_window: 0\n' > "$TMP/.reload/config"
mktx 300000
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "invalid override still self-heals the 200K stamp -> no trigger" '[ -z "$OUT" ]'

echo "== Stop budget: usage field absent -> byte-estimate fallback =="
printf 'context_budget_pct: 45\ncontext_window: 200000\n' > "$TMP/.reload/config"
head -c 120000 /dev/zero | tr '\0' 'x' > "$TMP/t.jsonl"   # ~30k tokens = 15% of 200k -> no trigger
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "fallback estimate computes (no crash, ~15% no trigger)" '[ -z "$OUT" ]'

echo "== Stop budget: pass2 with no digest -> does NOT arm, warns =="
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
rm -f "$TMP/.reload/session.md" "$TMP/.reload/pending"; touch "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass2 without digest does not arm" '[ ! -f "$TMP/.reload/pending" ]'
ck "pass2 without digest clears summarizing" '[ ! -f "$TMP/.reload/summarizing" ]'
ck "pass2 without digest warns clearly" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT armed\")" >/dev/null'

echo "== Stop budget: window UNKNOWN (no override, no stamp) -> assume 1M, no false-early trigger =="
rm -f "$TMP/.reload/model"                                   # no stamp
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"    # no context_window override
mktx 150000   # OLD: 150k/200k = 75% -> false block ; NEW: 150k/1M = 15% -> quiet
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "unknown window assumes 1M -> 15% -> no trigger" '[ -z "$OUT" ]'

echo "== SessionStart: unrecognized model id -> assumes 1M window =="
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-future-9"}' >/dev/null
ck "unknown id resolves to 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'

echo "== model_window: current Opus/Sonnet are 1M; older tiers + Haiku are 200K =="
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-opus-4-8"}' >/dev/null
ck "opus-4-8 resolves to 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-sonnet-4-6"}' >/dev/null
ck "sonnet-4-6 resolves to 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-opus-4-1"}' >/dev/null
ck "older opus-4-1 resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-haiku-4-5-20251001"}' >/dev/null
ck "haiku-4-5 resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
# boundary-anchored matching: a dated snapshot of an older tier still resolves 200K,
# but a future higher minor (4-10) must NOT collide with the 4-1 substring -> 1M.
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-opus-4-1-20250805"}' >/dev/null
ck "dated opus-4-1 snapshot still resolves 200K" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-opus-4-10"}' >/dev/null
ck "future opus-4-10 does NOT match opus-4-1 -> 1M (not 200K)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"claude-sonnet-4-50"}' >/dev/null
ck "future sonnet-4-50 does NOT match sonnet-4-5 -> 1M (not 200K)" 'grep -q "window: 1000000" "$TMP/.reload/model"'

echo "== Stop hook: live model from transcript updates stale model stamp =="
# Stamp Opus 1M, but transcript says haiku-4-5 (200K). At 50k tokens that's 25% of 200K
# which should trigger at 5% budget. With the stale 1M stamp it would be 5% -> borderline.
printf 'model: claude-opus-4-8[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"
printf 'context_budget_pct: 5\n' > "$TMP/.reload/config"
# Transcript with model field on assistant turn
printf '{"message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input_tokens":50000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TMP/t.jsonl"
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "live model refreshes stamp to 200K" 'grep -q "window: 200000" "$TMP/.reload/model"'
ck "50k/200K=25% > 5% budget -> triggers" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
