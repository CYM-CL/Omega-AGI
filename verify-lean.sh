#!/bin/bash
# Ω-落尘AGI Lean形式化验证 运行脚本
# 对应白皮书 §8 三层验证体系——第一层：理论形式化验证
#
# 用途：运行 Lean 4 形式化证明，验证 CDL 公理一致性、
#       格码同构、编译正确性等定理。
#
# 依赖：Lean 4.5.0+ (lake 5.0.0+)
# 位置：lean/ 目录（相对本脚本）

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LEAN_DIR="$SCRIPT_DIR/lean"
echo "[verify-lean] 运行 Ω-落尘AGI 形式化验证..."
echo "[verify-lean] Lean项目目录: $LEAN_DIR"

if [ ! -f "$LEAN_DIR/lakefile.lean" ]; then
    echo "[verify-lean] 错误: 未找到 lakefile.lean"
    echo "[verify-lean] 确保脚本在 omega-falling/ 目录下运行"
    exit 1
fi

cd "$LEAN_DIR"
lake build
echo "[verify-lean] 所有形式化证明验证通过 ✓"
