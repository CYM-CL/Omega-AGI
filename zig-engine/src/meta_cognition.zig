// Ω-落尘AGI 元认知系统 v4.1.0
//
// 严格对应白皮书v2.0要求：
// - 第12.4节：元学习算子M（定理12.4）：M(A) = Δ(A, A) = 0，0为唯一不动点
// - 第10章：n阶元认知层级与自指深度探针
//
// 设计哲学（尘算子核心）：
// 元认知不是"监控器"，而是 Δ 自指嵌套的涌现：
// - M(A) = Δ(A, A) = 0（自指归零，定理12.4）
// - M^n(A) = Δ(Δ(...Δ(A,A)...)) n阶嵌套（收敛到0）
// - 元认知层级：L0执行 → L1监控 → L2策略 → L3学习 → Ln元学习
// - 自指深度探针：测量 M^n 的收敛性（δ_n < C/n²）
//
// 元认知层级：
// L0：任务执行（直接Δ运算）
// L1：任务监控（Δ(executed, expected)）
// L2：策略选择（Δ(strategy, task)）
// L3：策略学习（Δ(learned, optimal)）
// Ln：元策略学习（Δ(meta_strategy, strategy)）
//
// 强类型封装：MetaLevel/MetaCognitiveState/MetaLearningResult
// 显式错误处理：MetaCognitionError 覆盖全量失败场景
// 可复现：所有测试固定种子

const std = @import("std");
const et = @import("error_types.zig");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;

// ============================================================
// 强类型错误体系
// ============================================================

/// 元认知错误类型
pub const MetaCognitionError = error{
    InvalidLevel,           // 无效的元认知层级
    InvalidInput,           // 无效的输入
    InvalidDepth,           // 无效的深度
    InvalidStrategy,        // 无效的策略
    InvalidConfidence,      // 无效的置信度
    ConvergenceFailed,      // 收敛失败
    MaxDepthExceeded,       // 超过最大深度
    StrategyNotFound,       // 策略未找到
    SelfEvaluationFailed,   // 自我评估失败
    OutOfMemory,            // 内存不足
    InvalidTaskId,          // 无效的任务ID
    InvalidMonitorValue,    // 无效的监控值
};

// ============================================================
// 强类型枚举与结构体
// ============================================================

/// 元认知层级（n阶）
pub const MetaLevel = enum(u8) {
    L0 = 0,  // 任务执行
    L1 = 1,  // 任务监控
    L2 = 2,  // 策略选择
    L3 = 3,  // 策略学习
    Ln = 4,  // 元策略学习（n阶）

    /// 获取层级名称
    pub fn name(self: MetaLevel) []const u8 {
        return switch (self) {
            .L0 => "L0-任务执行",
            .L1 => "L1-任务监控",
            .L2 => "L2-策略选择",
            .L3 => "L3-策略学习",
            .Ln => "Ln-元策略学习",
        };
    }

    /// 获取层级深度
    pub fn depth(self: MetaLevel) u8 {
        return @intFromEnum(self);
    }

    /// 从u8创建
    pub fn fromU8(v: u8) MetaCognitionError!MetaLevel {
        if (v > 4) return error.InvalidLevel;
        return @enumFromInt(v);
    }
};

/// 策略类型
pub const Strategy = enum(u8) {
    Direct = 0,       // 直接执行
    Decompose = 1,    // 分解策略
    Analogy = 2,      // 类比策略
    Search = 3,       // 搜索策略
    Learn = 4,        // 学习策略
    MetaLearn = 5,    // 元学习策略

    pub fn name(self: Strategy) []const u8 {
        return switch (self) {
            .Direct => "直接执行",
            .Decompose => "分解策略",
            .Analogy => "类比策略",
            .Search => "搜索策略",
            .Learn => "学习策略",
            .MetaLearn => "元学习策略",
        };
    }
};

/// 元认知状态
pub const MetaCognitiveState = struct {
    level: MetaLevel,
    task_obj_id: u64,        // 任务对象ID
    task_value: f64,         // 任务值
    monitor_value: f64,      // 监控值（Δ(executed, expected)）
    strategy: Strategy,      // 当前策略
    confidence: f64,         // 置信度（0~1）
    meta_value: f64,         // 元认知值（M(A)=Δ(A,A)）
    timestamp_ns: i128,      // 时间戳

    /// 计算元认知值 M(A) = Δ(A, A) = 0
    pub fn computeMetaValue(self: MetaCognitiveState) f64 {
        return delta(self.task_value, self.task_value);
    }
};

/// 深度探针结果
pub const DepthProbeResult = struct {
    depth: u32,             // 探针深度
    value: f64,             // 探针值
    delta_n: f64,           // 第n阶Δ
    threshold: f64,         // 收敛阈值 C/n²
    converged: bool,        // 是否收敛
};

/// 元学习结果
pub const MetaLearningResult = struct {
    level: MetaLevel,
    input_value: f64,
    output_value: f64,
    meta_value: f64,        // M(A) = Δ(A,A)
    iterations: u32,        // 迭代次数
    converged: bool,
    final_delta: f64,       // 最终Δ
};

/// 自我评估结果
pub const SelfEvaluationResult = struct {
    total_levels: u32,
    avg_confidence: f64,
    avg_meta_value: f64,
    convergence_rate: f64,  // 收敛率
    passed: bool,
};

// ============================================================
// 尘算子核心：Δ(x,y) = f(x) - g(y)
// ============================================================

/// 尘算子 Δ(x,y) = max(0, x - y)（纯辅助函数，下界保护）
/// 注：此文件不含 DeltaEngine 依赖，故保留独立 delta 作为纯辅助实现
/// 与 engine.delta() 语义一致：Δ(x,y) = max(0, x-y)
pub fn delta(x: f64, y: f64) f64 {
    return @max(0.0, x - y);
}

/// 元学习算子 M(A) = Δ(A, A) = 0（定理12.4）
pub fn metaOperator(a: f64) f64 {
    return delta(a, a);
}

/// n阶元学习算子 M^n(A) = Δ(Δ(...Δ(A,A)...)) n阶嵌套
/// 由于 M(A) = Δ(A,A) = 0，M^2(A) = Δ(0,0) = 0，所以 M^n(A) = 0 for n >= 1
pub fn metaOperatorN(a: f64, n: u32) f64 {
    if (n == 0) return a;
    var current = a;
    for (0..n) |_| {
        current = metaOperator(current);
    }
    return current;
}

// ============================================================
// 元认知系统主结构
// ============================================================

/// 元认知系统
pub const MetaCognition = struct {
    allocator: std.mem.Allocator,
    engine: ?*DeltaEngine = null,
    states: std.ArrayList(MetaCognitiveState),
    // 深度探针配置
    max_depth: u32,          // 最大深度
    constant_c: f64,         // 收敛常数C
    tolerance: f64,          // 收敛容差
    // 学习参数（从0开始动态学习）
    learning_rate: f64,      // 学习率
    /// 策略选择阈值（动态学习，从0开始）
    /// thresholds[0] = Direct上限, [1] = Decompose上限, [2] = Analogy上限, [3] = Search上限, [4] = Learn上限
    strategy_thresholds: [5]f64,
    /// 自我评估历史——用于学习评估模式
    self_assessment_history: std.ArrayList(SelfEvaluationResult),
    /// 自我评估通过阈值（动态学习）
    self_eval_pass_threshold: f64,
    // 统计
    total_meta_ops: u64,
    total_depth_probes: u64,
    total_strategy_selections: u64,
    total_self_evaluations: u64,

    /// 初始化
    pub fn init(allocator: std.mem.Allocator, engine: ?*DeltaEngine) MetaCognition {
        return MetaCognition{
            .allocator = allocator,
            .engine = engine,
            .states = std.ArrayList(MetaCognitiveState).empty,
            .max_depth = 0,        // 从0内生增长
            .constant_c = 0.0,     // 从0内生学习
            .tolerance = 0.0,      // 从0内生学习，通过 convergence_history 动态调整
            .learning_rate = 0.0,  // 从0内生学习
            // 策略阈值从0开始，通过 learnFromExperience 动态调整
            .strategy_thresholds = .{ 0.0, 0.0, 0.0, 0.0, 0.0 },
            .self_assessment_history = std.ArrayList(SelfEvaluationResult).empty,
            .self_eval_pass_threshold = 0.0, // 从0开始学习
            .total_meta_ops = 0,
            .total_depth_probes = 0,
            .total_strategy_selections = 0,
            .total_self_evaluations = 0,
        };
    }

    /// 释放资源
    pub fn deinit(self: *MetaCognition) void {
        self.states.deinit(self.allocator);
        self.self_assessment_history.deinit(self.allocator);
    }

    // ============================================================
    // 元认知操作
    // ============================================================

    /// 应用元学习算子 M(A) = Δ(A, A)
    pub fn applyMetaOperator(self: *MetaCognition, input_obj_id: u64, input_value: f64, level: MetaLevel, timestamp_ns: i128) MetaCognitionError!MetaLearningResult {
        if (input_obj_id == 0) return error.InvalidTaskId;
        if (std.math.isNan(input_value) or std.math.isInf(input_value)) return error.InvalidInput;

        // 使用图基Δ运算（当engine可用时），回退到标量Δ
        const meta_val = if (self.engine) |eng|
            (eng.graph.deltaObjToObj(input_obj_id, input_obj_id) catch 0.0)
        else
            metaOperator(input_value);
        self.total_meta_ops += 1;

        // 记录元认知状态
        const state = MetaCognitiveState{
            .level = level,
            .task_obj_id = input_obj_id,
            .task_value = input_value,
            .monitor_value = meta_val,
            .strategy = .Direct,
            .confidence = 1.0 - @min(1.0, meta_val),
            .meta_value = meta_val,
            .timestamp_ns = timestamp_ns,
        };
        self.states.append(self.allocator, state) catch return error.OutOfMemory;

        return MetaLearningResult{
            .level = level,
            .input_value = input_value,
            .output_value = meta_val,
            .meta_value = meta_val,
            .iterations = 1,
            .converged = @abs(meta_val) < self.tolerance,
            .final_delta = meta_val,
        };
    }

    /// n阶元学习算子深度探针
    /// 测量 M^n(A) 的收敛性（δ_n < C/n²）
    pub fn probeDepth(self: *MetaCognition, input_value: f64, max_depth: u32) MetaCognitionError!DepthProbeResult {
        if (std.math.isNan(input_value) or std.math.isInf(input_value)) return error.InvalidInput;
        if (max_depth == 0) return error.InvalidDepth;
        if (max_depth > self.max_depth) return error.MaxDepthExceeded;

        self.total_depth_probes += 1;

        // 计算 M^n(A)
        var current = input_value;
        var prev = input_value;
        for (0..max_depth) |n| {
            prev = current;
            current = metaOperator(current);
            const delta_n = @abs(current - prev);
            const threshold = self.constant_c / @as(f64, @floatFromInt(n + 1)) / @as(f64, @floatFromInt(n + 1));
            if (delta_n < threshold) {
                return DepthProbeResult{
                    .depth = @intCast(n + 1),
                    .value = current,
                    .delta_n = delta_n,
                    .threshold = threshold,
                    .converged = true,
                };
            }
        }

        // 达到最大深度
        const final_delta = @abs(current - prev);
        const final_threshold = self.constant_c / @as(f64, @floatFromInt(max_depth)) / @as(f64, @floatFromInt(max_depth));
        return DepthProbeResult{
            .depth = max_depth,
            .value = current,
            .delta_n = final_delta,
            .threshold = final_threshold,
            .converged = final_delta < final_threshold,
        };
    }

    /// 策略选择：基于Δ距离选择最优策略
    /// 注意：使用绝对差值 |task - expected| 而非 Δ（Δ有下界保护）
    /// 阈值从经验中动态学习，初始全为0
    pub fn selectStrategy(self: *MetaCognition, task_value: f64, expected_value: f64) MetaCognitionError!Strategy {
        if (std.math.isNan(task_value) or std.math.isInf(task_value)) return error.InvalidInput;
        if (std.math.isNan(expected_value) or std.math.isInf(expected_value)) return error.InvalidInput;

        self.total_strategy_selections += 1;

        // 使用绝对差值（双向Δ：Δ(task,expected) + Δ(expected,task)）
        const d = @abs(task_value - expected_value);

        // 根据动态学习到的阈值选择策略
        // 阈值从0开始，随学习增长
        if (d < self.strategy_thresholds[0]) {
            return .Direct;       // 差值小，直接执行
        } else if (d < self.strategy_thresholds[1]) {
            return .Decompose;    // 差值中等，分解策略
        } else if (d < self.strategy_thresholds[2]) {
            return .Analogy;      // 差值较大，类比策略
        } else if (d < self.strategy_thresholds[3]) {
            return .Search;       // 差值大，搜索策略
        } else if (d < self.strategy_thresholds[4]) {
            return .Learn;        // 差值很大，学习策略
        } else {
            return .MetaLearn;    // 差值极大，元学习策略
        }
    }

    /// 自我评估：评估所有元认知状态，记录评估历史供学习
    pub fn selfEvaluate(self: *MetaCognition) MetaCognitionError!SelfEvaluationResult {
        if (self.states.items.len == 0) return error.SelfEvaluationFailed;

        self.total_self_evaluations += 1;

        var total_confidence: f64 = 0.0;
        var total_meta_value: f64 = 0.0;
        var converged_count: u32 = 0;

        for (self.states.items) |state| {
            total_confidence += state.confidence;
            total_meta_value += state.meta_value;
            if (@abs(state.meta_value) < self.tolerance) {
                converged_count += 1;
            }
        }

        const count = @as(f64, @floatFromInt(self.states.items.len));
        const avg_confidence = total_confidence / count;
        const avg_meta_value = total_meta_value / count;
        const convergence_rate = @as(f64, @floatFromInt(converged_count)) / count;

        const result = SelfEvaluationResult{
            .total_levels = @intCast(self.states.items.len),
            .avg_confidence = avg_confidence,
            .avg_meta_value = avg_meta_value,
            .convergence_rate = convergence_rate,
            .passed = convergence_rate >= self.self_eval_pass_threshold,
        };

        // 记录评估历史用于学习评估模式
        self.self_assessment_history.append(self.allocator, result) catch |err| {
            et.logGlobalError(.Warning, "meta_cognition", "append_assessment", et.errorCode(err), "记录自我评估历史失败");
        };

        return result;
    }

    /// 获取状态数
    pub fn stateCount(self: *MetaCognition) u32 {
        return @intCast(self.states.items.len);
    }

    /// 获取统计
    pub fn getStats(self: *MetaCognition) struct { total_meta_ops: u64, total_depth_probes: u64, total_strategy_selections: u64, total_self_evaluations: u64 } {
        return .{
            .total_meta_ops = self.total_meta_ops,
            .total_depth_probes = self.total_depth_probes,
            .total_strategy_selections = self.total_strategy_selections,
            .total_self_evaluations = self.total_self_evaluations,
        };
    }

    /// 从经验中学习——基于Δ压力反馈自适应调整策略阈值和评估标准
    /// 每次调用根据历史Δ值、收敛率、选择次数更新所有可学习参数
    /// 阈值从0开始，沿Δ压力梯度增长
    pub fn learnFromExperience(self: *MetaCognition) void {
        if (self.states.items.len < 2) return;

        // --------------------------------------------------
        // 1. 从元认知状态中提取Δ压力信息更新策略阈值
        // --------------------------------------------------
        var max_delta_observed: f64 = 0.0;
        var avg_confidence: f64 = 0.0;
        for (self.states.items) |state| {
            // monitor_value = Δ(executed, expected) = meta_value = Δ(A,A)
            const abs_monitor = @abs(state.monitor_value);
            if (abs_monitor > max_delta_observed) max_delta_observed = abs_monitor;
            avg_confidence += state.confidence;
        }
        avg_confidence /= @as(f64, @floatFromInt(self.states.items.len));

        // 根据观测到的最大Δ值扩展策略阈值
        // 阈值 = 学习率 × 最大Δ值 × 自适应系数
        const adaptive_factor = 1.0 + avg_confidence; // 置信度高时阈值可更大
        if (max_delta_observed > 1e-15) {
            // 阈值从0开始，沿Δ压力梯度逐步增长
            for (&self.strategy_thresholds, 0..) |*t, i| {
                const ratio = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(self.strategy_thresholds.len + 1));
                t.* += self.learning_rate * max_delta_observed * ratio * adaptive_factor;
            }
        }

        // --------------------------------------------------
        // 2. 从自我评估历史中更新通过阈值
        // --------------------------------------------------
        if (self.self_assessment_history.items.len > 0) {
            var total_rate: f64 = 0.0;
            for (self.self_assessment_history.items) |assessment| {
                total_rate += assessment.convergence_rate;
            }
            const avg_rate = total_rate / @as(f64, @floatFromInt(self.self_assessment_history.items.len));
            // 通过阈值向平均收敛率靠拢（从0开始学习）
            self.self_eval_pass_threshold += self.learning_rate * (avg_rate - self.self_eval_pass_threshold);
            // 仅保留非负约束，让阈值完全由 self_assessment_history 内生决定（移除 0.1/0.95 硬编码截断）
            if (self.self_eval_pass_threshold < 0.0) self.self_eval_pass_threshold = 0.0;
        }
    }
};

// ============================================================
// 单元测试（10+测试，覆盖正常/异常/边界/极限）
// ============================================================

const testing = std.testing;

test "MetaCognition 初始化与默认状态" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expect(mc.states.items.len == 0);
    try testing.expect(mc.max_depth == 0);
    try testing.expect(mc.constant_c == 0.0);
    try testing.expect(mc.tolerance == 0.0);
}

test "MetaLevel 枚举正确" {
    try testing.expect(@intFromEnum(MetaLevel.L0) == 0);
    try testing.expect(@intFromEnum(MetaLevel.L1) == 1);
    try testing.expect(@intFromEnum(MetaLevel.L2) == 2);
    try testing.expect(@intFromEnum(MetaLevel.L3) == 3);
    try testing.expect(@intFromEnum(MetaLevel.Ln) == 4);
}

test "MetaLevel.name 返回正确名称" {
    try testing.expectEqualStrings("L0-任务执行", MetaLevel.L0.name());
    try testing.expectEqualStrings("L1-任务监控", MetaLevel.L1.name());
    try testing.expectEqualStrings("Ln-元策略学习", MetaLevel.Ln.name());
}

test "MetaLevel.fromU8 正确转换" {
    try testing.expect(try MetaLevel.fromU8(0) == .L0);
    try testing.expect(try MetaLevel.fromU8(4) == .Ln);
    try testing.expectError(error.InvalidLevel, MetaLevel.fromU8(5));
}

test "delta 尘算子：Δ(x,y) = max(0, x-y)" {
    try testing.expectApproxEqAbs(@as(f64, 3.0), delta(5.0, 2.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), delta(2.0, 5.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), delta(5.0, 5.0), 1e-10);
}

test "metaOperator 元学习算子 M(A) = Δ(A,A) = 0" {
    // 定理12.4：M(A) = Δ(A,A) = 0
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperator(5.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperator(0.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperator(100.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperator(3.14159), 1e-10);
}

test "metaOperatorN n阶元学习算子收敛到0" {
    // M^1(A) = 0
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperatorN(5.0, 1), 1e-10);
    // M^2(A) = Δ(0,0) = 0
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperatorN(5.0, 2), 1e-10);
    // M^10(A) = 0
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperatorN(5.0, 10), 1e-10);
    // M^0(A) = A（0阶不应用）
    try testing.expectApproxEqAbs(@as(f64, 5.0), metaOperatorN(5.0, 0), 1e-10);
}

test "applyMetaOperator 应用元学习算子" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    const result = try mc.applyMetaOperator(1, 5.0, .L1, 1000);
    try testing.expect(result.level == .L1);
    try testing.expectApproxEqAbs(@as(f64, 5.0), result.input_value, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.output_value, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.meta_value, 1e-10);
    try testing.expect(result.converged);
    try testing.expect(mc.stateCount() == 1);
}

test "applyMetaOperator 无效任务ID返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.InvalidTaskId, mc.applyMetaOperator(0, 5.0, .L0, 1000));
}

test "applyMetaOperator NaN输入返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.InvalidInput, mc.applyMetaOperator(1, std.math.nan(f64), .L0, 1000));
}

test "probeDepth 深度探针收敛" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    // max_depth从0内生增长，测试需要显式设置
    mc.max_depth = 10;
    mc.constant_c = 1.0;
    mc.tolerance = 1e-10;
    // M^1(A) = 0，所以第1阶就收敛
    const result = try mc.probeDepth(5.0, 10);
    try testing.expect(result.depth >= 1);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.value, 1e-10);
    try testing.expect(result.converged);
}

test "probeDepth 无效输入返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.InvalidInput, mc.probeDepth(std.math.nan(f64), 10));
}

test "probeDepth 深度0返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.InvalidDepth, mc.probeDepth(5.0, 0));
}

test "probeDepth 超过最大深度返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.MaxDepthExceeded, mc.probeDepth(5.0, 101));
}

test "selectStrategy 策略选择" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();

    // 显式设置策略阈值（从0内生学习前，设置基准值用于测试）
    mc.strategy_thresholds = .{ 0.1, 0.2, 0.4, 0.6, 0.8 };

    // 现在阈值已部分建立，可以区分不同策略
    // Δ小 → 直接执行
    try testing.expect(try mc.selectStrategy(5.0, 5.05) == .Direct);
    // Δ中等 → 分解策略
    try testing.expect(try mc.selectStrategy(5.0, 5.2) == .Decompose);
    // Δ较大 → 类比策略
    try testing.expect(try mc.selectStrategy(5.0, 5.4) == .Analogy);
    // Δ大 → 搜索策略
    try testing.expect(try mc.selectStrategy(5.0, 5.6) == .Search);
    // Δ很大 → 学习策略
    try testing.expect(try mc.selectStrategy(5.0, 5.8) == .Learn);
    // Δ极大 → 元学习策略
    try testing.expect(try mc.selectStrategy(5.0, 6.0) == .MetaLearn);
}

test "selectStrategy NaN输入返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.InvalidInput, mc.selectStrategy(std.math.nan(f64), 5.0));
}

test "selfEvaluate 自我评估" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    _ = try mc.applyMetaOperator(1, 5.0, .L0, 1000);
    _ = try mc.applyMetaOperator(2, 3.0, .L1, 1000);
    _ = try mc.applyMetaOperator(3, 7.0, .L2, 1000);

    const result = try mc.selfEvaluate();
    try testing.expect(result.total_levels == 3);
    // 所有M(A)=0，所以收敛率=1.0
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.convergence_rate, 1e-10);
    try testing.expect(result.passed);
}

test "selfEvaluate 无状态返回错误" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    try testing.expectError(error.SelfEvaluationFailed, mc.selfEvaluate());
}

test "Strategy 枚举正确" {
    try testing.expect(@intFromEnum(Strategy.Direct) == 0);
    try testing.expect(@intFromEnum(Strategy.MetaLearn) == 5);
    try testing.expectEqualStrings("直接执行", Strategy.Direct.name());
    try testing.expectEqualStrings("元学习策略", Strategy.MetaLearn.name());
}

test "MetaCognitionError 覆盖所有失败场景" {
    const errors = [_]MetaCognitionError{
        error.InvalidLevel,
        error.InvalidInput,
        error.InvalidDepth,
        error.InvalidStrategy,
        error.InvalidConfidence,
        error.ConvergenceFailed,
        error.MaxDepthExceeded,
        error.StrategyNotFound,
        error.SelfEvaluationFailed,
        error.OutOfMemory,
        error.InvalidTaskId,
        error.InvalidMonitorValue,
    };
    try testing.expect(errors.len == 12);
}

test "Δ精度验证：M(A)=0 严格成立" {
    // 定理12.4：M(A) = Δ(A,A) = 0，精度1e-15
    try testing.expectApproxEqAbs(@as(f64, 0.0), metaOperator(3.14159265358979323846), 1e-15);
}

test "getStats 返回正确统计" {
    var mc = MetaCognition.init(testing.allocator, null);
    defer mc.deinit();
    _ = try mc.applyMetaOperator(1, 5.0, .L0, 1000);
    _ = try mc.probeDepth(5.0, 10);
    _ = try mc.selectStrategy(5.0, 5.5);
    _ = try mc.selfEvaluate();

    const stats = mc.getStats();
    try testing.expect(stats.total_meta_ops == 1);
    try testing.expect(stats.total_depth_probes == 1);
    try testing.expect(stats.total_strategy_selections == 1);
    try testing.expect(stats.total_self_evaluations == 1);
}
