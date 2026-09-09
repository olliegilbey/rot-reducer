# rot-reducer

> A Claude Code plugin that asks Claude to leave a handoff behind before auto-compaction replaces its transcript with a summary, so long autonomous sessions carry their thread across the boundary instead of rediscovering it.

## The problem

Claude Code auto-compacts when a session reaches a configured token count. Compaction keeps the session alive but summarises older turns away, and the first casualty is usually the *why*: architectural choices, in-flight reasoning, what was already ruled out. If Claude is mid-task when it fires, it wakes up with half-finished work and a vague idea of where it left off.

The fix is not to stop before the boundary. A session that downs tools at 290k and waits for a human has the worst of both: no compaction, and no progress. The fix is to write down what carries forward, then keep going.

This plugin counts down to your actual compaction point and asks for that handoff. It never tells Claude to stop.

## Requirements

**Auto-compaction must be on.** If it is off, no boundary exists, every message this plugin could send would describe an event that will never happen, and the hook stays completely silent by design.

```text
/autocompact 300k
```

That sets the boundary and persists it to `~/.claude/settings.json`. Also confirm compaction itself is enabled:

```bash
jq '{autoCompactEnabled, autoCompactWindow}' ~/.claude/settings.json
```

`autoCompactEnabled` must not be `false`. `jq` is required for the hook itself (`brew install jq` on macOS).

## How it works

A `PostToolUse` hook reads the session transcript after every tool call, estimates current token usage, and injects an `additionalContext` message that Claude reads on its next turn. Fires are anchored to your compaction boundary rather than to fixed token counts, so they follow the boundary wherever you set it.

Claude Code compacts *before* the number you configure, because it needs room to
run the summary itself, and the exact point moves. Ten automatic compactions
observed against a 300k window landed between **267,419** and **271,573**, with
one late outlier at **284,061**. The hook takes the low end, so the effective
boundary `E` is 89% of your setting. A fire that lands after compaction is worth
nothing, so it errs early.

Three fires, at fixed distances below `E`:

| Fire | Trigger | Window 300k (`E` ≈ 267k) | Window 180k (`E` ≈ 160k) | What Claude is told |
|------|---------|--------------------------|--------------------------|---------------------|
| 1 | `E` − 42k | 225k | 118k | Suggestion: create or refresh a handoff, keep working |
| 2 | `E` − 32k | 235k | 128k | Same, with a smaller number |
| 3 | `E` − 22k | 245k | 138k | Instruction: write or update the handoff now |

Ten thousand tokens apart, deliberately bunched near the end. A note only helps
once there is something worth handing off, so spreading the first one earlier
buys nothing.

Offsets hang off `E` rather than the configured window so that they state real
runway. Measured from 300k, the last fire looks 55k clear of the boundary when
it is really 22k.

The offsets also carry a margin for the turn in flight. The hook reads usage
entries that are already written, so the turn being generated right now is
invisible to it and the count always trails reality a little. Across 2,219
measured steps above 150k tokens the trail is under 709 tokens half the time,
but one step in a hundred exceeds 11,981 and the largest seen was 33,716. The
22k on the last fire covers the one-in-a-hundred case. Covering the worst case
would cost more usable context than it is worth, and an oversized jump still
fires, just later than the message claims.

Each fires once, on first upward crossing. Past `E` the hook goes quiet, since compaction is imminent by definition and the message has landed three times. After a compaction the token count drops and the whole schedule re-arms, which is deliberate: the model genuinely has room again.

The first two suggest and the last one instructs. The escalation is in tone, not volume. Every message carries a live countdown, so each one tells Claude something the last did not, and every one of them ends in *keep working*.

Distances are fixed rather than proportional because what matters is how much room is left to write a handoff in, and that is an absolute amount of work, not a fraction of a window.

The two message strings live in one block at the top of `scripts/rot-reducer.sh` (`SUGGEST_MSG` and `INSTRUCT_MSG`) and are meant to be edited to taste. `%LEFT%` is substituted with the tokens remaining, rounded to the nearest thousand.

## Finding your boundary

The hook resolves `autoCompactWindow` in Claude Code's own settings precedence order, highest first:

1. `CLAUDE_CODE_AUTO_COMPACT_WINDOW` environment variable (plain integers only)
2. `<cwd>/.claude/settings.local.json`
3. `<cwd>/.claude/settings.json`
4. `~/.claude/settings.local.json`
5. `~/.claude/settings.json`

All documented value forms are accepted: `"500k"`, `"1M"`, `200000`, and a bare number between 100 and 1000 meaning thousands. The resolved figure is cached per session on first read, since the window will not move mid-session and this hook runs on every tool call.

**Blind spot:** a hook cannot see managed policy settings or the `--autocompact` command-line flag. A session started with that flag will be measured against the wrong number. This is unclosable from a hook and is accepted.

**Fallback:** if `autoCompactWindow` is set nowhere, Claude Code's effective default is model-specific and readable from no file or environment variable. The hook then guesses 300k, or 180k when `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` marks a 200k-class model. That guess is why setting the window explicitly is a requirement rather than a suggestion.

## Install

```text
/plugin marketplace add olliegilbey/rot-reducer
/plugin install rot-reducer@olliegilbey-plugins
```

Choose scope when prompted. **Project** installs it for the current repo only, **user** for every session everywhere.

## Updating to a new version

Run both, in this order, from inside Claude Code:

```text
/plugin marketplace update olliegilbey-plugins
/plugin update rot-reducer@olliegilbey-plugins
```

The first pulls the latest catalogue from GitHub; the second installs the new version. Then `/reload-plugins` (or restart Claude Code) to pick up the change in the running session.

To confirm which version is actually live:

```bash
jq '.plugins["rot-reducer@olliegilbey-plugins"][].version' \
  ~/.claude/plugins/installed_plugins.json
```

If that still shows the old number, the marketplace catalogue hasn't refreshed. Re-run the first command. An update installs into a new versioned directory; the old one stays on disk and is harmless.

## Configuration

All settings are environment variables read at hook invocation time. Override in your shell before launching `claude`:

```bash
# Distances below the boundary at which to fire, outermost first.
# The last one instructs; the rest suggest. Any count works.
export CC_CONTEXT_FIRE_OFFSETS="35000 25000 15000"

# Effective boundary as a percentage of the configured window. Claude Code
# compacts early and variably: 267,430 and 284,061 seen against 300k, so we
# take the low end. Both the fire points and the countdown use this.
export CC_CONTEXT_EFFECTIVE_PCT=89

# Guessed boundary, used only when autoCompactWindow is set nowhere.
export CC_CONTEXT_FALLBACK_1M=300000
export CC_CONTEXT_FALLBACK_200K=180000

# Tool-count fallback (used only when the transcript is unreadable)
export CC_CONTEXT_FALLBACK_TOKENS_PER_CALL=800

# Include subagents (default 0 = skip them). A subagent can't carry a
# handoff into the parent session, so nudging one is pointless and the
# main agent ends up parroting the warning back.
export CC_CONTEXT_INCLUDE_SUBAGENTS=0
```

## Token source

Tried in order:

1. **Transcript JSONL** (primary). Sums the most recent assistant turn's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens + output_tokens`. Output counts because the model's own reply becomes context on the very next turn; omitting it undercounted by 41,000 tokens on one observed session, enough to miss the boundary entirely. Compact-aware: anchors on `compact_boundary` events and only counts post-boundary `usage` entries, falling back to `compactMetadata.postTokens` if no fresh turn has landed yet. This prevents spurious fires in the few-second window right after a compaction.
2. **Debug log**. Parses `~/.claude/debug/*.txt` for `autocompact: tokens=N`. Only populated under `claude --debug`.
3. **Tool-call count estimate**. `count × FALLBACK_TOKENS_PER_CALL`. Always available, but a weak fit against a hard boundary: a crude estimate can fire early or not at all. Last resort only.

Per-invocation source, token count, resolved boundary, and fire index are written to `${CLAUDE_PLUGIN_DATA}/<session_id>/last_eval`. State files are namespaced by `session_id` so concurrent sessions don't collide.

## Fire log

Every injection appends one line to `${CLAUDE_PLUGIN_DATA}/fires.log`, shared across all sessions:

```text
ts=2026-09-07T17:51:42 session=abc123 fire=2 level=3 tokens=260400 left=39600 boundary=300000 origin=settings source=transcript count=61
```

`origin` records where the boundary came from (`settings`, `env`, or `fallback-1m`), which is the first thing to check when fires land in the wrong place. Lines beginning with `#` are operator notes and are ignored by the tallies below.

```bash
LOG="$HOME/.claude/plugins/data/rot-reducer-olliegilbey-plugins/fires.log"

# fires by position in the schedule, all time
grep -v '^#' "$LOG" | sed 's/.*fire=\([0-9]*\).*/fire \1/' | sort | uniq -c

# distinct sessions that fired at least once
grep -v '^#' "$LOG" | sed 's/.*session=\([^ ]*\).*/\1/' | sort -u | wc -l

# average fires per firing session
grep -v '^#' "$LOG" | sed 's/.*session=\([^ ]*\).*/\1/' | sort | uniq -c \
  | awk '{n++; t+=$1} END {printf "%.1f across %d sessions\n", t/n, n}'
```

The log grows by at most three lines per session. Delete it any time; it's diagnostic only and nothing reads it back.

## Verifying it works

- After any tool call: `cat ${CLAUDE_PLUGIN_DATA}/<session_id>/last_eval`. If the file exists, the hook is firing.
- `skipped=auto-compaction-disabled` in that file means exactly what it says. Turn compaction on; nothing else will happen until you do.
- Check `boundary=` and `origin=` in the same line to confirm the window resolved the way you expect.
- `source=estimate` means the transcript wasn't readable. Check permissions on `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
- In a long session you should see one fire per trigger point, three in total, then silence. After a compaction the schedule re-arms.
- `fires.log` is the durable record. `last_eval` only holds the most recent evaluation and is overwritten constantly.

## Tests

```bash
bash tests/hook-test.sh
```

Drives the hook with synthetic input across a temporary settings tree: the fire schedule, big jumps, re-arming after compaction, every window value format, settings precedence, the disabled case, and the subagent skip.

## Credits

Debug-log parsing and the tool-count fallback originate with [yurukusa/cc-safe-setup](https://github.com/yurukusa/cc-safe-setup)'s `context-monitor`. This plugin routes its output through the documented [`additionalContext`](https://code.claude.com/docs/en/hooks) hook mechanism so the model reads it, and anchors on the compaction boundary rather than on fixed thresholds.

## License

MIT, see [LICENSE](LICENSE).
