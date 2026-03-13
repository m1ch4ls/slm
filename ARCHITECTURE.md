# SLM Daemon Architecture

## Overview

Replace the HTTP client/server architecture with a native Unix socket daemon. This eliminates token estimation errors, removes HTTP/SSE parsing complexity, and provides exact tokenization via llama.cpp's C API.

## Goals

- **Exact tokenization**: No estimation heuristics, use actual tokenizer
- **Zero user friction**: Auto-start daemon on first request, transparent restart on crash
- **Simpler protocol**: Length-prefixed binary instead of HTTP/JSON/SSE
- **Sequential processing**: One request at a time, no concurrency complexity
- **Single model**: Well-known location in config, no model switching

## Architecture

```
┌─────────────────┐         ┌─────────────────────┐
│   slm (CLI)     │◄───────►│    slm-daemon       │
│   - Thin client │  Unix   │    - Model loaded   │
│   - Auto-starts │  Socket │    - Exact tokenizer│
│     daemon      │         │    - Inference      │
└─────────────────┘         └─────────────────────┘
```

## Daemon Lifecycle

### Auto-Start Flow

1. Client tries to connect to `/run/user/UID/slm/daemon.sock`
2. If connection fails:
   - Clean up stale socket file if exists
   - Spawn `slm-daemon` process with `detach=true`
   - Write PID to `/run/user/UID/slm/daemon.pid`
   - Retry connection with timeout (max 5s for model load)
3. Once connected, send request

### Daemon Shutdown

- Handles `SIGTERM`/`SIGINT` for graceful shutdown
- Removes socket file on exit
- Client auto-restarts daemon if connection drops mid-stream

### Sequential Request Handling

- Daemon accepts **one connection at a time**
- Processes request completely before accepting next
- No queue, no concurrency, simple state machine

## Wire Protocol

### Request Format (Client → Daemon)

Binary, length-prefixed:

```
[u32: prompt_len] [u8[]: prompt_bytes]
[u32: stdin_len]  [u8[]: stdin_bytes]
[u32: max_tokens]
```

### Response Format (Daemon → Client)

Streaming tokens, length-prefixed:

```
[u16: token_len] [u8[]: token_bytes]  (repeated)
[u16: 0]                               (end marker)
```

### Why Length-Prefixed Binary?

- **Zero parsing overhead**: No JSON, no SSE, no escaping
- **Handles any content**: Newlines, quotes, binary data all work
- **Trivial implementation**: `std.io` primitives only
- **Language agnostic**: Simple enough for any client

## Tokenization Strategy

### Exact Token Count

```zig
// Get exact token count
fn countTokens(vocab, text) !usize {
    // llama_tokenize returns negative count if buffer too small
    const n = llama_tokenize(vocab, text, text.len, null, 0, true, true);
    return @intCast(-n);
}
```

### Binary Search Truncation

If input exceeds budget:

1. Binary search on character position
2. Tokenize substring at each midpoint
3. Find exact position that fits
4. No estimation, no guessing

## Directory Structure

```
token-saver/
├── src/
│   ├── main.zig          # CLI client (default mode)
│   ├── daemon.zig        # Daemon mode
│   ├── protocol.zig      # Wire format read/write
│   ├── llama_api.zig     # C bindings wrapper
│   └── tokenizer.zig     # Exact tokenization logic
├── build.zig
└── ARCHITECTURE.md       # This file

# Runtime files:
/run/user/UID/slm/
├── daemon.sock           # Unix socket
└── daemon.pid            # PID file for cleanup
```

## Implementation Phases

### Phase 1: Protocol & Client

- [ ] Define request/response structs
- [ ] Implement binary protocol (read/write)
- [ ] Client auto-start logic
- [ ] Daemon spawn wrapper

### Phase 2: Daemon Core

- [ ] llama.cpp C bindings
- [ ] Model loading at startup
- [ ] Socket server (sequential)
- [ ] Request handler skeleton

### Phase 3: Tokenization

- [ ] Exact token counting
- [ ] Binary search truncation
- [ ] Chat format tokenization
- [ ] Budget calculation

### Phase 4: Inference

- [ ] llama_decode() integration
- [ ] Token streaming to client
- [ ] Sampling parameters
- [ ] Stats tracking (optional)

### Phase 5: Polish

- [ ] Signal handling (SIGTERM)
- [ ] Error handling & recovery
- [ ] Logging
- [ ] Build system updates

## Build Configuration

```zig
// build.zig
const exe = b.addExecutable(.{
    .name = "slm",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// Link llama.cpp static library
exe.addIncludePath(b.path("llama.cpp/include"));
exe.addLibraryPath(b.path("llama.cpp/build/lib"));
exe.linkSystemLibrary("llama");
exe.linkLibC();
```

## Error Handling

### Client Side

| Error | Action |
|-------|--------|
| Connection refused | Start daemon, retry |
| Daemon timeout | Print error, exit |
| Broken pipe mid-stream | Restart daemon, retry request |
| Invalid response | Print error, exit |

### Daemon Side

| Error | Action |
|-------|--------|
| Model load fail | Exit with error code |
| Tokenization fail | Close connection, log, continue |
| Inference fail | Close connection, log, continue |
| Out of memory | Exit (system will restart on next request) |

## Comparison with HTTP Approach

| Aspect | HTTP Client/Server | Daemon |
|--------|-------------------|---------|
| Cold start | 5s (server start) | 5s (daemon start, same) |
| Hot latency | ~50ms HTTP overhead | ~2ms socket |
| Token accuracy | Estimated (heuristic) | Exact (C API) |
| Protocol | HTTP + JSON + SSE | Binary length-prefixed |
| Dependencies | External llama.cpp server | Self-contained |
| Code complexity | ~340 lines | ~280 lines (split: 80 client + 200 daemon) |
| Pathological inputs | Retry hell | Exact truncation |
| Concurrency | Server handles it | Sequential (simpler) |

## Open Questions

1. **Build integration**: Should we vendor llama.cpp or use system install?
2. **GPU support**: How to handle n_gpu_layers parameter?
3. **Context size**: Read from config or detect from model?
4. **Logging**: Client and daemon both log to stderr? Syslog?
5. **Multiple users**: Socket in /run/user/UID/ handles multi-user automatically

## Success Criteria

- [ ] `ps aux | slm 'find nodejs'` works without truncation errors
- [ ] Cold start < 6 seconds (model load)
- [ ] Hot request < 10ms overhead (socket + tokenization)
- [ ] Daemon restart is transparent to user
- [ ] No HTTP, no JSON parsing, no SSE
- [ ] Single binary: `slm` (client) and `slm-daemon` (auto-started)
