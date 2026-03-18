# SLM Plugin for OpenCode

This plugin automatically injects SLM usage instructions into opencode's system prompt and reminds the agent to use the `slm` tool when bash command output exceeds 1KB.

## What it does

1. **Injects instructions into system prompt** - Uses `experimental.chat.system.transform` hook to load `SLM_INSTRUCTIONS.md` and add it to the system prompt (like how CLAUDE.md works)

2. **Monitors bash executions** - Uses the `tool.execute.after` hook to detect large outputs

3. **Reminds about slm** - When output exceeds 1KB, injects a reminder to pipe through slm

## Files

- `slm-reminder.ts` - The plugin implementation
- `SLM_INSTRUCTIONS.md` - Usage guidelines (loaded automatically by the plugin)

## Installation

### Option 1: Project-specific

Copy both files to your project's opencode plugins directory:

```bash
mkdir -p .opencode/plugins
cp slm-reminder.ts SLM_INSTRUCTIONS.md .opencode/plugins/
```

### Option 2: Global

Copy to your global opencode config:

```bash
mkdir -p ~/.config/opencode/plugins
cp slm-reminder.ts SLM_INSTRUCTIONS.md ~/.config/opencode/plugins/
```

### Install Dependencies

If you haven't already installed the plugin types:

```bash
cd ~/.config/opencode && bun add @opencode-ai/plugin
```

## How it works

### System Prompt Injection

The plugin uses the `experimental.chat.system.transform` hook to mutate the system prompt array. This is the same mechanism opencode uses for CLAUDE.md - instructions are injected at the system level, not as user messages.

```
System Prompt Assembly:
├── Base provider prompt (anthropic.txt, beast.txt, etc.)
├── Environment block (model, directory, date)
├── AGENTS.md / CLAUDE.md (from filesystem walk)
└── SLM_INSTRUCTIONS.md ← Injected by this plugin
```

### Large Output Reminder

When a bash command produces more than 1KB of output, the plugin injects a context message:

> ⚠️ **Large Output Detected**: The previous bash command produced 2048 bytes of output (>1KB).
>
> Consider piping this output through `slm` to summarize or extract relevant information.

## Customization

### Adjust the threshold

Edit the `SIZE_THRESHOLD` constant in `slm-reminder.ts`:

```typescript
const SIZE_THRESHOLD = 1024; // Change to your preferred size in bytes
```

### Modify the instructions

Edit `SLM_INSTRUCTIONS.md` to customize:
- When to use slm
- Example commands
- When NOT to use slm
- Tips and best practices

The plugin loads this file dynamically, so changes take effect for new sessions immediately.

## Architecture

```
┌─────────────────────────────┐     ┌──────────────────────┐
│ System Prompt Construction  │────▶│ Load SLM_INSTRUCTIONS │
│ (experimental.chat.system   │     │ Inject to system[]    │
│  .transform hook)           │     └──────────────────────┘
└─────────────────────────────┘

┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Bash Execute   │────▶│ Check Output Size │────▶│ Remind if >1KB  │
│ (tool.execute   │     │ (tool.execute     │     │ (session.prompt  │
│  .after hook)   │     │  .after hook)     │     │  noReply: true) │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

## Hooks Used

| Hook | Purpose |
|------|---------|
| `experimental.chat.system.transform` | Inject SLM instructions into system prompt |
| `tool.execute.after` | Detect large bash outputs and remind about slm |

## Fallback Behavior

If `SLM_INSTRUCTIONS.md` is not found, the plugin uses embedded default instructions so it still works out of the box.
