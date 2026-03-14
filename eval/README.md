# SLM Daemon Evaluation Suite

Comprehensive testing framework for the SLM Daemon using `promptfoo`.

## Overview

This evaluation suite tests the SLM Daemon across multiple dimensions:

1. **Tokenization Accuracy** - Exact token counts via llama.cpp tokenizer
2. **Protocol Correctness** - Binary length-prefixed wire protocol
3. **Edge Cases** - Long inputs, unicode, binary data, empty strings
4. **Performance** - Hot/cold latency benchmarks
5. **Error Handling** - Graceful degradation and recovery

## Quick Start

```bash
# Install promptfoo (choose one)
npm install -g promptfoo
# or
brew install promptfoo
# or
pip install promptfoo

# Run basic evaluation
promptfoo eval

# Run with web UI for analysis
promptfoo eval --view
```

## Testing Approaches

### 1. Custom Script Provider (Simplest)

The `exec:` provider calls your SLM CLI directly:

```yaml
# promptfooconfig.yaml
providers:
  - 'exec:./zig-out/bin/slm'
```

**Pros:**
- Zero setup
- Tests actual CLI interface
- Works with binary protocol

**Cons:**
- Less control over protocol details
- Harder to inspect internal state

### 2. JavaScript Provider (Recommended)

The custom provider in `eval/providers/slm-daemon.js` gives full control:

```yaml
providers:
  - file://./eval/providers/slm-daemon.js
    config:
      daemonPath: ./zig-out/bin/slm
      socketPath: /run/user/1000/slm/daemon.sock
      timeout: 30000
```

**Pros:**
- Direct binary protocol testing
- Access to daemon metadata
- Fine-grained assertions

**Cons:**
- Requires Node.js
- More setup

### 3. Shell Script Integration

Run integration tests directly:

```bash
./eval/scripts/test-integration.sh
```

## Test Categories

### Tokenization Tests

Verify exact token counting:

```yaml
- description: 'Tokenization accuracy - simple text'
  vars:
    input: 'The quick brown fox'
  assert:
    - type: javascript
      value: 'const r = JSON.parse(output); return r.tokenCount > 0 && r.tokenCount < 10;'
```

### Edge Cases

Test pathological inputs:

```yaml
# Long input (50k+ chars)
- description: 'Very long input truncation'
  vars:
    input: 'x'.repeat(50000)
  assert:
    - type: javascript
      value: 'return output.includes("truncated") || output.includes("error") === false;'
```

### Performance Benchmarks

```yaml
# Hot request should be <10ms
- description: 'Hot request latency'
  vars:
    input: 'Quick response'
  assert:
    - type: latency
      threshold: 10  # milliseconds
```

### Unicode & Binary

```yaml
# Unicode normalization
- description: 'Unicode handling'
  vars:
    input: 'café e\u0301'  # é in two forms
  assert:
    - type: javascript
      value: 'return !output.includes("error");'
```

## Custom Metrics

Define SLM-specific metrics:

```yaml
derivedMetrics:
  - name: 'tokenization_accuracy'
    value: 'tokenization_correct / __count'
  
  - name: 'avg_latency_ms'
    value: 'latency_sum / __count'
```

## Binary Protocol Testing

To test the binary protocol directly (requires custom provider):

```javascript
// In eval/providers/slm-daemon.js
const result = await provider.callBinaryProtocol(
  'Hello',
  Buffer.from('stdin data'),
  512  // max_tokens
);
console.log(result.tokens);  // Array of token strings
```

## Matrix Testing

Test multiple prompts and variables:

```yaml
tests:
  - description: 'Multiple models'
    vars:
      input: 'Test prompt'
      model: ['tiny', 'small', 'medium']  # Test with different models
```

Promptfoo will create a matrix: `prompts × providers × test cases`

## CI/CD Integration

```yaml
# .github/workflows/eval.yml
- name: Run SLM Evaluation
  run: |
    npm install -g promptfoo
    
    # Build your daemon
    zig build
    
    # Run evaluation
    promptfoo eval --output results.json
    
    # Fail if tests don't pass
    promptfoo eval --fail-on-error
```

## Viewing Results

### Web UI

```bash
promptfoo eval --view
# Opens http://localhost:15500/eval
```

### JSON Output

```bash
promptfoo eval --output results.json
```

### CSV Export

```bash
promptfoo eval --output results.csv
```

## Advanced: Testing Daemon Lifecycle

### Test Auto-Start

```javascript
// Test that client auto-starts daemon when not running
assert: type: javascript
  value: |
    // Remove socket file
    fs.unlinkSync('/run/user/UID/slm/daemon.sock');
    
    // Make request - daemon should auto-start
    const result = await callSLM('test');
    
    // Verify daemon is now running
    const pid = fs.readFileSync('/run/user/UID/slm/daemon.pid');
    return pid !== null;
```

### Test Restart on Crash

```javascript
// Test recovery after daemon crash
assert: type: javascript
  value: |
    // Kill daemon
    const pid = getDaemonPid();
    process.kill(pid, 'SIGKILL');
    
    // Make request - client should restart
    const result = await callSLM('after crash');
    
    // Should work transparently
    return !result.error;
```

## Comparison: Promptfoo vs DeepEval vs Ragas

| Feature | Promptfoo | DeepEval | Ragas |
|---------|-----------|----------|-------|
| **Custom Providers** | ✅ Full control | ⚠️ Python-only | ❌ API-focused |
| **Binary Protocol** | ✅ Script/exec | ⚠️ Would need wrapper | ❌ No |
| **Unix Socket** | ✅ Direct support | ⚠️ Python wrapper | ❌ HTTP-only |
| **Declarative Tests** | ✅ YAML | ✅ Python | ✅ Python |
| **Matrix Testing** | ✅ Built-in | ⚠️ Manual | ❌ No |
| **CI/CD** | ✅ Native | ✅ pytest | ✅ pytest |
| **Latency Tests** | ✅ Built-in | ⚠️ Custom | ❌ No |
| **Best For** | **Unix daemons** | RAG apps | RAG pipelines |

**Recommendation:** **Promptfoo** is the best choice for SLM Daemon because:
1. Direct executable invocation (`exec:./slm`)
2. No HTTP layer required
3. First-class binary/support
4. Built-in performance testing
5. Simpler setup than Python frameworks

## Files Structure

```
eval/
├── providers/
│   └── slm-daemon.js          # Custom JavaScript provider
├── scripts/
│   ├── test-slmdaemon.js      # Node.js test harness
│   └── test-integration.sh    # Bash integration test
└── README.md                   # This file

promptfooconfig.yaml           # Main test configuration
```

## Troubleshooting

### "Connection refused"

```bash
# Check if daemon is running
ls -la /run/user/$(id -u)/slm/

# If not, the client should auto-start it
# Check SLM binary exists
test -x ./zig-out/bin/slm || zig build
```

### "Timeout error"

```yaml
# Increase timeout in config
providers:
  - file://./eval/providers/slm-daemon.js
    config:
      timeout: 60000  # 60 seconds
```

### "Binary protocol error"

```javascript
// Add debug logging to slm-daemon.js
console.error('Request:', request.toString('hex'));
console.error('Response:', responseBuffer.toString('hex'));
```

## Resources

- [Promptfoo Docs](https://promptfoo.dev/docs/)
- [Custom Providers](https://promptfoo.dev/docs/providers/custom-api/)
- [Assertions & Metrics](https://promptfoo.dev/docs/configuration/expected-outputs/)
- [ARCHITECTURE.md](../ARCHITECTURE.md) - SLM Daemon design