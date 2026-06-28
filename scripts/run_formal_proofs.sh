#!/usr/bin/env bash
# 形式化证明全量运行脚本 v4.1.0
# 集成 3 大定理 × 3 工具 = 9 个新证明文件 + SeedKernel 系列 + anchors
# 覆盖：CCC结构定理、格码同构定理、自指不动点定理
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT/reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/formal-proofs.txt"
: > "$REPORT"

STATUS=0
Z3_TOTAL_UNSAT=0

# 通用运行函数：检查工具可用性并运行
run_required() {
  local tool="$1"
  shift
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "MISSING: $tool" | tee -a "$REPORT"
    STATUS=1
    return 0
  fi
  echo "RUN: $tool $*" | tee -a "$REPORT"
  if ! "$tool" "$@" 2>&1 | tee -a "$REPORT"; then
    STATUS=1
  fi
}

# Z3 专用运行函数：统计 unsat 数量
run_z3() {
  local smt2_file="$1"
  local label="$2"
  local min_unsat="${3:-1}"
  if ! command -v z3 >/dev/null 2>&1; then
    echo "MISSING: z3" | tee -a "$REPORT"
    STATUS=1
    return 0
  fi
  echo "RUN: z3 $smt2_file ($label)" | tee -a "$REPORT"
  local tmp_out
  tmp_out="$(mktemp)"
  if ! z3 "$smt2_file" 2>&1 | tee "$tmp_out" | tee -a "$REPORT"; then
    STATUS=1
  fi
  local unsat_count
  unsat_count="$(grep -c '^unsat$' "$tmp_out" || true)"
  Z3_TOTAL_UNSAT=$((Z3_TOTAL_UNSAT + unsat_count))
  echo "  $label: $unsat_count unsat checks (min required: $min_unsat)" | tee -a "$REPORT"
  if [[ "$unsat_count" -lt "$min_unsat" ]]; then
    echo "  FAIL: $label expected at least $min_unsat unsat checks" | tee -a "$REPORT"
    STATUS=1
  fi
  rm -f "$tmp_out"
}

# ============================================================
# 第一部分：SeedKernel 系列（原有证明）
# ============================================================

# Lean SeedKernel（如果工具链可用）
if compgen -G "$HOME/.elan/toolchains/*" >/dev/null 2>&1 || command -v lean >/dev/null 2>&1; then
  run_required lean "$ROOT/proofs/lean/SeedKernel.lean"
else
  echo "SKIP: Lean toolchain unavailable; Lean is not a current gate" | tee -a "$REPORT"
fi

# Coq SeedKernel
run_required coqc "$ROOT/proofs/coq/SeedKernel.v"

# Z3 anchors（安全锚定，至少 10 个 unsat）
run_z3 "$ROOT/proofs/z3/anchors.smt2" "anchors" 10

# ============================================================
# 第二部分：CCC 结构定理（白皮书 3.2 节）
# ============================================================

echo "" | tee -a "$REPORT"
echo "=== CCC Structure Theorem (Whitepaper 3.2) ===" | tee -a "$REPORT"

# Lean CCC 结构定理
if command -v lean >/dev/null 2>&1; then
  run_required lean "$ROOT/proofs/lean/CCCStructure.lean"
fi

# Coq CCC 结构定理
run_required coqc "$ROOT/proofs/coq/CCCStructure.v"

# Z3 CCC 结构定理（至少 11 个 unsat）
run_z3 "$ROOT/proofs/z3/ccc_structure.smt2" "ccc_structure" 11

# ============================================================
# 第三部分：格码同构定理（白皮书 3.3 节）
# ============================================================

echo "" | tee -a "$REPORT"
echo "=== Lattice-Code Isomorphism Theorem (Whitepaper 3.3) ===" | tee -a "$REPORT"

# Lean 格码同构定理
if command -v lean >/dev/null 2>&1; then
  run_required lean "$ROOT/proofs/lean/LatticeCodeIsomorphism.lean"
fi

# Coq 格码同构定理
run_required coqc "$ROOT/proofs/coq/LatticeCodeIsomorphism.v"

# Z3 格码同构定理（至少 12 个 unsat）
run_z3 "$ROOT/proofs/z3/lattice_code_isomorphism.smt2" "lattice_code_isomorphism" 12

# ============================================================
# 第四部分：自指不动点定理（白皮书 12.4 节）
# ============================================================

echo "" | tee -a "$REPORT"
echo "=== Self-Reference Fixed-Point Theorem (Whitepaper 12.4) ===" | tee -a "$REPORT"

# Lean 自指不动点定理
if command -v lean >/dev/null 2>&1; then
  run_required lean "$ROOT/proofs/lean/SelfReferenceFixedPoint.lean"
fi

# Coq 自指不动点定理
run_required coqc "$ROOT/proofs/coq/SelfReferenceFixedPoint.v"

# Z3 自指不动点定理（至少 9 个 unsat）
run_z3 "$ROOT/proofs/z3/self_reference_fixed_point.smt2" "self_reference_fixed_point" 9

# ============================================================
# 汇总报告
# ============================================================

echo "" | tee -a "$REPORT"
echo "=== Summary ===" | tee -a "$REPORT"
echo "Total Z3 unsat checks: $Z3_TOTAL_UNSAT (expected >= 42)" | tee -a "$REPORT"
if [[ "$Z3_TOTAL_UNSAT" -lt 42 ]]; then
  echo "FAIL: Total Z3 unsat checks below threshold (42)" | tee -a "$REPORT"
  STATUS=1
fi

if [[ "$STATUS" -eq 0 ]]; then
  echo "formal proofs: PASS" | tee -a "$REPORT"
else
  echo "formal proofs: FAIL" | tee -a "$REPORT"
fi
exit "$STATUS"
