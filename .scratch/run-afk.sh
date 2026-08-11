#!/bin/bash
set -eo pipefail

MAX_ITERATIONS="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

if [ -z "$MAX_ITERATIONS" ]; then
  echo "Usage: $0 <max-iterations>"
  exit 1
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Max iterations must be a positive integer"
  exit 1
fi

PROJECT=$(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d | sed 's|^.*/||' | fzf --prompt "Select project: ")

if [ -z "$PROJECT" ]; then
  echo "No project selected"
  exit 1
fi

PLAN="$SCRIPT_DIR/$PROJECT"

if [ ! -d "$PLAN" ]; then
  echo "Project '$PROJECT' not found in $SCRIPT_DIR"
  exit 1
fi

prompt=$(cat "$SCRIPT_DIR"/prompt.md)

for ((iteration = 1; iteration <= MAX_ITERATIONS; iteration++)); do
  echo "Starting iteration $iteration/$MAX_ITERATIONS"
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

  issues=$(cat "$PLAN"/issues/*.md 2>/dev/null || echo "No issues found")
  commits=$(git log -n 5 --format="%H%n%ad%n%B---" --date=short 2>/dev/null || echo "No commits found")
  opencode run --model openai/gpt-5.6-sol \
    "Project: ${PLAN} Previous commits: $commits Issues: $issues $prompt" \
    | tee "$tmpfile"

  if grep -q '<promise>NO MORE TASKS</promise>' "$tmpfile"; then
    echo "No more AFK tasks after $iteration iteration(s)"
    exit 0
  fi

  rm -f "$tmpfile"
done

echo "Reached max iterations ($MAX_ITERATIONS) before agent reported no more tasks"
