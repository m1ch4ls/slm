# slm - Small Language Model CLI

A minimal CLI tool with a client-daemon architecture for piping command output to a local small language model. The daemon loads models directly via llama.cpp's C API - no external server required.

## Claude Code Plugin

This repository also includes a **Claude Code plugin** that reminds Claude to use slm for text processing tasks, saving API tokens.

### Quick Install

```bash
# Add the marketplace
claude plugin marketplace add github:m1ch4ls/slm

# Install the plugin
claude plugin install slm-reminder@slm
```

See [Plugin Documentation](.claude/plugins/slm/README.md) for details.

## Architecture

- **slm** - Lightweight client that connects to the daemon via Unix domain socket
- **slm-daemon** - Background service that loads and runs the model using llama.cpp

The client automatically spawns the daemon if not running. The daemon stays resident for fast subsequent queries.

## Usage

```bash
# Find errors in logs
cat application.log | slm "find all error messages"

# Extract specific data
ps aux | slm "list only the node processes"

# Summarize output
git diff | slm "summarize the changes in 3 bullet points"

# Run benchmarks
slm-benchmark /path/to/model.gguf --prompt "What is 2+2?"
```

## Setup

1. Build both binaries:
```bash
zig build -Drelease=true
```

This creates `slm` (client) and `slm-daemon` (background service).

2. Create config file:
```bash
mkdir -p ~/.config/slm
cat > ~/.config/slm/config << 'EOF'
model=/path/to/your/model.gguf
EOF
```

3. Run (daemon auto-starts on first use):
```bash
# Just use it - daemon spawns automatically
echo "Hello world" | slm "translate to French"
```

## Configuration

Config file format (`~/.config/slm/config`):
```
model=/path/to/model.gguf              # Required: path to GGUF model
context_size=32768                     # Optional: context window size (default: 32768)
n_threads=4                            # Optional: CPU threads for inference (default: 4)
n_gpu_layers=-1                        # Optional: GPU layers (-1 = all, 0 = CPU only)
main_gpu=0                             # Optional: Which GPU to use (default: 0)
n_batch=2048                           # Optional: Batch size for inference (default: 2048)
flash_attn=true                        # Optional: Enable Flash Attention (default: true)
```

## Features

- **Daemon architecture** - Client stays lightweight, daemon handles model loading
- **Auto-spawn** - Daemon starts automatically when needed
- **Zero external dependencies** - Pure Zig + llama.cpp C API, no separate server
- **GPU acceleration** - CUDA/ROCm support via configurable GPU layers
- **Flash Attention** - Enabled by default for faster inference
- **Streaming output** - Tokens appear as they're generated
- **Think block filtering** - Automatically strips <think>...</think> reasoning blocks
- **Unix domain sockets** - Fast local IPC, no network overhead
- **Built-in benchmark tool** - `slm-benchmark` for performance testing

## Requirements

- Zig 0.13.0 or later
- llama.cpp libraries (libllama, libggml, libggml-base) - build from submodule or system
- Linux (uses `/run/user/{uid}/` for sockets)
- GGUF format model (Qwen 0.5B-1B recommended for speed)

## Building llama.cpp

If the libraries aren't available system-wide:

```bash
cd llama.cpp
mkdir build && cd build
cmake .. -DLLAMA_NATIVE=ON -DLLAMA_BACKEND_DL=ON -DBUILD_SHARED_LIBS=ON
make -j$(nproc)
```

## Model Recommendations

- **Qwen/Qwen2.5-0.5B-Instruct** - Fast, good for extraction tasks
- **Qwen/Qwen2.5-1.5B-Instruct** - Better quality, still fast on modern hardware
- Any GGUF format model compatible with llama.cpp

## Troubleshooting

**Daemon fails to start**: Check that llama.cpp libraries are in the expected path (same directory as binary or `../lib`)

**Socket errors**: The daemon uses `/run/user/{uid}/slm/daemon.sock` - ensure the directory exists and is writable

**GPU not used**: Set `n_gpu_layers=-1` in config to load all layers on GPU, or check `main_gpu` if you have multiple GPUs
