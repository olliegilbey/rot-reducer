#!/usr/bin/env bash
# rot-reducer.sh
#
# PostToolUse hook for the rot-reducer plugin.
#
# Reads the hook input JSON on stdin, estimates how many tokens the current
# session has consumed, and emits a `hookSpecificOutput.additionalContext`
# message on stdout as the session approaches Claude Code's auto-compaction
# boundary. The message asks the model to leave a handoff behind, so work
# continues cleanly once the transcript is replaced by a summary.
#
# It never tells the model to stop. A session that stalls short of the
# boundary is strictly worse off than one that runs through it: it gets
# neither the compaction nor the work.
#
# Inspired by yurukusa/cc-safe-setup's context-monitor, which writes warnings
# to stderr that only the human sees. This variant uses the documented hook
# output mechanism so the model itself reads the warning and can act on it.
#
# Exit code is always 0 — we never block a turn.

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via environment)
# ----------------------------------------------------------------------------
# Fires are anchored to the auto-compaction boundary B, not to absolute token
# counts. Three of them, at fixed distances below B: two suggestions then one
# instruction. Fixed rather than proportional because what matters is how much
# room is left to write a handoff in, and that is an absolute amount of work.
#
# Offsets are measured from the EFFECTIVE boundary (see below), not the
# configured window, so they state real runway. Against a 300k setting the
# effective boundary is ~267k and these land at 232k, 242k and 252k. Tuned
# from live behaviour: an agent that saw the first note wrote its handoff
# immediately, so the useful window is well before the boundary.
FIRE_OFFSETS="${CC_CONTEXT_FIRE_OFFSETS:-35000 25000 15000}"

# Fallback boundary, used only when `autoCompactWindow` is set nowhere. The
# real default in that case is model-specific and readable from nothing, so
# these are a guess. The window size is a proxy for model generation:
#   1m   - newer models that ship the 1M window.
#   200k - older 200k-class models.
# CLAUDE_CODE_DISABLE_1M_CONTEXT is the only window signal a hook can read.
# It errs toward 1m, which is the right way to be wrong now that nearly
# everything is a 1m model.
FALLBACK_1M="${CC_CONTEXT_FALLBACK_1M:-300000}"
FALLBACK_200K="${CC_CONTEXT_FALLBACK_200K:-180000}"

# A boundary below this is treated as unusable (the lowest offset would land
# at or below zero) and we fall back to the defaults above.
MIN_USABLE_BOUNDARY=60000

# Claude Code compacts BEFORE the configured window, needing room to run the
# summarisation, and the exact point varies. Two observed against a 300k
# setting: 267,430 (89%) and 284,061 (95%). We take the LOW end, because a
# fire that lands after compaction is worthless. Everything below hangs off
# this effective boundary, so an offset means real runway.
EFFECTIVE_PCT="${CC_CONTEXT_EFFECTIVE_PCT:-89}"

# ----------------------------------------------------------------------------
# Messages
# ----------------------------------------------------------------------------
# Fires 1-4 suggest; fire 5 instructs. The escalation is in tone, not volume.
#
# Placeholder: the literal token `%LEFT%` is substituted at emit time with the
# tokens remaining until the boundary, rounded to the nearest thousand and
# comma-grouped. It is a plain find-and-replace — nothing else in these
# strings is substituted.
#
SUGGEST_MSG="NOTE: ~%LEFT% tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working."
INSTRUCT_MSG="WARNING: ~%LEFT% tokens until auto-compaction. Write or update your handoff now. Keep working through the boundary. Stopping short strands the session."

# Tool-count fallback: assumed tokens per tool call when transcript and
# debug log are both unavailable. Crude, and a weak fit against a hard
# boundary — it can fire early or not at all. Kept only as last resort.
FALLBACK_TOKENS_PER_CALL="${CC_CONTEXT_FALLBACK_TOKENS_PER_CALL:-800}"

# Include subagents in budget monitoring. Off by default — subagents
# can't carry a handoff into the parent session, so a nudge to them is
# meaningless and the main agent ends up parroting it back.
INCLUDE_SUBAGENTS="${CC_CONTEXT_INCLUDE_SUBAGENTS:-0}"

# Per-plugin persistent state dir. Provided by Claude Code as
# ~/.claude/plugins/data/<id>/. We namespace by session_id below.
DATA_ROOT="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/rot-reducer}"

# ----------------------------------------------------------------------------
# Read and parse hook input from stdin
# ----------------------------------------------------------------------------
# jq is required — without it we can't parse hook input, read settings, or
# build clean JSON output. Fail silently (exit 0, no stdout).
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"

# Skip subagent tool calls unless explicitly opted-in. Canonical signal is
# the documented `agent_id` field, which Claude Code populates only when the
# hook fires inside a subagent. The `*/subagents/*` transcript path check is
# kept as a belt-and-braces fallback for edge cases where agent_id isn't set.
if [ "$INCLUDE_SUBAGENTS" != "1" ]; then
  AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)"
  [ -n "$AGENT_ID" ] && exit 0
  case "$TRANSCRIPT_PATH" in
  */subagents/*) exit 0 ;;
  esac
fi

# Without a session_id we can't safely namespace state. Bucket under "unknown".
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

STATE_DIR="${DATA_ROOT}/${SESSION_ID}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

COUNT_FILE="${STATE_DIR}/count"
FIRED_FILE="${STATE_DIR}/fired"
CONFIG_FILE="${STATE_DIR}/config"
DEBUG_FILE="${STATE_DIR}/last_eval"

# Increment tool-call counter (used only for the fallback token estimate).
COUNT="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
COUNT=$((COUNT + 1))
echo "$COUNT" >"$COUNT_FILE"

LAST_FIRED="$(cat "$FIRED_FILE" 2>/dev/null || echo 0)"

# ----------------------------------------------------------------------------
# Resolve the auto-compaction boundary
# ----------------------------------------------------------------------------
# Precedence, highest first (matching Claude Code's own settings order, minus
# the two we cannot see):
#   CLAUDE_CODE_AUTO_COMPACT_WINDOW   (env, plain integers only)
#   <cwd>/.claude/settings.local.json
#   <cwd>/.claude/settings.json
#   ~/.claude/settings.local.json
#   ~/.claude/settings.json
#
# We cannot read managed policy or the `--autocompact` command-line flag. A
# session started with that flag will be measured against the wrong number;
# that blind spot is unclosable from a hook and is accepted.

settings_files() {
  [ -n "$CWD" ] && printf '%s\n%s\n' \
    "${CWD}/.claude/settings.local.json" \
    "${CWD}/.claude/settings.json"
  printf '%s\n%s\n' \
    "${HOME}/.claude/settings.local.json" \
    "${HOME}/.claude/settings.json"
}

# First value found for a top-level key, walking files in precedence order.
setting_value() {
  local key="$1" file val
  while IFS= read -r file; do
    [ -r "$file" ] || continue
    # `//` treats `false` as absent, so `has` is the only safe test here:
    # autoCompactEnabled is a boolean and false is exactly the value we need.
    val="$(jq -r --arg k "$key" 'if has($k) then (.[$k] | tostring) else empty end' "$file" 2>/dev/null)"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  done < <(settings_files)
  return 1
}

# Accepted forms: "500k", "1M", 200000, and a bare number 100-1000 meaning
# thousands. Echoes an integer token count, or nothing if unparseable.
parse_window() {
  local raw n
  raw="$(printf '%s' "$1" | tr -d '"' | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
  *k)
    n="${raw%k}"
    case "$n" in *[!0-9]*) return 1 ;; esac
    echo $((n * 1000))
    ;;
  *m)
    n="${raw%m}"
    case "$n" in *[!0-9]*) return 1 ;; esac
    echo $((n * 1000000))
    ;;
  *)
    case "$raw" in '' | *[!0-9]*) return 1 ;; esac
    if [ "$raw" -ge 100 ] && [ "$raw" -le 1000 ]; then
      echo $((raw * 1000))
    else
      echo "$raw"
    fi
    ;;
  esac
}

resolve_config() {
  local enabled window boundary profile origin

  # Compaction switched off means no boundary exists, so every message this
  # hook could send would be describing an event that will never happen.
  enabled="$(setting_value autoCompactEnabled)"
  if [ "$enabled" = "false" ]; then
    echo "disabled"
    return 0
  fi

  boundary=""
  origin=""
  if [ -n "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ]; then
    boundary="$(parse_window "$CLAUDE_CODE_AUTO_COMPACT_WINDOW")" && origin="env"
  fi
  if [ -z "$boundary" ]; then
    window="$(setting_value autoCompactWindow)"
    if [ -n "$window" ]; then
      boundary="$(parse_window "$window")" && origin="settings"
    fi
  fi

  # Nothing set anywhere, or a value too small to hang five offsets off.
  if [ -z "$boundary" ] || [ "$boundary" -lt "$MIN_USABLE_BOUNDARY" ] 2>/dev/null; then
    if [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" = "1" ]; then
      profile="200k"
      boundary="$FALLBACK_200K"
    else
      profile="1m"
      boundary="$FALLBACK_1M"
    fi
    origin="fallback-${profile}"
  fi

  echo "${boundary} ${origin}"
}

# Resolved once per session and cached. The window will not move mid-session,
# and this hook runs on every single tool call.
if [ -r "$CONFIG_FILE" ]; then
  CONFIG="$(cat "$CONFIG_FILE" 2>/dev/null)"
else
  CONFIG="$(resolve_config)"
  printf '%s' "$CONFIG" >"$CONFIG_FILE" 2>/dev/null || true
fi

if [ "$CONFIG" = "disabled" ]; then
  {
    printf 'ts=%s count=%d skipped=auto-compaction-disabled\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S')" "$COUNT"
  } >"$DEBUG_FILE" 2>/dev/null || true
  exit 0
fi

BOUNDARY="${CONFIG%% *}"
ORIGIN="${CONFIG##* }"

# ----------------------------------------------------------------------------
# Token sources, tried in order: transcript → debug log → tool-count estimate
# ----------------------------------------------------------------------------

# Transcript JSONL: each assistant turn line carries `message.usage` with
# input_tokens + cache_read_input_tokens + cache_creation_input_tokens. Their
# sum approximates context occupancy for that turn. We pre-filter to candidate
# lines with grep to keep jq's workload bounded on long transcripts.
#
# Compact-aware: Claude Code writes a `"subtype":"compact_boundary"` line on
# auto- and manual-compact. Pre-boundary `usage` entries report the OLD
# (pre-compact) context size and would trigger spurious fires for the few
# seconds before the first post-compact assistant turn lands its own `usage`
# entry. We anchor on the most recent boundary, only consider `usage` entries
# after it, and fall back to its `compactMetadata.postTokens` if none exist yet.
tokens_from_transcript() {
  [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ] || return 1
  local window after_boundary boundary_line_no boundary_json post_tokens result
  window=$(tail -n 400 "$TRANSCRIPT_PATH" 2>/dev/null) || return 1
  [ -n "$window" ] || return 1

  boundary_line_no=$(printf '%s\n' "$window" |
    grep -n '"subtype":"compact_boundary"' | tail -1 | cut -d: -f1)
  if [ -n "$boundary_line_no" ]; then
    boundary_json=$(printf '%s\n' "$window" | sed -n "${boundary_line_no}p")
    post_tokens=$(printf '%s' "$boundary_json" |
      jq -r '.compactMetadata.postTokens // empty' 2>/dev/null)
    after_boundary=$(printf '%s\n' "$window" | awk -v n="$boundary_line_no" 'NR>n')
  else
    after_boundary="$window"
    post_tokens=""
  fi

  result=$(printf '%s\n' "$after_boundary" |
    grep '"usage"' |
    jq -r '
            select(.message.usage) | .message.usage |
            (.input_tokens // 0)
            + (.cache_read_input_tokens // 0)
            + (.cache_creation_input_tokens // 0)
            + (.output_tokens // 0)
        ' 2>/dev/null |
    tail -1)
  if [ -n "$result" ] && [ "$result" -gt 0 ] 2>/dev/null; then
    echo "$result"
    return 0
  fi

  # No post-boundary usage entry yet — trust the boundary's own postTokens.
  if [ -n "$post_tokens" ] && [ "$post_tokens" -gt 0 ] 2>/dev/null; then
    echo "$post_tokens"
    return 0
  fi
  return 1
}

# Debug log: only populated when the user ran `claude --debug`. Same parsing
# as the yurukusa reference — pick the most recent `autocompact: tokens=N`.
tokens_from_debug() {
  local debug_dir="$HOME/.claude/debug"
  [ -d "$debug_dir" ] || return 1
  local latest
  # shellcheck disable=SC2012
  latest="$(ls -t "$debug_dir"/*.txt 2>/dev/null | head -1)"
  [ -n "$latest" ] || return 1
  local line tokens
  line="$(grep 'autocompact:' "$latest" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  tokens="$(echo "$line" | sed 's/.*tokens=\([0-9]*\).*/\1/')"
  [ -n "$tokens" ] && [ "$tokens" -gt 0 ] 2>/dev/null && {
    echo "$tokens"
    return 0
  }
  return 1
}

# Tool-count fallback: crude linear estimate. Always succeeds.
tokens_from_count() {
  echo $((COUNT * FALLBACK_TOKENS_PER_CALL))
}

TOKENS=""
SOURCE=""
if TOKENS="$(tokens_from_transcript)"; then
  SOURCE="transcript"
elif TOKENS="$(tokens_from_debug)"; then
  SOURCE="debug"
else
  TOKENS="$(tokens_from_count)"
  SOURCE="estimate"
fi

# ----------------------------------------------------------------------------
# Which fire are we at, and has it already gone off?
# ----------------------------------------------------------------------------
# Fire index counts how many trigger points the session has passed:
#   0     below the first trigger
#   1-5   at that fire's trigger point
#   6     past the boundary itself, where we go quiet
#
# Index is recomputed from live tokens every call and persisted every call, so
# a compaction (which drops tokens) re-arms the whole schedule on the way back
# up. That is deliberate: after a compaction the model genuinely has room again.
EFFECTIVE=$((BOUNDARY * EFFECTIVE_PCT / 100))

FIRE=0
IDX=0
for OFFSET in $FIRE_OFFSETS; do
  IDX=$((IDX + 1))
  TRIGGER=$((EFFECTIVE - OFFSET))
  if [ "$TOKENS" -ge "$TRIGGER" ]; then
    FIRE="$IDX"
  fi
done
TOTAL_FIRES="$IDX"
if [ "$TOKENS" -ge "$EFFECTIVE" ]; then
  FIRE=$((TOTAL_FIRES + 1))
fi

INJECT=0
if [ "$FIRE" -gt "$LAST_FIRED" ] && [ "$FIRE" -ge 1 ] && [ "$FIRE" -le "$TOTAL_FIRES" ]; then
  INJECT=1
fi

echo "$FIRE" >"$FIRED_FILE"

# Debug breadcrumb (not injected into Claude's context — operator-only).
{
  printf 'ts=%s count=%d tokens=%d source=%s boundary=%d origin=%s fire=%d last_fired=%d inject=%d\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$COUNT" "$TOKENS" "$SOURCE" \
    "$BOUNDARY" "$ORIGIN" "$FIRE" "$LAST_FIRED" "$INJECT"
} >"$DEBUG_FILE" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Build and emit message
# ----------------------------------------------------------------------------
if [ "$INJECT" -eq 1 ]; then
  LEFT=$((EFFECTIVE - TOKENS))
  [ "$LEFT" -lt 0 ] && LEFT=0
  # Round to the nearest thousand and comma-group. The message says "~", and
  # an exact figure implies a precision the token estimate doesn't have.
  LEFT_ROUNDED=$(((LEFT + 500) / 1000 * 1000))
  LEFT_PRETTY="$(awk -v n="$LEFT_ROUNDED" 'BEGIN {
        s = sprintf("%d", n); out = ""
        while (length(s) > 3) {
            out = "," substr(s, length(s) - 2) out
            s = substr(s, 1, length(s) - 3)
        }
        print s out
    }')"

  # Fires 1 to n-1 suggest; the last one instructs.
  if [ "$FIRE" -ge "$TOTAL_FIRES" ]; then
    MSG="$INSTRUCT_MSG"
    LEVEL=4
  else
    MSG="$SUGGEST_MSG"
    LEVEL=3
  fi
  MSG="${MSG//%LEFT%/$LEFT_PRETTY}"

  # Append-only fire log, shared across every session. One line per injection.
  # `level` is kept alongside `fire` so the historical log stays comparable.
  printf 'ts=%s session=%s fire=%d level=%d tokens=%d left=%d boundary=%d origin=%s source=%s count=%d\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$SESSION_ID" "$FIRE" "$LEVEL" "$TOKENS" \
    "$LEFT" "$BOUNDARY" "$ORIGIN" "$SOURCE" "$COUNT" \
    >>"${DATA_ROOT}/fires.log" 2>/dev/null || true

  jq -n --arg ctx "$MSG" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $ctx
        }
    }'
fi

exit 0
