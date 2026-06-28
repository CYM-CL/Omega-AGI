# Ω-AGI (Omega-AGI)

**CDL v2.1 格富集2-范畴差异格智能体 — Δ驱动的AGI引擎**

**License: CC BY-NC-ND 4.0** | **Status: Pre-alpha**

---

## 项目结构

```
Ω-AGI/
├── zig-engine/          Zig引擎
│   ├── src/             源文件
│   └── build.zig        构建配置
├── seed-kernel/         Rust种子核（FFI层）
├── docs/                白皮书+架构设计书
├── proofs/              Lean/Coq形式化证明
├── build.sh             统一构建脚本
└── verify.sh            验证脚本
```

**两种语言**：Rust种子核(FFI) + Zig引擎

---

## 构建

前置：Zig ≥ 0.16.0、Rust ≥ 1.70、macOS (M3)

```bash
./build.sh     # Rust种子核(cargo) → Zig引擎(zig build)
```

或直接 `cd zig-engine && zig build`（依赖已修复）。

---

## 验证

```bash
./verify.sh                # 12测试管线 + CL-SCT训练
./verify.sh emergence      # 涌现性验证
./verify.sh --formal       # 含形式化证明
```

---

## 核心亮点

### 1. Δ(x,y) 单原语系统

不是神经网络，不是大模型。整个系统从一条公理自生：
```
Δ(x, y) = max(0, f(x) - g(y))
```
没有反向传播、没有损失函数、没有训练/推理分离。每次Δ传导同时完成运算和学习。

### 2. CDL 形式化数学底座 + Lean 证明

Category Difference Lattice 统一格论与范畴论。所有核心定理在 Lean 中形式化证明（T15/T18，0个sorry）。这可能是唯一有严格数学证明的 AGI 项目。

### 3. 自监督元学习（七路共识）

系统不依赖外部标注或损失函数，而是通过七条独立评价路径的共识/分歧驱动自我演化（Kendall W 协调系数）。共识高 → 收敛；分歧高 → 继续探索。

### 4. 三元分区安全架构

```
公理固化区(不可修改) → 可演化自生区(运算引擎) → 冻结区(三重门禁)
```

已沉淀知识通过三关验证后冻结，不可逆修改。内置安全机制，非事后添加。

### 5. 完整工程实现（Rust + Zig，~70源文件）

- Rust种子核（FFI层）+ Zig引擎
- `zig build` 0 errors，3/3步骤全通过
- L1-L3训练管线可运行（303+600+300步）
- Lean/Coq形式化证明

## 运行流程

### 核心：evaluate() 一次Δ传导（cdl_expr.zig）

```
入口: evaluate(root_idx, pool, ctx, getF, getG)
  1. 递归深度保护(超出max_depth返回0)
  2. total_conductions++ (全局传导序列号，U64_MAX归零)
  3. 获取ExprNode + ExprActivity
  4. 访问时衰减: 根据上次激活间隔+稳定度折损传导贡献度
     decay = exp(-interval / effective_window)
  5. 按节点类型调度:
     .ValueRef → 通过回调读取节点值
     .Delta    → evaluate(left), evaluate(right), delta(l,r)
     .paths    → 遍历子路径 evaluate(), 加权求和
  6. 返回结果 f64
```

### 入口：main.zig → test_mod() → 各测试模块

```
delta_engine.evaluate()     → 封装cdl_expr.evaluate()
cognitive_simulator.run()   → evaluate()收敛循环 (Δ<1e-12 或 100次)
trainer.cl_sct_evolution()  → L1→L2→L3训练管线
```

### 认知模拟（白皮书§4.5）

同上evaluate()收敛循环，在CDL子图上执行（不修改主图）。

### 元学习（白皮书§8）

七条独立路径评价当前状态（Kendall W协调系数）。

## 核心概念

| 概念 | 包含 | 作用 |
|------|------|------|
| **世界模型** | 尘图 + 运算引擎(Pareto/跃迁) | 知识存储 + Δ脑内模拟 |
| **元学习** | meta_evaluator(七路共识) + meta_learner(参数优化) | 自监督驱动演化 |
| **元认知** | meta_cognition | Δ自指嵌套，自我反思 |

---

## 当前状态（基于实际运行）

| 模块 | 状态 | 验证方式 |
|------|------|---------|
| 世界模型 | ✅ | zig build 0 errors |
| 元学习 | ✅ | zig build test full pass |
| 元认知 | ✅ | zig build test full pass |
| 训练器 | ⏳ 代码运行，断言需修复 | L1:303 L2:600 L3:300步 |
| 安全系统 | ✅ | zig build 0 errors |
| 能力层/涌现 | ❓ | 未验证 |

详情见 `docs/Ω-架构设计书.md`。

---

*文档：`docs/`下含白皮书(96K)和架构设计书(16K)。*


