# slm-daemon

Lightweight local LLM inference daemon.

## Quick Start

```bash
./slm-daemon
```

Or run the binary directly:
```bash
LD_LIBRARY_PATH=./lib ./bin/slm-daemon
```

## Directory Structure

- `bin/` - Executable binaries
- `lib/` - Shared libraries and GPU backends
- `slm-daemon` - Convenience wrapper script

## GPU Backends

The daemon loads GPU backends dynamically from the `lib/` directory:

- `libggml-cpu.so` - CPU backend (always loaded)
- `libggml-hip.so` - AMD ROCm/HIP backend
- `libggml-cuda.so` - NVIDIA CUDA backend (not included in this build)
- `libggml-metal.so` - Apple Metal backend (macOS only)

Backends are loaded at runtime based on what's available on your system.

## Configuration

Create a config file at `~/.config/slm/config`:

```
model=/path/to/your/model.gguf
n_gpu_layers=-1
main_gpu=0
context_size=32768
n_threads=4
```

## Requirements

- AMD GPU: ROCm libraries must be installed on the system
- NVIDIA GPU: CUDA libraries must be installed on the system
- CPU: No additional requirements
