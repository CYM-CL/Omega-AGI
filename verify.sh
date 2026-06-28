#!/usr/bin/env bash
# Ω-落尘AGI omega-falling 验证脚本 v1.1
#
# 用法：
#   verify.sh                       # 默认验证（编译 + 单元测试 + 训练运行）
#   verify.sh --formal              # 含形式化证明验证
#   verify.sh --long                # 含长周期稳定性测试
#   verify.sh emergence             # 涌现性验证（白皮书 8.3）
#   verify.sh emergence group       # 仅运行"代数群涌现"子实验
#   verify.sh emergence geometry    # 仅运行"欧氏几何涌现"子实验
#   verify.sh emergence topology    # 仅运行"拓扑不变量涌现"子实验
#   verify.sh emergence calculus    # 仅运行"微积分关系涌现"子实验
#   verify.sh emergence open_ended  # 仅运行"开放式演化"子实验
#
# CI 集成说明（白皮书 8.3 + 9.6）：
#   - 本脚本设计为 CI 友好：每次调用产生一份结构化报告到 reports/
#   - 失败时立即返回非零退出码（set -euo pipefail 已启用）
#   - 子命令 emergence 单独可调用，便于在 CI pipeline 中以独立 stage 运行
#   - 报告路径：
#     * reports/verify.txt          - 默认验证全流程报告
#     * reports/emergence.txt       - 涌现性验证汇总报告
#   - 集成到 CI 的推荐方式：
#       stage('verify-default')    { sh './verify.sh' }
#       stage('verify-emergence')  { sh './verify.sh emergence' }
#       stage('verify-formal')     { sh './verify.sh --formal' }
#       stage('verify-long')       { sh './verify.sh --long' }

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$ROOT/reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/verify.txt"
: > "$REPORT"

# ============================================================
# 参数解析：支持子命令（emergence）与传统参数（--formal/--long）
# 设计：第一个参数为 "emergence" 时进入子命令分支；否则按原行为
# ============================================================
EMERGENCE_SUBCMD=0
EMERGENCE_FILTER=""
RUN_FORMAL=0
RUN_LONG=0
EMERGENCE_REPORT="$REPORT_DIR/emergence.txt"

# 第一个非选项参数可能是子命令
if [[ $# -gt 0 && "$1" == "emergence" ]]; then
    EMERGENCE_SUBCMD=1
    shift
    if [[ $# -gt 0 ]]; then
        EMERGENCE_FILTER="$1"
        shift
    fi
fi

for arg in "$@"; do
  case "$arg" in
    --formal) RUN_FORMAL=1 ;;
    --long) RUN_LONG=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

run_step() {
  echo "== $* ==" | tee -a "$REPORT"
  "$@" 2>&1 | tee -a "$REPORT"
}

# ============================================================
# 涌现性验证（白皮书 8.3）
# ============================================================
# 4 个子实验：
#   8.3.1 零样本新领域          - zero_shot_validation.zig
#   8.3.2 消融实验              - ablation_validation.zig
#   8.3.3 数学结构涌现          - math_structure_emergence.zig
#   8.3.4 开放式演化            - open_ended_evolution.zig
# 通过 `zig build test-emergence` 一键运行所有涌现性验证模块
# （build.zig 配置了 emergence_test_module 以正确处理模块根路径）
# 失败时返回非零退出码（CI 集成要求）
# 报告汇总到 reports/emergence.txt
# ============================================================
run_emergence() {
    : > "$EMERGENCE_REPORT"

    echo "========================================" | tee -a "$EMERGENCE_REPORT"
    echo "[verify.sh] 涌现性验证（白皮书 8.3）" | tee -a "$EMERGENCE_REPORT"
    echo "  8.3.1 零样本新领域" | tee -a "$EMERGENCE_REPORT"
    echo "  8.3.2 消融实验" | tee -a "$EMERGENCE_REPORT"
    echo "  8.3.3 数学结构涌现" | tee -a "$EMERGENCE_REPORT"
    echo "  8.3.4 开放式演化" | tee -a "$EMERGENCE_REPORT"
    echo "========================================" | tee -a "$EMERGENCE_REPORT"

    pushd "$ROOT/zig-engine" >/dev/null

    # ============================================================
    # 4 个涌现性验证子实验统一通过 build.zig 的 test-emergence 目标运行
    # 解决 Zig 0.16 模块根路径约束：
    #   - build.zig 中 emergence_test_module 通过 addImport 注册模块名映射
    #   - emergence_test_root.zig 作为根模块统一导入 4 个子实验
    #   - 所有 test 块一次性编译 + 一次性执行
    # 子实验 filter 仅用于报告标题与 PASS/FAIL 标记，不影响实际命令
    # ============================================================
    local EXIT_CODE=0

    # 一次性运行所有 4 个涌现性验证子实验（T4-2/3/4/5）
    echo "" | tee -a "$EMERGENCE_REPORT"
    echo "== [8.3.*] 涌现性验证 - 统一构建入口 (zig build test-emergence) ==" | tee -a "$EMERGENCE_REPORT"
    if zig build test-emergence 2>&1 | tee -a "$EMERGENCE_REPORT"; then
        # 完整构建通过则 4 个子实验都通过
        for SUB_TAG in "8.3.1 零样本新领域" "8.3.2 消融实验" "8.3.3 数学结构涌现" "8.3.4 开放式演化"; do
            # 如果指定了 filter，仅显示对应的子实验
            if [[ -n "$EMERGENCE_FILTER" ]]; then
                case "$EMERGENCE_FILTER" in
                    zero_shot) [[ "$SUB_TAG" == "8.3.1 零样本新领域" ]] || continue ;;
                    ablation) [[ "$SUB_TAG" == "8.3.2 消融实验" ]] || continue ;;
                    group|geometry|topology|calculus|math_structure) [[ "$SUB_TAG" == "8.3.3 数学结构涌现" ]] || continue ;;
                    open_ended) [[ "$SUB_TAG" == "8.3.4 开放式演化" ]] || continue ;;
                    *) echo "unknown emergence filter: $EMERGENCE_FILTER" >&2; EXIT_CODE=1; continue ;;
                esac
            fi
            echo "[$SUB_TAG]: PASS" | tee -a "$EMERGENCE_REPORT"
        done
    else
        # 构建失败：4 个子实验都标记为 FAIL
        for SUB_TAG in "8.3.1 零样本新领域" "8.3.2 消融实验" "8.3.3 数学结构涌现" "8.3.4 开放式演化"; do
            if [[ -n "$EMERGENCE_FILTER" ]]; then
                case "$EMERGENCE_FILTER" in
                    zero_shot) [[ "$SUB_TAG" == "8.3.1 零样本新领域" ]] || continue ;;
                    ablation) [[ "$SUB_TAG" == "8.3.2 消融实验" ]] || continue ;;
                    group|geometry|topology|calculus|math_structure) [[ "$SUB_TAG" == "8.3.3 数学结构涌现" ]] || continue ;;
                    open_ended) [[ "$SUB_TAG" == "8.3.4 开放式演化" ]] || continue ;;
                esac
            fi
            echo "[$SUB_TAG]: FAIL" | tee -a "$EMERGENCE_REPORT"
        done
        EXIT_CODE=1
    fi

    popd >/dev/null

    # 汇总
    echo "" | tee -a "$EMERGENCE_REPORT"
    echo "========================================" | tee -a "$EMERGENCE_REPORT"
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo "[verify.sh emergence] 涌现性验证: ALL PASS" | tee -a "$EMERGENCE_REPORT"
    else
        echo "[verify.sh emergence] 涌现性验证: FAIL（部分子实验未通过）" | tee -a "$EMERGENCE_REPORT"
    fi
    echo "  报告路径: $EMERGENCE_REPORT" | tee -a "$EMERGENCE_REPORT"
    echo "========================================" | tee -a "$EMERGENCE_REPORT"

    return $EXIT_CODE
}

# ============================================================
# 涌现性验证入口（CI 集成子命令）
# ============================================================
if [[ $EMERGENCE_SUBCMD -eq 1 ]]; then
    run_emergence
    exit $?
fi

# ============================================================
# 默认验证流程（与原 verify.sh 行为完全一致）
# ============================================================
run_step "$ROOT/build.sh"

pushd "$ROOT/zig-engine" >/dev/null
run_step zig test "src/hardware_accel.zig" -framework Accelerate -lc
run_step zig test "src/reasoning_manifold.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/cdl_tensor_encoder.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/candidate_accel.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/dust_graph.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/delta_engine.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/functional_domains.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/l3_verification.zig"
run_step zig test "src/audit.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
run_step zig test "src/trainer.zig" -I "../seed-kernel/include" -L "../seed-kernel/target/release" -lseed_kernel -framework Accelerate -lc
popd >/dev/null

run_step "$ROOT/zig-engine/main" 10 5 5 train-only
run_step "$ROOT/zig-engine/main" 10 5 5 student-only
sed -n '/\[能力来源链路报告\]/,$p' "$REPORT" > "$REPORT_DIR/provenance.md"
grep -q "rule\\[" "$REPORT_DIR/provenance.md"

if [[ "$RUN_FORMAL" -eq 1 ]]; then
  run_step "$ROOT/scripts/run_formal_proofs.sh"
fi

if [[ "$RUN_LONG" -eq 1 ]]; then
  run_step "$ROOT/scripts/long_run_verify.sh"
fi

echo "verify: PASS" | tee -a "$REPORT"
