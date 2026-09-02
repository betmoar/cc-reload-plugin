#!/usr/bin/env bash
# shellcheck disable=SC2034  # path constants below are consumed by the sourcing hook scripts
#
# cc-reload shared hook guards. Sourced by every hook script.
#
# Two invariants enforced here for ALL hooks:
#   1. Fail open if jq is missing — we cannot parse hook input safely, so do
#      nothing rather than misbehave. (Sourced `exit 0` exits the caller too.)
#   2. Stand down if a cc-repete loop owns this session — cc-repete owns the
#      context budget / handoff / rehydrate cycle while a loop is active, and
#      cc-reload must never fight it.
#
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RELOAD_DIR="$PROJECT_DIR/.reload"
DIGEST="$RELOAD_DIR/session.md"
PENDING="$RELOAD_DIR/pending"          # arming marker: rehydrate on next SessionStart
SUMMARIZING="$RELOAD_DIR/summarizing"  # transient: budget snapshot turn in progress
NOTIFIED="$RELOAD_DIR/notified"        # notify ladder: last occupancy % a budget notice fired at
CONFIG="$RELOAD_DIR/config"
MODELFILE="$RELOAD_DIR/model"          # model id + resolved window, stamped by SessionStart

command -v jq >/dev/null 2>&1 || exit 0

# Create .reload/ and drop a self-ignoring .gitignore the first time, so a plugin
# user's project never accidentally commits per-session runtime state. A lone "*"
# ignores every file in the dir — including the .gitignore itself — so nothing
# under .reload/ is ever tracked, regardless of the project's own gitignore.
ensure_reload_dir() {
  mkdir -p "$RELOAD_DIR"
  [ -f "$RELOAD_DIR/.gitignore" ] || printf '*\n' > "$RELOAD_DIR/.gitignore"
}

# True when a cc-repete loop is active in this project -> cc-reload stands down.
repete_active() {
  local f="$PROJECT_DIR/.repete/loop.local.md"
  [ -f "$f" ] && grep -qE '^active:[[:space:]]*true[[:space:]]*$' "$f"
}

# Read a "key: value" line from a file (absent -> empty). Strips a trailing
# `# comment`, the surrounding whitespace and a single layer of surrounding
# quotes, so a string value keeps any internal spaces.
#
# The comment strip is load-bearing (audit 2026-09-02 F04): the README's own
# `.reload/config` example is written `key: value   # comment`, and every value
# used to come back WITH the comment, fail its validation and silently fall
# back to the default — the documented `context_window` pin was dropped. Values
# here are numbers, enums and model ids; `#` is never legitimate content.
# FOUR readers parse this file and must agree: this function,
# scripts/reload-config.sh `get`, and scripts/statusline.sh (three inline
# copies) — tests/test-config.sh "reader PARITY" pins them to each other.
kv() {
  [ -f "$2" ] || return 0
  grep -E "^$1:" "$2" | head -1 \
    | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]*#.*\$//; s/[[:space:]]+\$//; s/^\"(.*)\"\$/\1/"
}
cfg() { kv "$1" "$CONFIG"; }

# --- concurrent-session ownership (see docs/spec/concurrent-sessions.md §4.2) ---
#
# Identity lives IN the artifact, never in a shared marker beside it: a
# directory-global owner file is overwritten by whichever session starts last,
# so it identifies neither the incumbent nor the writer — the same defect as the
# unowned digest it would be guarding (spec §4.2.1, rejected alternative).

OWNER_WINDOW_DEFAULT=14400   # 4h, in seconds

# True only when the digest carries a COMPLETE frontmatter region: `---` on line
# 1 and a closing `---` below it. An opener with no closer is not "frontmatter
# running to EOF" — it is a digest with no frontmatter at all, and every line
# after it is untrusted body (invariant 8). Treating it as frontmatter let a body
# line reading `session_id: …` be read as the owner AND rewritten in place, which
# is precisely the corruption the body-scoping exists to prevent. The digest is
# model-written under a line budget, so a dropped closing fence or a truncated
# mid-write is an ordinary failure, not a contrived one.
frontmatter_closed() {
  [ -f "$DIGEST" ] || return 1
  awk '
    NR==1 && $0 != "---" { exit 1 }        # no opener: no frontmatter
    NR>1  && $0 == "---" { ok=1; exit }    # closer found
    END { exit ok ? 0 : 1 }                # opened but never closed -> none
  ' "$DIGEST" 2>/dev/null
}

# The digest's stamped owner, or "" when absent/empty/un-parseable. An empty
# result means UNDETECTABLE, not "safe" — callers proceed silently (fail-open).
#
# NOT kv(): that greps ^session_id: anywhere in the file, and a digest BODY is
# model-written and untrusted (invariant 8) — an "Open questions" bullet reading
# `session_id: whatever` would be picked up as the owner. Scope to the YAML
# frontmatter: start at the opening ---, stop at the closing one. One awk pass.
digest_owner() { digest_field session_id; }

# digest_field <key> -> the FRONTMATTER value of <key>, or "" when the digest,
# the frontmatter region or the key is absent. Surrounding quotes are stripped
# (one layer, only when both are present); anything else is returned verbatim
# — an unquoted value is a value, not an absence (audit 2026-09-02 F08: the
# banner's `intent` used an `awk -F'"'` that dropped every unquoted intent and
# truncated an escaped one). Frontmatter-scoped like digest_owner() because the
# BODY is model-written and untrusted (invariant 8): a body line `intent:` or
# `session_id:` must never be read as the field. <key> is a literal identifier
# (session_id, intent, updated_at) — never user input.
digest_field() {
  [ -f "$DIGEST" ] || return 0
  frontmatter_closed || return 0
  awk -v key="$1" '
    NR==1 && $0 != "---" { exit }          # no frontmatter at all
    NR>1 && $0 == "---"  { exit }          # closing fence: stop before the body
    index($0, key ":") == 1 {
      sub("^" key ":[[:space:]]*", "")
      sub(/[[:space:]]+$/, "")
      if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") }
      print; exit
    }
  ' "$DIGEST" 2>/dev/null
}

# Rewrite the digest's frontmatter session_id to NEW_ID. Called by SessionStart
# once it has rehydrated a digest: this session now carries that working
# thread, so it claims it — the next /snapshot then sees INCUMBENT==WRITER and
# stays silent, which is what makes an ordinary /clear (which mints a fresh id
# every time) idempotent instead of tripping the guard on its own primary path.
#
# Same frontmatter scoping as digest_owner(): the BODY is model-written and
# untrusted (invariant 8), so a body line that happens to start with
# `session_id:` must survive byte-identical. Only the frontmatter key is ever
# a rewrite target.
#
# Fail-open like claim-digest.sh: atomic temp file + mv, and ANY failure along
# the way (awk error, unwritable dir, mv failure) leaves $DIGEST exactly as it
# was and returns quietly — this must never be able to destroy or truncate a
# digest. Callers must never gate an exit on this (invariant 3) — it only
# records ownership, it does not decide whether to rehydrate.
claim_digest() {
  local new_id="$1"
  [ -n "$new_id" ] || return 0
  [ -f "$DIGEST" ] || return 0
  # No COMPLETE frontmatter region -> nothing to claim; leave the digest
  # untouched. head -1 alone accepted an unterminated fence, and the awk below
  # then rewrote the first body line matching ^session_id: (see
  # frontmatter_closed above).
  frontmatter_closed || return 0

  local tmp="$DIGEST.claim.$$"
  if awk -v id="$new_id" '
    NR==1 { print; if ($0 != "---") { body=1 }; next }  # no opening fence -> never in frontmatter
    body { print; next }                                # past the closing fence: verbatim, never rescanned
    $0 == "---" { print; body=1; next }                 # closing fence
    /^session_id:/ && !replaced {
      print "session_id: \"" id "\""
      replaced=1
      next
    }
    { print }
  ' "$DIGEST" > "$tmp" 2>/dev/null && mv "$tmp" "$DIGEST" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null   # never leave a truncated partial behind
  return 0
}

# Freshness window in seconds. A non-negative integer in config wins; anything
# else (unset, garbage, negative) falls back to the default. 0 disables the
# check entirely, matching the context_budget_pct: 0 convention.
owner_window() {
  local w; w="$(cfg context_owner_window)"
  [[ "$w" =~ ^[0-9]+$ ]] && printf '%s' "$w" || printf '%s' "$OWNER_WINDOW_DEFAULT"
}

# Resolve a model id to its context window in tokens. Current-generation
# main-session models — Opus 4.6/4.7/4.8, Sonnet 4.6, the 5-series (Fable/Mythos/
# Sonnet 5/Opus 5), and any "[1m]" id — ship a 1M window at standard pricing.
# Haiku is a genuine 200K tier, as were the OLDER non-"[1m]" Opus/Sonnet (4.0/4.1/
# 4.5 and Sonnet 4.0/4.5, which offered 1M only behind the "[1m]" beta). Any
# unrecognized id assumes a large 1M window (optimistic — better to checkpoint a
# small session late than nag a large one early). This is a heuristic over
# model-id strings — `context_window` in .reload/config always wins (set it for
# your main model so a new/unrecognized id can't misconfigure the budget). Most
# 200K ids now belong to subagents; the budget targets the main session's window.
model_window() {
  # Minor-version matches are boundary-anchored: an id ends at the minor (e.g.
  # claude-opus-4-8) or continues with a "-<date>" snapshot suffix (e.g.
  # claude-haiku-4-5-20251001). A bare *opus-4-1* substring would ALSO match a
  # future claude-opus-4-10 and misclassify it 200K, so anchor on end-of-id (no
  # trailing glob) or a literal "-". The "[1m]" beta form is handled first, above.
  case "$1" in
    *"[1m]"*)                                        printf '1000000' ;;   # explicit 1M beta suffix
    *opus-4-6|*opus-4-6-*|*opus-4-7|*opus-4-7-*|*opus-4-8|*opus-4-8-*) printf '1000000' ;;   # current Opus: 1M at standard pricing
    *sonnet-4-6|*sonnet-4-6-*)                       printf '1000000' ;;   # Sonnet 4.6: 1M
    *fable-5*|*mythos-5*|*sonnet-5*|*opus-5*)        printf '1000000' ;;   # 5-series tiers: 1M
    *opus-4-0|*opus-4-0-*|*opus-4-1|*opus-4-1-*|*opus-4-5|*opus-4-5-*) printf '200000' ;;   # older non-[1m] Opus: genuine 200K
    *sonnet-4-0|*sonnet-4-0-*|*sonnet-4-5|*sonnet-4-5-*) printf '200000' ;;   # older non-[1m] Sonnet: genuine 200K
    *haiku*)                                         printf '200000'  ;;   # Haiku tiers: 200K (no minor split)
    # cc-proxy (non-Claude) models below. Only windows that DIFFER from the optimistic
    # 1M default get an explicit case; glm-5.2/deepseek-v4-*/qwen3.*-* are already 1M via
    # the default and deliberately have no case here (adding one would just be a no-op that
    # could bit-rot). Unlisted/OpenRouter-prefixed forms (e.g. "deepseek/deepseek-v4-pro",
    # "qwen/qwen3.7-max") fall through to the default too — cc-proxy publishes no window for
    # those. See CLAUDE.md invariant 5/6.
    *glm-4.5|*glm-4.5-*)                             printf '128000'  ;;   # glm-4.5, glm-4.5-air: 128K
    *glm-4.6|*glm-4.6-*|*glm-4.7|*glm-4.7-*)         printf '200000'  ;;   # glm-4.6, glm-4.7: 200K
    *glm-5|*glm-5-*|*glm-5.1|*glm-5.1-*)             printf '200000'  ;;   # glm-5, glm-5-turbo, glm-5.1: 200K (glm-5.2 falls through to default 1M)
    *)                                               printf '1000000' ;;   # unrecognized id -> assume large (see stop-hook floor)
  esac
}

# Ask a locally-running cc-proxy for a model's real context window, so the
# curated table above becomes a fallback rather than the only source of
# truth. cc-proxy v0.5.1+ publishes `context_window` (positive integer
# tokens) on `GET /v1/models`; ids it hasn't curated OMIT the field entirely
# (never null — CLAUDE.md coupling table). Called ONCE per session, from
# SessionStart only (hooks/sessionstart-hook.sh) — never from the Stop hook's
# per-turn hot path, and never from the mid-session restamp path in
# stop-hook.sh, which stays table-only on purpose.
#
# Prints the window on success; prints NOTHING (and returns non-zero) on ANY
# failure — no ANTHROPIC_BASE_URL, non-loopback host, no curl, timeout,
# non-200, malformed JSON, missing/invalid field. Callers must treat empty
# output as "consult the table", never as an error to surface.
#
# Loopback-only by design: this must never phone out. The URL is derived
# from ANTHROPIC_BASE_URL (whatever port the user's proxy actually bound —
# never hard-coded), and only used if its host is 127.0.0.1, localhost, or
# ::1.
proxy_window() {
  local model="$1"
  [ -n "$model" ] || return 1
  [ -n "${ANTHROPIC_BASE_URL:-}" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  # Extract the host from ANTHROPIC_BASE_URL (scheme://host[:port][/path]) and
  # require it to be loopback. This is a privacy guard, not an optimization —
  # a non-loopback base URL means a REAL remote endpoint, and this plugin must
  # never contact one on its own initiative.
  #
  # An IPv6 literal is BRACKETED in a URL (http://[::1]:4000) — that is the only
  # valid form, since a bare "::1:4000" cannot be split into host and port. So
  # strip the scheme, then peel the brackets FIRST; splitting on ":" before that
  # would cut "[::1]" down to "[" and silently fail the allowlist (the bug this
  # replaces). Only after the bracketed form is handled is it safe to cut at the
  # first ":" or "/", which delimits port/path for the unbracketed hosts.
  local host="${ANTHROPIC_BASE_URL#*://}"
  # Userinfo is refused OUTRIGHT (audit 2026-09-02 F06): the cuts below read
  # `http://127.0.0.1:4000@evil.example/` as host 127.0.0.1, while curl reads
  # everything before "@" as credentials and contacts evil.example. A loopback
  # proxy never needs userinfo, so any "@" in the authority ends the lookup.
  case "${host%%/*}" in *@*) return 1 ;; esac
  case "$host" in
    \[*\]*) host="${host#\[}"; host="${host%%\]*}" ;;   # [::1]:4000 -> ::1
    *)      host="${host%%/*}"; host="${host%%:*}" ;;   # 127.0.0.1:4000 -> 127.0.0.1
  esac
  case "$host" in
    127.0.0.1|localhost|::1) ;;
    *) return 1 ;;
  esac

  local base="${ANTHROPIC_BASE_URL%/}"
  local body
  body="$(curl -fsS --max-time 1 --connect-timeout 1 "$base/v1/models" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1

  local win
  win="$(printf '%s' "$body" | jq -r --arg id "$model" '
    ( .data // . // [] )
    | ( if type == "array" then . else [] end )
    | map(select(.id == $id))
    | first
    | (.context_window // empty)
  ' 2>/dev/null)"

  [[ "$win" =~ ^[0-9]+$ ]] && [ "$win" -gt 0 ] || return 1
  printf '%s' "$win"
}
