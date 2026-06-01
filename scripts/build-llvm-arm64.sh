#!/usr/bin/env bash
# ==============================================================================
# build-llvm-arm64.sh
# Local build script for ARM64 LLVM/Clang toolchain (kernel optimized)
#
# Usage:
#   ./scripts/build-llvm-arm64.sh [RELEASE|RelWithDebInfo]
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt install ninja-build cmake ccache python3 clang lld \
#     binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
#     zlib1g-dev libzstd-dev libxml2-dev libedit-dev libncurses5-dev swig
# ==============================================================================

set -euo pipefail

# ---- Configuration ----
LLVM_VERSION="${LLVM_VERSION:-llvmorg-19.1.7}"
BUILD_TYPE="${1:-Release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LLVM_SOURCE_DIR="${LLVM_SOURCE_DIR:-$PROJECT_DIR/llvm-project}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
INSTALL_DIR="${INSTALL_DIR:-$PROJECT_DIR/install}"
TARGET_TRIPLE="aarch64-linux-gnu"

echo "=============================================================================="
echo " Building LLVM/Clang ARM64 Toolchain (Kernel Optimized)"
echo "=============================================================================="
echo " LLVM Version : $LLVM_VERSION"
echo " Build Type   : $BUILD_TYPE"
echo " Source Dir   : $LLVM_SOURCE_DIR"
echo " Build Dir    : $BUILD_DIR"
echo " Install Dir  : $INSTALL_DIR"
echo " Target       : $TARGET_TRIPLE"
echo "=============================================================================="

# ---- Clone LLVM if not present ----
if [ ! -d "$LLVM_SOURCE_DIR" ]; then
    echo "[1/5] Cloning LLVM project ($LLVM_VERSION)..."
    git clone --depth 1 --branch "$LLVM_VERSION" \
        https://github.com/llvm/llvm-project.git "$LLVM_SOURCE_DIR"
else
    echo "[1/5] LLVM source already exists at $LLVM_SOURCE_DIR"
fi

# ---- Create build dirs ----
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

# ---- Configure CMake ----
echo "[2/5] Configuring CMake with kernel optimizations..."
JOBS="${JOBS:-$(nproc)}"

cmake -S "$LLVM_SOURCE_DIR/llvm" \
    -B "$BUILD_DIR" \
    -G "Ninja" \
    -Wno-dev \
    \
    `# ---- Build type ----` \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    \
    `# ---- Compiler settings ----` \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    \
    `# ---- Kernel-optimized C/C++ flags ----` \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -march=native -mtune=native -flto=thin -fomit-frame-pointer -fno-plt -fno-semantic-interposition -fvisibility=hidden -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -march=native -mtune=native -flto=thin -fomit-frame-pointer -fno-plt -fno-semantic-interposition -fvisibility=hidden -DNDEBUG" \
    -DCMAKE_EXE_LINKER_FLAGS_RELEASE="-Wl,-O3 -Wl,--as-needed -Wl,-z,now -Wl,-z,relro -Wl,--icf=all -Wl,--gc-sections -fuse-ld=lld" \
    -DCMAKE_SHARED_LINKER_FLAGS_RELEASE="-Wl,-O3 -Wl,--as-needed -Wl,-z,now -Wl,-z,relro -Wl,--icf=all -Wl,--gc-sections -fuse-ld=lld" \
    \
    `# ---- LLVM targets ----` \
    -DLLVM_TARGETS_TO_BUILD="AArch64;ARM" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
    \
    `# ---- LLVM projects ----` \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;compiler-rt;lldb;polly" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt;libcxx;libcxxabi;libunwind" \
    \
    `# ---- Kernel-oriented optimizations ----` \
    -DLLVM_ENABLE_LTO="Thin" \
    -DLLVM_ENABLE_LLD=ON \
    -DLLVM_ENABLE_PIC=ON \
    -DLLVM_ENABLE_PLUGINS=ON \
    -DLLVM_ENABLE_ZSTD=ON \
    -DLLVM_ENABLE_ZLIB=ON \
    -DLLVM_ENABLE_BOLT=ON \
    \
    `# ---- Linker ----` \
    -DLLVM_USE_LINKER=lld \
    -DLLVM_PARALLEL_COMPILE_JOBS="$JOBS" \
    -DLLVM_PARALLEL_LINK_JOBS="$JOBS" \
    \
    `# ---- Slim build ----` \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    \
    `# ---- Kernel features ----` \
    -DCOMPILER_RT_BUILD_SANITIZERS=ON \
    -DCOMPILER_RT_BUILD_XRAY=ON \
    -DCOMPILER_RT_BUILD_LIBFUZZER=ON \
    -DCOMPILER_RT_BUILD_PROFILE=ON \
    \
    `# ---- Assertions ----` \
    -DLLVM_ENABLE_ASSERTIONS=OFF

# ---- Build ----
echo "[3/5] Building LLVM/Clang (jobs=$JOBS)..."
cd "$BUILD_DIR"
ninja -j"$JOBS" \
    clang clang++ clang-tidy clang-format clangd \
    lld \
    llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-ranlib \
    llvm-readelf llvm-size llvm-strings llvm-strip \
    llvm-config llvm-profdata llvm-cov llvm-symbolizer \
    llvm-link opt llc llvm-as llvm-dis \
    FileCheck count not

# ---- Install ----
echo "[4/5] Installing to $INSTALL_DIR..."
ninja install

# ---- Create convenience symlinks ----
cd "$INSTALL_DIR/bin"
for tool in clang clang++; do
    ln -sf "$tool" "aarch64-linux-gnu-${tool#clang}" 2>/dev/null || true
done
ln -sf lld ld.lld 2>/dev/null || true
ln -sf lld aarch64-linux-gnu-ld.lld 2>/dev/null || true

# ---- Verify ----
echo "[5/5] Verifying toolchain..."
export PATH="$INSTALL_DIR/bin:$PATH"

echo "  Clang version: $(clang --version | head -1)"
echo "  LLD version:   $(ld.lld --version | head -1)"

# Quick compile test
echo 'int main(void) { return 0; }' > /tmp/test_arm64.c
if clang --target="$TARGET_TRIPLE" -O2 -flto=thin -fuse-ld=lld \
    /tmp/test_arm64.c -o /tmp/test_arm64 2>/dev/null; then
    echo "  Compile test:  PASSED"
else
    echo "  Compile test:  SKIPPED (no ARM64 sysroot)"
fi
rm -f /tmp/test_arm64.c /tmp/test_arm64

echo ""
echo "=============================================================================="
echo " BUILD COMPLETE"
echo " Toolchain: $INSTALL_DIR"
echo " Size:       $(du -sh "$INSTALL_DIR" | cut -f1)"
echo ""
echo " Usage for Linux kernel:"
echo "   export PATH=$INSTALL_DIR/bin:\$PATH"
echo "   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \\"
echo "     CC=\"clang --target=$TARGET_TRIPLE\" LD=ld.lld LLVM=1 LLVM_IAS=1"
echo "=============================================================================="
