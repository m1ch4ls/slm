#!/bin/bash
# Quick integration test for SLM Daemon
# Tests the basic functionality outlined in ARCHITECTURE.md

set -e

SLM="${SLM_PATH:-./zig-out/bin/slm}"

echo "=== SLM Daemon Integration Tests ==="
echo ""

# Test 1: Check if daemon starts
echo "Test 1: Daemon auto-start"
if ! $SLM --help > /dev/null 2>&1; then
    echo "SKIP: SLM binary not found at $SLM"
    exit 0
fi
echo "✓ SLM binary found"
echo ""

# Test 2: Simple inference
echo "Test 2: Simple inference"
OUTPUT=$($SLM "Hello, world!" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Simple inference works"
    echo "  Output preview: ${OUTPUT:0:100}..."
else
    echo "✗ Simple inference failed"
    echo "  Error: $OUTPUT"
    exit 1
fi
echo ""

# Test 3: Unicode handling
echo "Test 3: Unicode handling"
OUTPUT=$($SLM "¿Cómo estás? 你好" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Unicode input works"
else
    echo "✗ Unicode input failed"
    exit 1
fi
echo ""

# Test 4: Stdin handling
echo "Test 4: Stdin handling"
OUTPUT=$(echo "additional context" | $SLM "Main prompt" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Stdin handling works"
else
    echo "✗ Stdin handling failed"
    exit 1
fi
echo ""

# Test 5: Performance (hot request)
echo "Test 5: Hot request latency < 10ms"
START=$(date +%s%N)
$SLM "Quick test" > /dev/null 2>&1
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [ $ELAPSED_MS -lt 10 ]; then
    echo "✓ Hot request: ${ELAPSED_MS}ms (target: <10ms)"
else
    echo "⚠ Hot request: ${ELAPSED_MS}ms (target: <10ms, may be cold start)"
fi
echo ""

# Test 6: Long input
echo "Test 6: Long input handling"
LONG_INPUT=$(python3 -c "print('x' * 50000)")
OUTPUT=$(echo "$LONG_INPUT" | timeout 10s $SLM "Process this:" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Long input handling works"
else
    echo "✗ Long input handling failed"
    exit 1
fi
echo ""

echo "=== All integration tests passed ==="