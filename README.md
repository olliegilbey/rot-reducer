# rot-reducer

> A Claude Code plugin that warns Claude itself when its context window is filling up, so long autonomous sessions wrap work cleanly before auto-compaction kicks in.

## The problem

Claude Code auto-compacts when its context window fills. Compaction summarises older turns, which keeps the session going but loses detail — architectural choices, in-flight reasoning, the *why* behind decisions. If Claude is mid-task when it triggers, it wakes up with half-finished work and a vague idea of where it left off.

This plugin nudges Claude *before* that happens. As context fills, it drops a short status note into Claude's next turn — *"you're at X% of the high-performance window, wrap to a clean checkpoint and consider `/compact`"* — so Claude can finish the current step, summarise state, and choose the right transition (`/compact` to continue, `/clear` to switch tasks).

## How it works

A `PostToolUse` hook reads the session transcript after every tool call, estimates current token usage, and — at four escalating levels — injects an `additionalContext` message that Claude reads on the next turn.

| Level | `200k` trigger | `1m` trigger | Re-inject       | What Claude is told to do |
|-------|----------------|--------------|-----------------|---------------------------|
| L1    | 125k tokens    | 160k tokens  | once            | Heads-up only — keep going, look ahead to a natural pause |
| L2    | 135k tokens    | 190k tokens  | every 10 calls  | Don't start new tasks or tangents |
| L3    | 145k tokens    | 220k tokens  | every 6 calls   | Stop soon, suggest a fresh context window to the human |
| L4    | 155k tokens    | 250k tokens  | every 3 calls   | Into reserves — continue only if it wraps in a few turns |

"Re-inject" counts tool calls between repeats. `once` means the message fires on the *transition* into that level and never again while you stay there; it re-arms if usage drops below and later climbs back.

The message text lives in one block at the top of `scripts/rot-reducer.sh` (`L1_MSG` … `L4_MSG`) and is meant to be edited to taste. The deliberate choice in the shipped wording is **not** to name a specific command — people use different exit strategies, and the model picks one that fits.

Messages are phrased as a percentage of the high-performance window (L4 = 100% baseline). Raw token counts aren't useful to the model — it has no native sense of its own ceiling — so the percentage gives a calibrated signal.

## Profiles: 200k vs 1M context

The profiles track **model capability, not window size as such** — the window is just a proxy for model generation. 200k-class models tend to be older and weaker at long-context retrieval, so they start to rot and lose multi-step discipline well before their nominal ceiling (~150k usable). The newer models that ship the 1M window are simply better at holding long context, so they stay coherent much further out, and the `1m` profile reflects that with a higher 160–250k band. A bigger window doesn't magically help — it's that the models behind it handle long context better.

`CC_CONTEXT_PROFILE` selects the set:

- `auto` (default) — uses the `1m` profile unless `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` is set, which is how Claude Code signals the extended window is off. The window size itself is exposed to neither hooks nor the transcript, so this env var is the only signal available.
- `200k` / `1m` — force a profile explicitly. Recommended if `auto` guesses wrong — e.g. an account on a 200k-only model with no disable flag set would otherwise be read as `1m`.

Per-level `CC_CONTEXT_L*_TOKENS` env vars override individual thresholds regardless of profile.

## Install

```text
/plugin marketplace add olliegilbey/rot-reducer
/plugin install rot-reducer@olliegilbey-plugins
```

`jq` must be installed (`brew install jq` on macOS).

Choose scope when prompted — **project** installs it for the current repo only, **user** for every session everywhere.

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

If that still shows the old number, the marketplace catalogue hasn't refreshed — re-run the first command. Note that an update installs into a new versioned directory; the old one stays on disk and is harmless.

## Configuration

All settings are environment variables read at hook invocation time. Override in your shell before launching `claude`:

```bash
# Profile: auto (default) | 200k | 1m. auto picks 1m unless
# CLAUDE_CODE_DISABLE_1M_CONTEXT=1. See "Profiles" above.
export CC_CONTEXT_PROFILE=auto

# Per-level threshold overrides (token counts). If set, these win over
# the profile default for that level. Shown here at the 200k defaults;
# the 1m profile defaults to 160000/190000/220000/250000.
export CC_CONTEXT_L1_TOKENS=125000
export CC_CONTEXT_L2_TOKENS=135000
export CC_CONTEXT_L3_TOKENS=145000
export CC_CONTEXT_L4_TOKENS=155000

# Re-injection cadence (tool calls between nudges; 0 = transition only)
export CC_CONTEXT_L1_CADENCE=0
export CC_CONTEXT_L2_CADENCE=10
export CC_CONTEXT_L3_CADENCE=6
export CC_CONTEXT_L4_CADENCE=3

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

## Fire log

Every injection appends one line to `${CLAUDE_PLUGIN_DATA}/fires.log`, shared across all sessions:

```text
ts=2026-08-06T17:51:42 session=abc123 level=2 tokens=195400 pct=78 source=transcript profile=1m count=61
```

It records the **level number**, not the message text, so counts stay comparable after you rewrite the wording. Lines beginning with `#` are operator notes and are ignored by the tally below.

```bash
# fires by level, all time
grep -v '^#' "$HOME/.claude/plugins/data/rot-reducer-olliegilbey-plugins/fires.log" \
  | sed 's/.*level=\([0-9]*\).*/L\1/' | sort | uniq -c

# distinct sessions that fired at least once
grep -v '^#' "$HOME/.claude/plugins/data/rot-reducer-olliegilbey-plugins/fires.log" \
  | sed 's/.*session=\([^ ]*\).*/\1/' | sort -u | wc -l
```

The log grows by one line per nudge — a few dozen lines a month in normal use. Delete it any time; it's diagnostic only and nothing reads it back.

## Verifying it works

- After any tool call: `cat ${CLAUDE_PLUGIN_DATA}/<session_id>/last_eval`. If the file exists, the hook is firing. The breadcrumb records `profile=` so you can confirm `auto` resolved the way you expect.
- `source=estimate` means the transcript wasn't readable — check permissions on `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
- In a long session you should see L1 fire once (at ~125k on the `200k` profile, ~160k on `1m`), then L2/L3/L4 escalate as work continues. After a compaction, the level resets.
- `fires.log` (see below) is the durable record — `last_eval` only holds the most recent evaluation and is overwritten constantly.

## Credits

Threshold structure, debug-log parsing, and tool-count fallback originate with [yurukusa/cc-safe-setup](https://github.com/yurukusa/cc-safe-setup)'s `context-monitor`. This plugin routes the warnings through the documented [`additionalContext`](https://code.claude.com/docs/en/hooks) hook output so the model reads them.

## License

MIT — see [LICENSE](LICENSE).
