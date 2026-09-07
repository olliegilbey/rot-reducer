# Plan: rot-reducer: compaction pre-flight mode

Full replacement of the four-level warning mode. The hook's job is no longer
to tell a human how deep their session is; it is to get a handoff written to
disk before auto-compaction replaces the transcript with a summary.

## Why the old mode is being retired

Measured from the durable fire log, 7 Aug – 4 Sep, under the 160/190/220/250k
thresholds:

- 561 injections across 114 of 220 monitored sessions, 4.9 per firing session.
- L4 was unbounded: 116 fires across 24 sessions. One session fired 23 times,
  climbing 254k → 370k.
- 28% of re-fires happened with under 5k tokens of movement since the previous
  one. One session fired the same message three times at an identical 193,368.
- Root cause: `autoCompactEnabled` is `false`, so nothing in the system could
  bound a session. The hook was the only backstop, and volume was the only
  escalation it had.

Two design errors underneath that. Cadence counted tool calls, which have no
relationship to context growth. And every message said *stop*, which put the
hook in opposition to the work, so the only outcomes were quitting early or
learning to ignore it. The token count it reported was already visible in the
UI, so it told the human nothing new either.

Simulating the new schedule against the same log: **561 fires → 106**, sessions
touched 114 → 68, worst case capped at 5 by construction.

## Verified facts (don't re-guess)

Carried forward, still true:

- Hook stdout `hookSpecificOutput.additionalContext` (string) paired with
  `hookSpecificOutput.hookEventName` is injected next to the tool result.
- PostToolUse input includes `session_id`, `transcript_path`, `cwd`,
  `tool_name`, `tool_input`, `tool_response`, `tool_use_id`.
- `${CLAUDE_PLUGIN_DATA}` is a persistent per-plugin dir under
  `~/.claude/plugins/data/<id>/`.

New, from https://code.claude.com/docs/en/settings and model-config:

- `autoCompactWindow` is **top-level** in any settings file. Accepted forms:
  `"500k"`, `"1M"`, `200000`, and a bare number 100–1000 meaning thousands.
  The env var `CLAUDE_CODE_AUTO_COMPACT_WINDOW` accepts plain integers only.
- Settings precedence, highest first: managed policy, `--autocompact` CLI flag,
  `.claude/settings.local.json`, `.claude/settings.json`,
  `~/.claude/settings.json`. **A hook cannot see the CLI flag**. Unclosable
  blind spot, accepted.
- `/autocompact 300k` persists to `~/.claude/settings.json`.
- When `autoCompactWindow` is unset, the effective boundary is model-specific
  and **not readable from any file or environment variable**.
- Docs state `autoCompactWindow` "still has an effect" when
  `autoCompactEnabled` is false, but never say what. Undocumented, so treated
  here as "no boundary exists".
- Transcript assistant lines carry `message.model` (e.g. `claude-sonnet-5`).
  **No field anywhere records window size or whether the 1m context is
  active**, verified by grepping the full key space of a real transcript.
- A hook cannot trigger compaction. PreCompact can only cancel one, not shape
  what survives it.

## Design

### Boundary resolution, once per session, cached

Resolve `autoCompactWindow` by first file containing the key:

1. `<cwd>/.claude/settings.local.json`
2. `<cwd>/.claude/settings.json`
3. `~/.claude/settings.local.json`
4. `~/.claude/settings.json`

`CLAUDE_CODE_AUTO_COMPACT_WINDOW` overrides all four if set. Parse all four
value forms. Cache the resolved integer to the session state dir on first read
and reuse it for the session's life; log it in the debug breadcrumb.

**Fallback when the key is absent anywhere:** 300k on a 1m model, 180k on a
200k model. Model class comes from the existing environment proxy:
`CLAUDE_CODE_DISABLE_1M_CONTEXT=1` means 200k, otherwise 1m. Rejected a
model-ID lookup table read from the transcript: it goes stale on every model
release, and still can't tell whether a 1m window is switched on. A proxy that
is knowingly conservative beats a table that is confidently wrong.

**Silent when `autoCompactEnabled` is false.** No boundary exists, so every
message in this mode would be a lie. The model would write a handoff and then
run indefinitely. Exit 0, no output, and record the reason in the debug file.

### Fire schedule

Five fires at fixed distances below the boundary B:

| Fire | Trigger | Level | At B=300k | At B=180k |
|---|---|---|---|---|
| 1 | B − 50k | L3 | 250k | 130k |
| 2 | B − 40k | L3 | 260k | 140k |
| 3 | B − 30k | L3 | 270k | 150k |
| 4 | B − 20k | L3 | 280k | 160k |
| 5 | B − 10k | L4 | 290k | 170k |

Each fires once on first upward crossing. No cadence, no tool-call counting.
Fixed distances rather than proportions: the quantity that matters is how much
room is left to write a handoff in, which is an absolute amount of work.

Past B, silent. Compaction is imminent by definition and the model has been
told five times.

After a compaction the token count drops, crossings re-arm, and the schedule
runs again. This is deliberate: the model genuinely has room again.

### Messages

Every message carries a live countdown, is idempotent, and ends in *keep
working*. Placeholder `%LEFT%` substitutes remaining tokens to the boundary.

L3 (fires 1–4):

> NOTE: ~%LEFT% tokens until auto-compaction. Consider creating or refreshing
> a handoff with task state, decisions, and next steps. Keep working.

L4 (fire 5):

> WARNING: ~%LEFT% tokens until auto-compaction. Write or update your handoff
> now. Keep working through the boundary. Stopping short strands the session.

L3 suggests, L4 instructs. Four suggestions that escalate to one instruction
reads as a countdown; five instructions read as nagging, which is what the old
mode did wrong.

"Creating or refreshing" is what makes repetition informative rather than
repetitive: a model that already wrote one just updates it, and a handoff
written at 250k is stale by 290k.

Neither message says "file" or "on disk". Ollie's call: a model that is told
to write a handoff will produce one in the usual place without being told
where that is.

## Stripped

- L1 and L2 thresholds, messages, and their `CC_CONTEXT_L*_TOKENS` overrides.
- All `CC_CONTEXT_L*_CADENCE` variables and the cadence branch.
- Tool-call-based re-injection and the `last_inject_at` state file.
- The `%PCT%` placeholder and the L4-as-100% baseline maths.

## Kept

Transcript token parsing, compact-boundary anchoring, subagent skip via
`agent_id`, `fires.log`, the debug breadcrumb, and the tool-count fallback
token source. The tool-count fallback stays as last resort but is now a
weaker fit. A crude estimate against a hard boundary can fire early or not
at all. Acceptable: it only applies when the transcript is unreadable.

## Prerequisite

This mode does nothing until compaction is on. README must state, as a
requirement rather than a suggestion:

```
/autocompact 300k          # sets the boundary, persists to user settings
autoCompactEnabled: true   # in ~/.claude/settings.json
```

## Build order

1. Boundary resolution + parser + cache, behind the debug breadcrumb only.
2. Fire schedule replacing level/cadence logic.
3. New messages, old ones deleted.
4. README prerequisite section.
5. Re-run the fire-log simulation post-ship to confirm ~106 fires.

## Deferred

- **Rename.** The plugin prepares for a compaction boundary rather than
  reducing rot. Ollie's position: preparing for compaction is still a form of
  rot reduction, so the name stays. Revisit after a week of live use. Renaming
  touches the marketplace entry, plugin id, and installed data dir, so it
  shouldn't ride along with a mode rewrite.
- **Managed-policy settings file** is not read. Enterprise fleets only.
