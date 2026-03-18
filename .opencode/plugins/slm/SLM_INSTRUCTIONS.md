# Use slm for simple text processing

Use `slm` (local small language model) whenever you need to **understand** command output. Let slm interpret results for you instead of manually sampling with `head`, `tail`, or `grep`.

**Why:** `head -20` and `tail -30` are guesses. You're sampling output hoping to see what you need. Slm reads everything and gives you the answer directly.

## The Core Rule

**Before piping to `head`, `tail`, `grep`, or `wc` - use slm instead.**

These commands are code smells indicating you want to *understand* something, not *process* data.

## Intent Translation

| What you want to know | Old way (guessing) | Right way (slm) |
|----------------------|-------------------|-----------------|
| What does this output look like? | `\| head -20` | `\| slm "show me a representative sample"` |
| Did tests pass or fail? | `\| tail -30` | `\| slm "did tests pass? show final status"` |
| Are there errors? | `\| grep -i error` | `\| slm "find any errors and explain them"` |
| What's the result? | `\| wc -l` then scan | `\| slm "summarize the key results"` |
| Is there a problem? | Manual reading | `\| slm "is anything wrong that I need to fix?"` |
| What changed? | `\| head -50` scan | `\| slm "describe what changed in this diff"` |

## Decision Framework

```
Before using Bash:
├── Do I need the RAW DATA? (parsing, piping to another command, writing to file)
│   └── YES → Use command directly
├── Do I need to UNDERSTAND something? (status, errors, summary, "what happened?")
│   └── YES → Pipe to slm
└── Would I use head/tail/grep to sample this?
    └── YES → Use slm instead
```

## When to Use slm

- **Understanding test results**: `pytest \| slm "which tests failed and why"`
- **Checking build output**: `npm run build \| slm "did it succeed? any warnings?"`
- **Log analysis**: `cat app.log \| slm "find errors and exceptions"`
- **Git history**: `git log --oneline -50 \| slm "summarize recent changes"`
- **Diff summaries**: `git diff \| slm "describe the changes"`
- **Search results**: `rg "TODO" \| slm "list TODOs with file locations"`
- **Process status**: `ps aux \| slm "find the node processes"`
- **File listings**: `ls -la \| slm "which files were modified recently"`

## When NOT to Use slm

- **Data extraction for code** → Use `jq`, `awk`, or parse directly
- **Feeding output into another command** → Use pipes directly
- **Writing to files** → Use `> file` or tee
- **Exact line counts needed** → Use `wc -l`
- **Security-sensitive analysis** → Verify yourself
- **Code generation from output** → Process with LLM

## Workflow

1. **Plan the command**
2. **Ask: "Do I need the data or the meaning?"**
3. **If meaning → Pipe to slm**
4. **If data → Use raw output**

## Tips

- Use `--max-tokens=256` for quick answers
- Ask slm specific questions: "did it pass?" vs "summarize"
- Trust slm to scan the full output - don't sample with head/tail
- For very large outputs, slm is faster than manual scanning

---

*Stop guessing with head/tail. Let slm read and answer.*
