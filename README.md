# context-budget-monitor

A Claude Code plugin that injects graduated context-budget warnings **into
Claude's own context** during long autonomous sessions, so the model wraps
up cleanly before auto-compaction degrades the session.

It runs as a `PostToolUse` hook, reads the session transcript to estimate
how many tokens have been consumed, and emits an
`hookSpecificOutput.additionalContext` message when configured thresholds
are crossed. The model sees these messages next to the tool result and
can act on them.

## Why this, and not just a stderr warning

Inspired by [yurukusa/cc-safe-setup][yurukusa]'s `context-monitor` hook,
which writes graduated warnings to stderr. That works for the human
watching the terminal but the model never sees them — by the time you
notice the warning, auto-compact may already be inevitable. This plugin
uses the documented [`additionalContext`][addctx] hook output so the
model itself reads the warning mid-turn and can wrap the current
sub-task at a clean checkpoint, propose `/compact` with steering
instructions, or stop and report status.

The threshold logic, debug-log parsing, tool-count fallback estimation,
and evacuation template mechanism all originate with yurukusa's design.
This plugin keeps that design and swaps the output channel.

[yurukusa]: https://github.com/yurukusa/cc-safe-setup
[addctx]: https://code.claude.com/docs/en/hooks

## What it does

| Level | Default trigger | Re-inject cadence | Action requested of the model |
|-------|-----------------|-------------------|-------------------------------|
| L1 caution    | 125k tokens | every 7 tool calls | Begin steering toward a clean checkpoint |
| L2 wrap       | 135k tokens | every 5 tool calls | Finish current sub-task, recommend `/compact` with steering |
| L3 hard stop  | 145k tokens | every 3 tool calls | Stop new work, fill evacuation template, recommend `/compact` |
| L4 overdrive  | 155k tokens | every 2 tool calls | Past hard-stop boundary — end turn immediately |

Each level fires once on the upward transition, then re-injects at the
listed cadence until the next level is crossed (or until context drops
back below the threshold, e.g. after `/compact`).

At L3+, an **evacuation template** with `[TODO]` placeholders is
appended to `MISSION.md` in the project root. A 30-minute cooldown plus
a "skip if existing unfilled template" check prevents spam. The
injected message tells the model where the template lives so it can
fill it before `/compact`.

The default thresholds target the 200k-class context window where ~150k
is the practical ceiling before auto-compact bites. They are absolute
token counts, not percentages, so the same configuration is sensible on
1M-context sessions — you stop wanting fresh nudges past ~150k either
way.

## Token source

The script tries three sources in order:

1. **Transcript JSONL** (primary): reads `transcript_path` from the
   hook input, finds the most recent assistant turn's `message.usage`,
   sums `input_tokens + cache_read_input_tokens +
   cache_creation_input_tokens`. Compact-aware — when a
   `compact_boundary` event is present in the tail window, only
   `usage` entries after it are considered. If no post-boundary
   `usage` entry exists yet (the few-second gap right after auto-
   compact), falls back to `compactMetadata.postTokens`. Without
   this, the model would receive a spurious "compact now" nudge
   immediately after an auto-compact already happened.
2. **Debug log** (yurukusa's path, kept for completeness): parses
   `~/.claude/debug/*.txt` for `autocompact: tokens=N`. Only populated
   under `claude --debug`.
3. **Tool-call count estimate** (fallback): `count *
   FALLBACK_TOKENS_PER_CALL` (default 800). Crude but always available.

Each invocation records which source was used in
`${CLAUDE_PLUGIN_DATA}/<session_id>/last_eval` for transparency.

## Configuration

All settings are environment variables read at hook invocation time.
Override in your shell before launching `claude`:

```bash
# Thresholds (token counts)
export CC_CONTEXT_L1_TOKENS=125000
export CC_CONTEXT_L2_TOKENS=135000
export CC_CONTEXT_L3_TOKENS=145000
export CC_CONTEXT_L4_TOKENS=155000

# Re-injection cadence (tool calls between nudges at each level)
export CC_CONTEXT_L1_CADENCE=7
export CC_CONTEXT_L2_CADENCE=5
export CC_CONTEXT_L3_CADENCE=3
export CC_CONTEXT_L4_CADENCE=2

# Mission file path (where the evacuation template is appended)
export CC_CONTEXT_MISSION_FILE="$PWD/MISSION.md"

# Evacuation template cooldown (seconds)
export CC_CONTEXT_EVAC_COOLDOWN_SEC=1800

# Tool-count fallback estimate (only used when transcript and debug log are unavailable)
export CC_CONTEXT_FALLBACK_TOKENS_PER_CALL=800
```

State files live under `${CLAUDE_PLUGIN_DATA}/<session_id>/`, namespaced
by hook-input `session_id` so concurrent sessions don't trample each
other and counters reset cleanly on a new session.

## Installation

`jq` must be installed (`brew install jq` on macOS).

### One-shot test (session-scoped)

```bash
claude --plugin-dir /path/to/context-budget-monitor
```

Only active for the launched session; the hook is unregistered when you
exit.

### Persistent install from a local clone

This repo ships its own `.claude-plugin/marketplace.json` so the plugin
directory doubles as a single-plugin marketplace. From inside any Claude
Code session:

```text
/plugin marketplace add /path/to/context-budget-monitor
/plugin install context-budget-monitor@olliegilbey-plugins
/reload-plugins
```

The marketplace registration and the installed plugin both persist
across sessions. Update with `/plugin marketplace update
olliegilbey-plugins` after pulling new commits; uninstall with `/plugin
uninstall context-budget-monitor@olliegilbey-plugins`.

### Persistent install from GitHub (after publishing)

Once pushed to a public repo:

```text
/plugin marketplace add <owner>/<repo>
/plugin install context-budget-monitor@olliegilbey-plugins
```

## What to watch for in a real session

- After ~100k tokens the model should start preferring subagents for
  reads/searches.
- After ~130k it should propose `/compact` at the next natural break,
  with steering instructions that name the architectural decisions
  worth preserving.
- After ~150k a `MISSION.md` should appear (or get an appended block);
  the model should stop new work and summarise state.
- Run `cat ${CLAUDE_PLUGIN_DATA}/<session_id>/last_eval` in another
  shell to confirm the source (transcript / debug / estimate), current
  token count, and current level.
- If `last_eval` shows `source=estimate`, the transcript path is
  unreadable for some reason — check permissions on
  `~/.config/claude/projects/.../*.jsonl`.

## File layout

```
context-budget-monitor/
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   └── hooks.json
├── scripts/
│   └── context-monitor.sh
├── docs/superpowers/plans/context-budget-monitor.md
├── LICENSE
└── README.md
```

## Credits

The threshold structure, debug-log parsing approach, tool-count
fallback heuristic, and evacuation template mechanism are all carried
over from [yurukusa/cc-safe-setup][yurukusa]'s `context-monitor`. The
contribution here is routing the warnings through the documented
`additionalContext` hook output so the model itself reads them.

## License

MIT — see [LICENSE](LICENSE).
