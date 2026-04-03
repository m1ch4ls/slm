#!/bin/bash
set -e

# Build script for llama.cpp with Flash Attention support
# Works on Linux and macOS, auto-detects available hardware

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_DIR="${SCRIPT_DIR}/llama.cpp"
BUILD_DIR="${LLAMA_DIR}/build"
INSTALL_PREFIX="${SCRIPT_DIR}/llama-install"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS=Linux;;
        Darwin*)    OS=macOS;;
        CYGWIN*|MINGW*|MSYS*) OS=Windows;;
        *)          OS="UNKNOWN:$(uname -s)"
    esac
    log_info "Detected OS: $OS"
}

# Detect CPU features
detect_cpu_features() {
    CPU_FLAGS=""
    if [ "$OS" = "Linux" ]; then
        if grep -q "avx512" /proc/cpuinfo 2>/dev/null; then
            CPU_FLAGS="$CPU_FLAGS -DGGML_AVX512=ON"
            log_info "CPU supports AVX-512"
        elif grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
            CPU_FLAGS="$CPU_FLAGS -DGGML_AVX2=ON"
            log_info "CPU supports AVX2"
        fi
    elif [ "$OS" = "macOS" ]; then
        # macOS uses system_profiler or sysctl
        if sysctl -a | grep -q "hw.optional.avx2" 2>/dev/null; then
            log_info "macOS detected"
        fi
    fi
}

# Detect NVIDIA GPU
detect_cuda() {
    if command -v nvcc &> /dev/null; then
        CUDA_VERSION=$(nvcc --version | grep "release" | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p')
        log_info "CUDA detected: version $CUDA_VERSION"
        
        # Check for compute capability
        if command -v nvidia-smi &> /dev/null; then
            GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
            log_info "NVIDIA GPU: $GPU_NAME"
        fi
        return 0
    else
        log_warn "CUDA not detected"
        return 1
    fi
}

# Detect AMD GPU (ROCm)
detect_rocm() {
    if [ "$OS" = "Linux" ] && command -v hipcc &> /dev/null; then
        log_info "ROCm/HIP detected"
        return 0
    else
        log_warn "ROCm not detected"
        return 1
    fi
}

# Detect Apple Silicon
detect_metal() {
    if [ "$OS" = "macOS" ]; then
        if [ "$(uname -m)" = "arm64" ]; then
            log_info "Apple Silicon detected - Metal will be enabled"
            return 0
        else
            log_info "Intel Mac detected - Metal available but CPU may be better"
            return 0
        fi
    fi
    return 1
}

# Detect Vulkan
detect_vulkan() {
    # Check for Vulkan headers - required for building
    if [ -f "/usr/include/vulkan/vulkan.h" ] || \
       [ -f "/usr/local/include/vulkan/vulkan.h" ] || \
       [ -f "/opt/homebrew/include/vulkan/vulkan.h" ] || \
       [ -f "$VULKAN_SDK/include/vulkan/vulkan.h" ]; then
        log_info "Vulkan SDK detected"
        return 0
    else
        log_warn "Vulkan SDK not detected (headers not found)"
        return 1
    fi
}

# Clone or update llama.cpp
setup_llama() {
    if [ ! -d "$LLAMA_DIR" ]; then
        log_info "Cloning llama.cpp repository..."
        git clone --recursive https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
    else
        log_info "Updating llama.cpp repository..."
        cd "$LLAMA_DIR"
        git pull --recurse-submodules
        cd "$SCRIPT_DIR"
    fi
}

# Build llama.cpp with detected backends
build_llama() {
    log_info "Configuring llama.cpp build..."
    
    # Base cmake flags
    CMAKE_FLAGS=(
        -S "$LLAMA_DIR"
        -B "$BUILD_DIR"
        -DCMAKE_BUILD_TYPE=Release
        -DBUILD_SHARED_LIBS=ON
        -DLLAMA_BUILD_TESTS=OFF
        -DLLAMA_BUILD_EXAMPLES=ON
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
    )
    
    # Flash Attention flags (enable for all GPU backends)
    CMAKE_FLAGS+=(
        -DGGML_CUDA_FA_ALL_QUANTS=ON
    )
    
    # Add CPU-specific flags
    CMAKE_FLAGS+=($CPU_FLAGS)
    
    # Detect and enable backends
    local backend_enabled=false
    
    # CUDA (NVIDIA)
    if detect_cuda; then
        CMAKE_FLAGS+=(
            -DGGML_CUDA=ON
            -DGGML_CUDA_FORCE_CUBLAS=OFF  # Use custom kernels for better Flash Attention
        )
        backend_enabled=true
        log_info "Enabling CUDA backend with Flash Attention"
    fi
    
    # ROCm/HIP (AMD)
    rocm_result=$(detect_rocm && echo "found" || echo "not_found")
    if [ "$rocm_result" = "found" ]; then
        CMAKE_FLAGS+=(-DGGML_HIP=ON)
        backend_enabled=true
        
        # Check if rocWMMA is available for Flash Attention
        if [ -f "/opt/rocm/include/rocwmma/rocwmma-version.hpp" ] || \
           [ -f "/usr/include/rocwmma/rocwmma-version.hpp" ]; then
            CMAKE_FLAGS+=(-DGGML_HIP_ROCWMMA_FATTN=ON)
            log_info "Enabling ROCm/HIP backend with Flash Attention"
        else
            log_info "Enabling ROCm/HIP backend (Flash Attention disabled - rocWMMA not found)"
        fi
    fi
    
    # Metal (Apple)
    if detect_metal; then
        CMAKE_FLAGS+=(-DGGML_METAL=ON)
        backend_enabled=true
        log_info "Enabling Metal backend (Flash Attention included by default)"
    fi
    
    # Vulkan (cross-platform GPU)
    if detect_vulkan; then
        CMAKE_FLAGS+=(-DGGML_VULKAN=ON)
        backend_enabled=true
        log_info "Enabling Vulkan backend"
    fi
    
    # BLAS (CPU acceleration)
    if [ "$OS" = "macOS" ]; then
        # Accelerate framework on macOS
        CMAKE_FLAGS+=(-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple)
        log_info "Enabling Apple Accelerate framework"
    elif [ "$OS" = "Linux" ]; then
        # Try to detect OpenBLAS or MKL
        if pkg-config --exists openblas 2>/dev/null || [ -f "/usr/lib/libopenblas.so" ] || [ -f "/usr/lib/x86_64-linux-gnu/libopenblas.so" ]; then
            CMAKE_FLAGS+=(-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS)
            log_info "Enabling OpenBLAS"
        fi
    fi
    
    # If no GPU backend detected, ensure CPU is optimized
    if [ "$backend_enabled" = false ]; then
        log_warn "No GPU backend detected. Building optimized CPU version."
        CMAKE_FLAGS+=(-DGGML_NATIVE=ON)
    fi
    
    # Print configuration
    log_info "CMake configuration:"
    printf '  %s\n' "${CMAKE_FLAGS[@]}"
    
    # Configure
    cmake "${CMAKE_FLAGS[@]}"
    
    # Build with parallel jobs
    local JOBS
    if command -v nproc &> /dev/null; then
        JOBS=$(nproc)
    elif command -v sysctl &> /dev/null; then
        JOBS=$(sysctl -n hw.ncpu)
    else
        JOBS=4
    fi
    
    log_info "Building llama.cpp with $JOBS parallel jobs..."
    cmake --build "$BUILD_DIR" --config Release --parallel "$JOBS"
    
    log_info "Build complete!"
}

# Install/copy libraries
install_llama() {
    log_info "Installing llama.cpp libraries to $INSTALL_PREFIX..."
    
    cmake --install "$BUILD_DIR" --prefix "$INSTALL_PREFIX"
    
    # Also copy any additional backend libraries
    mkdir -p "$INSTALL_PREFIX/lib"
    
    # Copy backend plugins if they exist
    if [ -d "$BUILD_DIR/bin" ]; then
        cp -v "$BUILD_DIR"/bin/libggml-*.so "$INSTALL_PREFIX/lib/" 2>/dev/null || true
        cp -v "$BUILD_DIR"/bin/libggml-*.dylib "$INSTALL_PREFIX/lib/" 2>/dev/null || true
    fi
    
    log_info "Libraries installed to: $INSTALL_PREFIX/lib"
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build llama.cpp with Flash Attention support for Linux/macOS

Options:
    -h, --help          Show this help message
    --clean             Clean build directory before building
    --prefix PATH       Set installation prefix (default: ./llama-install)
    --cuda              Force enable CUDA backend
    --rocm              Force enable ROCm/HIP backend
    --metal             Force enable Metal backend (macOS only)
    --vulkan            Force enable Vulkan backend
    --cpu-only          Build CPU-only version (no GPU backends)

Examples:
    $0                  Auto-detect and build all available backends
    $0 --cuda           Force CUDA build
    $0 --clean          Clean and rebuild
    $0 --prefix /usr    Install to /usr

EOF
}

# Parse arguments
CLEAN=false
FORCE_CUDA=false
FORCE_ROCM=false
FORCE_METAL=false
FORCE_VULKAN=false
CPU_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --prefix)
            INSTALL_PREFIX="$2"
            shift 2
            ;;
        --cuda)
            FORCE_CUDA=true
            shift
            ;;
        --rocm)
            FORCE_ROCM=true
            shift
            ;;
        --metal)
            FORCE_METAL=true
            shift
            ;;
        --vulkan)
            FORCE_VULKAN=true
            shift
            ;;
        --cpu-only)
            CPU_ONLY=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main
main() {
    log_info "=== llama.cpp Build Script ==="
    log_info "Platform: $(uname -a)"
    
    detect_os
    
    if [ "$CLEAN" = true ] && [ -d "$BUILD_DIR" ]; then
        log_info "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
    fi
    
    setup_llama
    detect_cpu_features
    build_llama
    install_llama
    
    log_info ""
    log_info "=== Build Complete ==="
    log_info "Installation prefix: $INSTALL_PREFIX"
    log_info "To use with your Zig build:"
    log_info "  zig build -Dllama_prefix=$INSTALL_PREFIX"
    log_info ""
    log_info "To verify Flash Attention is enabled:"
    log_info "  strings $INSTALL_PREFIX/lib/libggml.so | grep -i flash"
    log_info ""
    log_info "Available binaries:"
    ls -la "$BUILD_DIR/bin/"* 2>/dev/null | grep -E "(llama-cli|llama-server|\.so$|\.dylib$)" || true
}

main
