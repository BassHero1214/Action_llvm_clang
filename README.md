# LLVM/Clang 原生 ARM64 编译链

基于 GitHub Actions 交叉编译 + 本地 PGO/BOLT 双模式，产出最高优化的 **ARM64 (AArch64)** LLVM/Clang 工具链。

## 🔧 两种构建方式

| | CI (Actions) | 本地脚本 |
|---|---|---|
| 编译方式 | x86_64 → ARM64 交叉编译 | 本地原生 ARM64 |
| LTO | ✅ ThinLTO | ✅ ThinLTO |
| PGO | ⚠️ QEMU 不支持 prof 写入 | ✅ 真实 PGO 两阶段 |
| BOLT | ❌ 需 ARM64 真机 | ✅ 支持 |
| 编译器 | Clang 18 + LLD | Clang (自举) + LLD |

## ✨ 优化清单

### 编译优化

| 标志 | 作用 |
|------|------|
| `-O3` | 最高级别优化 |
| `-march=armv8.5-a+sve2+crc+crypto+fp16+rcpc+dotprod` | ARMv8.5 + 全指令扩展 |
| `-flto=thin` | 跨模块 ThinLTO |
| `-fomit-frame-pointer` | 释放帧指针寄存器 |
| `-ffunction-sections -fdata-sections` | 分段编译，配合链接器 GC |
| `-fno-plt` | 跳过 PLT 间接跳转 |
| `-fmerge-all-constants` | 合并重复常量 |
| `-funique-internal-linkage-names` | 内链符号唯一化，增强 LTO |
| `-fstrict-vtable-pointers` | 虚表指针优化 |
| `-fno-semantic-interposition` | 禁止符号插入 |

### 链接优化

| 标志 | 作用 |
|------|------|
| `-fuse-ld=lld` | LLD 多线程链接 |
| `-Wl,-O3 -Wl,--lto-O3` | 链接器 + LTO 最高优化 |
| `-Wl,--gc-sections` | 丢弃未使用段 |
| `-Wl,--as-needed` | 消除冗余依赖 |
| `-Wl,--icf=all` | 合并相同函数体 |
| `-Wl,-z,now` | Full RELRO |
| `-Wl,--thinlto-cache-dir` | ThinLTO 增量缓存 |

## 🚀 使用

```bash
# ARM64 设备上
tar -xJf llvm-clang-arm64-native-*.tar.xz -C /opt/llvm/
export PATH=/opt/llvm/bin:$PATH
make ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) defconfig Image
```

## 📋 CI 工作流参数

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `llvm_version` | string | `llvmorg-22.1.7` | LLVM 版本 |
| `build_type` | choice | `Release` | Release / RelWithDebInfo |
| `runner` | choice | `ubuntu-24.04` | 4/8/16 核 |
| `enable_lto` | boolean | `true` | Clang ThinLTO |
| `enable_pgo` | boolean | `false` | PGO（CI 中 QEMU 不支持，优雅降级） |
| `quick_test` | boolean | `false` | 仅编译 1 文件验证标志 |
| `upload_artifact` | boolean | `true` | 上传产物 |

## 🖥️ 本地脚本

```bash
# 基础构建
./scripts/build-llvm-arm64.sh

# 完整优化（PGO + BOLT）
./scripts/build-llvm-arm64.sh --pgo --bolt

# 自定义版本
LLVM_VERSION=llvmorg-22.1.7 ./scripts/build-llvm-arm64.sh --pgo
```

本地脚本支持真正的两阶段 PGO（插桩 → 训练 → 重编译）和 BOLT 二进制后优化。

## 📊 PGO / BOLT 状态

| 优化 | CI (Actions) | 本地脚本 |
|------|-------------|----------|
| PGO | ⚠️ 优雅降级（QEMU 不生成 `.profraw`） | ✅ 两阶段真机 PGO |
| BOLT | ❌ 需 ARM64 硬件 | ✅ 支持 |
| ThinLTO | ✅ Clang + LLD | ✅ 原生自举 |

## ⏱️ 构建时间

| 场景 | CI (Actions) | 本地 (PGO) |
|------|-------------|------------|
| 首次（无缓存） | ~3-4h | ~2h + 训练 + ~2h |
| ccache 命中 | ~15min | ~15min |
| Stage 1 缓存 | ~1.5h (仅 Stage 2) | N/A |

## 🏗️ 产物

| 项目 | 大小 |
|------|------|
| `.tar.xz` 压缩包 | ~150MB |
| 解压后 | ~1GB |
| 包含 | clang, clang++, lld, llvm-ar, llvm-nm, llvm-objcopy, llvm-objdump, llvm-ranlib, llvm-readelf, llvm-size, llvm-strings, llvm-strip |
