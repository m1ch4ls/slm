# SLM Plugin for OpenCode

This plugin automatically injects SLM usage instructions into opencode's system prompt and reminds the agent to use the `slm` tool when they use sampling commands (head, tail, grep, etc.) or when output exceeds 1KB.

## What it does

1. **Injects instructions into system prompt** - Uses `experimental.chat.system.transform` hook to load `SLM_INSTRUCTIONS.md` and add it to the system prompt
 
2. **Detects sampling commands** - Uses `tool.execute.after` hook to detect head/tail/grep/wc/awk/less/more and suggest slm alternatives
 
3. **Monitors large outputs** - When output exceeds 1KB (and no sampling detected), injects a reminder with rate limiting

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

### Sampling Detection & Large Output Reminder

The plugin checks every bash command after execution:

**Sampling Detection** (always triggers, no rate limit):
When a command uses `head`, `tail`, `grep`, `wc`, `awk`, or `less/more`:
 
> 💡 **Sampling Detected**: You used 'tail' to sample output.
>
> Consider using slm instead - it reads everything and gives you the answer:
>   • Instead of: your-command | tail -30
>   • Use: your-command | slm "what's the final status?"

**Large Output Detection** (rate limited):
When output exceeds 1KB and no sampling detected:

> 💡 **Large Output**: The previous bash command produced 2048 bytes of output.
>
> Consider using slm to understand the output instead of reading it all:
>   • your-command | slm "summarize the key points"
>   • your-command | slm "did it succeed? any errors?"

### Rate Limiting

Large output reminders use rate limiting to avoid spam:
 - First reminder: immediate
 - Second reminder: after 3 tool calls
 - Third reminder: after 6 tool calls
 - Fourth+: after 10 tool calls

Rate limiting resets when you actually use slm in a command.

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

┌─────────────────┐     ┌───────────────────────┐     ┌──────────────────┐
│  Bash Execute   │────▶│ Detect Sampling       │────▶│ Suggest slm      │
│ (tool.execute   │     │ (head/tail/grep/etc)  │     │ (no rate limit)  │
│  .after hook)   │     └───────────────────────┘     └──────────────────┘
└─────────────────┘
         │
         └───────────▶ Check Size > 1KB ────▶ Rate Limited Reminder
```

## Hooks Used

| Hook | Purpose |
|------|---------|
| `experimental.chat.system.transform` | Inject SLM instructions into system prompt |
| `tool.execute.after` | Detect large bash outputs and remind about slm |

## Fallback Behavior

If `SLM_INSTRUCTIONS.md` is not found, the plugin uses embedded default instructions so it still works out of the box.
