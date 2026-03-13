#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_DIR="$SCRIPT_DIR/llama.cpp"
MODELS_DIR="$SCRIPT_DIR/models"
MODEL_REPO="unsloth/Qwen3.5-0.8B-GGUF"
MODEL_FILENAME="Qwen3.5-0.8B-Q6_K.gguf"
MODEL_PATH="$MODELS_DIR/$MODEL_FILENAME"

# GPU detection variables
GPU_TYPE="cpu"
CMAKE_GPU_FLAGS=""

# Function to detect GPU
 detect_gpu() {
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        GPU_TYPE="cuda"
        CMAKE_GPU_FLAGS="-DGGML_CUDA=ON"
        echo "NVIDIA GPU detected - will use CUDA acceleration"
    elif command -v rocm-smi &> /dev/null && rocm-smi &> /dev/null; then
        GPU_TYPE="hip"
        CMAKE_GPU_FLAGS="-DGGML_HIP=ON"
        echo "AMD GPU detected - will use ROCm/HIP acceleration"
    elif [ "$(uname)" = "Darwin" ] && system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Metal"; then
        GPU_TYPE="metal"
        CMAKE_GPU_FLAGS="-DGGML_METAL=ON"
        echo "Apple Silicon detected - will use Metal acceleration"
    else
        GPU_TYPE="cpu"
        CMAKE_GPU_FLAGS="-DGGML_CUDA=OFF -DGGML_HIPBLAS=OFF -DGGML_METAL=OFF"
        echo "No GPU detected - will use CPU only"
    fi
}

echo "=== Llama.cpp Server Setup and Run Script ==="

# Detect GPU before anything else
detect_gpu

# Function to check if rebuild is needed
check_rebuild_needed() {
    local build_info_file="$LLAMA_CPP_DIR/.build_config"
    
    if [ ! -f "$build_info_file" ]; then
        return 0  # Rebuild needed - no build info exists
    fi
    
    local last_gpu_type=$(cat "$build_info_file" 2>/dev/null || echo "none")
    if [ "$last_gpu_type" != "$GPU_TYPE" ]; then
        echo "GPU configuration changed (was: $last_gpu_type, now: $GPU_TYPE)"
        return 0  # Rebuild needed - GPU type changed
    fi
    
    return 1  # No rebuild needed
}

# Function to install/build llama.cpp
install_llama_cpp() {
    echo "Building llama.cpp with $GPU_TYPE support..."
    
    # Check if cmake is installed
    if ! command -v cmake &> /dev/null; then
        echo "Error: cmake is not installed. Please install it first."
        exit 1
    fi
    
    # Clone llama.cpp if not exists
    if [ ! -d "$LLAMA_CPP_DIR" ]; then
        echo "Cloning llama.cpp repository..."
        git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
    fi
    
    cd "$LLAMA_CPP_DIR"
    
    # Clean previous build if exists and rebuild needed
    if [ -d "build" ] && check_rebuild_needed; then
        echo "Cleaning previous build..."
        rm -rf build
    fi
    
    # Build llama.cpp with appropriate GPU support
    echo "Configuring with: $CMAKE_GPU_FLAGS"
    cmake -B build $CMAKE_GPU_FLAGS -DLLAMA_BUILD_SERVER=ON
    cmake --build build --config Release -j$(nproc)
    
    # Save build configuration
    echo "$GPU_TYPE" > "$LLAMA_CPP_DIR/.build_config"
    
    echo "llama.cpp built successfully with $GPU_TYPE support!"
}

# Function to download model
download_model() {
    echo "Downloading model from $MODEL_REPO..."
    
    mkdir -p "$MODELS_DIR"
    
    # Remove corrupted file if it exists
    if [ -f "$MODEL_PATH" ]; then
        rm -f "$MODEL_PATH"
    fi
    
    cd "$MODELS_DIR"
    
    # Try using huggingface-cli first (most reliable)
    if command -v huggingface-cli &> /dev/null; then
        echo "Using huggingface-cli to download model..."
        huggingface-cli download "$MODEL_REPO" "$MODEL_FILENAME" --local-dir . --local-dir-use-symlinks False
    # Try using wget/curl for direct download
    elif command -v wget &> /dev/null; then
        echo "Downloading with wget..."
        wget --show-progress -O "$MODEL_PATH" "https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILENAME"
    elif command -v curl &> /dev/null; then
        echo "Downloading with curl..."
        curl -# -L -o "$MODEL_PATH" "https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILENAME"
    else
        echo "Error: No download tool found (huggingface-cli, wget, or curl)"
        echo "Please install one of them or download the model manually from:"
        echo "https://huggingface.co/$MODEL_REPO"
        exit 1
    fi
    
    # Validate the downloaded file is a valid GGUF
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Error: Model download failed or file not found at $MODEL_PATH"
        exit 1
    fi
    
    # Check GGUF magic bytes
    MAGIC=$(head -c 4 "$MODEL_PATH")
    if [ "$MAGIC" != "GGUF" ]; then
        echo "Error: Downloaded file is not a valid GGUF model (wrong magic bytes)"
        echo "File may be corrupted or the model path is incorrect."
        echo "First 100 bytes of file:"
        head -c 100 "$MODEL_PATH"
        echo ""
        rm -f "$MODEL_PATH"
        exit 1
    fi
    
    echo "Model downloaded successfully!"
}

# Check if llama.cpp exists and if rebuild is needed
if [ ! -d "$LLAMA_CPP_DIR" ] || [ ! -f "$LLAMA_CPP_DIR/build/bin/llama-server" ] || check_rebuild_needed; then
    echo "llama.cpp server not found or needs rebuild. Building..."
    install_llama_cpp
else
    echo "llama.cpp found at $LLAMA_CPP_DIR (configured for $GPU_TYPE)"
fi

# Check if model exists
if [ ! -f "$MODEL_PATH" ]; then
    echo "Model not found at $MODEL_PATH"
    download_model
else
    echo "Model found at $MODEL_PATH"
fi

# Run llama server
echo ""
echo "=== Starting Llama Server ==="
echo "Model: $MODEL_FILENAME"
echo "Backend: $GPU_TYPE"
echo "Server will be available at http://localhost:9090"
echo ""

# For AMD GPUs, only use discrete GPU (avoid iGPU memory issues)
if [ "$GPU_TYPE" = "hip" ]; then
    export HIP_VISIBLE_DEVICES=0
    echo "Using discrete GPU only (HIP_VISIBLE_DEVICES=0)"
fi

"$LLAMA_CPP_DIR/build/bin/llama-server" \
    -m "$MODEL_PATH" \
    --host 127.0.0.1 \
    --port 9090 \
    -c 65536 \
    -n 512 \
    --timeout 300 \
    --temp 0.1 \
    --top-p 0.5 \
    --top-k 10 \
    --chat-template-kwargs '{"enable_thinking": false}'
