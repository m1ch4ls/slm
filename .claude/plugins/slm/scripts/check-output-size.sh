#!/bin/bash
# Check if bash output exceeds threshold and remind about slm
# This script receives PostToolUse JSON on stdin

SIZE_THRESHOLD=1024  # 1KB

# Read JSON input from stdin
INPUT=$(cat)

# Extract the tool output using jq
OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty')

# If no output, exit silently
if [ -z "$OUTPUT" ]; then
  exit 0
fi

# Calculate size in bytes
OUTPUT_SIZE=$(echo -n "$OUTPUT" | wc -c)

# Check if output exceeds threshold
if [ "$OUTPUT_SIZE" -gt "$SIZE_THRESHOLD" ]; then
  # Output a reminder that Claude will see as context
  echo "💡 **SLM Tip**: The previous bash command produced ${OUTPUT_SIZE} bytes of output (>1KB)."
  echo ""
  echo "Consider using slm to process this output and save tokens:"
  echo "  • Summarize: your-command | slm \"summarize the key points\""
  echo "  • Extract: your-command | slm \"extract only error messages\""
  echo "  • Count: your-command | slm \"count occurrences by category\""
  echo ""
fi

exit 0
