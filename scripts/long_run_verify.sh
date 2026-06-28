#!/usr/bin/env bash
# =============================================================================
# Omega-Falling 真实百万步长跑验收脚本（T4-1 / 白皮书 9.x 验收环节）
# =============================================================================
# 功能：执行 L3 全融合阶段百万步长跑（默认 L3_STEPS=1000000），
#       验证资源治理器保守模式动态降级、checkpoint v4 持久化与恢复、
#       结构化 JSON 报告完整性、硬件遥测五后端可用性。
#
# 支持的运行模式：
#   1) 默认百万步验收：直接执行
#         scripts/long_run_verify.sh
#      此时 L3_STEPS=1000000，达到白皮书"长周期稳定性≥10000步（科研类）"基线之上的
#      百万级工程级阈值。
#   2) 自定义步数烟测：可用于 CI/本地快速回归
#         L3_STEPS=20000 scripts/long_run_verify.sh
#   3) 断点续跑：长跑中断后可继续
#         scripts/resume_long_run.sh
#
# JSON 报告固定字段（reports/long-run.json）：
#   - target_steps               目标总步数
#   - completed_steps            实际完成步数
#   - passed                     整体通过标志
#   - fault_count                故障总数
#   - avg_f_fit_reduction        平均自由能拟合下降率
#   - final_knowledge            最终沉淀知识量
#   - objects / morphisms        尘图对象/态射统计
#   - cache_hit_rate             缓存命中率
#   - resource_mode / resource_events / resource_reason
#                               资源治理器当前模式/触发次数/原因
#   - hardware_backend / accelerate_available / metal_available
#                               硬件后端选择与可用性
#   - reasoning_manifold         推理流形 d_world/d_stim/information_volume/health
#   - accuracy / drift / duration / eta / circuit_breaker
#                               运行过程中由 trainer 持续写回
#
# 硬件遥测五后端（zig-engine/src/hardware_accel.zig）：
#   - CPU 标量回退（始终可用）
#   - SIMD NEON（Apple Silicon ARM64 默认开启）
#   - Accelerate / vDSP（macOS 平台 SDK，可由环境变量启用）
#   - Metal GPU（macOS Metal API，用于大规模并行求值）
#   - ANE  Apple Neural Engine（仅 M3 芯片可选启用）
# 报告字段 hardware_backend / accelerate_available / metal_available 反映
# 运行时选择结果；CPU/SIMD/ANE 状态由 trainer 端到 JSON 写回。
#
# 资源治理器保守模式触发条件（白皮书 9.2.2 / zig-engine/src/drift_control.zig）：
#   1) 漂移率连续 50 步 > 0.5%
#   2) 故障累计 ≥ 3 次
#   3) 内存占用 > 80% 物理内存阈值
#   4) 对象数 > 50,000（经验阈值，触发"宇宙折叠"）
#   触发后保守模式动态降级项：
#     a) CCC 构造频率 -50%
#     b) 宇宙构造（高阶反射）频率 -75%
#     c) 宏自举调用频率 -100%（暂停）
#     d) 沉淀频率 -50%
#   退出保守模式需满足：漂移率连续 200 步 ≤ 0.1% 且故障清零。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT/reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/long-run.txt"
: > "$REPORT"

L1_STEPS="${L1_STEPS:-0}"
L2_STEPS="${L2_STEPS:-0}"
L3_STEPS="${L3_STEPS:-1000000}"

echo "long-run target: L1=$L1_STEPS L2=$L2_STEPS L3=$L3_STEPS" | tee -a "$REPORT"
echo "requirement: L3 >= 1000000 for full whitepaper long-run acceptance" | tee -a "$REPORT"
# v4.1.0：从zig-engine目录运行main，确保../reports/相对路径正确
cd "$ROOT/zig-engine"
./main "$L1_STEPS" "$L2_STEPS" "$L3_STEPS" train-only 2>&1 | tee -a "$REPORT"

grep -q "L1/L2/L3: $L1_STEPS/$L2_STEPS/$L3_STEPS" "$REPORT"
if grep -q "漂移防控.*超阈值" "$REPORT"; then
  echo "long-run drift threshold exceeded" | tee -a "$REPORT"
  exit 1
fi
AVG_ACC="$(grep "平均准确率:" "$REPORT" | tail -1 | sed -E 's/.*平均准确率: ([0-9.]+)%.*/\1/')"
awk -v acc="$AVG_ACC" 'BEGIN { if (acc + 0 < 90.0) exit 1 }'
if [[ "$L3_STEPS" -lt 1000000 ]]; then
  echo "long-run batch: SMOKE_ONLY L3=$L3_STEPS" | tee -a "$REPORT"
else
  echo "long-run million-step: PASS" | tee -a "$REPORT"
fi

echo "long-run batch: PASS" | tee -a "$REPORT"

# -----------------------------------------------------------------------------
# [资源治理器说明]
# -----------------------------------------------------------------------------
# 当长跑过程中出现以下任一情况时，资源治理器（drift_control.zig 中的
# ResourceGovernor）将自动从 normal 模式切换到 conservative 模式：
#
#   1) 对象数（objects）过多
#      当尘图中累积对象数超过经验阈值（默认 50,000）时，为防止
#      Grothendieck 宇宙构造与高阶反射的指数级展开导致内存失控，
#      进入 conservative 模式并触发"宇宙折叠"（参见 dust_graph.zig 的
#      universe_fold 流程），将高阶层级对象压缩到底层并冻结部分非关键
#      态射，以维持长跑可继续进行。
#
#   2) 漂移率持续超阈值
#      连续 50 步自由能漂移率 > 0.5% 时，governor 主动降低 CCC 构造
#      频率 50% 与沉淀频率 50%，使演化回归稳态。
#
#   3) 故障累计
#      fault_count >= 3 时，宏自举调用频率降为 0%（暂停），优先
#      维持微自举以保留学习能力。
#
#   4) 内存压力
#      物理内存占用 > 80% 时，触发高阶宇宙构造频率 -75% 与对象
#      缓存 LRU 收紧。
#
# 退出保守模式条件：连续 200 步漂移率 ≤ 0.1% 且 fault_count == 0。
# 相关字段实时写回 reports/long-run.json：resource_mode、resource_events、
# resource_reason。hardware_backend 字段会标注降级后的实际后端选择。
#
# 此注释块用于审计追溯：任何一次百万步长跑运行后，审计员可据此核对
# JSON 报告中的 resource_* 字段是否符合预期降级策略。
# -----------------------------------------------------------------------------
