// Ω-落尘AGI Δ传导模拟系统 v1.0
//
// 对应白皮书 §4.5 Δ传导模拟：核心认知机制（脑内模拟）
//
// 设计哲学：
// 系统唯一认知原语是"在尘图上构建一个CDL子图结构，
// 让Δ传导在其中自由传播、自发收敛到稳态"。
// 所有认知行为——推理、规划、物理模拟、语言理解——
// 都是这个单一操作在不同约束深度和规模下的表现。
//
// 本模块提供此原语的高层封装：
// - Simulator: 核心模拟器，执行Δ传导模拟
// - Scenario: 模拟场景（一组Δ约束条件）
// - SimulationSandbox: 隔离的仿真环境（定义在cdl_expr.zig中）
//
// 使用方式（对应白皮书 §4.5.2 操作过程）：
//   1. 在尘图上构建CDL表达式树（表示要模拟的场景）
//   2. Simulator.run(scenario) 在尘图上执行Δ传导模拟
//   3. 读取 SimulationResult 获取收敛结果
//   4. 或用 Sandbox.runInSandbox() 在隔离副本上做假设推演

const std = @import("std");
const cdl = @import("cdl_expr.zig");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;

/// Δ传导模拟结果
pub const SimulationResult = struct {
    output_value: f64,
    conduction_steps: u64,
    converged: bool,
};

/// 模拟场景（Δ约束入口）
pub const Scenario = struct {
    root_expr: cdl.ExprIdx,
    name: []const u8,
};

// ============================================================
// 全局回调（桥接到 delta_engine 的 NodeRef 求值链）
// ============================================================
var g_sim_engine: ?*DeltaEngine = null;

fn getNodeFCallback(node_id: u64) f64 {
    if (g_sim_engine) |engine| return engine.evalExprF(node_id);
    return 0.0;
}

fn getNodeGCallback(node_id: u64) f64 {
    if (g_sim_engine) |engine| return engine.evalExprG(node_id);
    return 0.0;
}

/// Δ传导模拟器（§4.5 核心认知机制）
pub const Simulator = struct {
    engine: *DeltaEngine,

    pub fn init(engine: *DeltaEngine) Simulator {
        return .{ .engine = engine };
    }

    /// 在主池上执行Δ传导模拟（正式推理）
    pub fn run(self: *Simulator, scenario: Scenario) SimulationResult {
        g_sim_engine = self.engine;
        var ctx = cdl.EvalContext.init();
        defer ctx.deinit(self.engine.allocator);

        // Δ传导收敛循环（白皮书§4.5）：反复求值直到Δ(result, prev) < ε
        // 脑内模拟的本质：在尘图上构建CDL子图，让Δ传导在其中传播直到不动点
        var prev_result: f64 = 0.0;
        const tolerance: f64 = 1e-12;
        const max_iterations: u32 = 100;
        var iteration: u32 = 0;
        var result: f64 = 0.0;

        while (iteration < max_iterations) : (iteration += 1) {
            result = self.engine.cdl_eval.evaluate(
                &self.engine.cdl_pool, scenario.root_expr, &ctx,
                getNodeFCallback, getNodeGCallback,
            );

            // 检查是否收敛：Δ(current, prev) < ε
            if (@abs(result - prev_result) < tolerance) break;
            prev_result = result;
        }

        return .{
            .output_value = result,
            .conduction_steps = self.engine.delta_call_count,
            .converged = iteration < max_iterations - 1,
        };
    }

    /// 在沙箱中执行Δ传导模拟（假设推演，无副作用）
    pub fn runInSandbox(self: *Simulator, scenario: Scenario, sandbox: *cdl.SimulationSandbox) SimulationResult {
        g_sim_engine = self.engine;
        var ctx = cdl.EvalContext.init();
        defer ctx.deinit(self.engine.allocator);

        // Δ传导收敛循环（白皮书§4.5）：沙箱中同样需要收敛
        var prev_result: f64 = 0.0;
        const tolerance: f64 = 1e-12;
        const max_iterations: u32 = 100;
        var iteration: u32 = 0;
        var result: f64 = 0.0;

        while (iteration < max_iterations) : (iteration += 1) {
            result = sandbox.evaluateInSandbox(scenario.root_expr, &ctx,
                getNodeFCallback, getNodeGCallback);

            if (@abs(result - prev_result) < tolerance) break;
            prev_result = result;
        }

        return .{
            .output_value = result,
            .conduction_steps = self.engine.delta_call_count,
            .converged = iteration < max_iterations - 1,
        };
    }

    /// 比较两个场景的模拟结果
    pub fn compare(self: *const Simulator, a: SimulationResult, b: SimulationResult) f64 {
        _ = self;
        return @max(0.0, a.output_value - b.output_value);
    }

    /// 自我模型精度：通过 Simulator 评估 Δ 表达式收敛速度来判断自指质量
    /// 方法：随机采样池中 Δ 表达式，运行 Simulator 跟踪收敛迭代次数
    ///       迭代少 → 表达式清晰一致，自模型质量高
    ///       迭代多 → 表达式复杂/不一致，自模型模糊
    /// 分数 = 1.0 - avg_iterations / max_iterations
    pub fn computeSelfModelAccuracy(self: *Simulator) f64 {
        const pool = self.engine.cdl_pool;
        const count = pool.size();
        if (count < 3) return 0.5;

        const max_iterations: u32 = 100;
        const tolerance: f64 = 1e-12;
        const max_samples = @min(count, @as(usize, 30));

        var total_iterations: u64 = 0;
        var sample_count: usize = 0;
        var prng = std.Random.DefaultPrng.init(@as(u64, count));
        const rng = prng.random();

        for (0..max_samples) |_| {
            const idx = rng.intRangeAtMost(usize, 0, count - 1);
            const node = pool.getNode(@as(cdl.ExprIdx, @intCast(idx))) orelse continue;

            // 只使用 Δ 和 paths 表达式（有实际传导结构的）
            switch (node.*) {
                .Delta, .paths => {},
                else => continue,
            }

            const expr_idx: cdl.ExprIdx = @intCast(idx);

            // 用 Simulator 逻辑评估该表达式（迭代至收敛）
            g_sim_engine = self.engine;
            var ctx = cdl.EvalContext.init();
            defer ctx.deinit(self.engine.allocator);

            var prev_result: f64 = 0.0;
            var iteration: u32 = 0;
            while (iteration < max_iterations) : (iteration += 1) {
                const result = self.engine.cdl_eval.evaluate(
                    &self.engine.cdl_pool, expr_idx, &ctx,
                    getNodeFCallback, getNodeGCallback,
                );
                if (@abs(result - prev_result) < tolerance) break;
                prev_result = result;
            }

            total_iterations += iteration;
            sample_count += 1;
        }

        if (sample_count == 0) return 0.5;
        const avg_iters = @as(f64, @floatFromInt(total_iterations)) / @as(f64, @floatFromInt(sample_count));
        return @max(0.0, 1.0 - avg_iters / @as(f64, @floatFromInt(max_iterations)));
    }
};

// ============================================================
// 测试
// ============================================================
const testing = std.testing;

test "Simulator 创建" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    const sim = Simulator.init(&engine);
    _ = sim;
}

test "Simulator 场景执行" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var sim = Simulator.init(&engine);

    const a_expr = try engine.cdl_pool.makeNodeRef(engine.zero_id, true);
    const b_expr = try engine.cdl_pool.makeNodeRef(engine.one_id, false);
    const delta_expr = try engine.cdl_pool.makeDelta(a_expr, b_expr);

    const result = sim.run(.{
        .root_expr = delta_expr,
        .name = "Δ(zero, one)",
    });
    try testing.expect(std.math.isFinite(result.output_value));
}

test "Simulator 沙箱隔离执行" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var sim = Simulator.init(&engine);

    var sandbox = try engine.createSandbox();
    defer sandbox.deinit();

    const a_expr = try engine.cdl_pool.makeNodeRef(engine.zero_id, true);
    const b_expr = try engine.cdl_pool.makeNodeRef(engine.one_id, false);
    const delta_expr = try engine.cdl_pool.makeDelta(a_expr, b_expr);

    const result = sim.runInSandbox(.{
        .root_expr = delta_expr,
        .name = "沙箱Δ(zero, one)",
    }, &sandbox);
    try testing.expect(std.math.isFinite(result.output_value));
    try testing.expect(result.converged);
}
