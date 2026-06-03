# LLVM/Clang 原生 ARM64 编译链 Action

基于 GitHub Actions 交叉编译 **原生 ARM64 (AArch64)** LLVM/Clang 工具链。产物为 ARM64 ELF 二进制，部署到 ARM64 设备直接编译内核。

## ✨ 特性

| 特性 | 说明 |
|------|------|
| 🎯 **原生 ARM64** | 产出 ARM64 ELF，运行在 ARM64 Linux 设备 |
| ⚡ **-O3 + 段GC** | 高级优化 + `--gc-sections` 体积优化 |
| 📦 **compiler-rt** | sanitizers / xray / profile |
| 💾 **ccache** | 首次 ~2h，后续 ~12min |
| 🔗 **共享库** | `LLVM_BUILD_LLVM_DYLIB` 减小体积 |
| 📦 **Artifact** | ~153MB `.tar.xz` / ~967MB 解压 |
| 🔄 **自动取消** | `concurrency` 新跑自动取消旧跑 |

## 🚀 使用

```bash
# ARM64 设备上
tar -xJf llvm-clang-arm64-native-*.tar.xz -C /opt/llvm/
export PATH=/opt/llvm/bin:$PATH
make ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) defconfig Image
```

## 📋 工作流参数

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `llvm_version` | string | `llvmorg-19.1.7` | LLVM 版本 |
| `build_type` | choice | `Release` | Release / RelWithDebInfo |
| `runner` | choice | `ubuntu-24.04` | 4/8/16 核 |
| `enable_lto` | boolean | `false` | GCC LTO（交叉编译不推荐） |
| `enable_pgo` | boolean | `false` | **预留，未实现** |
| `enable_bolt` | boolean | `false` | **预留，未实现** |
| `upload_artifact` | boolean | `true` | 上传产物 |

## 📊 PGO / BOLT / LTO 状态

| 优化 | 状态 | 原因 |
|------|------|------|
| PGO | ❌ | 需两阶段构建（插桩→训练→重编译），CI 成本过高 |
| BOLT | ❌ | 需后链接优化 ARM64 二进制，交叉编译链不支持 |
| ThinLTO | ❌ | 需 Clang，Ubuntu ARM64 sysroot 下 Clang+LLD 有链接兼容问题 |
| GCC LTO | ⚠️ | `-flto` 导致静态库膨胀（1.39G vs 967M），不推荐 |

## ⏱️ 构建时间

| 场景 | 耗时 |
|------|------|
| 首次（无缓存） | ~2h |
| ccache 命中 | ~12min |
| 全缓存命中 | ~3min |
