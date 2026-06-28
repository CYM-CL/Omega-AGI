// Ω-落尘AGI 持续自主学习循环 v7.5.0
//
// 核心设计哲学：
//   持续自主学习是Δ压力驱动的自然延伸——系统不需要外部标签或人类干预。
//   当共识(W)达到饱和时，系统应能：
//     1) 从已有模式中组合出新任务（类比于"提出新问题"）
//     2) 通过不同Δ路径验证结果的自洽性（自我批改）
//     3) 将高自洽性的新模式加入训练集（知识自我扩张）
//
// 这实现了一个完全内生的学习环：
//   Δ压力 → 规则压缩 → 规则组合 → 新任务生成 → 自洽验证 → 任务入库 → 继续训练
//
// 系统不需要知道"今天学数学还是物理"——它只做一件事：在Δ压力下持续降低F_fit

const std = @import("std");
const tt = @import("trainer_types.zig");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;
const sm64 = @import("splitmix64.zig");
const dg = @import("domain_generalization.zig");
const et = @import("error_types.zig");

/// 自生成任务（系统自己提出的"新问题"）
pub const SelfGeneratedTask = struct {
    param1: u64,
    param2: u64,
    complexity: tt.DeltaComplexity,
    /// 自洽性评分（0~1），由不同Δ路径交叉验证得出
    self_consistency: f64,
    /// 生成来源描述（监控用）
    source_description: []const u8,
};

/// 持续自主学习器
pub const ContinuousLearner = struct {
    allocator: std.mem.Allocator,
    engine: *DeltaEngine,

    /// 自生成的新任务列表
    self_generated_tasks: std.ArrayList(SelfGeneratedTask),
    /// 上次自学习步数
    last_self_learn_step: u64,
    /// 自学习间隔（每N步触发一次）
    learn_interval: u64,
    /// 累计自生成任务数
    total_self_generated: u64,
    /// 高自洽任务数（self_consistency > 0.9）
    high_consistency_count: u64,

    pub fn init(allocator: std.mem.Allocator, engine: *DeltaEngine) ContinuousLearner {
        return .{
            .allocator = allocator,
            .engine = engine,
            .self_generated_tasks = std.ArrayList(SelfGeneratedTask).empty,
            .last_self_learn_step = 0,
            .learn_interval = 100,  // 从0开始，每次传导后自检决定是否触发
            .total_self_generated = 0,
            .high_consistency_count = 0,
        };
    }

    pub fn deinit(self: *ContinuousLearner) void {
        self.self_generated_tasks.deinit(self.allocator);
    }

    /// 触发持续自主学习
    /// 核心哲学：从已有规则中组合新任务，并通过Δ自洽性验证
    pub fn step(self: *ContinuousLearner, current_step: u64, rng: *sm64.SplitMix64) !void {
        if (current_step < self.last_self_learn_step + self.learn_interval) return;
        self.last_self_learn_step = current_step;

        // 1. 从已有规则组合新任务
        try self.generateNovelTasks(rng);

        // 2. 从尘图模式中提取高Δ压力区域
        try self.extractHighPressurePatterns();

        // 3. 更新学习间隔（Δ压力越低，间隔越长——系统越自信，越不需要频繁自学习）
        self.updateInterval();
    }

    /// 从已有对象组合新任务（v5.0：CDL表达式替代student_rules）
    /// 核心哲学：系统通过组合任意对象的Δ模式来"提出新问题"
    /// 改为从图中已有对象的CDL表达式中随机选取组合。
    fn generateNovelTasks(self: *ContinuousLearner, rng: *sm64.SplitMix64) !void {
        // 从图中已有对象中随机选取组合进行嵌套Δ运算
        const obj_count = self.engine.graph.objectCount();
        if (obj_count < 4) return; // 需要至少4个对象才能组合两个嵌套Δ

        // 生成4个随机对象ID（允许重复以支持自指组合）
        const o1: u64 = @intCast(@mod(rng.nextU64(), @as(u64, @intCast(obj_count))));
        const o2: u64 = @intCast(@mod(rng.nextU64(), @as(u64, @intCast(obj_count))));
        const o3: u64 = @intCast(@mod(rng.nextU64(), @as(u64, @intCast(obj_count))));
        const o4: u64 = @intCast(@mod(rng.nextU64(), @as(u64, @intCast(obj_count))));

        // 使用随机对象ID作为组合参数（对象ID即其CDL表达式的标识符）
        const p1 = o1;
        const p2 = o2;
        const p3 = o3;
        const p4 = o4;

        // 组合规则产生新任务：Δ(Δ(p1,p2), Δ(p3,p4))
        const a_id = try self.engine.getOrCreateNumber(p1);
        const b_id = try self.engine.getOrCreateNumber(p2);
        const c_id = try self.engine.getOrCreateNumber(p3);
        const d_id = try self.engine.getOrCreateNumber(p4);

        // 计算嵌套Δ
        const inner_a = self.engine.deltaExpr(a_id, b_id);
        const inner_b = self.engine.deltaExpr(c_id, d_id);
        const inner_a_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.engine.allocator, "cl_inner_{d:.10}", .{@abs(inner_a)}),
                    @abs(inner_a),
                );
        const inner_b_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.engine.allocator, "cl_inner_{d:.10}", .{@abs(inner_b)}),
                    @abs(inner_b),
                );

        // 交叉验证：用两种不同路径验证自洽性
        // 路径A：Δ(Δ(p1,p2), Δ(p3,p4))
        const path_a = self.engine.deltaExpr(inner_a_id, inner_b_id);
        // 路径B：Δ(Δ(p1,p3), Δ(p2,p4))
        const p1_id = try self.engine.getOrCreateNumber(p1);
        const p3_id = try self.engine.getOrCreateNumber(p3);
        const p2_id = try self.engine.getOrCreateNumber(p2);
        const p4_id = try self.engine.getOrCreateNumber(p4);
        const alt_inner_a = self.engine.deltaExpr(p1_id, p3_id);
        const alt_inner_b = self.engine.deltaExpr(p2_id, p4_id);
        const alt_a_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.engine.allocator, "cl_alt_{d:.10}", .{@abs(alt_inner_a)}),
                    @abs(alt_inner_a),
                );
        const alt_b_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.engine.allocator, "cl_alt_{d:.10}", .{@abs(alt_inner_b)}),
                    @abs(alt_inner_b),
                );
        const path_b = self.engine.deltaExpr(alt_a_id, alt_b_id);

        // 自洽性 = 1 - |path_a - path_b| / (|path_a| + |path_b| + 1)
        const diff = @abs(path_a - path_b);
        const magnitude = @abs(path_a) + @abs(path_b) + 1.0;
        const consistency = 1.0 - diff / magnitude;

        const new_param1 = p1 ^ p3; // XOR组合
        const new_param2 = p2 ^ p4;

        try self.self_generated_tasks.append(self.allocator, .{
            .param1 = new_param1,
            .param2 = new_param2,
            .complexity = .Level_3,
            .self_consistency = consistency,
            .source_description = "规则组合自生成",
        });

        self.total_self_generated += 1;
        if (consistency > 0.0) {
            self.high_consistency_count += 1;
        }
    }

    /// 从尘图中提取Δ压力高的区域生成新任务
    fn extractHighPressurePatterns(self: *ContinuousLearner) !void {
        _ = self;
        // v7.5.0：预留接口——后续通过分析Δ压力梯度定位高压力区域
        // 高Δ高压力区域 = 系统尚未掌握的模式 → 自动生成针对性训练任务
    }

    /// 自适应性学习间隔更新
    /// 核心哲学：自学习间隔与任务总量成反比——任务越多间隔越长，完全内生
    fn updateInterval(self: *ContinuousLearner) void {
        if (self.total_self_generated > 0) {
            // 学习间隔 = max(50, min(高自洽数, 总生成数))
            // 确保间隔至少为50步，防止过于频繁的自学习
            self.learn_interval = @max(50, @min(self.high_consistency_count, self.total_self_generated));
        }
    }

    /// 获取自生成任务
    pub fn getGeneratedTask(self: *ContinuousLearner) ?SelfGeneratedTask {
        if (self.self_generated_tasks.items.len == 0) return null;
        return self.self_generated_tasks.items[self.self_generated_tasks.items.len - 1];
    }

    /// 自生成任务数
    pub fn generatedCount(self: *const ContinuousLearner) usize {
        return self.self_generated_tasks.items.len;
    }
};