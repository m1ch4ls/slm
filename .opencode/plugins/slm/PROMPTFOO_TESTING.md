# OpenCode SLM Plugin - Promptfoo Testing Guide

This guide shows how to test the SLM plugin using [promptfoo](https://promptfoo.dev/) with the OpenCode SDK provider.

## Overview

Your SLM plugin has two behaviors to test:
1. **System Prompt Injection** - Injects SLM instructions into the system prompt
2. **Large Output Detection** - Reminds about slm when bash outputs exceed 1KB

## Installation

```bash
# Install promptfoo globally
npm install -g promptfoo

# Or use npx
npx promptfoo@latest
```

## Project Structure

```
.opencode/plugins/slm/
├── slm.ts                    # Plugin source
├── SLM_INSTRUCTIONS.md       # Instructions file
├── promptfoo/
│   ├── promptfooconfig.yaml  # Main test configuration
│   ├── tests/
│   │   ├── test-system-prompt.yaml
│   │   └── test-large-output.yaml
│   └── fixtures/
│       └── test-project/     # Isolated test workspace
│           ├── README.md
│           └── src/
│               └── example.ts
```

## Basic Configuration

### 1. Simple System Prompt Test

Create `promptfoo/promptfooconfig.yaml`:

```yaml
# Test that SLM instructions are injected into system prompt
description: "SLM Plugin - System Prompt Injection Tests"

prompts:
  - "List all files in the current directory"

providers:
  - id: opencode:sdk
    config:
      # Auto-start OpenCode server with plugin loaded
      provider_id: anthropic
      model: claude-sonnet-4-20250514
      
      # Working directory with plugin
      working_dir: ./fixtures/test-project
      
      # Enable file tools for the test
      tools:
        read: true
        grep: true
        glob: true
        list: true
        bash: true
      
      # Load the plugin
      # The plugin must be installed in the test environment
      mcp:
        slm-plugin:
          type: local
          command: ['bun', 'run', '../../slm.ts']
          enabled: true

tests:
  - description: "Verify system prompt contains SLM instructions"
    assert:
      # Check that the response acknowledges slm capability
      - type: contains
        value: "slm"
        # This checks if slm is mentioned in the conversation
```

### 2. Testing with Custom Agent Configuration

For more control, configure a custom agent that loads your plugin:

```yaml
providers:
  - id: opencode:sdk
    config:
      provider_id: anthropic
      model: claude-sonnet-4-20250514
      working_dir: ./fixtures/test-project
      
      custom_agent:
        description: "Test agent with SLM plugin"
        mode: primary
        model: claude-sonnet-4-20250514
        tools:
          read: true
          bash: true
          grep: true
        permission:
          bash: allow
          edit: deny
          external_directory: deny
        # Plugin is loaded via the server config
        # You need to ensure the plugin is available in the test environment
```

## Test Scenarios

### Scenario 1: System Prompt Injection

Create `promptfoo/tests/test-system-prompt.yaml`:

```yaml
description: "Test SLM instructions in system prompt"

prompts:
  - "What are your instructions for using slm?"
  - "How should I process large text outputs?"

providers:
  - id: opencode:sdk
    config:
      provider_id: anthropic
      model: claude-sonnet-4-20250514
      working_dir: ./fixtures/test-project
      tools:
        read: true
      persist_sessions: true  # Reuse session to check context

tests:
  - description: "SLM instructions are present in system context"
    assert:
      - type: contains
        value: "slm"
      - type: contains  
        value: "local small language model"
      - type: contains
        value: "summarize"
      
  - description: "Plugin explains when to use slm"
    assert:
      - type: contains
        value: "summarizing"
      - type: contains
        value: "extracting"
      - type: llm-rubric
        value: "The response explains that slm should be used for simple text processing tasks like summarizing command output"
```

### Scenario 2: Large Output Detection

Create `promptfoo/tests/test-large-output.yaml`:

```yaml
description: "Test large bash output triggers slm reminder"

prompts:
  # This prompt should trigger a large output (>1KB)
  - |
    Run this command and tell me what you see:
    ```bash
    for i in {1..100}; do echo "Line $i: This is a test line with some content to make it longer"; done
    ```

providers:
  - id: opencode:sdk
    config:
      provider_id: anthropic
      model: claude-sonnet-4-20250514
      working_dir: ./fixtures/test-project
      tools:
        bash: true
        read: true
      permission:
        bash: allow
      persist_sessions: true

tests:
  - description: "Large output triggers slm suggestion"
    assert:
      - type: contains
        value: "slm"
      - type: contains
        value: "pipe"
      - type: llm-rubric
        value: "The response suggests using 'slm' to process or summarize the large output instead of displaying it all"
      - type: cost
        threshold: 0.10  # Ensure we're not wasting tokens on large outputs
```

### Scenario 3: Model Comparison

Test how different models handle the SLM instructions:

```yaml
description: "Compare SLM plugin behavior across models"

prompts:
  - "Generate a large output and process it efficiently"

providers:
  # Test with Anthropic
  - id: opencode:sdk
    config:
      provider_id: anthropic
      model: claude-sonnet-4-20250514
      working_dir: ./fixtures/test-project
      
  # Test with OpenAI
  - id: opencode:sdk
    config:
      provider_id: openai
      model: gpt-4o-mini
      working_dir: ./fixtures/test-project
      
  # Test with local model via Ollama
  - id: opencode:sdk
    config:
      provider_id: ollama
      model: llama3
      working_dir: ./fixtures/test-project

tests:
  - description: "All models respect SLM instructions"
    assert:
      - type: contains
        value: "slm"
      - type: cost
        threshold: 0.05
```

## Running Tests

```bash
# Run all tests
cd promptfoo
promptfoo eval

# Run specific test file
promptfoo eval -c tests/test-system-prompt.yaml

# Run with verbose output
promptfoo eval --verbose

# Run with specific provider
promptfoo eval --providers opencode:sdk

# View results
promptfoo view
```

## Advanced: Testing Plugin Hooks Directly

For more precise testing, you can test the plugin's behavior programmatically:

```typescript
// promptfoo/tests/plugin-hook-test.ts
import { createOpencode } from "@opencode-ai/sdk";
import { SlmPlugin } from "../../slm";

async function testSystemPromptHook() {
  const opencode = await createOpencode({
    hostname: "127.0.0.1",
    port: 4097, // Unique port for isolation
    config: {
      model: "anthropic/claude-3-5-sonnet",
    },
  });

  // Load the plugin
  const plugin = await SlmPlugin({
    client: opencode.client,
    directory: process.cwd(),
  });

  // Test the system transform hook
  const input = { system: [] };
  const output = { system: [] };
  
  await plugin["experimental.chat.system.transform"](input, output);
  
  // Assert system prompt was modified
  console.assert(
    output.system.some(s => s.text?.includes("slm")),
    "System prompt should contain slm instructions"
  );

  await opencode.server.close();
}

testSystemPromptHook();
```

## Testing Strategy Summary

| Test Type | What It Tests | How |
|-----------|---------------|-----|
| **System Prompt** | Instructions injected correctly | Ask about slm usage |
| **Large Output** | 1KB threshold triggers reminder | Generate large output |
| **Model Comparison** | Different models handle plugin | Run same test across providers |
| **Cost Threshold** | Plugin saves tokens | Assert on token cost |
| **Hook Direct** | Plugin logic works | Programmatic hook testing |

## Key Configuration Options

| Option | Purpose | Example |
|--------|---------|---------|
| `working_dir` | Isolated test environment | `./fixtures/test-project` |
| `tools.bash` | Enable bash commands | `true` |
| `permission.bash` | Allow/deny bash | `allow` / `ask` / `deny` |
| `persist_sessions` | Reuse session across tests | `true` / `false` |
| `mcp` | Load MCP servers/plugins | See MCP config |
| `provider_id` | Which LLM provider | `anthropic`, `openai`, `ollama` |
| `model` | Specific model to use | `claude-sonnet-4-20250514` |

## CI/CD Integration

```yaml
# .github/workflows/test-plugin.yml
name: Test SLM Plugin

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Node
        uses: actions/setup-node@v3
        with:
          node-version: '20'
      
      - name: Install OpenCode CLI
        run: curl -fsSL https://opencode.ai/install | bash
      
      - name: Install Dependencies
        run: npm install -g promptfoo
      
      - name: Run Plugin Tests
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          cd .opencode/plugins/slm/promptfoo
          promptfoo eval
```

## Tips

1. **Use `persist_sessions: true`** when you need context to carry between prompts
2. **Set `external_directory: deny`** for security in CI/CD
3. **Use cost assertions** to verify the plugin actually saves tokens
4. **Start with small models** (gpt-4o-mini) for faster/cheaper iteration
5. **Use temporary directories** - promptfoo cleans up automatically
6. **Test negative cases** - Verify the plugin doesn't fire on small outputs

## Troubleshooting

**Plugin not loading?**
- Ensure the plugin path is correct relative to the working directory
- Check that dependencies are installed (`bun install`)

**Server not starting?**
- Check port availability (default 4096)
- Verify OpenCode CLI is installed

**Tests timing out?**
- Increase timeout: `timeout: 60000` in provider config
- Use smaller models for faster responses

## Next Steps

1. Create the test fixtures directory
2. Write your first `promptfooconfig.yaml`
3. Run `promptfoo eval` to validate setup
4. Add assertions for your specific use cases
5. Integrate with CI/CD for automated testing
