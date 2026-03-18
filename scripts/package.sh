#!/bin/bash
# Package slm-daemon for distribution

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
BUILD_DIR="$PROJECT_ROOT/llama.cpp/build"

# Clean and create dist structure
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/bin"
mkdir -p "$DIST_DIR/lib"

echo "Packaging slm-daemon..."

# Copy daemon binary
cp "$PROJECT_ROOT/zig-out/bin/slm-daemon" "$DIST_DIR/bin/"

# Copy client binary if it exists
if [ -f "$PROJECT_ROOT/zig-out/bin/slm" ]; then
    cp "$PROJECT_ROOT/zig-out/bin/slm" "$DIST_DIR/bin/"
fi

# Copy required shared libraries
echo "Copying llama.cpp libraries..."
cp "$BUILD_DIR/bin/libllama.so"* "$DIST_DIR/lib/"
cp "$BUILD_DIR/bin/libggml.so"* "$DIST_DIR/lib/"
cp "$BUILD_DIR/bin/libggml-base.so"* "$DIST_DIR/lib/"

# Copy CPU backend (always included)
echo "Copying CPU backend..."
cp "$BUILD_DIR/bin/libggml-cpu.so" "$DIST_DIR/lib/"

# Copy HIP backend if available
if [ -f "$BUILD_DIR/bin/libggml-hip.so" ]; then
    echo "Copying HIP backend..."
    cp "$BUILD_DIR/bin/libggml-hip.so" "$DIST_DIR/lib/"
fi

# Create wrapper script that sets up the environment
cat > "$DIST_DIR/slm-daemon" << 'EOF'
#!/bin/bash
# Wrapper script for slm-daemon
# Automatically finds the lib directory relative to this script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$SCRIPT_DIR/lib:$LD_LIBRARY_PATH"
exec "$SCRIPT_DIR/bin/slm-daemon" "$@"
EOF
chmod +x "$DIST_DIR/slm-daemon"

# Create README
cat > "$DIST_DIR/README.md" << 'EOF'
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
EOF

# Create tarball
VERSION="$(date +%Y%m%d)"
PACKAGE_NAME="slm-daemon-linux-amd64-${VERSION}.tar.gz"

echo "Creating tarball: $PACKAGE_NAME"
cd "$PROJECT_ROOT"
tar czf "$PACKAGE_NAME" -C "$DIST_DIR" .

echo ""
echo "Distribution package created: $PROJECT_ROOT/$PACKAGE_NAME"
echo ""
echo "Contents:"
ls -lh "$DIST_DIR"
echo ""
echo "To test: cd dist && ./slm-daemon"
