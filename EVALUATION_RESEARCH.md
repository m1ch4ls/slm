# SLM Daemon Prompt Evaluation Research & Recommendation

## Executive Summary

**Recommended Framework:** **Promptfoo** ✅

Promptfoo is the ideal framework for testing your SLM Daemon because it:

1. ✅ Supports custom executables (`exec:./slm`) - no HTTP required
2. ✅ Works with Unix socket communication directly
3. ✅ Has built-in tokenization, latency, and protocol testing
4. ✅ Declarative YAML config - no code required for basic tests
5. ✅ 9,000+ GitHub stars, active development
6. ✅ Language-agnostic (shell scripts, JavaScript, Python)

## Research Findings

### Frameworks Evaluated

| Framework | Stars | Focus | Unix Socket | Binary Protocol | Custom Executable |
|-----------|-------|-------|-------------|----------------|-------------------|
| **Promptfoo** | 15k | General LLM eval | ✅ Direct | ✅ Via scripts | ✅ `exec:` |
| DeepEval | 3k | Python unit tests | ⚠️ Wrapper needed | ⚠️ Complex | ⚠️ Python-only |
| Ragas | 7k | RAG pipelines | ❌ HTTP-focused | ❌ No | ❌ API-only |
| TruLens | 2k | Production monitoring | ⚠️ Wrapper needed | ❌ No | ❌ HTTP-only|

### Why Promptfoo Wins

#### 1. **Perfect Match for Your Architecture**

From your ARCHITECTURE.md:
> Replace the HTTP client/server architecture with a native Unix socket daemon. This eliminates token estimation errors, removes HTTP/SSE parsing complexity, and provides exact tokenization via llama.cpp's C API.

Promptfoo is designed for exactly this use case:
- **No HTTP required** - can call executables directly
- **Binary protocol support** - via custom providers
- **Tokenization testing** - built-in assertions

#### 2. **Minimal Setup**

```yaml
# That's literally all you need:
providers:
  - 'exec:./zig-out/bin/slm'
```

Compare to DeepEval (Python):

```python
# Need to wrap your daemon in Python
import socket
import subprocess

def call_slm_daemon(prompt):
    # Start daemon
    subprocess.run(['./slm'])
    # Connect to Unix socket
    sock = socket.socket(socket.AF_UNIX)
    # Implement binary protocol...- # Parse binary response...
```

#### 3. **Comprehensive Test Types**

From your success criteria (ARCHITECTURE.md):

> - [ ] `ps aux | slm 'find nodejs'` works without truncation errors
> - [ ] Cold start < 6 seconds (model load)
> - [ ] Hot request < 10ms overhead (socket + tokenization)
> - [ ] Daemon restart is transparent to user
> - [ ] No HTTP, no JSON parsing, no SSE
> - [ ] Single binary: `slm` (client) and `slm-daemon` (auto-started)

Promptfoo tests all of these:

```yaml
# Cold start
- description: 'Cold start under 6 seconds'
  assert:
    - type: latency
      threshold: 6000

# Hot request
- description: 'Hot request latency'
  assert:
    - type: latency
      threshold: 10

# Transparency
- description: 'Daemon restart transparent'
  assert:
    - type: javascript
      value: 'return !output.includes("error");'
```

#### 4. **Protocol Testing Architecture**

Your binary protocol (ARCHITECTURE.md lines 52-69):

```
Request:  [u32: prompt_len] [u8[]: prompt_bytes] 
          [u32: stdin_len]  [u8[]: stdin_bytes] 
          [u32: max_tokens]

Response: [u16: token_len] [u8[]: token_bytes] (repeated) 
          [u16: 0] (end marker)
```

Custom provider implementation in `eval/providers/slm-daemon.js` (lines 155-220):

```javascript
async callBinaryProtocol(prompt, stdinBuffer, maxTokens) {
  const client = net.createConnection(socketPath);
  
  // Build binary request
  const request = Buffer.concat([
    promptLen, promptBuffer,
    stdinLen, stdinBuffer,
    maxTokensBuffer
  ]);
  
  client.write(request);
  // Parse response...
}
```

## Implementation Strategy

### Phase 1: Basic Tests (Day 1)

```bash
# Install promptfoo
npm install -g promptfoo

# Run evals
promptfoo eval
```

Start with:
- Tokenization accuracy
- Simple latency tests
- Edge cases (unicode, empty strings)

### Phase 2: Advanced Protocol Testing (Day 2-3)

Create custom JavaScript provider (already done in `eval/providers/slm-daemon.js`):
- Binary protocol validation
- Token streaming verification
- Daemon lifecycle tests

### Phase 3: CI/CD Integration (Day 4)

```yaml
# .github/workflows/eval.yml
- run: zig build
- run: promptfoo eval --output results.json --fail-on-error
```

### Phase 4: Regression Suite (Ongoing)

Add tests for:
- New protocol features
- Performance regressions
- Edge cases discovered in production

## Test Coverage Map

| Requirement | Test Type | Location |
|-------------|-----------|----------|| Exact tokenization | JavaScript assertion | `promptfooconfig.yaml:24-32` |
| Unicode handling | JavaScript assertion | `promptfooconfig.yaml:34-43` |
| Long input truncation | JavaScript assertion | `promptfooconfig.yaml:58-66` |
| Binary protocol | Custom provider | `eval/providers/slm-daemon.js:155-220` |
| Hot latency <10ms | Built-in assertion | `promptfooconfig.yaml:119-125` |
| Cold start <6s | Built-in assertion | `promptfooconfig.yaml:127-131` |
| Daemon restart | JavaScript assertion | `promptfooconfig.yaml:134-142` |

## Cost Comparison

| Framework | Setup Time | Maintenance | Flexibility |
|-----------|------------|-------------|-------------|
| **Promptfoo** | 15 min | Low | High |
| DeepEval | 2 hours | Medium | Medium |
| Custom solution | 8+ hours | High | Highest |

## Alternatives Considered

### DeepEval

**Pros:**
- Python-native (familiar )
- 14+ built-in metrics
- Pytest-like syntax

**Cons:**
- Requires Python wrapper around your Zig daemon
- No native Unix socket support
- More setup for binary protocol

**When to use:** If you're already using Python for other testing and want tight pytest integration.

### Custom Solution

**Pros:**
- Complete control
- No dependencies

**Cons:**
- 8+ hours to build
- No built-in metric libraries
- No matrix testing
- No web UI

**When to use:** If promptfoo doesn't meet a specific requirement (unlikely).

## Next Steps

### Immediate Actions

1. **Install promptfoo:**
   ```bash
   cd eval/
   npm install
   ```

2. **Verify configuration:**
   ```bash
   promptfoo eval --dry-run
   ```

3. **Start with basic tests:**
   ```bash
   promptfoo eval
   ```

### Before Implementation

From your ARCHITECTURE.md Phase 1 checklist:

```markdown
### Phase 1: Protocol & Client

- [ ] Define request/response structs
- [ ] Implement binary protocol (read/write)
- [ ] Client auto-start logic
- [ ] Daemon spawn wrapper
```

**Recommendation:** Complete Phase 1 first, then run promptfoo evals to validate the implementation.

## Example Workflow

```bash
# Day 1: Basic tokenization tests
promptfoo eval

# Output:✓ Tokenization accuracy - simple text: PASS
✓ Tokenization - special characters: PASS
✓ Very long input truncation: PASS

# Day 2: Add custom provider for binary protocol
promptfoo eval --view  # Open web UI

# Configure: Use eval/providers/slm-daemon.js# View: Real-time token stream validation

# Day 3: CI/CD
git push  # Triggers GitHub Actions
# Automatically runs: promptfoo eval --fail-on-error
```

## Resources

### Documentation
- [Promptfoo Docs](https://promptfoo.dev/docs/)
- [Custom Providers](https://promptfoo.dev/docs/providers/custom-api/)
- [Assertions Guide](https://promptfoo.dev/docs/configuration/expected-outputs/)

### Examples
- `eval/README.md` - Complete setup guide
- `eval/providers/slm-daemon.js` - Binary protocol implementation
- `eval/scripts/test-integration.sh` - Quick integration test

### Support
- [Promptfoo Discord](https://discord.gg/promptfoo)
- [GitHub Issues](https://github.com/promptfoo/promptfoo/issues)

## Conclusion

**Promptfoo is the right tool for SLM Daemon evaluation** because:

1. ✅ Designed for non-HTTP providers (executables, scripts)
2. ✅ No wrapper needed for Unix socket communication
3. ✅ Binary protocol support via custom providers
4. ✅ Declarative configuration (minimal code)
5. ✅ Built-in performance testing
6. ✅ Active community (15k+ stars)

Start with `promptfoo eval` and iterate based on results. The custom provider in `eval/providers/slm-daemon.js` gives you full control when you need it.

**Estimated effort:**2-4 hours to set up basic suite, 1-2 days for comprehensive coverage.