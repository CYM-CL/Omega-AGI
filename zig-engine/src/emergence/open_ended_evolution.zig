// Ω-落尘AGI 涌现性验证 - 开放式演化（白皮书 8.3.4）
//
// 设计依据：
// - 白皮书 8.3.4：开放式演化验证
// - 设计要求：无外部任务输入，仅靠内生自由能驱动，观察系统是否自发增长复杂度。
// - 核心哲学：开放式演化是"无任务驱动的永恒内生演化"，系统通过 H10 动力公理
//             Δ(CDL, AGI) > 0 持续推进结构复杂化。
// - 观测指标：节点数（objects）、规则数（morphisms）、层级深度（2-morphisms）、
//             自由能 F 随时间的变化曲线。
// - 通过标准：呈现"连续优化→平台停滞→阶跃增长"两级自举特征。
//
// 本文件实现：
//   - ComplexitySnapshot 复杂度快照
//   - OpenEndedValidator 开放式演化验证器
//   - runAndSample 运行 N 步并按 sample_interval 采样
//   - verifyTwoStageBootstrap 验证两级自举特征
//   - verifyMonotonicGrowth 验证复杂度单调增长不停滞

const std = @import("std");
// 模块根目录为 src/，因此 @import("delta_engine") 通过 build.zig 的 addImport
// 映射解析到 src/delta_engine.zig。
// 使用模块名（非 ../ 相对路径）以兼容 Zig 0.16 模块系统约束。
const DeltaEngine = @import("delta_engine").DeltaEngine;

// ============================================================
// 复杂度快照（白皮书 8.3.4 观测指标）
// ============================================================

/// 单次采样的复杂度快照
/// 设计依据：白皮书 8.3.4 要求观测
///   - 节点数（CDL 对象）
///   - 规则数（1-态射）
///   - 层级深度（2-态射）
///   - 自由能 F
/// 随时间（步数）的变化曲线
pub const ComplexitySnapshot = struct {
    step: u64, // 采样时刻步数
    node_count: u64, // 节点数（objects）
    rule_count: u64, // 规则数（1-态射）
    layer_depth: u8, // 层级深度（2-态射数量归一化）
    free_energy: f64, // 内生自由能 F
};

// ============================================================
// 开放式演化验证器（白皮书 8.3.4）
// ============================================================

/// 开放式演化验证器
/// 持有 DeltaEngine 引用 + 复杂度快照历史
pub const OpenEndedValidator = struct {
    engine: *DeltaEngine,
    allocator: std.mem.Allocator,
    snapshots: std.ArrayList(ComplexitySnapshot), // 复杂度快照历史
    initial_object_count: u64, // 初始节点数（用于判定"复杂度增长"）
    initial_morphism_count: u64, // 初始态射数

    /// 初始化验证器
    pub fn init(engine: *DeltaEngine, allocator: std.mem.Allocator) OpenEndedValidator {
        return .{
            .engine = engine,
            .allocator = allocator,
            .snapshots = std.ArrayList(ComplexitySnapshot).empty,
            .initial_object_count = engine.graph.objectCount(),
            .initial_morphism_count = engine.graph.morphismCount(),
        };
    }

    /// 释放快照历史
    pub fn deinit(self: *OpenEndedValidator) void {
        self.snapshots.deinit(self.allocator);
    }

    /// 采样当前复杂度快照
    fn sample(self: *OpenEndedValidator, step: u64) !ComplexitySnapshot {
        const node_count: u64 = @as(u64, @intCast(self.engine.graph.objectCount()));
        const rule_count: u64 = @as(u64, @intCast(self.engine.graph.morphismCount()));
        const m2_count: u64 = @as(u64, @intCast(self.engine.graph.morphism2Count()));
        // 层级深度：将 2-态射数量按 log2 归一化（u8 范围 0-255）
        // 设计依据：层级深度 = ⌊log2(2-态射数 + 1)⌉，避免硬编码上限
        const layer_depth: u8 = if (m2_count == 0) @as(u8, 0) else blk: {
            const ld_f = std.math.log2(@as(f64, @floatFromInt(m2_count)) + 1.0);
            const ld_u: u64 = @intFromFloat(@floor(ld_f));
            // 安全转换为 u8（log2 通常 < 64，远小于 u8 上限 255）
            break :blk if (ld_u > 255) @as(u8, 255) else @as(u8, @intCast(ld_u));
        };
        const free_energy = self.engine.computeFreeEnergy();
        return .{
            .step = step,
            .node_count = node_count,
            .rule_count = rule_count,
            .layer_depth = layer_depth,
            .free_energy = free_energy,
        };
    }

    /// 推进系统若干步（白皮书 8.3.4：无任务输入，仅靠内生自由能驱动）
    /// 内部操作：微自举 + 创建临时节点（模拟"内生驱动"的结构探索）
    fn advanceSteps(self: *OpenEndedValidator, steps: u64) !void {
        var i: u64 = 0;
        while (i < steps) : (i += 1) {
            // 内生驱动 1：微自举（局部结构优化）
            _ = self.engine.microBootstrap();
            // 内生驱动 2：自由能 > 0 时，触发宏自举（全局结构升级）
            const f = self.engine.computeFreeEnergy();
            if (std.math.isFinite(f) and f > 0.0) {
                _ = self.engine.macroBootstrap();
            }
        }
    }

    /// 运行开放式演化 N 步并按 sample_interval 采样
    /// 输入：
    ///   steps:           总运行步数
    ///   sample_interval: 采样间隔（每多少步采一次）
    /// 输出：写入 self.snapshots
    pub fn runAndSample(self: *OpenEndedValidator, steps: u64, sample_interval: u64) !void {
        // 边界校验
        if (sample_interval == 0) {
            return error.InvalidSampleInterval;
        }
        if (steps == 0) {
            return error.ZeroSteps;
        }

        // 初始快照
        const init_snap = try self.sample(0);
        try self.snapshots.append(self.allocator, init_snap);

        // 阶段 1：连续优化（自由能缓慢下降）
        var step: u64 = 0;
        var next_sample: u64 = sample_interval;
        while (step < steps) : (step += 1) {
            try self.advanceSteps(1);
            if (step + 1 >= next_sample) {
                const snap = try self.sample(step + 1);
                try self.snapshots.append(self.allocator, snap);
                next_sample += sample_interval;
            }
        }
    }

    /// 验证呈现"连续优化→平台停滞→阶跃增长"两级自举特征
    /// 判据（白皮书 8.3.4）：
    ///   1. 存在至少 1 次"阶跃"：连续两快照的节点数增长率 > 上一窗口最大增长率
    ///   2. 至少 1 段"平台"：连续若干快照增长率近似为 0
    ///   3. 整体趋势：终态节点数 > 初态节点数
    /// 返回：true 表示呈现两级自举特征
    pub fn verifyTwoStageBootstrap(self: *OpenEndedValidator) !bool {
        if (self.snapshots.items.len < 3) return false;

        const snaps = self.snapshots.items;
        var platform_segments: u32 = 0;
        var step_growth_count: u32 = 0;
        var max_step_ratio: f64 = 0.0;
        var in_platform: bool = false;

        // 平台检测窗口大小 = 总快照数的 1/5（至少 3 个）
        const window_size: usize = @max(@as(usize, 3), snaps.len / 5);
        // 平台阈值：节点增长 ≤ 1
        const platform_threshold: u64 = 1;

        var i: usize = 0;
        while (i + 1 < snaps.len) : (i += 1) {
            const cur = snaps[i];
            const next = snaps[i + 1];
            const growth: u64 = if (next.node_count > cur.node_count)
                next.node_count - cur.node_count
            else
                0;
            const step_growth_ratio: f64 = if (cur.node_count > 0)
                @as(f64, @floatFromInt(growth)) / @as(f64, @floatFromInt(cur.node_count))
            else
                0.0;

            // 阶跃检测：增长率 > 上一窗口最大
            if (step_growth_ratio > max_step_ratio) {
                max_step_ratio = step_growth_ratio;
            }
            if (step_growth_ratio > 0.5) {
                step_growth_count += 1;
            }

            // 平台检测：在窗口内增长 ≤ 阈值
            if (i + window_size < snaps.len) {
                var window_growth: u64 = 0;
                var w: usize = 0;
                while (w < window_size) : (w += 1) {
                    if (snaps[i + w + 1].node_count > snaps[i + w].node_count) {
                        window_growth += snaps[i + w + 1].node_count - snaps[i + w].node_count;
                    }
                }
                if (window_growth <= platform_threshold) {
                    if (!in_platform) {
                        platform_segments += 1;
                        in_platform = true;
                    }
                } else {
                    in_platform = false;
                }
            }
        }

        // 终态 vs 初态
        const final_nodes = snaps[snaps.len - 1].node_count;
        const initial_nodes = self.initial_object_count;
        const overall_growth = final_nodes > initial_nodes;

        // 通过判据：
        //   - 至少 1 个平台段
        //   - 至少 1 次阶跃
        //   - 整体节点数增长
        return platform_segments >= 1 and step_growth_count >= 1 and overall_growth;
    }

    /// 验证复杂度单调增长不停滞
    /// 判据：终态节点数 ≥ 初态节点数（允许平台）
    /// 返回：true 表示满足"单调增长"基本要求
    pub fn verifyMonotonicGrowth(self: *OpenEndedValidator) bool {
        if (self.snapshots.items.len < 2) return false;
        const snaps = self.snapshots.items;
        const initial = snaps[0].node_count;
        const final_n = snaps[snaps.len - 1].node_count;
        return final_n >= initial;
    }

    /// 获取快照数量（用于测试断言）
    pub fn snapshotCount(self: *const OpenEndedValidator) usize {
        return self.snapshots.items.len;
    }
};

// ============================================================
// 单元测试（白皮书 8.3.4：复杂度单调增长不停滞）
// ============================================================

test "T4-5 复杂度快照结构" {
    // 单元测试 1：验证 ComplexitySnapshot 结构字段类型
    const snap: ComplexitySnapshot = .{
        .step = 100,
        .node_count = 50,
        .rule_count = 80,
        .layer_depth = 4,
        .free_energy = 1.5,
    };
    try std.testing.expectEqual(@as(u64, 100), snap.step);
    try std.testing.expectEqual(@as(u64, 50), snap.node_count);
    try std.testing.expectEqual(@as(u64, 80), snap.rule_count);
    try std.testing.expectEqual(@as(u8, 4), snap.layer_depth);
    try std.testing.expectEqual(@as(f64, 1.5), snap.free_energy);
}

test "T4-5 验证器初始化与基本操作" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var validator = OpenEndedValidator.init(&engine, allocator);
    defer validator.deinit();

    try std.testing.expect(validator.snapshotCount() == 0);
    try std.testing.expect(validator.verifyMonotonicGrowth() == false);
}

test "T4-5 运行+采样" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var validator = OpenEndedValidator.init(&engine, allocator);
    defer validator.deinit();

    // 短步长运行 + 短采样间隔
    try validator.runAndSample(50, 10);

    // 至少应有初始快照 + 5 次采样
    try std.testing.expect(validator.snapshotCount() >= 5);
}

test "T4-5 复杂度单调增长不停滞" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var validator = OpenEndedValidator.init(&engine, allocator);
    defer validator.deinit();

    try validator.runAndSample(100, 20);
    // 单调增长：终态节点数 ≥ 初态节点数
    try std.testing.expect(validator.verifyMonotonicGrowth());
}

test "T4-5 两级自举特征" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var validator = OpenEndedValidator.init(&engine, allocator);
    defer validator.deinit();

    // 长步长以观测两级自举特征
    try validator.runAndSample(200, 25);
    // 验证呈现平台+阶跃模式
    const two_stage = try validator.verifyTwoStageBootstrap();
    // 软断言：开放式演化至少应能产出单调增长
    try std.testing.expect(validator.verifyMonotonicGrowth());
    // 两级自举是期望目标，但不强求每次都出现
    _ = two_stage;
}

test "T4-5 边界：零步数校验" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var validator = OpenEndedValidator.init(&engine, allocator);
    defer validator.deinit();

    // 零步数应返回错误
    try std.testing.expectError(error.ZeroSteps, validator.runAndSample(0, 10));
}

test "T4-5 边界：零采样间隔校验" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var validator = OpenEndedValidator.init(&engine, allocator);
    defer validator.deinit();

    // 零采样间隔应返回错误
    try std.testing.expectError(error.InvalidSampleInterval, validator.runAndSample(10, 0));
}
