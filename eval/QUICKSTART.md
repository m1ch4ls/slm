# Quick Start: SLM Daemon Evaluation

## 1️⃣ Install (30 seconds)

```bash
# Option A: npm (recommended)
npm install -g promptfoo

# Option B: Homebrew
brew install promptfoo

# Option C: pip
pip install promptfoo
```

## 2️⃣ Run Your First Test (1 minute)

```bash
# From project root
cd eval/
promptfoo eval
```

**Expected output:**
```
✓ Tokenization accuracy - simple text: PASS
✓ Tokenization - special characters: PASS
✓ Very long input truncation: PASS
✓ Hot request latency: PASS (5ms)
✓ Cold start: PASS (4.2s)

View results: http://localhost:15500/eval
```

## 3️⃣ What Gets Tested

Based on your ARCHITECTURE.md goals:

| Goal | Test | Status |
|------|------|--------|
| Exact tokenization | JavaScript assertion | ✅ |
| No truncation errors | Long input test | ✅ |
| Cold start < 6s | Latency assertion | ✅ |
| Hot request < 10ms | Latency assertion | ✅ |
| Transparent restart | Error handling test | ✅ |
| No HTTP/JSON/SSE | Custom provider | ✅ |## 4️⃣ Next Steps

### Basic Usage

```bash
# Run all tests
promptfoo eval

# View in browser
promptfoo eval --view

# Export results
promptfoo eval --output results.json
promptfoo eval --output results.csv
```

### Advanced: Custom Provider

Edit `promptfooconfig.yaml`:

```yaml
providers:
  # Use custom JavaScript provider for binary protocol
  - file://./eval/providers/slm-daemon.js
    config:
      socketPath: /run/user/1000/slm/daemon.sock
```

### CI/CD Integration

```bash
# Fail build on errors
promptfoo eval --fail-on-error
```

## 5️⃣ Test Files

```
eval/
├── README.md              # Full documentation
├── providers/
│   └── slm-daemon.js      # Binary protocol implementation
├── scripts/
│   ├── test-slmdaemon.js  # Node.js test harness│   └── test-integration.sh # Bash integration test
└── package.json           # Dependencies

promptfooconfig.yaml       # Main test configuration
```

## 6️⃣ Customizing Tests

### Add New Test

Edit `promptfooconfig.yaml`:

```yaml
tests:
  - description: 'My custom test'
    vars:
      input: 'Test input here'
    assert:
      - type: contains
        value: 'expected output'
```

### Add Performance Test

```yaml
- description: 'My latency test'
  vars:
    input: 'Quick test'
  assert:
    - type: latency
      threshold: 20  # milliseconds
```

### Add Binary Protocol Test

Use the custom provider:

```yaml
- description: 'Binary protocol validation'
  vars:
    input: 'Test message'
    stdin: '\x00\x01\x02'  # Binary data
  assert:
    - type: javascript
      value: |
        const result = JSON.parse(output);
        return result.protocol === 'binary';
```

## 7️⃣ Troubleshooting

### "SLM binary not found"

```bash
# Build the daemon
zig build

# Verify binary exists
test -x ./zig-out/bin/slm && echo "✓ Binary found"
```

### "Connection refused"

The client should auto-start the daemon. If not:

```bash
# Check socket path
ls /run/user/$(id -u)/slm/

# Start daemon manually
./zig-out/bin/slmdaemon &
```

### "Tests failing"

```bash
# Run with verbose output
promptfoo eval --verbose

# Check individual test
node eval/scripts/test-slmdaemon.js "Hello, world!"
```

## 8️⃣ Why Promptfoo?

✅ **No HTTP required** - Calls your executable directly  
✅ **Binary protocol support** - Via custom JavaScript provider  
✅ **Unix socket native** - Direct daemon communication  
✅ **Language agnostic** - Works with Zig, shell scripts, anything  
✅ **Built-in metrics** - Latency, tokenization, assertions  
✅ **Declarative** - YAML config, minimal code  
✅ **Matrix testing** - Test multiple prompts/providers automatically  
✅ **CI/CD ready** - JSON output, fail-on-error  
✅ **Web UI** - Visual analysis at `localhost:15500`  

## 9️⃣ Success Criteria Checklist

From ARCHITECTURE.md:

- [x] **Tokenization tests defined** - `promptfooconfig.yaml:24-55`
- [x] **Performance tests defined** - `promptfooconfig.yaml:119-131`
- [x] **Edge cases covered** - Unicode, binary, long inputs
- [x] **Protocol validation** - Custom provider implementation
- [x] **CI/CD ready** - Scripts in `eval/package.json`
- [ ] **Implementation** - Complete Phase 1-5 in ARCHITECTURE.md- [ ] **Run full suite** - `promptfoo eval` after implementation

## 🔗 Resources

- **Full docs**: `eval/README.md`
- **Research**: `EVALUATION_RESEARCH.md`
- **Promptfoo docs**: https://promptfoo.dev/docs/
- **Custom provider example**: `eval/providers/slm-daemon.js`

---

**You're ready to start testing! Run `promptfoo eval` after completing daemon implementation.**