---
description: Guidelines for using slm (small local model) to save tokens on simple text processing tasks. Use before running Bash commands that produce text output you need to analyze, summarize, extract, or transform. Always consider slm for command output processing, log parsing, data extraction, or text transformation.
---

# Use slm for simple text processing

**CRITICAL: Before using the Bash tool, ask yourself: "Will I need to process, summarize, or analyze the output?" If yes, pipe the output through slm instead of processing it yourself.**

Use `slm` (local small language model) instead of processing text yourself whenever the task is simple and mechanical. This saves tokens and money.

**Why:** Every token spent on mundane text processing is wasted when a free local model can do it. You are an expensive API - let the cheap local model handle the grunt work.

**How to apply:** Before running Bash or processing any text-heavy output, ask: "Could slm do this via a pipe?" If yes, use Bash to pipe the data through slm.

## When to use slm (ALWAYS consider these before Bash)

| Task | Example |
|------|---------|
| Summarizing command output | `git log --oneline -20 | slm "summarize in 3 bullets"` |
| Summarizing file contents | `cat README.md | slm --max-tokens=256 "summarize"` |
| Extracting data from output | `ps aux | slm "list only python processes"` |
| Parsing error logs | `cat errors.log | slm "group errors by type"` |
| Counting/listing from output | `npm run lint | slm "count errors by category"` |
| Simple text transforms | `echo "text" | slm "convert to bullet points"` |
| Describing diffs | `git diff | slm --max-tokens=256 "summarize changes"` |
| Formatting data | `cat data.json | slm "extract the names field as a list"` |
| Analyzing test output | `pytest | slm "list failed tests with reasons"` |
| Processing search results | `rg "pattern" | slm "summarize findings"` |

## When NOT to use slm

- Code generation or editing (use the LLM - correctness matters)
- Architectural decisions or complex reasoning
- Multi-step analysis that requires project context
- Anything where slm output feeds into code changes (the LLM should verify)
- Security-sensitive analysis

## Workflow: Before Every Bash Command

1. **Plan the command** - What are you trying to achieve?
2. **Will you process the output?** - If you'll summarize, extract, count, or transform the output, use slm
3. **Pipe to slm** - Add `| slm "your instruction"` to the command
4. **Present the result** - Show the user the slm output directly

## Tips

- Use `--max-tokens=256` for short summaries to keep slm fast
- Pipe raw command output directly — don't pre-process it yourself
- If you need to present a summary to the user, let slm generate it and show the result
- Chain: use slm output to inform your next action, but don't trust it for code correctness
- For large outputs (>1KB), the system will remind you automatically

---

*This skill is automatically loaded before Bash commands to remind you to use slm for efficient text processing.*