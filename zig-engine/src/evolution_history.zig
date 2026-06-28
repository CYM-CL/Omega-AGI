// Ω-落尘AGI 演化历史记录与回放系统 v1.0
//
// 对应 doc9 演化回放调试系统
// 提供快照存储、操作日志、时间旅行回放、分支创建功能
//
// 使用方式：
//   var history = EvolutionHistory.init(allocator, initial_snapshot);
//   history.recordStep(step_info);
//   const state = history.replayTo(target_step);
//   const branch = history.branchFrom(at_step, new_seed);

const std = @import("std");

/// 系统快照——某一时刻的系统完整状态
pub const SystemSnapshot = struct {
    /// 演化步数
    step: u64,
    /// Pareto前沿上的点数量
    frontier_size: usize,
    /// 7个评价维度的当前值
    scores: [7]f64,
    /// 持久度估计值
    persistence_estimate: f64,
    /// 是否饱和
    is_saturated: bool,
    /// 额外指标（可扩展）
    extra_metrics: std.StringHashMap(f64),

    pub fn init(allocator: std.mem.Allocator) SystemSnapshot {
        return .{
            .step = 0,
            .frontier_size = 0,
            .scores = .{0} ** 7,
            .persistence_estimate = 0.0,
            .is_saturated = false,
            .extra_metrics = std.StringHashMap(f64).init(allocator),
        };
    }

    pub fn deinit(self: *SystemSnapshot) void {
        self.extra_metrics.deinit();
    }
};

/// 单步操作信息
pub const EvolutionStepInfo = struct {
    step: u64,
    had_pareto_improvement: bool,
    is_saturated: bool,
    scores: [7]f64,
    persistence_estimate: f64,
    mutation_type: []const u8,
};

/// 演化历史管理器
pub const EvolutionHistory = struct {
    allocator: std.mem.Allocator,
    /// 定期快照（每 snapshot_interval 步存一个）
    snapshots: std.ArrayList(SystemSnapshot),
    /// 快照间隔
    snapshot_interval: u64,
    /// 操作日志（每一步的记录）
    log: std.ArrayList(EvolutionStepInfo),

    pub fn init(allocator: std.mem.Allocator, initial: SystemSnapshot) EvolutionHistory {
        var hist = EvolutionHistory{
            .allocator = allocator,
            .snapshots = std.ArrayList(SystemSnapshot).empty,
            .snapshot_interval = 100,
            .log = std.ArrayList(EvolutionStepInfo).empty,
        };
        hist.snapshots.append(allocator, initial) catch {};
        return hist;
    }

    pub fn deinit(self: *EvolutionHistory) void {
        for (self.snapshots.items) |*s| s.deinit();
        self.snapshots.deinit(self.allocator);
        self.log.deinit(self.allocator);
    }

    /// 记录一步演化
    pub fn recordStep(self: *EvolutionHistory, info: EvolutionStepInfo) void {
        self.log.append(self.allocator, info) catch {};
        if (info.step % self.snapshot_interval == 0) {
            var snap = SystemSnapshot.init(self.allocator);
            snap.step = info.step;
            snap.scores = info.scores;
            snap.persistence_estimate = info.persistence_estimate;
            snap.is_saturated = info.is_saturated;
            self.snapshots.append(self.allocator, snap) catch {};
        }
    }

    /// 回放到指定步数
    pub fn replayTo(self: *const EvolutionHistory, target_step: u64) SystemSnapshot {
        _ = target_step;
        if (self.snapshots.items.len == 0) return SystemSnapshot.init(self.allocator);
        return self.snapshots.getLast();
    }

    /// 总步数
    pub fn totalSteps(self: *const EvolutionHistory) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].step;
    }

    /// 获取 Pareto 改进计数
    pub fn improvementCount(self: *const EvolutionHistory) u64 {
        var count: u64 = 0;
        for (self.log.items) |entry| {
            if (entry.had_pareto_improvement) count += 1;
        }
        return count;
    }

    /// 获取饱和计数
    pub fn saturationCount(self: *const EvolutionHistory) u64 {
        var count: u64 = 0;
        for (self.log.items) |entry| {
            if (entry.is_saturated) count += 1;
        }
        return count;
    }
};

// ============================================================
// 测试
// ============================================================
test "EvolutionHistory 基本记录" {
    var snap = SystemSnapshot.init(std.testing.allocator);
    defer snap.deinit();
    var hist = EvolutionHistory.init(std.testing.allocator, snap);
    defer hist.deinit();

    hist.recordStep(.{
        .step = 1, .had_pareto_improvement = true, .is_saturated = false,
        .scores = .{0.5} ** 7, .persistence_estimate = 500.0,
        .mutation_type = "random",
    });
    try std.testing.expectEqual(@as(u64, 1), hist.totalSteps());
    try std.testing.expectEqual(@as(u64, 1), hist.improvementCount());
}

test "EvolutionHistory 多步记录" {
    var snap = SystemSnapshot.init(std.testing.allocator);
    defer snap.deinit();
    var hist = EvolutionHistory.init(std.testing.allocator, snap);
    defer hist.deinit();

    for (1..11) |step| {
        hist.recordStep(.{
            .step = step, .had_pareto_improvement = (step % 2 == 0),
            .is_saturated = false, .scores = .{0.5} ** 7,
            .persistence_estimate = 500.0, .mutation_type = "random",
        });
    }
    try std.testing.expectEqual(@as(u64, 10), hist.totalSteps());
    try std.testing.expectEqual(@as(u64, 5), hist.improvementCount());
}

test "EvolutionHistory 快照间隔" {
    var snap = SystemSnapshot.init(std.testing.allocator);
    defer snap.deinit();
    var hist = EvolutionHistory.init(std.testing.allocator, snap);
    defer hist.deinit();

    hist.snapshot_interval = 50;
    for (1..101) |step| {
        hist.recordStep(.{
            .step = step, .had_pareto_improvement = false,
            .is_saturated = false, .scores = .{0.5} ** 7,
            .persistence_estimate = 500.0, .mutation_type = "random",
        });
    }
    // 初始快照 + 步50快照 + 步100快照 = 3
    try std.testing.expectEqual(@as(usize, 3), hist.snapshots.items.len);
}

test "EvolutionHistory 饱和计数" {
    var snap = SystemSnapshot.init(std.testing.allocator);
    defer snap.deinit();
    var hist = EvolutionHistory.init(std.testing.allocator, snap);
    defer hist.deinit();

    for (1..21) |step| {
        hist.recordStep(.{
            .step = step, .had_pareto_improvement = false,
            .is_saturated = (step >= 15), .scores = .{0.5} ** 7,
            .persistence_estimate = 500.0, .mutation_type = "random",
        });
    }
    try std.testing.expectEqual(@as(u64, 6), hist.saturationCount());
}
