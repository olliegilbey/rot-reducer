# context-budget-monitor

> A Claude Code plugin that warns Claude itself when its context window is filling up, so long autonomous sessions wrap work cleanly before auto-compaction kicks in.

## The problem

Claude Code auto-compacts when its context window fills. Compaction summarises older turns, which keeps the session going but loses detail — architectural choices, in-flight reasoning, the *why* behind decisions. If Claude is mid-task when it triggers, it wakes up with half-finished work and a vague idea of where it left off.

This plugin nudges Claude *before* that happens. As context fills, it drops a short status note into Claude's next turn — *"you're at X% of the high-performance window, wrap to a clean checkpoint and consider `/compact`"* — so Claude can finish the current step, summarise state, and choose the right transition (`/compact` to continue, `/clear` to switch tasks).

## How it works

A `PostToolUse` hook reads the session transcript after every tool call, estimates current token usage, and — at four escalating levels — injects an `additionalContext` message that Claude reads on the next turn.

| Level | Trigger     | Re-inject       | What Claude is told to do |
|-------|-------------|-----------------|---------------------------|
| L1    | 125k tokens | once            | Heads-up only — keep going, don't break early |
| L2    | 135k tokens | every 10 calls  | Wrap to a clean checkpoint, recommend `/compact` |
| L3    | 145k tokens | every 6 calls   | Stop new work, fill an evacuation template, recommend `/compact` |
| L4    | 155k tokens | every 3 calls   | End the turn now |

Messages are phrased as a percentage of the high-performance window (L4 = 100% baseline). Raw token counts aren't useful to the model — it has no native sense of its own ceiling — so the percentage gives a calibrated signal.

At L3 and above, an **evacuation template** with `[TODO]` fields is appended to `MISSION.md` in the project root, telling Claude exactly what to checkpoint (current task, files modified, next action) before `/compact`. A 30-minute cooldown plus a "skip if existing unfilled template" check prevents spam.

Defaults target the standard 200k context window, where ~150k is the practical ceiling before quality degrades. The same configuration is sensible for 1M-context sessions — you stop wanting fresh nudges past ~150k regardless.

## Install

```text
/plugin marketplace add olliegilbey/context-budget-monitor
/plugin install context-budget-monitor@olliegilbey-plugins
```

Pick **user** scope when prompted so every Claude session gets it. `jq` must be installed (`brew install jq` on macOS).

Update with `/plugin marketplace update olliegilbey-plugins` then `/reload-plugins`.

## Configuration

All settings are environment variables read at hook invocation time. Override in your shell before launching `claude`:

```bash
# Thresholds (token counts)
export CC_CONTEXT_L1_TOKENS=125000
export CC_CONTEXT_L2_TOKENS=135000
export CC_CONTEXT_L3_TOKENS=145000
export CC_CONTEXT_L4_TOKENS=155000

# Re-injection cadence (tool calls between nudges; 0 = transition only)
export CC_CONTEXT_L1_CADENCE=0
export CC_CONTEXT_L2_CADENCE=10
export CC_CONTEXT_L3_CADENCE=6
export CC_CONTEXT_L4_CADENCE=3

# Mission file path (where the evacuation template is appended)
export CC_CONTEXT_MISSION_FILE="$PWD/MISSION.md"

# Evacuation template cooldown (seconds)
export CC_CONTEXT_EVAC_COOLDOWN_SEC=1800

# Tool-count fallback (used only when the transcript is unreadable)
export CC_CONTEXT_FALLBACK_TOKENS_PER_CALL=800

# Include subagents in budget monitoring (default 0 = skip them).
# Subagents can't run /compact or /clear, so nudging them is usually
# pointless and the main agent ends up parroting their warning back.
export CC_CONTEXT_INCLUDE_SUBAGENTS=0
```

## Token source

Tried in order:

1. **Transcript JSONL** (primary). Sums the most recent assistant turn's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. Compact-aware: anchors on `compact_boundary` events and only counts post-boundary `usage` entries, falling back to `compactMetadata.postTokens` if no fresh turn has landed yet. This prevents spurious nudges in the few-second window right after auto-compact.
2. **Debug log**. Parses `~/.claude/debug/*.txt` for `autocompact: tokens=N`. Only populated under `claude --debug`.
3. **Tool-call count estimate**. `count × FALLBACK_TOKENS_PER_CALL`. Crude but always available.

Per-invocation source, token count, and current level are written to `${CLAUDE_PLUGIN_DATA}/<session_id>/last_eval`. State files are namespaced by `session_id` so concurrent sessions don't collide.

## Verifying it works

- After any tool call: `cat $HOME/.claude/plugins/data/context-budget-monitor/<session_id>/last_eval`. If the file exists, the hook is firing.
- `source=estimate` means the transcript wasn't readable — check permissions on `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
- In a long session, you should see L1 fire once around ~125k, then L2/L3/L4 escalate as work continues. After `/compact`, the level resets.

## Credits

Threshold structure, debug-log parsing, tool-count fallback, and evacuation template mechanism originate with [yurukusa/cc-safe-setup](https://github.com/yurukusa/cc-safe-setup)'s `context-monitor`. This plugin routes the warnings through the documented [`additionalContext`](https://code.claude.com/docs/en/hooks) hook output so the model reads them.

## License

MIT — see [LICENSE](LICENSE).
