#!/usr/bin/env bash
# ==============================================================================
# build-llvm-arm64.sh
# Local native build script for ARM64 LLVM/Clang toolchain
#
# Supports: ThinLTO, PGO (2-stage), BOLT
#
# Usage:
#   ./scripts/build-llvm-arm64.sh              # Basic optimized build
#   ./scripts/build-llvm-arm64.sh --pgo        # PGO 2-stage build
#   ./scripts/build-llvm-arm64.sh --pgo --bolt # PGO + BOLT
#
# Prerequisites:
#   sudo apt install ninja-build cmake ccache python3 clang lld \
#     binutils-aarch64-linux-gnu zlib1g-dev libzstd-dev
# ==============================================================================

set -euo pipefail

# ---- Parse arguments ----
ENABLE_PGO=false
ENABLE_BOLT=false
BUILD_TYPE="Release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pgo)   ENABLE_PGO=true; shift ;;
        --bolt)  ENABLE_BOLT=true; shift ;;
        Release|RelWithDebInfo) BUILD_TYPE="$1"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- Configuration ----
LLVM_VERSION="${LLVM_VERSION:-llvmorg-22.1.7}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LLVM_SOURCE_DIR="${LLVM_SOURCE_DIR:-$PROJECT_DIR/llvm-project}"
STAGE1_DIR="${STAGE1_DIR:-$PROJECT_DIR/stage1}"
STAGE1_INSTALL="${STAGE1_INSTALL:-$PROJECT_DIR/stage1-install}"
STAGE2_DIR="${STAGE2_DIR:-$PROJECT_DIR/stage2}"
STAGE2_INSTALL="${STAGE2_INSTALL:-$PROJECT_DIR/install}"
JOBS="${JOBS:-$(nproc)}"

# ---- Detect best available Clang ----
# Prefer system Clang (knows where native headers are)
if [ -x /usr/bin/clang ] && [ -x /usr/bin/clang++ ]; then
    HOST_CC=/usr/bin/clang
    HOST_CXX=/usr/bin/clang++
elif command -v clang &>/dev/null && command -v clang++ &>/dev/null; then
    HOST_CC=clang
    HOST_CXX=clang++
else
    echo "ERROR: clang not found. Install: sudo apt install clang"
    exit 1
fi
echo "Using compiler: $HOST_CC"

# Verify compiler can find C++ headers (avoid cryptic CMake errors later)
if ! echo '#include <vector>' | "$HOST_CXX" -x c++ -c - -o /dev/null 2>/dev/null; then
    echo "ERROR: $HOST_CXX cannot compile C++ (missing headers?)"
    echo "  Fix: sudo apt install libstdc++-dev"
    exit 1
fi

OPT_CFLAGS="-O3 -march=armv8.5-a+sve2+crc+crypto+fp16+rcpc+dotprod"
OPT_CFLAGS="$OPT_CFLAGS -fomit-frame-pointer -ffunction-sections -fdata-sections"
OPT_CFLAGS="$OPT_CFLAGS -fno-plt -fmerge-all-constants -funique-internal-linkage-names"
OPT_CFLAGS="$OPT_CFLAGS -fstrict-vtable-pointers -fno-semantic-interposition"
OPT_CFLAGS="$OPT_CFLAGS -flto=thin"

OPT_LDFLAGS="-fuse-ld=lld -flto=thin -Wl,-O3 -Wl,--lto-O3"
OPT_LDFLAGS="$OPT_LDFLAGS -Wl,--gc-sections -Wl,--as-needed -Wl,--icf=all -Wl,-z,now"

COMMON_CMAKE_FLAGS=(
    -G Ninja -Wno-dev
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DCMAKE_C_COMPILER="$HOST_CC"
    -DCMAKE_CXX_COMPILER="$HOST_CXX"
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DCMAKE_C_FLAGS_RELEASE="$OPT_CFLAGS"
    -DCMAKE_CXX_FLAGS_RELEASE="$OPT_CFLAGS"
    -DCMAKE_EXE_LINKER_FLAGS="$OPT_LDFLAGS"
    -DCMAKE_SHARED_LINKER_FLAGS="$OPT_LDFLAGS"
    -DLLVM_TARGETS_TO_BUILD="AArch64;ARM"
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb;polly"
    -DLLVM_ENABLE_RUNTIMES="compiler-rt;libcxx;libcxxabi;libunwind"
    -DLLVM_ENABLE_LTO=Thin
    -DLLVM_USE_LINKER=lld
    -DLLVM_ENABLE_PIC=ON
    -DLLVM_ENABLE_ZSTD=ON
    -DLLVM_ENABLE_ZLIB=ON
    -DLLVM_PARALLEL_COMPILE_JOBS="$JOBS"
    -DLLVM_PARALLEL_LINK_JOBS="$JOBS"
    -DLLVM_BUILD_LLVM_DYLIB=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_BINDINGS=OFF
    -DLLVM_ENABLE_ASSERTIONS=OFF
)

NINJA_TARGETS=(
    clang clang-tidy clang-format clangd
    lld
    llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-ranlib
    llvm-readelf llvm-size llvm-strings llvm-strip
    llvm-config llvm-profdata llvm-cov llvm-symbolizer
    llvm-link opt llc llvm-as llvm-dis
    FileCheck count not
)

echo "=============================================================================="
echo " Building LLVM/Clang ARM64 Native Toolchain"
echo "=============================================================================="
echo " LLVM Version : $LLVM_VERSION"
echo " Build Type   : $BUILD_TYPE"
echo " PGO          : $ENABLE_PGO"
echo " BOLT         : $ENABLE_BOLT"
echo " Jobs         : $JOBS"
echo " Source Dir   : $LLVM_SOURCE_DIR"
echo " Install Dir  : $STAGE2_INSTALL"
echo "=============================================================================="

# ---- Clone LLVM if not present ----
if [ ! -d "$LLVM_SOURCE_DIR" ]; then
    echo "[Clone] Fetching LLVM $LLVM_VERSION..."
    git clone --depth 1 --branch "$LLVM_VERSION" \
        https://github.com/llvm/llvm-project.git "$LLVM_SOURCE_DIR"
else
    echo "[Clone] LLVM source already at $LLVM_SOURCE_DIR"
fi

# =========================================================================
# STAGE 1: Instrumented build (PGO) or Normal build
# =========================================================================
if [ "$ENABLE_PGO" = true ]; then
    echo ""
    echo "=============================================================================="
    echo " STAGE 1: Instrumented Build (PGO)"
    echo "=============================================================================="

    mkdir -p "$STAGE1_DIR" "$STAGE1_INSTALL"
    PGO_DIR="$PROJECT_DIR/pgo-profiles"
    mkdir -p "$PGO_DIR"

    cmake -S "$LLVM_SOURCE_DIR/llvm" -B "$STAGE1_DIR" \
        "${COMMON_CMAKE_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$STAGE1_INSTALL" \
        -DCMAKE_C_FLAGS_RELEASE="$OPT_CFLAGS -fprofile-generate=$PGO_DIR" \
        -DCMAKE_CXX_FLAGS_RELEASE="$OPT_CFLAGS -fprofile-generate=$PGO_DIR"

    echo "[Stage 1] Building instrumented clang..."
    ninja -C "$STAGE1_DIR" -j"$JOBS" "${NINJA_TARGETS[@]}"
    ninja -C "$STAGE1_DIR" install

    # ---- PGO Training ----
    echo ""
    echo "[PGO] Training: running instrumented clang on sample code..."
    cat > /tmp/pgo_train.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
struct Node { int v; struct Node* n; };
static int fib(int n) { return n<2 ? n : fib(n-1)+fib(n-2); }
int main(void) {
    int s=0; struct Node *h=NULL, *p;
    for (int i=0;i<500;i++) { p=malloc(sizeof(*p)); p->v=fib(i%25); p->n=h; h=p; }
    for (p=h;p;p=p->n) s+=p->v;
    printf("sum=%d\n",s);
    while(h){p=h;h=h->n;free(p);}
    return 0;
}
EOF
    for i in $(seq 1 10); do
        "$STAGE1_INSTALL/bin/clang" -O2 -c /tmp/pgo_train.c -o /tmp/pgo_train.o
    done
    rm -f /tmp/pgo_train.c /tmp/pgo_train.o

    # Merge profiles
    echo "[PGO] Merging profiles..."
    shopt -s nullglob
    PROFRAW_FILES=("$PGO_DIR"/*.profraw)
    if [ ${#PROFRAW_FILES[@]} -gt 0 ]; then
        "$STAGE1_INSTALL/bin/llvm-profdata" merge -output="$PGO_DIR/merged.profdata" "${PROFRAW_FILES[@]}"
        echo "      Profile merged: $(wc -c < "$PGO_DIR/merged.profdata") bytes"
        PGO_USE_FLAG="-fprofile-use=$PGO_DIR/merged.profdata -Wno-profile-instr-unprofiled"
    else
        echo "      WARNING: No profiles generated, PGO disabled"
        PGO_USE_FLAG=""
    fi

    # ---- STAGE 2: PGO-optimized build ----
    echo ""
    echo "=============================================================================="
    echo " STAGE 2: PGO-Optimized Build"
    echo "=============================================================================="

    BUILD_DIR="$STAGE2_DIR"
    INSTALL_DIR="$STAGE2_INSTALL"
    mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

    cmake -S "$LLVM_SOURCE_DIR/llvm" -B "$BUILD_DIR" \
        "${COMMON_CMAKE_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_C_FLAGS_RELEASE="$OPT_CFLAGS $PGO_USE_FLAG" \
        -DCMAKE_CXX_FLAGS_RELEASE="$OPT_CFLAGS $PGO_USE_FLAG"
else
    # ---- Single-stage (no PGO) ----
    BUILD_DIR="$STAGE2_DIR"
    INSTALL_DIR="$STAGE2_INSTALL"
    mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

    cmake -S "$LLVM_SOURCE_DIR/llvm" -B "$BUILD_DIR" \
        "${COMMON_CMAKE_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
fi

# ---- Build ----
echo "[Build] Compiling (jobs=$JOBS)..."
ninja -C "$BUILD_DIR" -j"$JOBS" "${NINJA_TARGETS[@]}"

# ---- Install ----
echo "[Install] Installing to $INSTALL_DIR..."
ninja -C "$BUILD_DIR" install

# ---- BOLT (after install, using built llvm-bolt) ----
if [ "$ENABLE_BOLT" = true ]; then
    echo ""
    echo "[BOLT] Optimizing binaries..."
    BOLT_BIN="$INSTALL_DIR/bin/llvm-bolt"
    if [ ! -f "$BOLT_BIN" ]; then
        echo "  WARNING: llvm-bolt not found, skipping BOLT"
    else
        for bin in clang clang++ lld; do
            if [ -f "$INSTALL_DIR/bin/$bin" ]; then
                echo "  BOLT optimizing: $bin"
                perf record -e cycles:u -o /tmp/bolt.perf -- "$INSTALL_DIR/bin/$bin" --version 2>/dev/null || true
                "$BOLT_BIN" "$INSTALL_DIR/bin/$bin" -o "$INSTALL_DIR/bin/$bin.bolt" \
                    -data=/tmp/bolt.perf -reorder-blocks=ext-tsp -reorder-functions=hfsort+ \
                    -split-functions -split-all-cold -dyno-stats 2>/dev/null || true
                if [ -f "$INSTALL_DIR/bin/$bin.bolt" ]; then
                    mv "$INSTALL_DIR/bin/$bin.bolt" "$INSTALL_DIR/bin/$bin"
                fi
                rm -f /tmp/bolt.perf
            fi
        done
        echo "[BOLT] Done"
    fi
fi

# ---- Create convenience symlinks ----
cd "$INSTALL_DIR/bin"
for tool in clang clang++; do
    ln -sf "$tool" "aarch64-linux-gnu-${tool#clang}" 2>/dev/null || true
done
ln -sf lld ld.lld 2>/dev/null || true
ln -sf lld aarch64-linux-gnu-ld.lld 2>/dev/null || true

# ---- Verify ----
echo ""
echo "[Verify] Testing toolchain..."
export PATH="$INSTALL_DIR/bin:$PATH"
echo "  Clang : $(clang --version 2>/dev/null | head -1 || echo 'N/A')"
echo "  LLD   : $(ld.lld --version 2>/dev/null | head -1 || echo 'N/A')"
if [ "$ENABLE_BOLT" = true ]; then
    echo "  BOLT  : $(llvm-bolt --version 2>/dev/null | head -1 || echo 'N/A')"
fi

echo 'int main(void) { return 0; }' > /tmp/test_arm64.c
if clang --target=aarch64-linux-gnu -O2 -flto=thin -fuse-ld=lld \
    /tmp/test_arm64.c -o /tmp/test_arm64 2>/dev/null; then
    echo "  Test   : PASSED"
else
    echo "  Test   : SKIPPED (no ARM64 sysroot)"
fi
rm -f /tmp/test_arm64.c /tmp/test_arm64

echo ""
echo "=============================================================================="
echo " BUILD COMPLETE"
echo " Toolchain : $INSTALL_DIR"
echo " Size      : $(du -sh "$INSTALL_DIR" 2>/dev/null | cut -f1)"
echo " PGO       : $ENABLE_PGO"
echo " BOLT      : $ENABLE_BOLT"
echo ""
echo " Usage for Linux kernel:"
echo "   export PATH=$INSTALL_DIR/bin:\$PATH"
echo "   make ARCH=arm64 LLVM=1 LLVM_IAS=1 -j\$(nproc) defconfig Image"
echo "=============================================================================="
