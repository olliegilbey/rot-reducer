#!/usr/bin/env bash
# Test harness for rot-reducer.sh. Drives the hook with synthetic input.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/rot-reducer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_PLUGIN_DATA="$TMP/data"
PROJ="$TMP/proj"
mkdir -p "$PROJ/.claude" "$TMP/data"

PASS=0
FAIL=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

# Build a transcript whose last usage line reports N tokens.
mk_transcript() { # path tokens
  printf '{"message":{"usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$2" >"$1"
}

# Fire the hook once. Echoes the injected message text, or empty.
fire() { # session tokens
  local sess="$1" tok="$2" tpath="$TMP/${1}.jsonl"
  mk_transcript "$tpath" "$tok"
  jq -n --arg s "$sess" --arg t "$tpath" --arg c "$PROJ" \
    '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"PostToolUse"}' |
    bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

echo "== compaction disabled: total silence =="
cat >"$PROJ/.claude/settings.json" <<'JSON'
{ "autoCompactEnabled": false, "autoCompactWindow": "300k" }
JSON
check "silent at 290k when disabled" "" "$(fire s-off 290000)"
check "debug says why" "skipped=auto-compaction-disabled" \
  "$(grep -o 'skipped=auto-compaction-disabled' "$TMP/data/s-off/last_eval")"

echo
echo "== boundary 300k: the five-fire schedule =="
cat >"$PROJ/.claude/settings.json" <<'JSON'
{ "autoCompactEnabled": true, "autoCompactWindow": "300k" }
JSON
check "silent at 240k (below first trigger)" "" "$(fire s1 240000)"
check "fire 1 at 250k" \
  "NOTE: ~50,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(fire s1 250000)"
check "no repeat at 255k (same band)" "" "$(fire s1 255000)"
check "no repeat at 259k (same band)" "" "$(fire s1 259000)"
check "fire 2 at 260k" \
  "NOTE: ~40,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(fire s1 260000)"
check "fire 3 at 271k rounds to 29,000" \
  "NOTE: ~29,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(fire s1 271000)"
check "fire 4 at 280k" \
  "NOTE: ~20,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(fire s1 280000)"
check "fire 5 at 290k instructs" \
  "WARNING: ~10,000 tokens until auto-compaction. Write or update your handoff now. Keep working through the boundary. Stopping short strands the session." \
  "$(fire s1 290000)"
check "silent at 299k (already fired 5)" "" "$(fire s1 299000)"
check "silent at 300k (past boundary)" "" "$(fire s1 300000)"
check "silent at 380k (well past)" "" "$(fire s1 380000)"
check "exactly 5 fires logged" "5" "$(grep -c 'session=s1 ' "$TMP/data/fires.log")"

echo
echo "== a big jump skips intermediate fires, does not stack =="
check "jumps straight to fire 4" \
  "NOTE: ~20,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(fire s2 280000)"
check "only one fire logged for the jump" "1" "$(grep -c 'session=s2 ' "$TMP/data/fires.log")"

echo
echo "== compaction re-arms the schedule =="
check "fire 5 before compaction" \
  "WARNING: ~10,000 tokens until auto-compaction. Write or update your handoff now. Keep working through the boundary. Stopping short strands the session." \
  "$(fire s3 290000)"
check "silent past boundary" "" "$(fire s3 305000)"
check "silent right after compaction drop" "" "$(fire s3 40000)"
check "fires again on the way back up" \
  "NOTE: ~50,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(fire s3 250000)"

echo
echo "== window value parsing =="
try_boundary() { # session json
  echo "$2" >"$PROJ/.claude/settings.json"
  fire "$1" 10000 >/dev/null
  grep -o 'boundary=[0-9]*' "$TMP/data/$1/last_eval" | cut -d= -f2
}
check '"500k"'    "500000"  "$(try_boundary p1 '{"autoCompactEnabled":true,"autoCompactWindow":"500k"}')"
check '"1M"'      "1000000" "$(try_boundary p2 '{"autoCompactEnabled":true,"autoCompactWindow":"1M"}')"
check '200000'    "200000"  "$(try_boundary p3 '{"autoCompactEnabled":true,"autoCompactWindow":200000}')"
check 'bare 200'  "200000"  "$(try_boundary p4 '{"autoCompactEnabled":true,"autoCompactWindow":200}')"
check 'garbage falls back' "300000" "$(try_boundary p5 '{"autoCompactEnabled":true,"autoCompactWindow":"banana"}')"
check 'too small falls back' "300000" "$(try_boundary p6 '{"autoCompactEnabled":true,"autoCompactWindow":"50k"}')"

echo
echo "== precedence and fallbacks =="
echo '{"autoCompactEnabled":true,"autoCompactWindow":"400k"}' >"$PROJ/.claude/settings.json"
echo '{"autoCompactWindow":"600k"}' >"$PROJ/.claude/settings.local.json"
check "settings.local.json beats settings.json" "600000" \
  "$(fire p7 10000 >/dev/null; grep -o 'boundary=[0-9]*' "$TMP/data/p7/last_eval" | cut -d= -f2)"
check "env var beats both" "700000" \
  "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=700000 fire p8 10000 >/dev/null; grep -o 'boundary=[0-9]*' "$TMP/data/p8/last_eval" | cut -d= -f2)"
rm "$PROJ/.claude/settings.local.json"

echo '{"autoCompactEnabled":true}' >"$PROJ/.claude/settings.json"
check "unset window, 1m default" "300000" \
  "$(fire p9 10000 >/dev/null; grep -o 'boundary=[0-9]*' "$TMP/data/p9/last_eval" | cut -d= -f2)"
check "unset window, 200k model default" "180000" \
  "$(CLAUDE_CODE_DISABLE_1M_CONTEXT=1 fire p10 10000 >/dev/null; grep -o 'boundary=[0-9]*' "$TMP/data/p10/last_eval" | cut -d= -f2)"
check "200k model fires at 130k" \
  "NOTE: ~50,000 tokens until auto-compaction. Consider creating or refreshing a handoff with task state, decisions, and next steps. Keep working." \
  "$(CLAUDE_CODE_DISABLE_1M_CONTEXT=1 fire p11 130000)"

echo
echo "== subagents are skipped =="
echo '{"autoCompactEnabled":true,"autoCompactWindow":"300k"}' >"$PROJ/.claude/settings.json"
mk_transcript "$TMP/sub.jsonl" 290000
check "agent_id present means no output" "" \
  "$(jq -n --arg t "$TMP/sub.jsonl" --arg c "$PROJ" \
    '{session_id:"sub1", agent_id:"a1", transcript_path:$t, cwd:$c}' |
    bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
