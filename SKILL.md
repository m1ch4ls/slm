---
name: slm
description: Use slm to delegate focused interpretation of substantial command output or text to a smaller language model. Trigger for summaries, status explanations, categorization, and evidence-backed extraction when you would otherwise sample noisy output; not for exact processing or high-impact reasoning.
---

# slm

Use `slm` to reduce primary-agent context spent interpreting noisy text. It delegates one focused task to a smaller, less-capable language model.

## Decision Rule

Use `slm` when finite output needs semantic interpretation and you would otherwise sample, truncate, search broadly, or spend significant context reading it.

Do not replace deterministic processing with `slm`. Use exact tools for exact selection, counting, parsing, sorting, transformation, or downstream data.

## Use For

- Summarizing finite logs, histories, diffs, and reports for orientation
- Explaining build or test diagnostics while treating the producer's exit status as authoritative
- Categorizing noisy results
- Extracting relevant items with exact supporting text and available identifiers or locations
- Producing a deliberately bounded status or short answer

## Do Not Use For

- Small output that is cheaper to inspect directly
- Interactive commands, watch modes, unbounded streams, or live logs
- Mutating, expensive, flaky, rate-limited, or time-sensitive commands that would need rerunning
- Output consumed by another command or written as authoritative data
- Code review, root-cause diagnosis, security analysis, or high-impact decisions
- Tasks requiring tools or context not present in stdin

## Invocation

- Decide before running a noisy command. Do not rerun it solely for delegation unless it is read-only, cheap, and deterministic enough.
- Use `command | slm "..."` for command output.
- Use `slm "..." < file` for file contents.
- Merge stderr with `2>&1` only when both streams contain relevant diagnostics.
- When producer status matters, preserve it using the shell's pipeline-failure mechanism. In Bash-compatible shells: `set -o pipefail`.
- Ask one focused, mechanical question and specify the required output shape.
- For extraction, request exact supporting text and available identifiers or locations.
- Use `--max-tokens` as a runaway-output guard when the expected answer is naturally short. It limits output, not input.
- Input and model context limits still apply. If `slm` fails or rejects the input, fall back to exact tools and primary-agent inspection rather than repeatedly retrying or splitting heuristically.
- Treat the result as an interpretation. Verify it when the input may be adversarial or before any high-impact action.

## Examples

```sh
git diff | slm "summarize the change areas in concise bullets for orientation"

slm --max-tokens=256 \
  "list errors with exact messages and available file or line references" \
  < application.log

test-command 2>&1 | slm --max-tokens=64 \
  "output one sentence explaining the final status"

# Bash-compatible: preserve the build command's failure status.
set -o pipefail; build-command 2>&1 | slm \
  "summarize warnings and errors with exact supporting text"
```
