#!/usr/bin/env node
/**
 * Simple test harness for SLM Daemon
 * 
 * This script demonstrates how to call the SLM daemon directly
 * and validates the binary protocol implementation.
 * 
 * Usage:
 *   node test-slmdaemon.js "instructions" "input"
 *   echo "input data" | node test-slmdaemon.js "instructions"
 *   node test-slmdaemon.js --test (run full test suite)
 */

const { spawn } = require('child_process');
const path = require('path');

const SLM_PATH = process.env.SLM_PATH || './zig-out/bin/slm';

async function testDaemon() {
  console.log('=== SLM Daemon Test Harness ===\n');
  
  // Test 1: Simple instructions with no input
  console.log('Test 1: Simple instructions');
  const result1 = await callSLM('Hello, world!');
  console.log('Output:', result1.output);
  console.log('Tokens:', result1.tokenCount);
  console.log('Latency:', result1.latency, 'ms\n');
  
  // Test 2: Instructions with stdin input
  console.log('Test 2: Instructions with stdin input');
  const result2 = await callSLM('Summarize this:', 'This is a test document that needs to be summarized. It contains some important information about testing.');
  console.log('Output:', result2.output);
  console.log('Tokens:', result2.tokenCount);
  console.log('Latency:', result2.latency, 'ms\n');
  
  // Test 3: Unicode in both instructions and input
  console.log('Test 3: Unicode handling');
  const result3 = await callSLM('¿Cómo estás?', '你好 🎉');
  console.log('Output:', result3.output);
  console.log('Tokens:', result3.tokenCount);
  console.log('Latency:', result3.tokenCount, 'ms\n');
  
  // Test 4: Long input
  console.log('Test 4: Long input (truncation test)');
  const longInput = 'x'.repeat(100000);
  const result4 = await callSLM('Process:', longInput);
  console.log('Truncated:', result4.truncated);
  console.log('Tokens:', result4.tokenCount);
  console.log('Latency:', result4.latency, 'ms\n');
  
  // Test 5: Code with whitespace as input
  console.log('Test 5: Code with whitespace');
  const codeInput = `
function test() {
    return "nested\\n\\ttabs";
}`;
  const result5 = await callSLM('What does this code do?', codeInput);
  console.log('Output snippet:', result5.output.substring(0, 100));
  console.log('Tokens:', result5.tokenCount);
  console.log('Latency:', result5.latency, 'ms\n');
  
  // Test 6: Multiple sequential requests
  console.log('Test 6: Sequential requests');
  for (let i = 0; i < 5; i++) {
    const start = Date.now();
    const result = await callSLM(`Request ${i}`);
    const elapsed = Date.now() - start;
    console.log(`  Request ${i}: ${result.tokenCount} tokens, ${elapsed}ms`);
  }
  console.log();
  
  console.log('=== All tests completed ===');
}

/**
 * Call SLM with separate instructions and input
 * @param {string|string[]} instructions - Instructions as CLI arguments
 * @param {string} input - Input data sent via stdin
 */
async function callSLM(instructions, input = '') {
  return new Promise((resolve, reject) => {
    // Build args array from instructions
    let args = [];
    if (Array.isArray(instructions)) {
      args = instructions.map(String);
    } else if (typeof instructions === 'string' && instructions.trim()) {
      args = [instructions];
    }
    
    const slm = spawn(SLM_PATH, args, {
      timeout: 30000
    });
    
    let stdout = '';
    let stderr = '';
    const startTime = Date.now();
    
    slm.stdout.on('data', (data) => {
      stdout += data.toString();
    });
    
    slm.stderr.on('data', (data) => {
      stderr += data.toString();
    });
    
    slm.on('error', reject);
    
    slm.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`SLM exited with code ${code}: ${stderr}`));
        return;
      }
      
      try {
        const data = JSON.parse(stdout);
        resolve({
          output: data.output || data.response,
          tokenCount: data.tokenCount || 0,
          truncated: data.truncated || false,
          latency: Date.now() - startTime
        });
      } catch (e) {
        // Not JSON, return raw
        resolve({
          output: stdout,
          tokenCount: 0,
          truncated: false,
          latency: Date.now() - startTime
        });
      }
    });
    
    // Send input to stdin
    if (input && input.length > 0) {
      slm.stdin.write(input);
    }
    slm.stdin.end();
  });
}

// Run if called directly
if (require.main === module) {
  const args = process.argv.slice(2);
  
  // Check for test mode
  if (args.includes('--test') || args.length === 0) {
    testDaemon().catch(err => {
      console.error('Test failed:', err);
      process.exit(1);
    });
  } else {
    // Single call mode: instructions [input]
    const instructions = args[0];
    const input = args[1] || '';
    
    callSLM(instructions, input)
      .then(result => {
        console.log(JSON.stringify(result, null, 2));
        process.exit(0);
      })
      .catch(err => {
        console.error('Error:', err.message);
        process.exit(1);
      });
  }
}

module.exports = { callSLM };
