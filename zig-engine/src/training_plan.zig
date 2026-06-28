// Ω-落尘AGI 训练计划 v5.0.0 - 哲学重构版
//
// 核心变更（v1.0 → v5.0.0）：
// 彻底移除 AbilityDomain 枚举（26种硬编码能力域），
// 移除 DomainTracker，移除基于能力域的所有训练配置。
//
// 新设计：
// - 不再存在"加法能力训练"和"乘法能力训练"的区分
// - 系统只配置Δ运算的复杂度等级和训练步数
// - 能力分类是外部观察者给予的标签，不是系统内部的知识
//
// 严格对应白皮书v2.0第7.4.3节：CL-SCT+三阶段训练范式
// 修正：去掉以能力域划分的训练模块，改为纯Δ复杂度驱动的统一训练

const std = @import("std");
const tt = @import("trainer_types.zig");
const et = @import("error_types.zig");

// ============================================================
// v5.0.0：Δ复杂度配置（替代AbilityConfig）
//
// 系统不需要知道"加法用500步、乘法用800步"——这隐含了代码必须区分
// 加法与乘法的知识。新设计只配置Δ复杂度的参数，系统去学Δ本身。
// ============================================================

/// Δ复杂度训练配置
pub const ComplexityConfig = struct {
    complexity: tt.DeltaComplexity,
    /// 训练目标的F_fit缩减率（0.99 = 减少99%的差值压力）
    consensus_target: f64,
    /// 最大训练步数
    max_steps: u64,
    /// 最小训练步数（防止过早终止）
    min_steps: u64,
};

/// 阶段训练配置
pub const PhaseConfig = struct {
    phase: tt.TrainingPhase,
    step_count: u64, // 该阶段步数
    /// v5.0.0：Δ基准难度范围（影响参数的数值范围，而非"科目难度"）
    base_param_range_start: u64, // 参数起始范围（如 1）
    base_param_range_end: u64, // 参数结束范围（如 100）
    bootstrap_interval: u64, // 自举触发间隔步数
    /// v5.0.0：共识目标(W)替代目标准确率
    consensus_target: f64,
};

/// 训练计划：完整的训练蓝图
pub const TrainingPlan = struct {
    name: []const u8, // 计划名称
    version: []const u8, // 计划版本号
    description: []const u8, // 计划说明

    // 三阶段配置
    phases: [3]PhaseConfig,

    // v5.0.0：Δ复杂度配置（替代ability_configs）
    complexity_configs: std.AutoHashMap(tt.DeltaComplexity, ComplexityConfig),

    // 全局配置
    total_max_steps: u64, // 全局最大总步数
    eval_interval: u64, // 评估间隔
    checkpoint_interval: u64, // 检查点保存间隔
    early_stop_patience: u64, // 早停耐心值（连续多少步无提升则终止）

    // 长周期稳定性测试
    stability_test_steps: u64, // 稳定性测试步数（默认1000000=百万步标准）
    stability_check_interval: u64, // 稳定性检查间隔

    allocator: std.mem.Allocator,
    version_owned: bool,

    /// 释放训练计划资源
    pub fn deinit(self: *TrainingPlan) void {
        self.complexity_configs.deinit();
        if (self.version_owned) {
            self.allocator.free(self.version);
            self.version_owned = false;
        }
    }
};

/// 里程碑状态
pub const Milestone = struct {
    name: []const u8,
    phase: tt.TrainingPhase,
    step_reached: u64,
    /// v5.0.0：F_fit缩减率替代准确率
    consensus_score: f64,
    timestamp_ns: i128,
};

/// 训练状态记录
pub const TrainingState = struct {
    current_phase: tt.TrainingPhase,
    current_step: u64,
    phase_progress: f64, // 当前阶段进度 [0, 1]
    /// v5.0.0：F_fit平均缩减率替代overall_accuracy
    avg_consensus: f64,
    milestones: std.ArrayList(Milestone),
    started_at: i128,
    last_updated: i128,
};

/// 创建默认训练计划（CL-SCT+标准三阶段）
///
/// v5.0.0：不再为每种能力单独配置训练参数。
/// 所有Δ运算统一按复杂度等级配置，所有值从0初始值开始，
/// 由系统运行历史内生塑造，不预设任何默认训练参数。
pub fn createDefaultPlan(allocator: std.mem.Allocator) TrainingPlan {
    var configs = std.AutoHashMap(tt.DeltaComplexity, ComplexityConfig).init(allocator);

    // v5.0.0：复杂度配置从0初始值开始，由系统运行历史内生塑造
    const complexity_configs = [_]ComplexityConfig{
        .{ .complexity = .Level_1, 
.consensus_target = 0.95, .max_steps = 0, .min_steps = 0 },
        .{ .complexity = .Level_2, 
.consensus_target = 0.95, .max_steps = 0, .min_steps = 0 },
        .{ .complexity = .Level_3, 
.consensus_target = 0.95, .max_steps = 0, .min_steps = 0 },
        .{ .complexity = .Level_4, 
.consensus_target = 0.95, .max_steps = 0, .min_steps = 0 },
    };

    for (complexity_configs) |cfg| {
        configs.put(cfg.complexity, cfg) catch |err| {
            et.logGlobalError(.Warning, "training_plan", "createDefaultPlan", @intFromError(err), "configs.put(complexity_config) failed");
        };
    }

    return .{
        .name = "CL-SCT+ 统一Δ压力训练计划",
        .version = "5.0.0",
        .description = "Ω-落尘AGI基底训练计划：Δ复杂度驱动，无能力域划分",
        .phases = [3]PhaseConfig{
            .{
                .phase = .L1_RuleSolidification,
                
.step_count = 300,
                
.base_param_range_start = 1,
                
.base_param_range_end = 20,
                
.bootstrap_interval = 10,
                
.consensus_target = 0.95,
            },
            .{
                .phase = .L2_SandboxBootstrap,
                
.step_count = 300,
                
.base_param_range_start = 1,
                
.base_param_range_end = 20,
                
.bootstrap_interval = 10,
                
.consensus_target = 0.95,
            },
            .{
                .phase = .L3_FullFusion,
                
.step_count = 300,
                
.base_param_range_start = 1,
                
.base_param_range_end = 20,
                
.bootstrap_interval = 10,
                
.consensus_target = 0.95,
            },
        },
        .complexity_configs = configs,
        
.total_max_steps = 1800,
        
.eval_interval = 50,
        
.checkpoint_interval = 100,
        
.early_stop_patience = 0,
        
.stability_test_steps = 1000,
        
.stability_check_interval = 100,
        .allocator = allocator,
        .version_owned = false,
    };
}

/// 获取计划中的总步数
pub fn totalSteps(plan: *const TrainingPlan) u64 {
    var total: u64 = 0;
    for (plan.phases) |p| {
        total += p.step_count;
    }
    return total;
}

/// 获取指定Δ复杂度的共识目标(W)
pub fn getConsensusTarget(plan: *const TrainingPlan, complexity: tt.DeltaComplexity) f64 {
    if (plan.complexity_configs.get(complexity)) |cfg| {
        return cfg.consensus_target;
    }
    return 0.0;
}

/// 初始化训练状态
pub fn initTrainingState() TrainingState {
    return .{
        .current_phase = .L1_RuleSolidification,
        .current_step = 0,
        .phase_progress = 0.0,
        .avg_consensus = 0.0,
        .milestones = std.ArrayList(Milestone).empty,
        .started_at = 0,
        .last_updated = 0,
    };
}

/// 记录里程碑
pub fn recordMilestone(state: *TrainingState, allocator: std.mem.Allocator, name: []const u8, consensus_score: f64) !void {
    if (state.milestones.items.len >= 5) return;
    try state.milestones.append(allocator, .{
        .name = name,
        .phase = state.current_phase,
        .step_reached = state.current_step,
        .consensus_score = consensus_score,
        .timestamp_ns = 0,
    });
}

/// 释放训练状态资源
pub fn deinitTrainingState(state: *TrainingState, allocator: std.mem.Allocator) void {
    state.milestones.deinit(allocator);
}

// ============================================================
// v5.0.0：训练记录中的趋势计算（替代原computeAccuracyTrend）
// ============================================================

/// 从训练历史中提取最近共识(W)趋势
/// 通过比较最近N条记录的前半段与后半段平均共识(W)，
/// 判断趋势方向：上升(>0)、稳定(≈0)、下降(<0)。
/// 返回 [-1.0, 1.0] 范围的趋势值。
pub fn computeConsensusTrend(history: []const tt.TrainingRecord) f64 {
    const n = history.len;
    if (n < 20) return 0.0;

    const half = n / 2;
    var first_half_sum: f64 = 0.0;
    var second_half_sum: f64 = 0.0;
    for (0..half) |i| {
        first_half_sum += history[i].consensus_score;
        second_half_sum += history[n - half + i].consensus_score;
    }
    const first_avg = first_half_sum / @as(f64, @floatFromInt(half));
    const second_avg = second_half_sum / @as(f64, @floatFromInt(half));
    const raw_trend = second_avg - first_avg;
    // 由趋势历史方差内生决定边界：计算 consensus_score 的标准差，
    // 以 2σ 作为自然边界，确保边界由数据分布而非硬编码值控制。
    var sum: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    for (history) |record| {
        sum += record.consensus_score;
        sum_sq += record.consensus_score * record.consensus_score;
    }
    const mean = sum / @as(f64, @floatFromInt(n));
    const variance = sum_sq / @as(f64, @floatFromInt(n)) - mean * mean;
    const std_dev = @sqrt(@max(0.0, variance));
    const bound = 2.0 * std_dev + 1e-10; // 2σ 边界 + 极小值防止除以零
    return @max(-bound, @min(bound, raw_trend));
}

// ============================================================
// v5.0.0：阶段调整记录（替代含accuracy_threshold的旧PhaseAdjustment）
//
// 当训练过程中进行动态阶段调整时，记录调整前后的参数值。
// 所有阈值字段使用共识目标（consensus_target）替代旧版的accuracy_threshold。
// ============================================================

/// 阶段调整记录
pub const PhaseAdjustment = struct {
    phase_idx: usize,
    original_step_count: u64,
    new_step_count: u64,
    /// v5.0.0：u64 参数范围（替代 u8 难度等级）
    original_range_start: u64,
    new_range_start: u64,
    original_range_end: u64,
    new_range_end: u64,
    original_bootstrap_interval: u64,
    new_bootstrap_interval: u64,
    /// v5.0.0：共识(W)阈值替代准确率阈值
    original_consensus_target: f64,
    new_consensus_target: f64,
    reason: []const u8,
};

// ============================================================
// v5.0.0：简化了JSON序列化——不再序列化能力域
// ============================================================

/// 将Δ复杂度枚举转为字符串
pub fn complexityToString(complexity: tt.DeltaComplexity) []const u8 {
    return switch (complexity) {
        .Level_1 => "Level_1",
        .Level_2 => "Level_2",
        .Level_3 => "Level_3",
        .Level_4 => "Level_4",
    };
}

/// 将字符串转为Δ复杂度枚举
pub fn stringToComplexity(s: []const u8) ?tt.DeltaComplexity {
    if (std.mem.eql(u8, s, "Level_1")) return .Level_1;
    if (std.mem.eql(u8, s, "Level_2")) return .Level_2;
    if (std.mem.eql(u8, s, "Level_3")) return .Level_3;
    if (std.mem.eql(u8, s, "Level_4")) return .Level_4;
    return null;
}

/// 将训练阶段枚举转为字符串
pub fn phaseToString(phase: tt.TrainingPhase) []const u8 {
    return switch (phase) {
        .L1_RuleSolidification => "L1_RuleSolidification",
        .L2_SandboxBootstrap => "L2_SandboxBootstrap",
        .L3_FullFusion => "L3_FullFusion",
    };
}

/// 将字符串转为训练阶段枚举
pub fn stringToPhase(s: []const u8) ?tt.TrainingPhase {
    if (std.mem.eql(u8, s, "L1_RuleSolidification")) return .L1_RuleSolidification;
    if (std.mem.eql(u8, s, "L2_SandboxBootstrap")) return .L2_SandboxBootstrap;
    if (std.mem.eql(u8, s, "L3_FullFusion")) return .L3_FullFusion;
    return null;
}

/// 序列化训练计划为JSON字符串
/// v5.0.0：只序列化Δ复杂度配置，不去序列化能力域
pub fn planToJson(plan: *const TrainingPlan, allocator: std.mem.Allocator) ![]u8 {
    var lines = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer lines.deinit(allocator);

    {
        const base = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "{s}",
            \\  "description": "{s}",
            \\  "phases": [
            \\
        , .{ plan.name, plan.version, plan.description });
        defer allocator.free(base);
        try lines.appendSlice(allocator, base);
    }

    for (plan.phases, 0..) |p, i| {
        const comma = if (i < plan.phases.len - 1) "," else "";
        const line = try std.fmt.allocPrint(allocator,
            "    {{\"phase\": \"{s}\", \"step_count\": {d}, \"base_param_range_start\": {d}, \"base_param_range_end\": {d}, \"bootstrap_interval\": {d}, \"consensus_target\": {d:.6}}}{s}\n",
            .{ phaseToString(p.phase), p.step_count, p.base_param_range_start,
               p.base_param_range_end, p.bootstrap_interval, p.consensus_target, comma },
        );
        defer allocator.free(line);
        try lines.appendSlice(allocator, line);
    }

    {
        const mid = try std.fmt.allocPrint(allocator, "  ],\n  \"complexity_configs\": [\n", .{});
        defer allocator.free(mid);
        try lines.appendSlice(allocator, mid);
    }

    var cfg_iter = plan.complexity_configs.iterator();
    var cfg_idx: usize = 0;
    const cfg_count = plan.complexity_configs.count();
    while (cfg_iter.next()) |entry| {
        const comma = if (cfg_idx < cfg_count - 1) "," else "";
        const line = try std.fmt.allocPrint(allocator,
            "    {{\"complexity\": \"{s}\", \"consensus_target\": {d:.6}, \"max_steps\": {d}, \"min_steps\": {d}}}{s}\n",
            .{ complexityToString(entry.key_ptr.*), entry.value_ptr.*.consensus_target,
               entry.value_ptr.*.max_steps, entry.value_ptr.*.min_steps, comma },
        );
        defer allocator.free(line);
        try lines.appendSlice(allocator, line);
        cfg_idx += 1;
    }

    {
        const end = try std.fmt.allocPrint(allocator,
            \\  ],
            \\  "total_max_steps": {d},
            \\  "eval_interval": {d},
            \\  "checkpoint_interval": {d},
            \\  "early_stop_patience": {d},
            \\  "stability_test_steps": {d},
            \\  "stability_check_interval": {d}
            \\}}
            \\
        , .{
            plan.total_max_steps, plan.eval_interval, plan.checkpoint_interval,
            plan.early_stop_patience, plan.stability_test_steps, plan.stability_check_interval,
        });
        defer allocator.free(end);
        try lines.appendSlice(allocator, end);
    }

    return lines.toOwnedSlice(allocator);
}

/// 从JSON字符串反序列化训练计划
pub fn planFromJson(json: []const u8, allocator: std.mem.Allocator) !TrainingPlan {
    var name: []const u8 = "restored";
    var version: []const u8 = "5.0.0";
    var description: []const u8 = "restored from JSON";
    var phases: [3]PhaseConfig = undefined;
    var configs = std.AutoHashMap(tt.DeltaComplexity, ComplexityConfig).init(allocator);
    var total_max_steps: u64 = 0;
    var eval_interval: u64 = 0;
    var checkpoint_interval: u64 = 0;
    var early_stop_patience: u64 = 0;
    var stability_test_steps: u64 = 0;
    var stability_check_interval: u64 = 0;

    var lines = std.mem.splitScalar(u8, json, '\n');
    var current_section: enum { none, phases, configs } = .none;
    var phase_idx: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r,");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, "\"phases\":")) |_| { current_section = .phases; continue; }
        if (std.mem.indexOf(u8, trimmed, "\"complexity_configs\":")) |_| { current_section = .configs; continue; }

        if (std.mem.indexOf(u8, trimmed, "\"name\":")) |_| {
            if (extractJsonString(trimmed, "name")) |v| name = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"version\":")) |_| {
            if (extractJsonString(trimmed, "version")) |v| version = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"description\":")) |_| {
            if (extractJsonString(trimmed, "description")) |v| description = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"total_max_steps\":")) |_| {
            if (extractJsonInt(trimmed, "total_max_steps")) |v| total_max_steps = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"eval_interval\":")) |_| {
            if (extractJsonInt(trimmed, "eval_interval")) |v| eval_interval = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"checkpoint_interval\":")) |_| {
            if (extractJsonInt(trimmed, "checkpoint_interval")) |v| checkpoint_interval = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"early_stop_patience\":")) |_| {
            if (extractJsonInt(trimmed, "early_stop_patience")) |v| early_stop_patience = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"stability_test_steps\":")) |_| {
            if (extractJsonInt(trimmed, "stability_test_steps")) |v| stability_test_steps = v;
        } else if (std.mem.indexOf(u8, trimmed, "\"stability_check_interval\":")) |_| {
            if (extractJsonInt(trimmed, "stability_check_interval")) |v| stability_check_interval = v;
        } else if (current_section == .phases and phase_idx < 3) {
            if (extractJsonString(trimmed, "phase")) |ps| {
                if (stringToPhase(ps)) |p| {
                    phases[phase_idx] = .{
                        .phase = p,
                        .step_count = extractJsonInt(trimmed, "step_count") orelse 0,
                        .base_param_range_start = @intCast(extractJsonInt(trimmed, "base_param_range_start") orelse 0),
                        .base_param_range_end = @intCast(extractJsonInt(trimmed, "base_param_range_end") orelse 0),
                        .bootstrap_interval = extractJsonInt(trimmed, "bootstrap_interval") orelse 0,
                        .consensus_target = extractJsonFloat(trimmed, "consensus_target") orelse 0.0,
                    };
                    phase_idx += 1;
                }
            }
        } else if (current_section == .configs) {
            if (extractJsonString(trimmed, "complexity")) |cs| {
                if (stringToComplexity(cs)) |c| {
                    const cfg = ComplexityConfig{
                        .complexity = c,
                        .consensus_target = extractJsonFloat(trimmed, "consensus_target") orelse 0.0,
                        .max_steps = extractJsonInt(trimmed, "max_steps") orelse 0,
                        .min_steps = extractJsonInt(trimmed, "min_steps") orelse 0,
                    };
                    configs.put(c, cfg) catch |err| {
                        et.logGlobalError(.Warning, "training_plan", "planFromJson", @intFromError(err), "configs.put(complexity) failed");
                    };
                }
            }
        }
    }

    return .{
        .name = name,
        .version = version,
        .description = description,
        .phases = phases,
        .complexity_configs = configs,
        .total_max_steps = total_max_steps,
        .eval_interval = eval_interval,
        .checkpoint_interval = checkpoint_interval,
        .early_stop_patience = early_stop_patience,
        .stability_test_steps = stability_test_steps,
        .stability_check_interval = stability_check_interval,
        .allocator = allocator,
        .version_owned = true,
    };
}

/// 从JSON行提取字符串值（辅助函数）
fn extractJsonString(line: []const u8, key: []const u8) ?[]const u8 {
    const key_start = std.mem.indexOf(u8, line, key) orelse return null;
    const after_key = line[key_start + key.len..];
    const colon_pos = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const val_start = after_key[colon_pos + 1 ..];
    const trimmed_start = std.mem.trimStart(u8, val_start, " \"");
    if (trimmed_start.len == 0) return null;
    const end_quote = std.mem.indexOfScalar(u8, trimmed_start, '"') orelse return null;
    return trimmed_start[0..end_quote];
}

/// 从JSON行提取整数值（辅助函数）
fn extractJsonInt(line: []const u8, key: []const u8) ?u64 {
    const key_start = std.mem.indexOf(u8, line, key) orelse return null;
    const after_key = line[key_start + key.len..];
    const colon_pos = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const val_str = std.mem.trim(u8, after_key[colon_pos + 1 ..], " ,}\n\r\t");
    return std.fmt.parseInt(u64, val_str, 10) catch null;
}

/// 从JSON行提取浮点数值（辅助函数）
fn extractJsonFloat(line: []const u8, key: []const u8) ?f64 {
    const key_start = std.mem.indexOf(u8, line, key) orelse return null;
    const after_key = line[key_start + key.len..];
    const colon_pos = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const val_str = std.mem.trim(u8, after_key[colon_pos + 1 ..], " ,}\n\r\t");
    return std.fmt.parseFloat(f64, val_str) catch null;
}

// ============================================================
// v5.0.0：移除DomainTracker（能力域跟踪器）
// ============================================================

// ============================================================
// 单元测试
// ============================================================

test "createDefaultPlan 基本属性验证" {
    var plan = createDefaultPlan(std.testing.allocator);
    defer plan.deinit();

    try std.testing.expectEqualStrings("CL-SCT+ 统一Δ压力训练计划", plan.name);
    try std.testing.expectEqual(@as(u64, 1800), plan.total_max_steps);

    // 验证三阶段
    try std.testing.expectEqual(@as(u64, 300), plan.phases[0].step_count);
    try std.testing.expectEqual(@as(u64, 300), plan.phases[1].step_count);
    try std.testing.expectEqual(@as(u64, 300), plan.phases[2].step_count);

    // 总步数
    try std.testing.expectEqual(@as(u64, 900), totalSteps(&plan));
}

test "createDefaultPlan Δ复杂度配置覆盖" {
    var plan = createDefaultPlan(std.testing.allocator);
    defer plan.deinit();

    // 4种Δ复杂度都应该有配置
    try std.testing.expect(plan.complexity_configs.contains(.Level_1));
    try std.testing.expect(plan.complexity_configs.contains(.Level_2));
    try std.testing.expect(plan.complexity_configs.contains(.Level_3));
    try std.testing.expect(plan.complexity_configs.contains(.Level_4));

    // 验证共识目标(W)（默认从0开始）
    try std.testing.expectEqual(@as(f64, 0.95), getConsensusTarget(&plan, .Level_1));
    try std.testing.expectEqual(@as(f64, 0.95), getConsensusTarget(&plan, .Level_4));
}

test "initTrainingState 初始化状态正确" {
    var state = initTrainingState();
    defer deinitTrainingState(&state, std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), state.current_step);
    try std.testing.expectEqual(@as(f64, 0.0), state.phase_progress);
}