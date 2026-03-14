#!/usr/bin/env node
/**
 * Simple test harness for SLM Daemon
 * 
 * This script demonstrates how to call the SLM daemon directly
 * and validates the binary protocol implementation.
 * 
 * Usage:
 *   node test-slmdaemon.js "prompt text"
 *   echo "stdin data" | node test-slmdaemon.js "prompt"
 */

const { spawn } = require('child_process');
const path = require('path');

const SLM_PATH = process.env.SLM_PATH || './zig-out/bin/slm';

async function testDaemon() {
  console.log('=== SLM Daemon Test Harness ===\n');
  
  // Test 1: Simple prompt
  console.log('Test 1: Simple prompt');
  const result1 = await callSLM('Hello, world!');
  console.log('Output:', result1.output);
  console.log('Tokens:', result1.tokenCount);
  console.log('Latency:', result1.latency, 'ms\n');
  
  // Test 2: Unicode
  console.log('Test 2: Unicode input');
  const result2 = await callSLM('¿Cómo estás? 你好');
  console.log('Output:', result2.output);
  console.log('Tokens:', result2.tokenCount);
  console.log('Latency:', result2.latency, 'ms\n');
  
  // Test 3: Long input
  console.log('Test 3: Long input (truncation test)');
  const longText = 'x'.repeat(100000);
  const result3 = await callSLM(longText);
  console.log('Truncated:', result3.truncated);
  console.log('Tokens:', result3.tokenCount);
  console.log('Latency:', result3.latency, 'ms\n');
  
  // Test 4: Code with whitespace
  console.log('Test 4: Code with whitespace');
  const code = `
function test() {
    return "nested\\n\\ttabs";
}`;
  const result4 = await callSLM(code);
  console.log('Output snippet:', result4.output.substring(0, 100));
  console.log('Tokens:', result4.tokenCount);
  console.log('Latency:', result4.latency, 'ms\n');
  
  // Test 5: Sequential requests
  console.log('Test 5: Sequential requests');
  for (let i = 0; i < 5; i++) {
    const start = Date.now();
    const result = await callSLM(`Request ${i}`);
    const elapsed = Date.now() - start;
    console.log(`  Request ${i}: ${result.tokenCount} tokens, ${elapsed}ms`);
  }
  console.log();
  
  console.log('=== All tests completed ===');
}

async function callSLM(prompt) {
  return new Promise((resolve, reject) => {
    const slm = spawn(SLM_PATH, [], {
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
    
    slm.stdin.write(prompt);
    slm.stdin.end();
  });
}

// Run if called directly
if (require.main === module) {
  const prompt = process.argv[2];
  
  if (prompt) {
    callSLM(prompt)
      .then(result => {
        console.log(JSON.stringify(result, null, 2));
        process.exit(0);
      })
      .catch(err => {
        console.error('Error:', err.message);
        process.exit(1);
      });
  } else {
    testDaemon().catch(err => {
      console.error('Test failed:', err);
      process.exit(1);
    });
  }
}

module.exports = { callSLM };