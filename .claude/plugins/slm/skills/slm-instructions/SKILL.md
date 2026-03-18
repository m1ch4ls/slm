---
description: Guidelines for using slm (small local model) to save tokens on text processing tasks
---

# Use slm for simple text processing

Use `slm` (local small language model) instead of processing text yourself whenever the task is simple and mechanical. This saves tokens and money.

**Why:** Every token spent on mundane text processing is wasted when a free local model can do it.

**How to apply:** Before writing a text-heavy response or reasoning through simple text, ask: "Could slm do this via a pipe?" If yes, use Bash to pipe the data through slm.

## When to use slm

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

## When NOT to use slm

- Code generation or editing (use the LLM — correctness matters)
- Architectural decisions or complex reasoning
- Multi-step analysis that requires project context
- Anything where slm output feeds into code changes (the LLM should verify)
- Security-sensitive analysis

## Tips

- Use `--max-tokens=256` for short summaries to keep slm fast
- Pipe raw command output directly — don't pre-process it yourself
- If you need to present a summary to the user, let slm generate it and show the result
- Chain: use slm output to inform your next action, but don't trust it for code correctness

---

*This skill reminds you to use slm for large bash outputs (>1KB) automatically.*
