import type { Plugin } from "@opencode-ai/plugin";
import { readFileSync } from "fs";
import { join } from "path";

/**
 * Plugin to remind the agent to use slm for large bash outputs
 * and inject slm usage instructions into the system prompt
 */
export const SlmPlugin: Plugin = async ({ client, directory }) => {
  const SIZE_THRESHOLD = 1024; // 1KB

  // State for rate limiting based on tool call count
  const state = {
    toolsSinceLastReminder: 0,
    reminderCount: 0,
  };

  // Get current threshold based on reminder count
  const getThreshold = () => {
    if (state.reminderCount === 0) return 0; // First reminder: immediate
    if (state.reminderCount === 1) return 3; // Second: wait 3 tool calls
    if (state.reminderCount === 2) return 6; // Third: wait 6 tool calls
    return 10; // Fourth+: wait 10 tool calls
  };

  // Load instructions file
  const instructionsPath = join(directory, "SLM_INSTRUCTIONS.md");
  let slmInstructions = "";
  try {
    slmInstructions = readFileSync(instructionsPath, "utf-8");
  } catch (error) {
    // Fallback to embedded instructions if file not found
    slmInstructions = `# Use slm for simple text processing

Use \`slm\` (local small language model) instead of processing text yourself whenever the task is simple and mechanical. This saves tokens and money.

**How to apply:** Before writing a text-heavy response, ask: "Could slm do this via a pipe?"

## When to use slm

| Task | Example |
|------|---------|
| Summarizing output | \`command \| slm "summarize"\` |
| Extracting data | \`ps aux \| slm "list only node processes"\` |
| Parsing logs | \`cat errors.log \| slm "group by type"\` |
| Describing diffs | \`git diff \| slm "summarize changes"\` |

## When NOT to use slm

- Code generation or editing (correctness matters)
- Architectural decisions
- Multi-step analysis requiring context
- Security-sensitive analysis`;
  }

  return {
    // Inject instructions into system prompt (like CLAUDE.md)
    "experimental.chat.system.transform": async (input, output) => {
      // Add SLM instructions to the system prompt array
      await client.app.log({
        body: {
          service: "slm",
          level: "info",
          message: "Injecting SLM instructions into system prompt",
        },
      });
      output.system.push(`\n\n## Instructions from: SLM_INSTRUCTIONS.md\n\n${slmInstructions}`);
    },

    // Remind about slm for large outputs
    "tool.execute.after": async (input, output) => {
      // Only check bash tool executions
      if (input.tool !== "bash") {
        return;
      }

      const command = input.args?.command as string | undefined;

      // Skip if the command already uses slm
      if (command && (command.includes("| slm") || command.includes("|slm"))) {
        // Reset counter when slm is actually used
        state.toolsSinceLastReminder = 0;
        state.reminderCount = 0;
        return;
      }

      // Count this tool call
      state.toolsSinceLastReminder++;

      // Get the output content (handle both string and object outputs)
      const outputContent = typeof output === "string" ? output : JSON.stringify(output);
      const outputSize = Buffer.byteLength(outputContent, "utf8");

      // Check if we should remind: large output AND enough tool calls have passed
      const threshold = getThreshold();
      const shouldRemind = outputSize > SIZE_THRESHOLD && state.toolsSinceLastReminder >= threshold;

      if (shouldRemind) {
        // Capture state before resetting for logging
        const reminderNum = state.reminderCount + 1;
        const toolsCounted = state.toolsSinceLastReminder;

        // Get current session from context or use SDK to find active session
        const sessions = await client.session.list();
        const currentSession = sessions.data[0]; // Get most recent session

        if (currentSession) {
          // Update state - reset counter and increment reminder count
          state.reminderCount++;
          state.toolsSinceLastReminder = 0;

          // Inject a reminder message into the session
          await client.session.prompt({
            path: { id: currentSession.id },
            body: {
              noReply: true, // Don't trigger AI response, just add context
              parts: [
                {
                  type: "text",
                  text: `⚠️ **Large Output Detected**: The previous bash command produced ${outputSize} bytes of output (>1KB).

Consider piping this output through \`slm\` to summarize or extract relevant information. Examples:
- \`your-command | slm "summarize the key findings"\`
- \`your-command | slm "extract only the error messages"\``,
                },
              ],
            },
          });
        }

        // Also log for visibility
        await client.app.log({
          body: {
            service: "slm-reminder",
            level: "info",
            message: `Large bash output detected (${outputSize} bytes), suggested using slm`,
            extra: {
              command,
              outputSize,
              sizeThreshold: SIZE_THRESHOLD,
              toolsSinceLastReminder: toolsCounted,
              reminderCount: reminderNum,
              nextReminderThreshold: getThreshold(),
            },
          },
        });
      }
    },
  };
};

export default SlmPlugin;
