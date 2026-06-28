
# Ω-AGI (Omega-AGI)

**We introduce Ω-AGI v5.0 as an endogenous evolution engine under the Gradient Universe · Dust Theory framework. Beginning from a primitive differential substrate, the system employs a Δ-operator and a graded-enriched 2-category formal system (CDL) to generate, through intrinsic evolution, the full spectrum of existence, including time, space, causality, and hierarchical complexity structures.**

**License:** CC BY-NC-ND 4.0 | **Status:** Pre-alpha

---

## Project Structure

```
Ω-AGI/
├── zig-engine/          Zig engine
│   ├── src/             Source files
│   └── build.zig        Build configuration
├── seed-kernel/         Rust seed kernel (FFI layer)
├── docs/                Whitepaper + architecture design documents
├── proofs/              Lean/Coq formal proofs
├── build.sh             Unified build script
└── verify.sh            Verification script
```

**Two-language architecture:** Rust seed kernel (FFI) + Zig engine

---

## Build

**Prerequisites:** Zig ≥ 0.16.0, Rust ≥ 1.70, macOS (M3)

```bash
./build.sh     # Rust seed kernel (cargo) → Zig engine (zig build)
```

Or directly:

```bash
cd zig-engine && zig build
```

(dependencies already fixed)

---

## Verification

```bash
./verify.sh                # 12-test pipeline + CL-SCT training
./verify.sh emergence      # emergence validation
./verify.sh --formal       # with formal proofs
```

---

## Key Highlights

### 1. Δ(x, y) Primitive System

Not a neural network, not a large model. The entire system is derived from a single axiom:

```
Δ(x, y) = max(0, f(x) - g(y))
```

There is no backpropagation, no loss function, and no separation between training and inference. Each Δ-conduction simultaneously performs computation and learning.

---

### 2. CDL Formal Mathematical Foundation + Lean Proofs

Category Difference Lattice (CDL) unifies lattice theory and category theory. All core theorems are formally verified in Lean (T15/T18, zero “sorry”). This may be one of the few AGI systems with rigorous formal mathematical proofs.

---

### 3. Self-Supervised Meta-Learning (Seven-Path Consensus)

The system does not rely on external labels or loss functions. Instead, it evolves through consensus and divergence across seven independent evaluation paths, measured via Kendall’s W coefficient:

* High consensus → convergence
* High divergence → continued exploration

---

### 4. Tri-Partition Safety Architecture

```
Axiom Frozen Zone (immutable)
→ Evolvable Self-Generative Zone (computational engine)
→ Frozen Zone (triple-gated sealing mechanism)
```

Knowledge is frozen only after passing three verification gates. This safety mechanism is intrinsic, not post hoc.

---

### 5. Full Engineering Implementation (Rust + Zig, ~70 source files)

* Rust seed kernel (FFI layer) + Zig engine
* `zig build` → 0 errors, all steps passed
* L1–L3 training pipeline executable (303 + 600 + 300 steps)
* Lean/Coq formal proofs integrated

---

## Execution Flow

### Core: Single Δ-Conduction (`evaluate()` in `cdl_expr.zig`)

```
Entry: evaluate(root_idx, pool, ctx, getF, getG)

1. Recursion depth guard (returns 0 if exceeded)
2. total_conductions++ (global sequence counter, wraps at U64_MAX)
3. Retrieve ExprNode + ExprActivity
4. Temporal decay based on last activation interval and stability:
   decay = exp(-interval / effective_window)
5. Dispatch by node type:
   .ValueRef → read value via callback
   .Delta    → evaluate(left), evaluate(right), delta(l, r)
   .paths    → traverse children, weighted sum of evaluations
6. Return f64 result
```

---

### Entry Point: `main.zig → test_mod() → test modules`

```
delta_engine.evaluate()     → wrapped cdl_expr.evaluate()
cognitive_simulator.run()   → convergence loop (Δ < 1e-12 or 100 iterations)
trainer.cl_sct_evolution()  → L1 → L2 → L3 training pipeline
```

---

### Cognitive Simulation (Whitepaper §4.5)

Runs convergence loops over CDL subgraphs without modifying the main graph.

---

### Meta-Learning (Whitepaper §8)

Seven independent evaluation paths produce system assessment via Kendall’s W concordance coefficient.

---

## Core Concepts

| Concept       | Components                                                                | Function                                        |
| ------------- | ------------------------------------------------------------------------- | ----------------------------------------------- |
| World Model   | Dust Graph + computational engine (Pareto / transitions)                  | Knowledge storage + Δ-based internal simulation |
| Meta-Learning | meta_evaluator (7-path consensus) + meta_learner (parameter optimization) | Self-supervised evolutionary drive              |
| Metacognition | meta_cognition                                                            | Recursive Δ self-reference and self-reflection  |

---

## Current Status (Based on Execution)

| Module                 | Status | Verification                      |
| ---------------------- | ------ | --------------------------------- |
| World Model            | ✅      | zig build: 0 errors               |
| Meta-Learning          | ✅      | full test pipeline passed         |
| Metacognition          | ✅      | full test pipeline passed         |
| Trainer                | ⏳      | code runs, assertions need fixing |
| Safety System          | ✅      | zig build: 0 errors               |
| Capability / Emergence | ❓      | not yet verified                  |

See `docs/Ω-architecture-design.md` for details.

---

*Documentation includes a 96K-character whitepaper and a 16K architecture design document under `docs/`.*


## ⚠️ Project Status & Collaboration

Ω-AGI is currently in a **pre-alpha research stage**.

Due to limited funding and resources, active development has been significantly slowed and can no longer be fully sustained by an independent researcher.

However, the theoretical framework, core architecture, and formal system remain open and complete at the conceptual level.


We are now looking for:

- Researchers interested in **gradient-based generative systems**
- Experts in **category theory, formal systems, or mathematical AI**
- Systems engineers (Rust / Zig / low-level architectures)
- Individuals interested in **endogenous intelligence and self-evolving computation**


## 🤝 Collaboration Vision

This project is not closed.

It is intended as a **research substrate**, open for continuation, reinterpretation, and extension by the community.

We welcome anyone who shares interest in:

- Δ-operator computation systems  
- CDL (Category Difference Lattice) formalism  
- endogenous intelligence models  
- Self-evolving computational architectures  

## 📬 Contact / Contribution

If you are interested in contributing, extending, or discussing this work:

- Open a GitHub Discussion
- Submit a Research Proposal via Issues
- Fork and experiment freely

---

> “A system designed to evolve should not depend on a single source of continuation.”
