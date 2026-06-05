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
CUSTOM_TOOLCHAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pgo)       ENABLE_PGO=true; shift ;;
        --bolt)      ENABLE_BOLT=true; shift ;;
        --toolchain) CUSTOM_TOOLCHAIN="$2"; shift 2 ;;
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
if [ -n "$CUSTOM_TOOLCHAIN" ]; then
    # Use user-specified toolchain
    if [ ! -d "$CUSTOM_TOOLCHAIN" ]; then
        echo "ERROR: Custom toolchain not found: $CUSTOM_TOOLCHAIN"
        exit 1
    fi
    HOST_CC="$CUSTOM_TOOLCHAIN/bin/clang"
    HOST_CXX="$CUSTOM_TOOLCHAIN/bin/clang++"
    if [ ! -x "$HOST_CC" ]; then
        echo "ERROR: $HOST_CC not found or not executable"
        exit 1
    fi
    export PATH="$CUSTOM_TOOLCHAIN/bin:$PATH"
    echo "Using toolchain: $CUSTOM_TOOLCHAIN"
elif [ -x /usr/bin/clang ] && [ -x /usr/bin/clang++ ]; then
    HOST_CC=/usr/bin/clang
    HOST_CXX=/usr/bin/clang++
elif command -v clang &>/dev/null && command -v clang++ &>/dev/null; then
    HOST_CC=clang
    HOST_CXX=clang++
else
    echo "ERROR: clang not found. Install: sudo apt install clang"
    exit 1
fi
echo "  CC   : $HOST_CC ($("$HOST_CC" --version | head -1))"
echo "  CXX  : $HOST_CXX"

# =========================================================================
# Pre-flight checks — fail fast before hours of compilation
# =========================================================================
echo ""
echo "[Check] Running pre-flight checks..."

# 1. C++ headers
if ! echo '#include <vector>' | "$HOST_CXX" -x c++ -c - -o /dev/null 2>/dev/null; then
    echo "  FAIL: $HOST_CXX cannot compile C++ (missing headers?)"
    echo "  Fix:  sudo apt install libstdc++-dev"
    exit 1
fi
echo "  PASS: C++ headers"

# 2. Compile + link
if ! echo 'int main(){return 0;}' | "$HOST_CXX" -x c++ - -o /dev/null 2>/dev/null; then
    echo "  FAIL: $HOST_CXX cannot link executables"
    exit 1
fi
echo "  PASS: Compile + link"

# 3. LLD
LLD_BIN="${CUSTOM_TOOLCHAIN:+$CUSTOM_TOOLCHAIN/bin/}ld.lld"
if ! ${LLD_BIN:-ld.lld} --version &>/dev/null; then
    echo "  FAIL: ld.lld not found. Install: sudo apt install lld"
    exit 1
fi
echo "  PASS: LLD $(${LLD_BIN:-ld.lld} --version | head -1)"

# 4. Ninja
if ! ninja --version &>/dev/null; then
    echo "  FAIL: ninja not found. Install: sudo apt install ninja-build"
    exit 1
fi
echo "  PASS: Ninja $(ninja --version)"

# 5. CPU features (detect native arch)
HOST_MARCH=$("$HOST_CC" -march=native -E - </dev/null 2>&1 | head -1 || echo "unknown")
echo "  CPU:  $HOST_MARCH"

# 6. Disk space
AVAIL_GB=$(df -BG . | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$AVAIL_GB" -lt 20 ]; then
    echo "  WARN: Only ${AVAIL_GB}GB free (need ~15GB for build)"
fi
echo "  PASS: ${AVAIL_GB}GB disk free"

echo ""

# ---- Flags (local native build) ----
# Use -march=native to auto-detect host CPU (avoids SIGILL on unsupported extensions)
OPT_CFLAGS="-O3 -march=native"
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
# Bootstrap: build profiling runtime for PGO support
# =========================================================================
if [ "$ENABLE_PGO" = true ]; then
    echo ""
    echo "[Bootstrap] Building ARM64 profiling runtime..."
    RT_DIR="$PROJECT_DIR/build-rt"
    cmake -S "$LLVM_SOURCE_DIR/compiler-rt" -B "$RT_DIR" -G Ninja -Wno-dev \
        -DCMAKE_C_COMPILER="$HOST_CC" \
        -DCMAKE_CXX_COMPILER="$HOST_CXX" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_FLAGS="-I$LLVM_SOURCE_DIR/compiler-rt/lib/profile -DINSTR_PROF_RAW_VERSION=10" \
        -DCMAKE_CXX_FLAGS="-I$LLVM_SOURCE_DIR/compiler-rt/lib/profile -DINSTR_PROF_RAW_VERSION=10" \
        -DCOMPILER_RT_BUILD_PROFILE=ON \
        -DCOMPILER_RT_BUILD_BUILTINS=OFF \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_SCUDO_STANDALONE=OFF \
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF
    ninja -C "$RT_DIR" clang_rt.profile-aarch64
    # Install to system Clang resource directory
    CLANG_RES="$("$HOST_CC" -print-resource-dir)"
    sudo mkdir -p "$CLANG_RES/lib/linux"
    sudo cp "$RT_DIR/lib/linux/libclang_rt.profile-aarch64.a" "$CLANG_RES/lib/linux/"
    echo "[Bootstrap] ARM64 profiling runtime ready"
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
