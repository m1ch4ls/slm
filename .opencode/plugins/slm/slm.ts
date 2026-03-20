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

  // Check if command uses sampling patterns
  const getSamplingTool = (command: string): string | null => {
    if (/\|\s*head\b/.test(command)) return 'head';
    if (/\|\s*tail\b/.test(command)) return 'tail';
    if (/\|\s*grep\b/.test(command)) return 'grep';
    if (/\|\s*wc\b/.test(command)) return 'wc';
    if (/\|\s*awk\b/.test(command)) return 'awk';
    if (/\|\s*less\b/.test(command) || /\|\s*more\b/.test(command)) return 'less/more';
    return null;
  };

  // Get suggestion text based on sampling tool
  const getSamplingSuggestion = (tool: string): string => {
    const suggestions: Record<string, string> = {
      head: '  • Instead of: your-command | head -20\n  • Use: your-command | slm "show me a representative sample"',
      tail: '  • Instead of: your-command | tail -30\n  • Use: your-command | slm "what\'s the final status?"',
      grep: '  • Instead of: your-command | grep "pattern"\n  • Use: your-command | slm "find lines about pattern"',
      wc: '  • Instead of: your-command | wc -l\n  • Use: your-command | slm "count items and summarize"',
      awk: '  • Instead of: your-command | awk ...\n  • Use: your-command | slm "extract the data you need"',
      'less/more': '  • Use: your-command | slm "what you want to know"',
    };
    return suggestions[tool] || '  • Use: your-command | slm "what you want to know"';
  };

  // Load instructions file
  const instructionsPath = join(directory, "SLM_INSTRUCTIONS.md");
  let slmInstructions = "";
  try {
    slmInstructions = readFileSync(instructionsPath, "utf-8");
  } catch (error) {
    // Fallback to embedded instructions if file not found
    slmInstructions = `# Use slm for simple text processing\n\nUse \`slm\` (local small language model) instead of processing text yourself whenever the task is simple and mechanical. This saves tokens and money.`;
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

    // Remind about slm for large outputs or sampling commands
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

      // Check if command uses sampling
      const samplingTool = command ? getSamplingTool(command) : null;
      const isLargeOutput = outputSize > SIZE_THRESHOLD;

      // Determine if we should remind and what type of reminder
      let shouldRemind = false;
      let reminderText = "";
      let reminderType = "";

      if (samplingTool) {
        const threshold = getThreshold();
        shouldRemind = state.toolsSinceLastReminder >= threshold;
        reminderType = "sampling";
        reminderText = `💡 **Sampling Detected**: You used '${samplingTool}' to sample output.\n\nConsider using slm instead - it reads everything and gives you the answer:\n${getSamplingSuggestion(samplingTool)}`;
      } else if (isLargeOutput) {
        // Apply rate limiting for large output reminders
        const threshold = getThreshold();
        shouldRemind = state.toolsSinceLastReminder >= threshold;
        reminderType = "large_output";
        reminderText = `💡 **Large Output**: The previous bash command produced ${outputSize} bytes of output.\n\nConsider using slm to understand the output instead of reading it all:\n  • your-command | slm "summarize the key points"\n  • your-command | slm "did it succeed? any errors?"`;
      }

      if (shouldRemind) {
        // Capture state before resetting for logging
        const reminderNum = state.reminderCount + 1;
        const toolsCounted = state.toolsSinceLastReminder;

        // Get current session from context or use SDK to find active session
        const sessions = await client.session.list();
        const currentSession = sessions.data[0]; // Get most recent session

        if (currentSession) {
          // Update state - reset counter and increment reminder count for large outputs only
          if (reminderType === "large_output") {
            state.reminderCount++;
            state.toolsSinceLastReminder = 0;
          }

          // Inject a reminder message into the session
          await client.session.prompt({
            path: { id: currentSession.id },
            body: {
              noReply: true, // Don't trigger AI response, just add context
              parts: [
                {
                  type: "text",
                  text: reminderText,
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
            message: `${reminderType === "sampling" ? "Sampling command" : "Large bash output"} detected, suggested using slm`,
            extra: {
              command,
              samplingTool,
              outputSize,
              sizeThreshold: SIZE_THRESHOLD,
              toolsSinceLastReminder: toolsCounted,
              reminderCount: reminderNum,
              reminderType,
              nextReminderThreshold: reminderType === "large_output" ? getThreshold() : null,
            },
          },
        });
      }
    },
  };
};

export default SlmPlugin;
