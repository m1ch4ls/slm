# SLM Reminder Plugin for Claude Code

Automatically reminds Claude to use `slm` (small local model) instead of sampling commands like head/tail/grep, saving API tokens and money.

This plugin is part of the **slm** marketplace.

## Features

- **SLM Instructions Skill**: Injects usage guidelines into Claude's context (auto-invoked)
- **Session Start Reminder**: Hook reminds about slm usage once at session start
- **Sampling Detection**: Detects head/tail/grep/wc usage and suggests slm alternatives
- **Large Output Fallback**: Also reminds for large outputs (>1KB) even without sampling

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
4. **Sampling Detection**: If the command used head, tail, grep, wc, awk, or less/more, a specific suggestion is shown
5. **Size Check**: If `tool_output` exceeds 1KB (and no sampling detected), a reminder is printed

### Hook Implementation

**SessionStart**:
- Outputs a brief reminder about using slm at the start of each session
- Simple echo command - no state tracking needed
- Zero overhead after session initialization

**PostToolUse (after Bash)**:
- Uses a **shell script** (`scripts/detect-sampling.sh`) that:
  - Receives `PostToolUse` JSON on stdin
  - Extracts the command and output using `jq`
  - Checks if the command contains sampling patterns (head, tail, grep, wc, awk, less, more)
  - Skips commands that already use slm (avoids redundant suggestions)
  - Counts bytes with `wc -c` for large output detection
  - Outputs contextual suggestions based on what was detected

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
│   └── detect-sampling.sh       # Detects sampling commands and large outputs
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
💡 Use slm instead of head/tail/grep. When you want to understand output, pipe to slm: command | slm "what you want to know"
```

**After using a sampling command:**
```bash
$ npm test 2>&1 | tail -30
# ... 30 lines of output ...
```

Claude will see:
```
💡 **Sampling Detected**: You used 'tail' to sample output.

Consider using slm instead - it reads everything and gives you the answer:
  • Instead of: your-command | tail -30
  • Use: your-command | slm "what's the final status?"
```

**After running Bash with large output:**
```bash
$ git log --oneline -50
# ... 50 lines of output ...
```

Claude will see:
```
💡 **Large Output**: The previous command produced 2847 bytes of output.

Consider using slm to understand the output instead of reading it all:
  • your-command | slm "summarize the key points"
  • your-command | slm "did it succeed? any errors?"
```

## Requirements

- `jq` must be installed (for JSON parsing in hook script)
- Bash shell

## See Also

- OpenCode SLM plugin: `/.opencode/plugins/slm/`
- Claude Code Hooks Docs: https://code.claude.com/docs/en/hooks
