# COMMUNICATION

This prompt runs inside an auto agent whose output is not read by humans. Be extra terse:

- Do not narrate routine reads or cross-referencing.
- Avoid prose summaries.

# ISSUES

Local issue files from `issues/` are provided at start of context. Parse them to understand the open issues.

You will work on the AFK issues only, not the HITL ones.

You've also been passed a file containing the last few commits. Review these to understand what work has been done.

If all AFK tasks are complete, output <promise>NO MORE TASKS</promise>.

# TASK SELECTION

Pick the next task. Prioritize tasks in this order:

1. Critical bugfixes
2. Development infrastructure

Getting development infrastructure like tests and types and dev scripts ready is an important precursor to building features.

3. Tracer bullets for new features

Tracer bullets are small slices of functionality that go through all layers of the system, allowing you to test and validate your approach early. This helps in identifying potential issues and ensures that the overall architecture is sound before investing significant time in development.

TL;DR - build a tiny, end-to-end slice of the feature first, then expand it out.

4. Polish and quick wins
5. Refactors

# EXPLORATION

Explore the repo.

# IMPLEMENTATION

If the task involves writing TypeScript code, use /tdd to complete the task.
Otherwise, proceed with the implementation.

# FEEDBACK LOOPS

Before committing, run the feedback loops:

- `zig build test` to run the tests
- `bun fmt src` to run the formatter

# COMMIT

Make a git commit. The commit message must:

1. Include key decisions made
2. Include files changed
3. Blockers or notes for next iteration

# THE ISSUE

If the task is complete, move the issue file to `issues/done/`.

If the task is not complete, add a note to the issue file with what was done.

# FINAL RULES

- There is no "user" in this context. Do not wait for any instructions. You have full agency to finish the work and are expected to do what it takes to finish it.
- ONLY WORK ON A SINGLE TASK.

