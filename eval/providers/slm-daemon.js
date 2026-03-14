/**
 * Custom promptfoo provider for SLM Daemon
 * 
 * This provider interfaces with the SLM daemon via Unix socket,
 * implementing the binary protocol defined in ARCHITECTURE.md
 * 
 * Usage in promptfooconfig.yaml:
 * providers:
 *   - file://./eval/providers/slm-daemon.js
 */

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

class SLMDaemonProvider {
  constructor(options = {}) {
    this.providerId = options.id || 'slm-daemon';
    this.config = {
      daemonPath: options.config?.daemonPath || './zig-out/bin/slm',
      socketPath: options.config?.socketPath || `/run/user/${process.getuid()}/slm/daemon.sock`,
      modelPath: options.config?.modelPath || null,
      timeout: options.config?.timeout || 30000,
      ...options.config
    };
  }

  id() {
    return this.providerId;
  }

  /**
   * Main API call method for promptfoo
   * @param {string} prompt - The prompt to send to SLM
   * @param {object} context - Test case context from promptfoo
   * @param {object} options - Provider options
   * @returns {Promise<ProviderResponse>}
   */
  async callApi(prompt, context, options) {
    const startTime = Date.now();
    
    try {
      // Check if we have stdin data from vars
      const stdinData = context?.vars?.stdin || '';
      
      // Execute SLM CLI
      const result = await this.executeSLM(prompt, stdinData, context);
      
      const latency = Date.now() - startTime;
      
      return {
        output: result.output,
        tokenUsage: {
          prompt: result.promptTokens || 0,
          completion: result.completionTokens || 0,
          total: result.totalTokens || 0
        },
        latency: latency,
        metadata: {
          daemonStarted: result.daemonStarted,
          truncated: result.truncated,
          tokenCount: result.tokenCount,
          protocol: 'binary-length-prefixed'
        }
      };
    } catch (error) {
      return {
        error: error.message,
        output: null,
        metadata: {
          errorType: error.constructor.name,
          latency: Date.now() - startTime
        }
      };
    }
  }

  /**
   * Execute the SLM CLI and capture output
   * @private
   */
  async executeSLM(prompt, stdinData, context) {
    return new Promise((resolve, reject) => {
      const args = [prompt];
      
      // Add model path if specified
      if (this.config.modelPath) {
        args.push('--model', this.config.modelPath);
      }
      
      // Spawn SLM process
      const slm = spawn(this.config.daemonPath, args, {
        timeout: this.config.timeout,
        stdio: ['pipe', 'pipe', 'pipe']
      });

      let stdout = '';
      let stderr = '';
      let jsonData = null;

      slm.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      slm.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      slm.on('error', (error) => {
        reject(new Error(`SLM process error: ${error.message}`));
      });

      slm.on('close', (code) => {
        if (code !== 0) {
          // Try to parse error from stderr
          const errorMsg = stderr || `SLM exited with code ${code}`;
          reject(new Error(errorMsg));
          return;
        }

        try {
          // Try to parse JSON output (if SLM outputs structured data)
          jsonData = JSON.parse(stdout);
          
          resolve({
            output: jsonData.response || jsonData.output || stdout,
            promptTokens: jsonData.prompt_tokens || jsonData.tokenCount || 0,
            completionTokens: jsonData.completion_tokens || 0,
            totalTokens: jsonData.total_tokens || jsonData.tokenCount || 0,
            tokenCount: jsonData.tokenCount,
            truncated: jsonData.truncated || false,
            daemonStarted: jsonData.daemon_started || false
          });
        } catch (e) {
          // If not JSON, return raw output
          resolve({
            output: stdout,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            truncated: false,
            daemonStarted: false
          });
        }
      });

      // Write stdin data if provided (for piped input)
      if (stdinData) {
        slm.stdin.write(stdinData);
      }
      
      slm.stdin.end();
    });
  }

  /**
   * Direct binary protocol interface (for advanced testing)
   * 
   * According to ARCHITECTURE.md, the binary protocol is:
   * Request:  [u32: prompt_len] [u8[]: prompt_bytes] [u32: stdin_len] [u8[]: stdin_bytes] [u32: max_tokens]
   * Response: [u16: token_len] [u8[]: token_bytes] (repeated) [u16: 0] (end marker)
   * 
   * @param {string} prompt - The prompt text
   * @param {Buffer} stdinBuffer - Binary stdin data
   * @param {number} maxTokens - Maximum tokens to generate
   * @returns {Promise<object>}
   */
  async callBinaryProtocol(prompt, stdinBuffer = Buffer.alloc(0), maxTokens = 512) {
    const net = require('net');
    
    return new Promise((resolve, reject) => {
      const socketPath = this.config.socketPath;
      const client = net.createConnection(socketPath);
      
      let responseBuffer = Buffer.alloc(0);
      
      client.on('error', (err) => {
        if (err.code === 'ENOENT' || err.code === 'ECONNREFUSED') {
          // Daemon not running - would need to start it
          reject(new Error('Daemon not running. Client should auto-start it.'));
        } else {
          reject(err);
        }
      });
      
      client.on('connect', () => {
        // Build binary request according to ARCHITECTURE.md
        const promptBuffer = Buffer.from(prompt, 'utf-8');
        const promptLen = Buffer.alloc(4);
        promptLen.writeUInt32LE(promptBuffer.length, 0);
        
        const stdinLen = Buffer.alloc(4);
        stdinLen.writeUInt32LE(stdinBuffer.length, 0);
        
        const maxTokensBuffer = Buffer.alloc(4);
        maxTokensBuffer.writeUInt32LE(maxTokens, 0);
        
        // Send: [prompt_len][prompt][stdin_len][stdin][max_tokens]
        const request = Buffer.concat([
          promptLen,
          promptBuffer,
          stdinLen,
          stdinBuffer,
          maxTokensBuffer
        ]);
        
        client.write(request);
      });
      
      client.on('data', (data) => {
        responseBuffer = Buffer.concat([responseBuffer, data]);
      });
      
      client.on('end', () => {
        // Parse response: [u16: token_len] [u8[]: token_bytes] ... [u16: 0]
        try {
          const tokens = [];
          let offset = 0;
          
          while (offset < responseBuffer.length) {
            const tokenLen = responseBuffer.readUInt16LE(offset);
            offset += 2;
            
            if (tokenLen === 0) {
              // End marker
              break;
            }
            
            const tokenBytes = responseBuffer.slice(offset, offset + tokenLen);
            offset += tokenLen;
            
            tokens.push(tokenBytes.toString('utf-8'));
          }
          
          resolve({
            tokens: tokens,
            outputText: tokens.join(''),
            tokenCount: tokens.length,
            protocol: 'binary'
          });
        } catch (err) {
          reject(new Error(`Failed to parse binary response: ${err.message}`));
        }
      });
      
      // Set timeout
      client.setTimeout(this.config.timeout);
      client.on('timeout', () => {
        client.destroy();
        reject(new Error('Connection timeout'));
      });
    });
  }
}

module.exports = SLMDaemonProvider;