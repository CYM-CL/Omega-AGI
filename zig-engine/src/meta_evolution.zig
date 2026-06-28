// Ω-落尘AGI 元演化策略引擎 v1.0 — doc11 策略池+变异+选择
const std = @import("std");

pub const VariationConfig = struct { mutation_rate: f64 = 0.1, amplitude: f64 = 0.2, operator_id: usize = 0 };
pub const SelectionConfig = struct { pareto_threshold: f64 = 0.1, pressure: f64 = 0.5, elite_ratio: f64 = 0.2 };
pub const TargetingConfig = struct { exploration_rate: f64 = 0.2, position_strength: f64 = 0.5, attribute_strength: f64 = 0.3 };
pub const TransitionConfig = struct { saturation_threshold: u64 = 1000, timing: f64 = 0.5, packing: f64 = 0.3 };

pub const EvolutionStrategy = struct {
    id: u64, name: []const u8, age: u64,
    variation: VariationConfig, selection: SelectionConfig,
    targeting: TargetingConfig, transition: TransitionConfig,
};

pub const StrategyPerformance = struct {
    improvement_rate: f64 = 0, front_expansion: f64 = 0,
    transition_success: f64 = 0, composite: f64 = 0, usage_count: u64 = 0,
};

pub const StrategyPool = struct {
    allocator: std.mem.Allocator,
    strategies: std.ArrayList(EvolutionStrategy),
    performances: std.ArrayList(StrategyPerformance),
    active_id: u64, next_id: u64,

    pub fn init(allocator: std.mem.Allocator) StrategyPool {
        var pool = StrategyPool{
            .allocator = allocator, .strategies = std.ArrayList(EvolutionStrategy).empty,
            .performances = std.ArrayList(StrategyPerformance).empty,
            .active_id = 1, .next_id = 2,
        };
        pool.strategies.append(allocator, .{ .id = 1, .name = "default", .age = 0,
            .variation = .{}, .selection = .{}, .targeting = .{}, .transition = .{} }) catch {};
        pool.performances.append(allocator, .{}) catch {};
        return pool;
    }

    pub fn deinit(self: *StrategyPool) void { self.strategies.deinit(self.allocator); self.performances.deinit(self.allocator); }

    pub fn mutate(self: *StrategyPool, parent_id: u64) ?u64 {
        for (self.strategies.items) |*s| {
            if (s.id != parent_id) continue;
            const new_id = self.next_id; self.next_id += 1;
            var rng = std.Random.DefaultPrng.init(@intCast(42));
            // 4组件变异（doc11 §2.2）：每次随机选一个组件进行针对性变异
            const component = @as(StrategyComponent, @enumFromInt(rng.random().uintLessThan(usize, 4)));
            var child = EvolutionStrategy{
                .id = new_id, .name = "mutant", .age = 0,
                .variation = s.variation, .selection = s.selection,
                .targeting = s.targeting, .transition = s.transition,
            };
            switch (component) {
                .variation => {
                    child.variation.mutation_rate = @max(0.01, s.variation.mutation_rate * (0.5 + rng.random().float(f64)));
                    child.variation.amplitude = @max(0.01, s.variation.amplitude * (0.5 + rng.random().float(f64)));
                    child.variation.operator_id = if (rng.random().boolean()) s.variation.operator_id else @as(usize, @intFromFloat(rng.random().float(f64) * 5));
                },
                .selection => {
                    child.selection.pareto_threshold = @max(0.01, s.selection.pareto_threshold * (0.5 + rng.random().float(f64)));
                    child.selection.pressure = @max(0.1, @min(1.0, s.selection.pressure * (0.5 + rng.random().float(f64))));
                    child.selection.elite_ratio = @max(0.05, @min(0.5, s.selection.elite_ratio * (0.5 + rng.random().float(f64))));
                },
                .targeting => {
                    child.targeting.exploration_rate = @max(0.05, @min(0.5, s.targeting.exploration_rate * (0.5 + rng.random().float(f64))));
                    child.targeting.position_strength = @max(0.1, @min(0.9, s.targeting.position_strength * (0.5 + rng.random().float(f64))));
                    child.targeting.attribute_strength = @max(0.1, @min(0.9, s.targeting.attribute_strength * (0.5 + rng.random().float(f64))));
                },
                .transition => {
                    child.transition.saturation_threshold = @as(u64, @intFromFloat(@max(100.0, @as(f64, @floatFromInt(s.transition.saturation_threshold)) * (0.5 + rng.random().float(f64)))));
                    child.transition.timing = @max(0.1, @min(1.0, s.transition.timing * (0.5 + rng.random().float(f64))));
                    child.transition.packing = @max(0.1, @min(1.0, s.transition.packing * (0.5 + rng.random().float(f64))));
                },
            }
            self.strategies.append(self.allocator, child) catch return null;
            self.performances.append(self.allocator, .{}) catch {};
            if (self.strategies.items.len <= 3) return new_id;
            var worst_idx: usize = 0;
            for (self.performances.items, 0..) |p, j| { if (p.composite < self.performances.items[worst_idx].composite) worst_idx = j; }
            _ = self.strategies.orderedRemove(worst_idx);
            _ = self.performances.orderedRemove(worst_idx);
            return new_id;
        }
        return null;
    }

    pub fn updatePerformance(self: *StrategyPool, strategy_id: u64, improvement: f64, front_exp: f64, trans_succ: f64) void {
        for (self.performances.items, 0..) |*p, i| {
            if (self.strategies.items[i].id != strategy_id) continue;
            p.usage_count += 1;
            const n = @as(f64, @floatFromInt(p.usage_count));
            p.improvement_rate = (p.improvement_rate * (n - 1) + improvement) / n;
            p.front_expansion = (p.front_expansion * (n - 1) + front_exp) / n;
            p.transition_success = (p.transition_success * (n - 1) + trans_succ) / n;
            p.composite = p.improvement_rate * 0.4 + p.front_expansion * 0.3 + p.transition_success * 0.3;
        }
    }

    // ------------------------------------------------------------------------
    // 深化版：策略评估基准测试与多样性维护
    // ------------------------------------------------------------------------

    /// 选择最佳策略（深化版）
    /// 策略：
    ///   1. 按综合性能排序
    ///   2. 考虑使用次数（使用次数太少的策略可能不可靠）
    ///   3. 返回最佳策略的ID
    pub fn selectBestStrategy(self: *const StrategyPool) u64 {
        if (self.strategies.items.len == 0) return 1;

        var best_idx: usize = 0;
        var best_score: f64 = -std.math.floatMax(f64);

        for (self.performances.items, 0..) |p, i| {
            // 考虑使用次数的置信度惩罚
            const usage_confidence = @min(1.0, @as(f64, @floatFromInt(p.usage_count)) / 10.0);
            const adjusted_score = p.composite * usage_confidence;

            if (adjusted_score > best_score) {
                best_score = adjusted_score;
                best_idx = i;
            }
        }

        return self.strategies.items[best_idx].id;
    }

    /// 计算策略多样性（深化版）
    /// 策略：
    ///   1. 计算各策略之间的参数差异
    ///   2. 多样性 = 平均参数差异
    ///   3. 多样性太低时需要引入更多变异
    pub fn computeDiversity(self: *const StrategyPool) f64 {
        const n = self.strategies.items.len;
        if (n < 2) return 0.0;

        var total_diff: f64 = 0.0;
        var pair_count: usize = 0;

        for (0..n) |i| {
            for (i + 1..n) |j| {
                const s1 = &self.strategies.items[i];
                const s2 = &self.strategies.items[j];

                // 计算各组件的差异
                var diff: f64 = 0.0;

                // 变异组件差异
                diff += @abs(s1.variation.mutation_rate - s2.variation.mutation_rate);
                diff += @abs(s1.variation.amplitude - s2.variation.amplitude) * 0.5;

                // 选择组件差异
                diff += @abs(s1.selection.pressure - s2.selection.pressure);
                diff += @abs(s1.selection.elite_ratio - s2.selection.elite_ratio) * 0.5;

                // 靶向组件差异
                diff += @abs(s1.targeting.exploration_rate - s2.targeting.exploration_rate);
                diff += @abs(s1.targeting.position_strength - s2.targeting.position_strength) * 0.5;

                // 跃迁组件差异
                diff += @abs(s1.transition.timing - s2.transition.timing);
                diff += @abs(s1.transition.packing - s2.transition.packing) * 0.5;

                total_diff += diff;
                pair_count += 1;
            }
        }

        if (pair_count == 0) return 0.0;

        // 归一化到 [0, 1]
        const avg_diff = total_diff / @as(f64, @floatFromInt(pair_count));
        return @min(1.0, avg_diff / 5.0);
    }

    /// 引入随机策略以维持多样性（深化版）
    /// 策略：
    ///   1. 当多样性低于阈值时，引入一个完全随机的策略
    ///   2. 替换性能最差的策略
    ///   3. 返回新策略的ID
    pub fn introduceRandomStrategy(self: *StrategyPool) ?u64 {
        if (self.strategies.items.len == 0) return null;

        const new_id = self.next_id;
        self.next_id += 1;

        // 生成完全随机的策略参数
        var rng = std.Random.DefaultPrng.init(@intCast(new_id * 12345));

        const random_strategy = EvolutionStrategy{
            .id = new_id,
            .name = "random_explorer",
            .age = 0,
            .variation = .{
                .mutation_rate = 0.01 + rng.random().float(f64) * 0.5,
                .amplitude = 0.05 + rng.random().float(f64) * 0.5,
                .operator_id = rng.random().uintLessThan(usize, 5),
            },
            .selection = .{
                .pareto_threshold = 0.01 + rng.random().float(f64) * 0.3,
                .pressure = 0.1 + rng.random().float(f64) * 0.8,
                .elite_ratio = 0.05 + rng.random().float(f64) * 0.4,
            },
            .targeting = .{
                .exploration_rate = 0.05 + rng.random().float(f64) * 0.45,
                .position_strength = 0.1 + rng.random().float(f64) * 0.8,
                .attribute_strength = 0.1 + rng.random().float(f64) * 0.8,
            },
            .transition = .{
                .saturation_threshold = 100 + rng.random().uintLessThan(u64, 2000),
                .timing = 0.1 + rng.random().float(f64) * 0.8,
                .packing = 0.1 + rng.random().float(f64) * 0.8,
            },
        };

        // 替换性能最差的策略
        var worst_idx: usize = 0;
        for (self.performances.items, 0..) |p, i| {
            if (p.composite < self.performances.items[worst_idx].composite) {
                worst_idx = i;
            }
        }

        // 只有当策略池足够大时才替换
        if (self.strategies.items.len >= 3) {
            _ = self.strategies.orderedRemove(worst_idx);
            _ = self.performances.orderedRemove(worst_idx);
        }

        self.strategies.append(self.allocator, random_strategy) catch return null;
        self.performances.append(self.allocator, .{}) catch return null;

        return new_id;
    }
};


test "StrategyPool 初始化" {
    var pool = StrategyPool.init(std.testing.allocator);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.strategies.items.len);
}

test "StrategyPool 变异" {
    var pool = StrategyPool.init(std.testing.allocator);
    defer pool.deinit();
    const new_id = pool.mutate(1);
    try std.testing.expect(new_id != null);
}

test "StrategyPool 性能更新" {
    var pool = StrategyPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.updatePerformance(1, 0.3, 0.2, 0.1);
    const comp = pool.performances.items[0].composite;
    try std.testing.expect(comp > 0);
}
 /// doc11 §2.1 策略组件枚举（用于4组件变异）
 pub const StrategyComponent = enum { variation, selection, targeting, transition };
 
 /// doc11 §2.1 评估策略表现：基于历史数据计算综合得分
 pub fn evaluateStrategy(strategy: *const EvolutionStrategy, performance: *const StrategyPerformance) f64 {
    _ = strategy;
    const imp = performance.improvement_rate * 0.4;
    const front = performance.front_expansion * 0.3;
    const trans = performance.transition_success * 0.3;
    return @max(0.0, @min(1.0, imp + front + trans));
 }
 
 
 test "StrategyPool 4组件变异 " {
     var pool = StrategyPool.init(std.testing.allocator);
     defer pool.deinit();
     const mut1 = pool.mutate(1);
     try std.testing.expect(mut1 != null and mut1.? > 1);
     const mut2 = pool.mutate(1);
     try std.testing.expect(mut2 != null and mut2.? > mut1.?);
 }
 
 test "evaluateStrategy 基本评估" {
     var pool = StrategyPool.init(std.testing.allocator);
     defer pool.deinit();
     const score = evaluateStrategy(&pool.strategies.items[0], &pool.performances.items[0]);
     try std.testing.expect(score >= 0 and score <= 1.0);
 }

    pub fn mutate4Components(self: *StrategyPool, parent_id: u64, rng: *std.rand.Random) ?u64 {
        const parent = for (self.strategies.items) |s| {
            if (s.strategy_id == parent_id) break s;
        } else return null;
        var child = parent;
        child.strategy_id = self.strategies.items.len;
        const component: u8 = @intCast(rng.intRangeLessThan(u8, 0, 4));
        switch (component) {
            0 => { child.variation.mutation_rate += (rng.float(f64) - 0.5) * 0.1; },
            1 => { child.selection.pareto_threshold += (rng.float(f64) - 0.5) * 0.1; },
            2 => { child.targeting.exploration_rate += (rng.float(f64) - 0.5) * 0.1; },
            3 => { child.transition.saturation_threshold += @intCast(rng.intRangeLessThan(i64, -10, 11)); },
            else => {},
        }
        self.strategies.append(self.allocator, child) catch return null;
        return child.strategy_id;
    }
