# Plan: context-budget-monitor plugin

A Claude Code plugin that nudges Claude to wrap up gracefully before
auto-compaction degrades a long session. Inspired by yurukusa/cc-safe-setup's
`context-monitor` hook; replaces its stderr-only output with the documented
`additionalContext` mechanism so the model itself reads the warning.

## Verified docs facts (don't re-guess)

From https://code.claude.com/docs/en/hooks:

- Hook stdout JSON schema includes `hookSpecificOutput.additionalContext` (a
  string) paired with `hookSpecificOutput.hookEventName`. PostToolUse
  supports it; the text is placed next to the tool result in Claude's
  context.
- PostToolUse input includes `session_id`, `transcript_path`, `cwd`,
  `tool_name`, `tool_input`, `tool_response`, `tool_use_id`.
- Matcher `""` (empty), `"*"`, or omitted all match every tool.
- Exit 0 with JSON on stdout is processed as a decision. Plain text on
  stdout/stderr is not injected into Claude's context (this is yurukusa's
  current limitation).

From https://code.claude.com/docs/en/plugins-reference:

- Layout: `.claude-plugin/plugin.json` for manifest, `hooks/hooks.json` at
  plugin root, `scripts/` at plugin root.
- `${CLAUDE_PLUGIN_ROOT}` is the absolute install path; reference scripts as
  `"${CLAUDE_PLUGIN_ROOT}"/scripts/foo.sh`.
- `${CLAUDE_PLUGIN_DATA}` is a persistent per-plugin state dir,
  `~/.claude/plugins/data/<id>/`. Created on first reference.
- Local-dir install for testing: `claude --plugin-dir <path>`.

## Design decisions (per brainstorm)

### Thresholds are absolute token counts, not percentages

User-configurable. Model-agnostic; works whether you're on 200k or 1M
context. Defaults:

| Level | Tokens | Cadence | Purpose |
|-------|--------|---------|---------|
| L1 caution  | 100,000 | every 7 tool calls  | Prefer subagent delegation for exploration |
| L2 wrap     | 130,000 | every 5 tool calls  | Wrap current sub-task; propose /compact |
| L3 hardstop | 150,000 | every 3 tool calls  | STOP, save plan, report status, await human |
| L4 overdrive | (>L3 by 10k) | every 2 tool calls | Keep pressure on if L3 is being ignored |

Cadence semantics: inject on first transition into a level, then re-inject
every Nth tool call within that level. Higher level = denser nudges. If
context drops back down (e.g. after `/compact`), the next upward crossing
re-fires.

Configurable via env vars at top of script, in `CC_CONTEXT_*` style. No
userConfig dialog — keep install frictionless.

### Token source: belt-and-braces

1. **Transcript JSONL**: read `transcript_path`, find the most recent line
   with `message.usage`, sum `input_tokens + cache_read_input_tokens +
   cache_creation_input_tokens` (these all consume the window). This is
   the most accurate source.
2. **Debug log** (yurukusa's path): parse `~/.claude/debug/*.txt` for
   `autocompact: tokens=N effectiveWindow=M`. Only populated under
   `claude --debug`.
3. **Tool count fallback**: yurukusa's `tokens ~= count * (window/180)`.
   Crude but always available.

The script picks the first that succeeds and records the source in a debug
state file (not in the injected message — keep that terse).

### State storage: `${CLAUDE_PLUGIN_DATA}/<session_id>/`

Per-session subdir keyed by hook input's `session_id`. Files:

- `count`           — tool-call counter (for fallback estimation + cadence)
- `level`           — last computed level (0–4)
- `last_inject_at`  — counter value at last injection
- `evac_cooldown`   — unix timestamp of last evacuation template write

Per-session namespacing means concurrent sessions don't trample each other
and counters reset cleanly each session. Old session dirs are not
garbage-collected by this plugin — they're tiny and Claude Code cleans up
plugin data dirs on uninstall.

### additionalContext message style

Factual, directive, brief. System-reminder voice. Examples (final wording
in script):

- L1: "Context budget at ~100k tokens. For the next exploration or
  research step, prefer delegating to a subagent so the results don't
  fill this session's context."
- L2: "Context budget at ~130k tokens. At the next clean checkpoint
  (test passing, file saved, sub-task done), wrap the current work and
  propose `/compact` with steering instructions that name the
  architectural decisions, modified files, and the next task to
  preserve."
- L3: "Context budget at ~150k tokens. Stop starting new work. Save plan
  progress to file, summarise what is complete and what is next, then
  report status to the user and await direction. Evacuation template
  written to <path>."
- L4: Same as L3 but more terse; no template re-write (cooldown handles
  that anyway).

### Evacuation template at L3 only

Same template shape as yurukusa: a markdown block appended to
`$CC_CONTEXT_MISSION_FILE` (default `${CLAUDE_PROJECT_DIR}/MISSION.md`)
with `[TODO]` placeholders. 30-min cooldown. Skipped if an unfilled
template already exists.

## Build order

1. Plan doc (this file). [done in this step]
2. `git init` (empty repo, no remote).
3. `.claude-plugin/plugin.json` manifest.
4. `hooks/hooks.json` — single PostToolUse hook with matcher "".
5. `scripts/context-monitor.sh` — the main script. Bash, `set -u` and
   `set -o pipefail`, use `jq` for stdin parsing (require it).
6. `README.md` — what/why, threshold table, install command, yurukusa
   credit.
7. `LICENSE` — MIT.
8. Smoke test: pipe synthetic PostToolUse JSON at L0/L1/L2/L3 tokens and
   verify stdout shape; verify state files; verify cadence by repeated
   invocation.

## Out of scope

- No formal test suite. Smoke testing only.
- No marketplace submission. User handles GitHub remote.
- No multi-session aggregation. Per-session state only.
- No automatic `/compact` invocation — we only nudge.
