#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
# cc-reload hook smoke tests. Run from anywhere: bash tests/test-hooks.sh
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.reload"
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
# ANTHROPIC_BASE_URL is SCRUBBED, not inherited: proxy_window() contacts a
# loopback cc-proxy when it is set, so on a maintainer's own machine (where the
# proxy is running and routes these ids for real) the model_window() table cases
# below got the proxy's answer instead of the table's — `glm-5.3` and
# `deepseek/deepseek-v4-pro` came back 1048576 where the table says 1000000, and
# the suite went red on an untouched tree. CI never saw it (no proxy on the
# runner), so the one documented gate lied exactly where it is developed. The
# proxy path has its own coverage below, via a stub `curl` on PATH that sets
# this variable deliberately.
run(){ # script source-json
  printf '%s' "$2" | ANTHROPIC_BASE_URL="" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/$1"
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
mkdir -p "$TMP/.repete"; printf -- '---\nactive: true\n---\n' > "$TMP/.repete/loop.local.md"
touch "$TMP/.reload/pending"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "Stop stands down under a repete loop" '[ -z "$OUT" ]'
OUT="$(run precompact-hook.sh '{"session_id":"S1","trigger":"manual"}')"
ck "PreCompact stands down under a repete loop" '[ -z "$OUT" ]'
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

echo "== Stop budget: over threshold (snapshot mode) -> pass1 block, pass2 arm =="
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\n' > "$TMP/.reload/config"
mktx 500000   # 500k of 1M = 50% >= 45%
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass1 blocks + asks for digest" 'printf "%s" "$OUT" | jq -e ".decision==\"block\" and (.reason|test(\"session.md\"))" >/dev/null'
ck "pass1 reports a percentage" 'printf "%s" "$OUT" | jq -r .reason | grep -q "50%"'
ck "summarizing marker set" '[ -f "$TMP/.reload/summarizing" ]'
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "pass2 arms reload" '[ -f "$TMP/.reload/pending" ]'
ck "pass2 clears summarizing" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop budget: legacy 'checkpoint' mode value still blocks (back-compat alias) =="
# A .reload/config written before the v0.2.0 rename holds 'checkpoint'; the Stop
# hook must read it as 'snapshot' and still run pass 1, or old configs silently
# fall back to notify and lose the automated path.
printf 'context_budget_pct: 45\ncontext_budget_mode: checkpoint\n' > "$TMP/.reload/config"
mktx 500000
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "legacy checkpoint value -> pass1 block" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "legacy checkpoint value -> summarizing set" '[ -f "$TMP/.reload/summarizing" ]'
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"

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
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\ncontext_window: 200000\n' > "$TMP/.reload/config"
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

echo "== model_window: cc-proxy (non-Claude) model ids =="
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-4.5"}' >/dev/null
ck "glm-4.5 resolves to 128K window" 'grep -q "window: 128000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-4.5-air"}' >/dev/null
ck "glm-4.5-air resolves to 128K window" 'grep -q "window: 128000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-4.6"}' >/dev/null
ck "glm-4.6 resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-4.7"}' >/dev/null
ck "glm-4.7 resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-5"}' >/dev/null
ck "glm-5 resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-5-turbo"}' >/dev/null
ck "glm-5-turbo resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-5.1"}' >/dev/null
ck "glm-5.1 resolves to 200K window" 'grep -q "window: 200000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-5.2"}' >/dev/null
ck "glm-5.2 resolves to 1M window (via default, not a special case)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"deepseek-v4-pro"}' >/dev/null
ck "deepseek-v4-pro resolves to 1M window (via default)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"deepseek-v4-flash"}' >/dev/null
ck "deepseek-v4-flash resolves to 1M window (via default)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"qwen3.7-max"}' >/dev/null
ck "qwen3.7-max resolves to 1M window (via default)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"deepseek/deepseek-v4-pro"}' >/dev/null
ck "OpenRouter-prefixed deepseek/deepseek-v4-pro resolves to 1M window (no cc-proxy window published)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
# boundary anchoring: glm-5.3/glm-6 must NOT collide with glm-5/glm-4.5/etc -> fall through to
# the optimistic 1M default (invariant 5). This is the load-bearing assertion for this block.
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-5.3"}' >/dev/null
ck "future glm-5.3 does NOT match glm-5/glm-5.1 -> 1M (not 200K)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
run sessionstart-hook.sh '{"session_id":"S1","source":"startup","model":"glm-6"}' >/dev/null
ck "future glm-6 does NOT match glm-4.x/5.x -> 1M (not 200K)" 'grep -q "window: 1000000" "$TMP/.reload/model"'

echo "== Stop pass1: stop_hook_active with no marker -> stands down (no infinite block loop) =="
# A blocked Stop re-fires the hook with stop_hook_active:true. Normally pass 2
# catches that turn via the summarizing marker; if the marker is gone the hook
# must NOT re-enter pass 1, or it would re-prompt the checkpoint forever.
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\ncontext_window: 1000000\n' > "$TMP/.reload/config"
mktx 500000   # 50% >= 45% would normally block
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\",\"stop_hook_active\":true}")"
ck "stop_hook_active suppresses a re-block" '[ -z "$OUT" ]'
ck "no summarizing marker written while stood down" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop pass2: digest refreshed during the checkpoint turn -> success message =="
rm -f "$TMP/.reload/pending"
touch -t 202001010000 "$TMP/.reload/summarizing" 2>/dev/null || touch "$TMP/.reload/summarizing"
sleep 0.01
printf -- '---\nintent: "fresh"\n---\n## Next concrete step\nY\n' > "$TMP/.reload/session.md"   # written AFTER the marker
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "fresh digest arms" '[ -f "$TMP/.reload/pending" ]'
ck "fresh digest reports saved" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"digest saved\")" >/dev/null'

echo "== Stop pass2: digest NOT refreshed -> still arms as a floor, but warns honestly =="
rm -f "$TMP/.reload/pending"
touch -t 202001010000 "$TMP/.reload/session.md"   # digest predates the marker
touch "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "stale digest still arms (floor, matches PreCompact)" '[ -f "$TMP/.reload/pending" ]'
ck "stale digest warns it was not refreshed" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT refresh\")" >/dev/null'
ck "stale digest clears summarizing" '[ ! -f "$TMP/.reload/summarizing" ]'

echo "== Stop: .reload unwritable -> silent (no block, no nagging notify) =="
# A FILE named .reload defeats mkdir -p / touch even when running as root. With
# .reload unreadable the mode defaults to notify, and a notify whose ladder can't
# be written would nag on EVERY Stop — so the hook must stay silent entirely.
rm -rf "$TMP/.reload"; : > "$TMP/.reload"
mktx 500000
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "unwritable .reload -> silent" '[ -z "$OUT" ]'
rm -f "$TMP/.reload"; mkdir -p "$TMP/.reload"

echo "== Stop pass1 (checkpoint mode): unwritable summarizing -> refuses to block =="
# Blocking without the marker on disk would re-prompt the checkpoint forever
# (pass 2 keys off it). A dangling symlink makes touch fail even as root while
# .reload/config stays readable, so this pins the checkpoint-mode refusal.
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\ncontext_window: 1000000\n' > "$TMP/.reload/config"
ln -s "$TMP/nonexistent-dir/x" "$TMP/.reload/summarizing"
rm -f "$TMP/.reload/pending"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "marker unwritable -> no block emitted" '[ -z "$OUT" ]'
ck "marker unwritable -> nothing armed" '[ ! -f "$TMP/.reload/pending" ]'
rm -f "$TMP/.reload/summarizing"

echo "== Stop hook: live model from transcript updates stale model stamp =="
# Stamp Opus 1M, but transcript says haiku-4-5 (200K). At 50k tokens that's 25% of 200K
# which should trigger at 5% budget. With the stale 1M stamp it would be 5% -> borderline.
printf 'model: claude-opus-4-8[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"
printf 'context_budget_pct: 5\ncontext_budget_mode: snapshot\n' > "$TMP/.reload/config"
# Transcript with model field on assistant turn
printf '{"message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input_tokens":50000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TMP/t.jsonl"
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "live model refreshes stamp to 200K" 'grep -q "window: 200000" "$TMP/.reload/model"'
ck "50k/200K=25% > 5% budget -> triggers" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Stop hook: [1m] stamp survives a bare-id transcript refresh (same model) =="
# The transcript never carries the "[1m]" alias suffix. A session stamped
# claude-sonnet-4-5[1m] (1M) whose transcript says claude-sonnet-4-5-20250929
# is the SAME model — restamping the bare id would downgrade the window to the
# 200K base and nag at 5x the real occupancy (audit F05).
printf 'model: claude-sonnet-4-5[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TMP/t.jsonl"
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing" "$TMP/.reload/notified"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "[1m] stamp keeps 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'
ck "[1m] stamp not overwritten by bare id" 'grep -q "claude-sonnet-4-5\[1m\]" "$TMP/.reload/model"'
ck "100k/1M=10% < 45% -> silent (no false nudge)" '[ -z "$OUT" ]'

echo "== Stop hook: alias-form [1m] stamp (sonnet[1m]) also survives =="
printf 'model: sonnet[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "alias sonnet[1m] keeps 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'
ck "alias form stays silent under real budget" '[ -z "$OUT" ]'

echo "== Stop hook: the [1m] shield is boundary-anchored (invariant 6, applied to BASE) =="
# claude-sonnet-4-5 is a literal PREFIX of a future claude-sonnet-4-50, so an
# unanchored substring test shields a genuinely different model and pins the
# stale [1m] stamp forever. Same collision shape invariant 6 already forbids in
# model_window() ("future opus-4-10"), one level up. The boundary is "-": the
# base must end at the id's end or at a literal dash.
printf 'model: claude-sonnet-4-5[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-50-20260101","usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TMP/t.jsonl"
rm -f "$TMP/.reload/notified"
run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" >/dev/null
ck "sonnet-4-50 is NOT shielded by a sonnet-4-5[1m] stamp" 'grep -q "claude-sonnet-4-50-20260101" "$TMP/.reload/model"'
ck "the stale [1m] stamp is replaced, not pinned" '! grep -q "\[1m\]" "$TMP/.reload/model"'

echo "== Stop hook: [1m] stamp does NOT shield a genuine family switch =="
# sonnet[1m] stamped, but the live turn ran haiku (a real /model switch):
# the base "sonnet" is absent from the live id, so the restamp proceeds -> 200K.
printf 'model: sonnet[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"
printf '{"message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TMP/t.jsonl"
rm -f "$TMP/.reload/notified"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "family switch from [1m] stamp restamps to 200K" 'grep -q "window: 200000" "$TMP/.reload/model"'
ck "100k/200K=50% >= 45% -> notifies" 'printf "%s" "$OUT" | jq -e ".systemMessage != null" >/dev/null'

echo "== Stop notify (DEFAULT mode): over budget -> nudge only, never blocks, no handshake =="
printf 'context_budget_pct: 45\ncontext_window: 1000000\n' > "$TMP/.reload/config"   # no mode key -> notify
mktx 500000   # 50% >= 45%
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing" "$TMP/.reload/notified"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "notify emits a /snapshot nudge" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"/snapshot\")" >/dev/null'
ck "notify never blocks" 'printf "%s" "$OUT" | jq -e ".decision == null" >/dev/null'
ck "notify writes no summarizing marker" '[ ! -f "$TMP/.reload/summarizing" ]'
ck "notify does not arm by itself" '[ ! -f "$TMP/.reload/pending" ]'
ck "ladder recorded at 50" '[ "$(cat "$TMP/.reload/notified")" = "50" ]'

echo "== Stop notify: ladder suppresses repeats; +10 points re-notifies =="
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "same occupancy -> silent" '[ -z "$OUT" ]'
mktx 600000   # 60% = 50 + 10 -> re-notify
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "+10 points -> re-notifies" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"60%\")" >/dev/null'
ck "ladder advanced to 60" '[ "$(cat "$TMP/.reload/notified")" = "60" ]'

echo "== Stop notify: dropping under budget resets the ladder =="
mktx 100000   # 10% < 45%
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "under budget -> silent" '[ -z "$OUT" ]'
ck "under budget -> ladder cleared" '[ ! -f "$TMP/.reload/notified" ]'

echo "== Stop checkpoint mode: armed reload suppresses re-block -> laddered reminder =="
# Once pass 2 (or a manual /snapshot) armed the reload, further over-budget
# Stops must NOT force another checkpoint turn — that re-blocked every second
# turn until the user /clear'd (audit F01).
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\ncontext_window: 1000000\n' > "$TMP/.reload/config"
mktx 500000
rm -f "$TMP/.reload/summarizing" "$TMP/.reload/notified"; touch "$TMP/.reload/pending"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "armed -> no re-block" 'printf "%s" "$OUT" | jq -e ".decision == null" >/dev/null'
ck "armed -> reminder says reload armed" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"armed\")" >/dev/null'
ck "armed -> no new handshake marker" '[ ! -f "$TMP/.reload/summarizing" ]'
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "armed reminder is laddered -> silent repeat" '[ -z "$OUT" ]'
rm -f "$TMP/.reload/pending" "$TMP/.reload/notified"

echo "== SessionStart hygiene: clear purges leaked handshake + ladder; resume keeps them =="
# Interrupted checkpoint turn + /clear leaked `summarizing` into the fresh
# session, whose first Stop then armed the dead session's digest (audit F03).
touch "$TMP/.reload/summarizing"; printf '50\n' > "$TMP/.reload/notified"
rm -f "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S1","source":"resume"}')"
ck "resume keeps a mid-flight handshake" '[ -f "$TMP/.reload/summarizing" ]'
ck "resume keeps the notify ladder" '[ -f "$TMP/.reload/notified" ]'
OUT="$(run sessionstart-hook.sh '{"session_id":"S2","source":"clear"}')"
ck "clear purges the leaked handshake" '[ ! -f "$TMP/.reload/summarizing" ]'
ck "clear purges the notify ladder" '[ ! -f "$TMP/.reload/notified" ]'

echo "== Arm ownership: PENDING carries the arming session's id =="
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S1"\nupdated_at: "x"\nintent: "own thread"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"

# PreCompact arms with its own id.
run precompact-hook.sh '{"session_id":"S_PC","trigger":"manual"}' >/dev/null
ck "precompact stamps the arm" '[ "$(cat "$TMP/.reload/pending")" = "S_PC" ]'

echo "== Arm coherence (revised): compares the arm's owner against the DIGEST's owner, =="
echo "== not against the rehydrating session's id — /clear mints a fresh id every time =="
# NOTE: the OLD suite tested "ARM_OWNER != SESSION_ID -> warn". That comparison is
# exactly the defect this revision fixes — S2 is the incoming session, not the
# incumbent's collaborator, so of COURSE it differs from S1's arm on every /clear.
# The assertions below replace that comparison with ARM_OWNER vs DIGEST_OWNER.

echo "-- ordinary /clear lineage: pending=S1, digest owner S1, incoming id S2 --"
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S1"\nupdated_at: "x"\nintent: "own thread"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
printf 'S1' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S2","source":"clear"}')"
ck "coherent arm rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "coherent arm warns nothing" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'
ck "digest is claimed by the rehydrating session (S2)" 'grep -q "^session_id: \"S2\"" "$TMP/.reload/session.md"'

echo "-- a second /clear, S2 -> S3, is likewise silent (the claim actually took) --"
printf 'S2' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S3","source":"clear"}')"
ck "second clear also silent (false positive does not reappear)" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'
ck "digest re-claimed by S3" 'grep -q "^session_id: \"S3\"" "$TMP/.reload/session.md"'

echo "-- incoherent arm: session A armed, but B's write landed under that arm (v0.1.5 guard still holds) --"
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S_B"\nupdated_at: "x"\nintent: "written by B"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
printf 'S_A' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S_C","source":"clear"}')"
ck "incoherent arm STILL rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "incoherent arm warns" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'
ck "warning names the armer" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"S_A\")" >/dev/null'
ck "warning names the digest writer" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"S_B\")" >/dev/null'
ck "incoherent arm still consumed" '[ ! -f "$TMP/.reload/pending" ]'

echo "-- empty arm (pre-0.3, no id ever recorded on the arm side): rehydrates, no warning, digest untouched --"
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S_ORIG"\nupdated_at: "x"\nintent: "untouched"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
touch "$TMP/.reload/pending"    # empty arm: no owner ever stamped
OUT="$(run sessionstart-hook.sh '{"source":"clear"}')"   # no session_id in payload either
ck "empty arm rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "empty arm warns nothing" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'
ck "empty arm + no incoming id -> digest stamp untouched" 'grep -q "^session_id: \"S_ORIG\"" "$TMP/.reload/session.md"'

echo "-- no runtime id on input: arm IS set, but the payload carries no session_id -> stamp untouched --"
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S_X"\nupdated_at: "x"\nintent: "untouched too"\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
printf 'S_X' > "$TMP/.reload/pending"     # coherent arm (matches digest owner)
OUT="$(run sessionstart-hook.sh '{"source":"clear"}')"    # no session_id field at all
ck "no runtime id still rehydrates" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"step X\")" >/dev/null'
ck "no runtime id warns nothing (coherent arm)" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'
ck "no runtime id -> claim skipped, stamp untouched" 'grep -q "^session_id: \"S_X\"" "$TMP/.reload/session.md"'

echo "-- untrusted body: a body line starting session_id: must NOT be rewritten, only frontmatter --"
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S1"\nupdated_at: "x"\nintent: "own thread"\n---\n## Open questions & risks\nsession_id: NOT-THE-OWNER (model-written, untrusted)\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
printf 'S1' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S2","source":"clear"}')"
ck "frontmatter session_id claimed" 'grep -q "^session_id: \"S2\"" "$TMP/.reload/session.md"'
ck "body's session_id: line survives byte-identical" 'grep -qF "session_id: NOT-THE-OWNER (model-written, untrusted)" "$TMP/.reload/session.md"'

echo "-- unterminated fence: no frontmatter region exists, so NOTHING may be rewritten --"
# The closed-fence case above proves the body is safe when the fence is well
# formed. This proves it when the model drops the closing --- (or is truncated
# mid-write): the old code treated "opened, never closed" as frontmatter running
# to EOF, so the first body line starting session_id: was both READ as the owner
# (feeding it into the user-visible warning) and REWRITTEN in place.
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nintent: "no closing fence"\n## Open questions & risks\nsession_id: NOT-THE-OWNER\n' > "$TMP/.reload/session.md"
printf 'S_ARMER' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S_NEW","source":"clear"}')"
ck "unterminated fence: body line NOT rewritten" 'grep -qF "session_id: NOT-THE-OWNER" "$TMP/.reload/session.md"'
ck "unterminated fence: no claim stamp injected" '! grep -qF "session_id: \"S_NEW\"" "$TMP/.reload/session.md"'
ck "unterminated fence: body id never named as digest owner" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT-THE-OWNER\")" >/dev/null'
ck "unterminated fence still rehydrates (fail-open, invariant 3)" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext != null" >/dev/null'

echo "== CLAUDE.md's invariant-13 test citations actually resolve =="
# The invariant list's own convention is "each has a named test", i.e. the
# quoted strings must be greppable. They were paraphrases and matched nothing,
# so anyone auditing invariant 13 found no guard where the doc promised three.
C="$(cd "$H/.." && pwd)/CLAUDE.md"
SUITE="${BASH_SOURCE[0]}"
# Each citation must appear BOTH in CLAUDE.md and as a real label in this file.
# No loop with `exit` — ck runs its argument under eval, so a bare exit would
# kill the suite instead of failing the assertion.
cited(){ grep -qF "$1" "$C" && grep -qF "ck \"$1" "$SUITE"; }
ck "invariant 13 cites a real label: coherent arm warns nothing" 'cited "coherent arm warns nothing"'
ck "invariant 13 cites a real label: second clear also silent" 'cited "second clear also silent"'
ck "invariant 13 cites a real label: incoherent arm warns" 'cited "incoherent arm warns"'

echo "== Structural guard: no id-equality condition governs an exit (v0.1.5) =="
# Spec criterion 3's second prong. The behavioral tests above prove rehydration
# happens on the inputs we thought to try; this proves nobody re-introduced the
# gate itself. An id comparison may set a warning flag — it must never reach exit.
# The comparison basis changed from ARM_OWNER/SESSION_ID to
# ARM_OWNER/DIGEST_OWNER_AT_REHYDRATE (fixing the defect); the structural
# invariant it guards — no id comparison reaches an exit — did not.
ck "no id comparison guards an exit" '! grep -nE "(ARM_OWNER|SESSION_ID|DIGEST_OWNER_AT_REHYDRATE).*(&&|\|\|).*exit|exit.*(ARM_OWNER|SESSION_ID|DIGEST_OWNER_AT_REHYDRATE)" "$H/sessionstart-hook.sh"'

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

echo "== proxy_window: learns a model's window from a local cc-proxy, table stays fallback =="
# Test seam: a stub `curl` earlier on PATH than the real one. This is the most
# robust seam in plain bash on macOS+Linux CI — no port binding, no background
# server to reap, no flakiness from a slow listener. The stub inspects
# STUB_CURL_MODE (set per-case) and never touches the network.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/curl" <<'STUBEOF'
#!/usr/bin/env bash
case "${STUB_CURL_MODE:-}" in
  ok)
    printf '%s' '{"data":[{"id":"stub-model","context_window":128000},{"id":"stub-null","context_window":null},{"id":"stub-zero","context_window":0},{"id":"stub-str","context_window":"abc"}]}'
    ;;
  down) exit 7 ;;   # curl's own "couldn't connect" exit code
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$STUBBIN/curl"

run_proxy(){ # model source-json-extra-env...
  local model="$1"
  printf '{"session_id":"S1","source":"startup","model":"%s"}' "$model" \
    | PATH="$STUBBIN:$PATH" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" \
      ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}" STUB_CURL_MODE="${STUB_CURL_MODE:-}" \
      bash "$H/sessionstart-hook.sh"
}

rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "proxy window wins over the table (table would not know stub-model)" 'grep -q "window: 128000" "$TMP/.reload/model"'

rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=ok run_proxy "stub-missing" >/dev/null
ck "proxy reachable but id absent -> table fallback (1M default)" 'grep -q "window: 1000000" "$TMP/.reload/model"'

rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=ok run_proxy "stub-null" >/dev/null
ck "proxy null context_window -> table fallback" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=ok run_proxy "stub-zero" >/dev/null
ck "proxy zero context_window -> table fallback" 'grep -q "window: 1000000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=ok run_proxy "stub-str" >/dev/null
ck "proxy garbage context_window -> table fallback" 'grep -q "window: 1000000" "$TMP/.reload/model"'

rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL='' STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "ANTHROPIC_BASE_URL unset -> no lookup, table used, no hang" 'grep -q "window: 1000000" "$TMP/.reload/model"'

rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="https://example.com" STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "non-loopback base URL -> no lookup attempted (privacy guard)" 'grep -q "window: 1000000" "$TMP/.reload/model"'

# IPv6 loopback is BRACKETED in a URL — the only valid form. An earlier sed-based
# host parse cut "[::1]" down to "[", so the ::1 allowlist entry never matched and
# the lookup was silently skipped on an IPv6-configured proxy. These lock both
# directions: bracketed loopback is allowed, bracketed non-loopback is not.
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://[::1]:9999" STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "bracketed IPv6 loopback [::1] -> proxy lookup fires" 'grep -q "window: 128000" "$TMP/.reload/model"'
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://[2001:db8::1]:9999" STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "bracketed IPv6 non-loopback -> no lookup (privacy guard)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
# A host that merely STARTS with the loopback literal must not pass — the
# allowlist is an exact match, not a prefix.
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1.evil.com:9999" STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "loopback-prefixed remote host -> no lookup (privacy guard)" 'grep -q "window: 1000000" "$TMP/.reload/model"'
# Userinfo in the authority: the plugin's host parse cut at the first ":" and
# read 127.0.0.1, while curl reads everything before "@" as credentials and
# contacts the REAL host after it (audit F06, reproduced with a logging stub).
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999@evil.example/" STUB_CURL_MODE=ok run_proxy "stub-model" >/dev/null
ck "userinfo in the base URL -> no lookup (privacy guard)" 'grep -q "window: 1000000" "$TMP/.reload/model"'

rm -f "$TMP/.reload/model"
START=$(date +%s)
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=down run_proxy "stub-model" >/dev/null
ELAPSED=$(( $(date +%s) - START ))
ck "proxy down -> table fallback" 'grep -q "window: 1000000" "$TMP/.reload/model"'
ck "proxy-down case does not hang (<5s)" '[ "$ELAPSED" -lt 5 ]'

echo "== proxy_window: F05 guard holds — [1m] Claude id still resolves 1M with proxy reachable =="
rm -f "$TMP/.reload/model"
ANTHROPIC_BASE_URL="http://127.0.0.1:9999" STUB_CURL_MODE=ok run_proxy "claude-opus-5[1m]" >/dev/null
ck "claude-opus-5[1m] stamps 1000000 (cc-proxy omits window for claude-* ids)" 'grep -q "window: 1000000" "$TMP/.reload/model"'


# ── 2026-09-02 principal audit: F01/F02/F03 — the transcript scan ─────────────
# Row builders. `main` is a main-thread assistant row; `side` is a SUBAGENT row
# (isSidechain:true) as older Claude Code versions append them to the main
# transcript (cc-repete cites "500 trailing sidechain lines" as a design
# margin, not a measurement; current
# versions write subagents/*.jsonl instead — the filter must be correct on both).
main_row(){ printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1" "$2"; }
side_row(){ printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1"; }

echo "== Stop hook: a subagent (sidechain) row last is NOT the main thread (audit F01) =="
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
printf 'model: claude-opus-4-8\nwindow: 1000000\n' > "$TMP/.reload/model"
{ main_row claude-opus-4-8 500000; side_row 20000; } > "$TMP/t.jsonl"     # main 50%, subagent 2% LAST
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "sidechain row last: main thread's 50% still nudges" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"50%\")" >/dev/null'
ck "sidechain row last: stamp is NOT restamped to the subagent model" 'grep -q "model: claude-opus-4-8" "$TMP/.reload/model"'
ck "sidechain row last: window stays 1M" 'grep -q "window: 1000000" "$TMP/.reload/model"'

echo "-- the [1m] shield survives a sidechain haiku row (F01 escalation: the F05 downgrade through a new door) --"
printf 'model: claude-sonnet-4-5[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"; rm -f "$TMP/.reload/notified"
{ main_row claude-sonnet-4-5-20250929 300000; side_row 15000; } > "$TMP/t.jsonl"
run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" >/dev/null
{ main_row claude-sonnet-4-5-20250929 300000; side_row 15000; main_row claude-sonnet-4-5-20250929 320000; } > "$TMP/t.jsonl"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "[1m] stamp survives a sidechain row" 'grep -q "claude-sonnet-4-5\[1m\]" "$TMP/.reload/model"'
ck "32% of the real 1M window -> silent (no 5x false nudge)" '[ -z "$OUT" ]'

echo "== Stop hook: one malformed transcript line does not blank the measurement (audit F02) =="
printf 'model: claude-opus-4-8\nwindow: 1000000\n' > "$TMP/.reload/model"; rm -f "$TMP/.reload/notified"
{ main_row claude-opus-4-8 100000; printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usa'; } > "$TMP/t.jsonl"
head -c 3000000 /dev/zero | tr '\0' ' ' >> "$TMP/t.jsonl"   # 3MB: byte/4 would read as ~75%
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "truncated trailing line: the valid 10% row is measured -> silent" '[ -z "$OUT" ]'
{ main_row claude-opus-4-8 100000; printf '{"type":"x","message":"a plain string"}\n'; printf '42\n'; } > "$TMP/t.jsonl"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>"$TMP/err.txt")"
ck "a row whose message is a string (and a bare number row) are skipped -> silent" '[ -z "$OUT" ]'
ck "...and produce no stderr" '[ ! -s "$TMP/err.txt" ]'

echo "-- a type-mismatched field on the LAST row must not resurrect an EARLIER row's number --"
# The scan emits "tokens model" per row and the caller keeps the LAST line. If
# tokens and model are combined in ONE fallible expression, a wrong TYPE in
# either half kills the whole row under -R, `tail -n 1` then returns an EARLIER
# row, and USED is a well-formed number that passes every validity check — so
# the byte/4 fallback never fires and a 95% session measures as 2%. That is
# silent-WRONG, strictly worse than the slurp this replaced (which produced no
# answer at all, i.e. the safe over-count). Each half must fail independently.
printf 'model: claude-opus-4-8\nwindow: 1000000\n' > "$TMP/.reload/model"; rm -f "$TMP/.reload/notified"
{ main_row claude-opus-4-8 20000
  printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","model":true,"usage":{"input_tokens":950000}}}\n'; } > "$TMP/t.jsonl"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "non-string model on the last row: its 95% is still measured (not the earlier 2%)" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"95%\")" >/dev/null'
# The other two shapes are unrecoverable (the token count itself is not a
# number), so SKIPPING the row is the right answer — what must not happen is a
# jq error on stderr, which is the signature of the whole-row abort above.
rm -f "$TMP/.reload/notified"
{ main_row claude-opus-4-8 500000
  printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":"950000"}}}\n'; } > "$TMP/t.jsonl"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>"$TMP/err.txt")"
ck "string input_tokens: row skipped, the last MEASURABLE row (50%) is used" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"50%\")" >/dev/null'
ck "...with no jq error on stderr" '[ ! -s "$TMP/err.txt" ]'
rm -f "$TMP/.reload/notified"
{ main_row claude-opus-4-8 500000
  printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","model":"claude-opus-4-8","usage":"n/a"}}\n'; } > "$TMP/t.jsonl"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>"$TMP/err.txt")"
ck "non-object usage: row skipped, the last measurable row (50%) is used" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"50%\")" >/dev/null'
ck "...with no jq error on stderr either" '[ ! -s "$TMP/err.txt" ]'

echo "== Stop hook: the scan is a tail WINDOW, with a full-file fallback (audit F03) =="
# Mechanism pin by INVOCATION, not wall-clock: a jq shim logs every argv. On the
# window path jq must never be handed the transcript PATH (it reads tail's
# stdin) and must never be run with a slurp flag; on the fallback path it must
# be handed the path exactly once. A shim is immune to machine speed.
JQSHIM="$TMP/jqshim"; mkdir -p "$JQSHIM"; REALJQ="$(command -v jq)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$JQ_LOG"\nexec %s "$@"\n' "$REALJQ" > "$JQSHIM/jq"; chmod +x "$JQSHIM/jq"
run_shim(){ printf '%s' "$1" | JQ_LOG="$TMP/jq.log" PATH="$JQSHIM:$PATH" ANTHROPIC_BASE_URL="" CLAUDE_PROJECT_DIR="$TMP" bash "$H/stop-hook.sh"; }
rm -f "$TMP/.reload/notified"; : > "$TMP/jq.log"
{ for i in $(seq 3000); do main_row claude-opus-4-8 1000; done; main_row claude-opus-4-8 500000; } > "$TMP/t.jsonl"
OUT="$(run_shim "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "window path: correct answer (50% nudges)" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"50%\")" >/dev/null'
ck "window path: jq never received the transcript path" '! grep -qF "$TMP/t.jsonl" "$TMP/jq.log"'
ck "no jq invocation slurps (-s / -rs)" '! grep -qE "(^| )-r?s( |$)" "$TMP/jq.log"'
rm -f "$TMP/.reload/notified"; : > "$TMP/jq.log"
{ main_row claude-opus-4-8 500000; for i in $(seq 2500); do side_row 100; done; } > "$TMP/t.jsonl"   # 2500 trailing sidechain rows > the window
OUT="$(run_shim "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "fallback path: still the correct answer (50% nudges)" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"50%\")" >/dev/null'
ck "fallback path: jq received the transcript path exactly once" '[ "$(grep -cF "$TMP/t.jsonl" "$TMP/jq.log")" -eq 1 ]'

echo "-- the \"tokens<space>model\" output CONTRACT, pinned at the seam --"
# The caller splits LAST_TURN on the first space and treats "no space at all" as
# "no model field". That guard looks dead — jq emits a trailing space even when
# .message.model is absent, so the no-space branch is unreachable TODAY — but it
# is the contract between the scan program and its consumer, and it is what
# stops a tokens-only line from being read as a MODEL ID. Measured with the
# guard removed and the program emitting tokens only: .reload/model is stamped
# `model: 500000`, which destroys window resolution and the [1m] shield for the
# rest of the session. Pin the contract at the seam so a future change to
# TURN_SCAN_JQ's shape cannot silently take that branch.
ck "scan program still emits a space-joined 'tokens model' pair" \
  'printf "%s\n" "{\"type\":\"assistant\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"model\":\"m1\",\"usage\":{\"input_tokens\":7}}}" | jq -rR "$(sed -n "/^TURN_SCAN_JQ=/,/^$/p" "$H/stop-hook.sh" | sed "1s/^TURN_SCAN_JQ=.//; \$d" | sed "\$s/.\$//")" 2>/dev/null | grep -qx "7 m1"'
# ...and that a tokens-ONLY line never reaches the stamp as a model id.
printf 'model: claude-sonnet-4-5[1m]\nwindow: 1000000\n' > "$TMP/.reload/model"; rm -f "$TMP/.reload/notified"
main_row claude-opus-4-8 500000 > "$TMP/t.jsonl"
run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" >/dev/null
ck "a bare token count is never stamped as the model id" '! grep -qE "^model: [0-9]+$" "$TMP/.reload/model"'

echo "== Stop hook: the README's own .reload/config example is honoured (audit F04) =="
# The README block carries inline `# comments`; every reader must strip them,
# or the pin it teaches is silently dropped. Feed the REAL README lines.
README_CFG="$(sed -n '/^context_budget_pct: 45       #/,/^context_window: 1000000      #/p' "$(dirname "$H")/README.md")"
ck "README still carries the three-line example (else this case is vacuous)" '[ "$(printf "%s\n" "$README_CFG" | wc -l)" -eq 3 ]'
printf '%s\n' "$README_CFG" | sed 's/^context_window: 1000000/context_window: 200000/' > "$TMP/.reload/config"
printf 'model: x\nwindow: 1000000\n' > "$TMP/.reload/model"; rm -f "$TMP/.reload/notified"
main_row x 150000 > "$TMP/t.jsonl"     # 75% of the 200k PIN, 15% of the 1M stamp
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "commented context_window pin is honoured -> 75% nudges" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"75%\")" >/dev/null'
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot   # forced digest turn\ncontext_window: 200000\n' > "$TMP/.reload/config"
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing" "$TMP/.reload/notified"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "commented context_budget_mode: snapshot still blocks" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing" "$TMP/.reload/notified"

echo "== Stop pass1: a DIRECTORY where the summarizing marker should be never blocks (audit F05) =="
# `touch` succeeds on a directory, `-f` never matches it and `rm -f` never
# removes it: pass 1 re-entered on every ordinary Stop (measured 3/3 blocks).
# Invariant 2 — never block without the MARKER on disk — is the rule.
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\ncontext_window: 1000000\n' > "$TMP/.reload/config"
main_row claude-opus-4-8 500000 > "$TMP/t.jsonl"
rm -rf "$TMP/.reload/summarizing" "$TMP/.reload/pending" "$TMP/.reload/notified"; mkdir "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "directory at summarizing: first Stop does not block" 'printf "%s" "$OUT" | jq -e ".decision == null" >/dev/null 2>&1 || [ -z "$OUT" ]'
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "directory at summarizing: second Stop does not block either" 'printf "%s" "$OUT" | jq -e ".decision == null" >/dev/null 2>&1 || [ -z "$OUT" ]'
rmdir "$TMP/.reload/summarizing"

echo "-- a DIRECTORY at pending: the arm cannot be written; say so, never re-block --"
printf -- '---\nsession_id: "S1"\n---\n## Next concrete step\nX\n' > "$TMP/.reload/session.md"
rm -rf "$TMP/.reload/pending"; mkdir "$TMP/.reload/pending"
touch -t 202001010000 "$TMP/.reload/summarizing"; touch "$TMP/.reload/session.md"
OUT="$(run stop-hook.sh "{\"session_id\":\"S1\",\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "pass 2 with an unwritable arm warns instead of claiming success" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT armed\")" >/dev/null'
ck "pass 2 with an unwritable arm never claims digest saved" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"digest saved\")" >/dev/null'
rm -f "$TMP/.reload/notified"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}" 2>/dev/null)"
ck "over budget with a directory at pending: no re-block (fail-open)" 'printf "%s" "$OUT" | jq -e ".decision == null" >/dev/null 2>&1 || [ -z "$OUT" ]'
OUT="$(run precompact-hook.sh '{"session_id":"S1","trigger":"manual"}' 2>/dev/null)"
ck "PreCompact with an unwritable arm warns" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT armed\")" >/dev/null'
rm -rf "$TMP/.reload/pending" "$TMP/.reload/summarizing" "$TMP/.reload/notified"

echo "== SessionStart banner: the intent is read from the FRONTMATTER, quoted or not (audit F08) =="
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"
printf -- '---\nsession_id: "S1"\nintent: unquoted intent text\n---\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
touch "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S2","source":"clear"}')"
ck "unquoted intent still leads the banner" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"unquoted intent text\")" >/dev/null'
printf -- '---\nsession_id: "S1"\n---\n## Open questions & risks\nintent: "BODY-INTENT untrusted"\n## Next concrete step\nstep X\n' > "$TMP/.reload/session.md"
touch "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"S2","source":"clear"}')"
ck "a body intent: line never reaches the banner" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"BODY-INTENT\")" >/dev/null'
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
