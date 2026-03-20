#!/bin/bash
# Detect if bash command used sampling commands (head, tail, grep, wc) and suggest slm
# Also reminds about slm for large outputs
# This script receives PostToolUse JSON on stdin and outputs hookSpecificOutput JSON

SIZE_THRESHOLD=1024  # 1KB

# Read JSON input from stdin
INPUT=$(cat)

# Extract the command and output using jq
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
OUTPUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty')

# If no command or output, exit silently
if [ -z "$COMMAND" ] || [ -z "$OUTPUT" ]; then
  exit 0
fi

# Skip if command already uses slm (avoid redundant suggestions)
if echo "$COMMAND" | grep -qi "slm"; then
  exit 0
fi

# Check for sampling commands
USES_SAMPLING=false
SAMPLING_TOOL=""

if echo "$COMMAND" | grep -qE '\| *head\b'; then
  USES_SAMPLING=true
  SAMPLING_TOOL="head"
elif echo "$COMMAND" | grep -qE '\| *tail\b'; then
  USES_SAMPLING=true
  SAMPLING_TOOL="tail"
elif echo "$COMMAND" | grep -qE '\| *grep\b'; then
  USES_SAMPLING=true
  SAMPLING_TOOL="grep"
elif echo "$COMMAND" | grep -qE '\| *wc\b'; then
  USES_SAMPLING=true
  SAMPLING_TOOL="wc"
elif echo "$COMMAND" | grep -qE '\| *awk\b'; then
  USES_SAMPLING=true
  SAMPLING_TOOL="awk"
elif echo "$COMMAND" | grep -qE '\| *less\b|\| *more\b'; then
  USES_SAMPLING=true
  SAMPLING_TOOL="less/more"
fi

# Calculate size in bytes
OUTPUT_SIZE=$(echo -n "$OUTPUT" | wc -c)
IS_LARGE=false
if [ "$OUTPUT_SIZE" -gt "$SIZE_THRESHOLD" ]; then
  IS_LARGE=true
fi

# Build the message
MESSAGE=""

if [ "$USES_SAMPLING" = true ]; then
  MESSAGE="💡 **Sampling Detected**: You used '$SAMPLING_TOOL' to sample output.

Consider using slm instead - it reads everything and gives you the answer:"
  
  case "$SAMPLING_TOOL" in
    "head")
      MESSAGE="$MESSAGE
  • Instead of: your-command | head -20
  • Use: your-command | slm \"show me a representative sample\""
      ;;
    "tail")
      MESSAGE="$MESSAGE
  • Instead of: your-command | tail -30
  • Use: your-command | slm \"what's the final status?\""
      ;;
    "grep")
      MESSAGE="$MESSAGE
  • Instead of: your-command | grep \"pattern\"
  • Use: your-command | slm \"find lines about pattern\""
      ;;
    "wc")
      MESSAGE="$MESSAGE
  • Instead of: your-command | wc -l
  • Use: your-command | slm \"count items and summarize\""
      ;;
    "awk")
      MESSAGE="$MESSAGE
  • Instead of: your-command | awk ...
  • Use: your-command | slm \"extract the data you need\""
      ;;
    *)
      MESSAGE="$MESSAGE
  • Use: your-command | slm \"what you want to know\""
      ;;
  esac
  
  MESSAGE="$MESSAGE
"
fi

# Also remind for large outputs even without sampling
if [ "$IS_LARGE" = true ] && [ "$USES_SAMPLING" = false ]; then
  MESSAGE="💡 **Large Output**: The previous command produced ${OUTPUT_SIZE} bytes of output.

Consider using slm to understand the output instead of reading it all:
  • your-command | slm \"summarize the key points\"
  • your-command | slm \"did it succeed? any errors?\"
"
fi

# Output as JSON with hookSpecificOutput if we have a message
if [ -n "$MESSAGE" ]; then
  jq -n --arg msg "$MESSAGE" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $msg
    }
  }'
fi

exit 0
