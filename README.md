# slm - Small Language Model CLI

A minimal CLI tool for piping command output to a local small language model.

## Usage

```bash
# Find errors in logs
cat application.log | slm "find all error messages"

# Extract specific data
ps aux | slm "list only the node processes"

# Summarize output
git diff | slm "summarize the changes in 3 bullet points"
```

## Setup

1. Build the CLI:
```bash
zig build -Drelease=true
```

2. Create config file:
```bash
mkdir -p ~/.config/slm
cat > ~/.config/slm/config << 'EOF'
model=/path/to/your/model.gguf
server_url=http://127.0.0.1:8080
context_size=32768
EOF
```

3. Start the llama.cpp server:
```bash
./server -m /path/to/your/model.gguf --port 8080 -c 32768
```

## Configuration

Config file format (`~/.config/slm/config`):
```
model=/path/to/model.gguf          # Required: path to GGUF model
server_url=http://127.0.0.1:8080   # Optional: server URL (default: http://127.0.0.1:8080)
context_size=32768                 # Optional: context size for reference
```

## Features

- **Zero external dependencies** - Pure Zig implementation, no curl or other tools needed
- **Native HTTP client** - Uses Zig's std.http.Client for direct communication
- **Streaming output** - Tokens appear as they're generated
- **Input truncation** - Large inputs are automatically truncated with a warning
- **Proper SSE parsing** - Handles server-sent events correctly
- **Fast startup** - Connects to already-running server, no model loading delay

## Requirements

- Zig 0.13.0 or later
- Running llama.cpp server with a compatible model (Qwen 0.5B-1B recommended)
- Linux or macOS

## Model Recommendations

- **Qwen/Qwen2.5-0.5B-Instruct** - Fast, good for extraction tasks
- **Qwen/Qwen2.5-1.5B-Instruct** - Better quality, still fast on modern hardware
- Any GGUF format model compatible with llama.cpp