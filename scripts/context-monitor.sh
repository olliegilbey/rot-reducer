#!/usr/bin/env bash
# context-monitor.sh
#
# PostToolUse hook for the context-budget-monitor plugin.
#
# Reads the hook input JSON on stdin, estimates how many tokens the current
# session has consumed, and emits a `hookSpecificOutput.additionalContext`
# message on stdout when a configured threshold is crossed (or re-fires at
# a graduated cadence so the nudge keeps appearing as the budget tightens).
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
# Token thresholds (absolute, model-agnostic). Designed for the 200k-class
# windows where ~150k is the practical ceiling before auto-compact bites.
L1_TOKENS="${CC_CONTEXT_L1_TOKENS:-125000}"   # caution
L2_TOKENS="${CC_CONTEXT_L2_TOKENS:-135000}"   # wrap to checkpoint
L3_TOKENS="${CC_CONTEXT_L3_TOKENS:-145000}"   # hard stop
L4_TOKENS="${CC_CONTEXT_L4_TOKENS:-155000}"   # overdrive (L3 ignored)

# Re-injection cadence — tool calls between re-nudges at each level.
# 0 disables periodic re-injection at that level (transition only).
L1_CADENCE="${CC_CONTEXT_L1_CADENCE:-0}"
L2_CADENCE="${CC_CONTEXT_L2_CADENCE:-10}"
L3_CADENCE="${CC_CONTEXT_L3_CADENCE:-6}"
L4_CADENCE="${CC_CONTEXT_L4_CADENCE:-3}"

# Tool-count fallback: assumed tokens per tool call when transcript and
# debug log are both unavailable. Crude but always available.
FALLBACK_TOKENS_PER_CALL="${CC_CONTEXT_FALLBACK_TOKENS_PER_CALL:-800}"

# Evacuation template (mission file) settings.
MISSION_FILE="${CC_CONTEXT_MISSION_FILE:-${CLAUDE_PROJECT_DIR:-$PWD}/MISSION.md}"
EVAC_COOLDOWN_SEC="${CC_CONTEXT_EVAC_COOLDOWN_SEC:-1800}"

# Per-plugin persistent state dir. Provided by Claude Code as
# ~/.claude/plugins/data/<id>/. We namespace by session_id below.
DATA_ROOT="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/context-budget-monitor}"

# ----------------------------------------------------------------------------
# Read and parse hook input from stdin
# ----------------------------------------------------------------------------
# jq is required — without it we can't parse hook input or build clean JSON
# output. Fail silently (exit 0, no stdout) so we don't break the session.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"

# Skip subagent tool calls. Subagents have their own (smaller) transcript and
# cannot run /compact or /clear, so any nudge we inject would be misleading.
# Their transcripts live in a /subagents/ subdir of the project session dir.
case "$TRANSCRIPT_PATH" in
    */subagents/*) exit 0 ;;
esac

# Without a session_id we can't safely namespace state. Bucket under "unknown".
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

STATE_DIR="${DATA_ROOT}/${SESSION_ID}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

COUNT_FILE="${STATE_DIR}/count"
LEVEL_FILE="${STATE_DIR}/level"
INJECT_FILE="${STATE_DIR}/last_inject_at"
EVAC_FILE="${STATE_DIR}/evac_cooldown"
DEBUG_FILE="${STATE_DIR}/last_eval"

# Increment tool-call counter (used for both cadence and fallback estimation).
COUNT="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
COUNT=$((COUNT + 1))
echo "$COUNT" >"$COUNT_FILE"

LAST_LEVEL="$(cat "$LEVEL_FILE" 2>/dev/null || echo 0)"
LAST_INJECT_AT="$(cat "$INJECT_FILE" 2>/dev/null || echo 0)"

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
# (pre-compact) context size and would trigger spurious L2/L3 fires for the
# few seconds before the first post-compact assistant turn lands its own
# `usage` entry. We anchor on the most recent boundary, only consider `usage`
# entries after it, and fall back to its `compactMetadata.postTokens` if none
# exist yet.
tokens_from_transcript() {
    [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ] || return 1
    local window after_boundary boundary_line_no boundary_json post_tokens result
    window=$(tail -n 400 "$TRANSCRIPT_PATH" 2>/dev/null) || return 1
    [ -n "$window" ] || return 1

    boundary_line_no=$(printf '%s\n' "$window" \
        | grep -n '"subtype":"compact_boundary"' | tail -1 | cut -d: -f1)
    if [ -n "$boundary_line_no" ]; then
        boundary_json=$(printf '%s\n' "$window" | sed -n "${boundary_line_no}p")
        post_tokens=$(printf '%s' "$boundary_json" \
            | jq -r '.compactMetadata.postTokens // empty' 2>/dev/null)
        after_boundary=$(printf '%s\n' "$window" | awk -v n="$boundary_line_no" 'NR>n')
    else
        after_boundary="$window"
        post_tokens=""
    fi

    result=$(printf '%s\n' "$after_boundary" \
        | grep '"usage"' \
        | jq -r '
            select(.message.usage) | .message.usage |
            (.input_tokens // 0)
            + (.cache_read_input_tokens // 0)
            + (.cache_creation_input_tokens // 0)
        ' 2>/dev/null \
        | tail -1)
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
    [ -n "$tokens" ] && [ "$tokens" -gt 0 ] 2>/dev/null && { echo "$tokens"; return 0; }
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
# Determine level and decide whether to inject
# ----------------------------------------------------------------------------
LEVEL=0
if   [ "$TOKENS" -ge "$L4_TOKENS" ]; then LEVEL=4
elif [ "$TOKENS" -ge "$L3_TOKENS" ]; then LEVEL=3
elif [ "$TOKENS" -ge "$L2_TOKENS" ]; then LEVEL=2
elif [ "$TOKENS" -ge "$L1_TOKENS" ]; then LEVEL=1
fi

case "$LEVEL" in
    1) CADENCE="$L1_CADENCE" ;;
    2) CADENCE="$L2_CADENCE" ;;
    3) CADENCE="$L3_CADENCE" ;;
    4) CADENCE="$L4_CADENCE" ;;
    *) CADENCE=0 ;;
esac

INJECT=0
if [ "$LEVEL" -gt "$LAST_LEVEL" ]; then
    # Transitioning up into a new level — always inject.
    INJECT=1
elif [ "$LEVEL" -ge 1 ] && [ "$CADENCE" -gt 0 ]; then
    SINCE=$((COUNT - LAST_INJECT_AT))
    if [ "$SINCE" -ge "$CADENCE" ]; then
        INJECT=1
    fi
fi

# Persist level regardless. This way a transition down (e.g. after /compact)
# is recorded without firing, and the next upward crossing fires fresh.
echo "$LEVEL" >"$LEVEL_FILE"

# Debug breadcrumb (not injected into Claude's context — operator-only).
{
    printf 'ts=%s count=%d tokens=%d source=%s level=%d last_level=%d inject=%d\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$COUNT" "$TOKENS" "$SOURCE" "$LEVEL" "$LAST_LEVEL" "$INJECT"
} >"$DEBUG_FILE" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Evacuation template — only at L3+, with cooldown
# ----------------------------------------------------------------------------
maybe_write_evac() {
    local lvl="$1"
    local now last
    now="$(date +%s)"
    last="$(cat "$EVAC_FILE" 2>/dev/null || echo 0)"
    if [ "$((now - last))" -lt "$EVAC_COOLDOWN_SEC" ]; then
        return 1
    fi
    # If there's already an unfilled template in the mission file, don't add
    # another — the user (or model) is supposed to fill the existing one.
    if [ -f "$MISSION_FILE" ] && grep -q '\[TODO\]' "$MISSION_FILE" 2>/dev/null; then
        return 1
    fi
    mkdir -p "$(dirname "$MISSION_FILE")" 2>/dev/null || return 1
    local ts
    ts="$(date '+%Y-%m-%d %H:%M')"
    cat >>"$MISSION_FILE" <<EVAC_EOF

## Context Evacuation Template (L${lvl} - ${ts})
<!-- Auto-generated by context-budget-monitor. Fill before /compact. -->
### Current Task
- Task: [TODO]
- Progress: [TODO]
- Files being edited: [TODO]

### Git State
- Branch: [TODO]
- Uncommitted changes: [TODO]

### Next Action
- Next command/action: [TODO]
EVAC_EOF
    echo "$now" >"$EVAC_FILE"
    return 0
}

# ----------------------------------------------------------------------------
# Build and emit message
# ----------------------------------------------------------------------------
if [ "$INJECT" -eq 1 ]; then
    # Express usage as % of the high-performance context window, with L4 as
    # the 100% baseline (the point at which the model is expected to be
    # past comfortable operation). Raw token counts are not informative to
    # the model — it doesn't know its own ceiling — but a normalized % is.
    PCT=$((TOKENS * 100 / L4_TOKENS))
    MSG=""
    case "$LEVEL" in
        1)
            MSG="Context at ~${PCT}% of high-performance window — heads-up only. Finish the current sub-task without changing course; at its natural endpoint consider \`/compact\` (continue) or \`/clear\` (switch). Do not break early."
            ;;
        2)
            MSG="Context at ~${PCT}% of high-performance window. Wrap to a clean checkpoint and recommend \`/compact\` (continue this work) or \`/clear\` (switch tasks) with a brief summary of what to preserve: architectural decisions, files modified, next task. Do not start new sub-tasks."
            ;;
        3)
            if maybe_write_evac "$LEVEL"; then
                MSG="Context at ~${PCT}% of high-performance window. Stop. Fill the [TODO] fields of the evacuation template at ${MISSION_FILE}, report status, and recommend \`/compact\` or \`/clear\`. Do not start new work."
            else
                MSG="Context at ~${PCT}% of high-performance window. Stop. Report status (what is complete, what is next, where work is checkpointed) and recommend \`/compact\` or \`/clear\`. Do not start new work."
            fi
            ;;
        4)
            if maybe_write_evac "$LEVEL"; then
                MSG="Context at ~${PCT}% — past high-performance window. End this turn now: fill the [TODO] fields of the evacuation template at ${MISSION_FILE}, give a status report, and recommend \`/compact\` or \`/clear\`. No further tool calls."
            else
                MSG="Context at ~${PCT}% — past high-performance window. End this turn now: status report and recommend \`/compact\` or \`/clear\`. No further tool calls."
            fi
            ;;
    esac

    if [ -n "$MSG" ]; then
        echo "$COUNT" >"$INJECT_FILE"
        jq -n --arg ctx "$MSG" '{
            hookSpecificOutput: {
                hookEventName: "PostToolUse",
                additionalContext: $ctx
            }
        }'
    fi
fi

exit 0
