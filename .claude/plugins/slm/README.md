# SLM Reminder Plugin for Claude Code

Automatically reminds Claude to use `slm` (small local model) for processing large text outputs, saving API tokens and money.

This plugin is part of the **slm** marketplace.

## Features

- **SLM Instructions Skill**: Injects usage guidelines into Claude's context (auto-invoked)
- **Session Start Reminder**: Hook reminds about slm usage once at session start
- **Post-Bash Large Output Detection**: Shell script checks bash output size (no LLM overhead)
- **Smart Reminders**: Triggers at session start and when output exceeds 1KB threshold

## Installation

### From marketplace (recommended):
```bash
# Add the marketplace
claude plugin marketplace add github:m1ch4ls/slm

# Install the plugin
claude plugin install slm-reminder@slm
```

### From local directory (development):
```bash
claude --plugin-dir /path/to/.claude/plugins/slm
```

### Install to project:
```bash
claude plugin add /path/to/.claude/plugins/slm --scope project
```

## How It Works

1. **Context Injection**: The `slm-instructions` skill loads automatically and provides guidelines on when to use slm
2. **Session Start Reminder**: When a session starts, a hook outputs a brief reminder to consider using slm
3. **Post-Bash Hook**: After every Bash tool execution, the shell script checks the JSON payload
4. **Size Check**: If `tool_output` exceeds 1KB, a reminder is printed to stdout (which Claude sees as context)

### Hook Implementation

**SessionStart**:
- Outputs a brief reminder about using slm at the start of each session
- Simple echo command - no state tracking needed
- Zero overhead after session initialization

**PostToolUse (after Bash)**:
- Uses a **shell script** (`scripts/check-output-size.sh`) that:
  - Receives `PostToolUse` JSON on stdin
  - Uses `jq` to extract the `tool_output` field
  - Counts bytes with `wc -c`
  - Conditionally outputs a tip if threshold exceeded

**No LLM calls are made** - this is deterministic and fast.

## Plugin Structure

```
slm/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── skills/
│   └── slm-instructions/
│       └── SKILL.md             # Usage guidelines (auto-loaded)
├── hooks/
│   └── hooks.json               # Hook configurations (SessionStart, PostToolUse)
├── scripts/
│   └── check-output-size.sh     # Deterministic size checker
└── README.md                    # This file
```

## Comparison with OpenCode Plugin

| Feature | OpenCode Plugin | Claude Code Plugin |
|---------|----------------|-------------------|
| System prompt injection | `experimental.chat.system.transform` hook | Auto-invoked **Skill** |
| Large output detection | `tool.execute.after` with SDK calls | `PostToolUse` + **shell script** |
| Implementation | TypeScript with `client.session.prompt()` | JSON + Markdown + **Bash/jq** |
| Complexity | Programmatic | Declarative + deterministic |
| LLM overhead | None (direct API calls) | **None** (pure shell logic) |

## Usage Examples

**At session start:**
```
💡 Remember: Use slm for simple text processing tasks. Pipe command output to slm when summarizing, extracting, or transforming text.
```

**After running Bash with large output:**
```bash
$ git log --oneline -50
# ... 50 lines of output ...
```

Claude will see:
```
💡 **SLM Tip**: The previous bash command produced 2847 bytes of output (>1KB).

Consider using slm to process this output and save tokens:
  • Summarize: your-command | slm "summarize the key points"
  • Extract: your-command | slm "extract only error messages"
  • Count: your-command | slm "count occurrences by category"
```

## Requirements

- `jq` must be installed (for JSON parsing in hook script)
- Bash shell

## See Also

- OpenCode SLM plugin: `/.opencode/plugins/slm/`
- Claude Code Hooks Docs: https://code.claude.com/docs/en/hooks
