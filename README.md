# LLVM/Clang ARM64 编译链 Action

基于 GitHub Actions 自动构建面向 **ARM64 (AArch64)** 平台的 LLVM/Clang 编译工具链，针对 **Linux 内核编译** 进行了深度优化。

## ✨ 特性

| 特性 | 说明 |
|------|------|
| 🎯 **ARM64 专用** | 目标架构 AArch64，默认 triple `aarch64-linux-gnu` |
| ⚡ **ThinLTO** | 全工具链启用 ThinLTO 链接时优化，提升运行时性能 |
| 📊 **PGO** | 可选 PGO（Profile-Guided Optimization），用 Linux 内核编译作为训练负载 |
| 🔩 **BOLT** | 可选 BOLT 后链接优化器，进一步优化二进制布局 |
| 💾 **ccache** | 跨工作流运行的编译缓存，加速重复构建 |
| 🧪 **内核冒烟测试** | 自动用编译好的工具链构建 ARM64 Linux 内核验证可用性 |
| 📦 **Artifact** | 自动打包上传 `.tar.xz` 制品，可下载部署 |

## 🚀 快速开始

### 方式一：GitHub Actions（推荐）

1. 将本仓库推送到 GitHub
2. 进入 **Actions** → **Build LLVM/Clang Toolchain for ARM64**
3. 点击 **Run workflow**，按需配置参数
4. 等待构建完成，下载 artifact

### 方式二：本地构建

```bash
# 安装依赖 (Ubuntu 24.04)
sudo apt install -y ninja-build cmake ccache python3 clang lld \
  binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  zlib1g-dev libzstd-dev libxml2-dev libedit-dev libncurses5-dev swig

# 运行构建
bash scripts/build-llvm-arm64.sh Release
```

## 📋 工作流输入参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `llvm_version` | string | `llvmorg-19.1.7` | LLVM 版本标签 |
| `build_type` | choice | `Release` | 构建类型 (Release / RelWithDebInfo) |
| `enable_lto` | boolean | `true` | 启用 ThinLTO |
| `enable_pgo` | boolean | `true` | 启用 PGO 优化 |
| `enable_bolt` | boolean | `false` | 启用 BOLT 优化 |
| `upload_artifact` | boolean | `true` | 上传构建产物 |

## 🔧 内核编译优化详解

### ThinLTO（默认启用）
- 跨编译单元的链接时优化
- 相比 Full LTO，内存消耗更低，编译速度更快
- 工具链本身也使用 ThinLTO 编译

### PGO 训练
- 使用 Linux 6.6 内核编译作为训练工作负载
- 生成 `.profdata` 文件优化 Clang 的热路径
- 提升实际编译内核时的性能 10-20%

### 链接器优化
- 使用 `lld` 作为链接器（比 GNU ld 快 2-4x）
- 启用 `--icf=all`（相同代码折叠）
- 启用 `--gc-sections`（移除无用段）
- 启用 `-z now` + `-z relro`（安全加固 + 启动性能）

### C/C++ 编译优化
- `-O3` 高级优化级别
- `-march=native` / `-mtune=native` 针对构建机器 CPU 调优
- `-fomit-frame-pointer` 减少栈帧开销
- `-fno-plt` 减少 PLT 跳转
- `-fno-semantic-interposition` 禁止符号插入
- `-fvisibility=hidden` 默认隐藏符号

## 📁 输出结构

```
install/
├── bin/
│   ├── clang                    # C 编译器
│   ├── clang++                  # C++ 编译器
│   ├── aarch64-linux-gnu-clang  # ARM64 交叉编译 symlink
│   ├── aarch64-linux-gnu-clang++# ARM64 交叉编译 symlink
│   ├── ld.lld                   # LLD 链接器
│   ├── llvm-ar / llvm-nm / ...  # LLVM 二进制工具
│   └── ...
├── include/                     # 头文件
├── lib/                         # 库 + runtime
│   ├── clang/                   # Clang 资源
│   ├── libLLVM.so               # LLVM 共享库
│   └── linux/                   # compiler-rt builtins (aarch64)
├── share/                       # 文档 + 数据
└── toolchain-info.txt           # 构建信息
```

## 🐧 使用编译后的工具链编译 Linux 内核

```bash
# 设置环境变量
export PATH=/path/to/install/bin:$PATH

# 克隆内核
git clone --depth 1 --branch v6.6 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux

# 使用我们的工具链编译
make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CC="clang --target=aarch64-linux-gnu" \
  LD=ld.lld \
  LLVM=1 \
  LLVM_IAS=1 \
  defconfig

make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CC="clang --target=aarch64-linux-gnu" \
  LD=ld.lld \
  LLVM=1 \
  LLVM_IAS=1 \
  -j$(nproc) Image modules dtbs
```

## 📊 预计构建时间

| 触发方式 | 预计时间 |
|----------|----------|
| 首次构建（无 ccache） | ~90-150 分钟 |
| 缓存命中（ccache） | ~20-40 分钟 |
| 含 PGO 训练 | +10-15 分钟 |

> 💡 建议使用 GitHub Actions 的 `ubuntu-24.04-64core` 或更大 runner 以缩短构建时间。

## 📝 许可证

本仓库中的脚本遵循 MIT 许可证。LLVM/Clang 项目本身遵循 [Apache 2.0 with LLVM Exceptions](https://llvm.org/LICENSE.txt)。
