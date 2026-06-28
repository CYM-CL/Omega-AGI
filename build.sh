#!/bin/bash
# ============================================================
# Ω-落尘AGI 统一构建脚本
# 针对Apple M3芯片ARM64架构极致优化
# ============================================================
set -e

# 项目根目录
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

echo "============================================================"
echo "Ω-落尘AGI 构建脚本 - M3芯片ARM64极致优化"
echo "============================================================"

# ============================================================
# 1. 编译Rust种子核（针对M3优化）
# ============================================================
echo ""
echo "[1/3] 编译Rust种子核（M3优化）..."
cd seed-kernel

# M3芯片专属RUSTFLAGS
# -C target-cpu=apple-m3: 针对M3微架构
# -C target-feature=+neon: NEON SIMD向量化
# -C link-args=-flto: 链接时优化
export RUSTFLAGS="-C target-cpu=apple-m3 -C target-feature=+neon -C link-args=-Wl,-dead_strip"

cargo build --release 2>&1
echo "  Rust种子核编译完成: $(ls -la target/release/libseed_kernel.a | awk '{print $5}') bytes"

# 运行Rust单元测试
echo "  运行Rust单元测试..."
cargo test --release 2>&1 | tail -5

# ============================================================
# 2. 编译Zig演化引擎（针对M3优化）
# ============================================================
echo ""
echo "[2/3] 编译Zig演化引擎（M3优化）..."
cd "$PROJECT_ROOT/zig-engine"

# 确保Zig在PATH中
export PATH="$HOME/.local/bin:$PATH"

# 清理旧构建
rm -rf .zig-cache main omega-falling

# Zig编译命令
# -O ReleaseFast: 最高优化
# -target aarch64-macos: ARM64 macOS目标
# -lc: 链接C标准库
# -lseed_kernel: 链接Rust种子核
SDKROOT_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
zig build-exe src/main.zig \
    -O ReleaseFast \
    -I ../seed-kernel/include \
    -L ../seed-kernel/target/release \
    -lseed_kernel \
    -F "$SDKROOT_PATH/System/Library/Frameworks" \
    -framework Accelerate \
    -lc \
    -target aarch64-macos \
    2>&1

echo "  Zig演化引擎编译完成: $(ls -la main | awk '{print $5}') bytes"

# ============================================================
# 3. 验证可执行文件
# ============================================================
echo ""
echo "[3/3] 验证可执行文件..."
file main
echo ""
echo "构建完成！运行: ./main"
echo "============================================================"
