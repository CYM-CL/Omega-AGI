// Ω-落尘AGI 靶向演化 v2.0 — doc8 完整实现 + Phase 3.1-3.4
const std = @import("std");

pub const MutationTarget = struct { module_id: u64, node_id: u64 };

pub const OperatorStats = struct { operator_type: usize, total_attempts: u64, successful_attempts: u64, success_rate: f64 };

pub const TargetedEvolution = struct {
    /// 靶向强度字段（v7.1新增）
    position_strength: f64 = 0.5,    // 位置靶向强度
    operator_strength: f64 = 0.3,    // 算子靶向强度
    attribute_strength: f64 = 0.2,   // 属性靶向强度
    exploration_rate: f64 = 0.2,
    min_exploration_rate: f64,
    max_exploration_rate: f64,
    position_targeting_strength: f64,
    attribute_targeting_strength: f64,  // doc8 §1.4: 属性靶向强度 (3.1)
    prune_threshold: f64,    // doc8 §1.6: 精简阈值 (3.6)
    operator_stats: [4]OperatorStats,
    improvement_history: [100]bool,
    history_index: usize,
    pub fn init() TargetedEvolution {
        var stats: [4]OperatorStats = undefined;
        for (0..4) |i| { stats[i] = .{ .operator_type=i, .total_attempts=1, .successful_attempts=0, .success_rate=0.0 }; }
        return .{ .exploration_rate=0.2, .min_exploration_rate=0.05, .max_exploration_rate=0.5,
            .position_targeting_strength=0.7, .attribute_targeting_strength=0.5,
            .prune_threshold=0.1,
            .operator_stats=stats, .improvement_history=.{false}**100, .history_index=0 };
    }
    pub fn shouldExplore(self: *const TargetedEvolution, rng: *std.Random.DefaultPrng) bool {
        return rng.random().float(f64) < self.exploration_rate;
    }
    pub fn selectOperator(self: *TargetedEvolution, rng: *std.Random.DefaultPrng) usize {
        var tw: f64 = 0; for (&self.operator_stats) |s| { tw += s.success_rate + 0.1; }
        var pick = rng.random().float(f64) * tw;
        for (&self.operator_stats, 0..) |s, i| { pick -= s.success_rate + 0.1; if (pick <= 0) return i; }
        return 3;
    }
    pub fn updateOperatorStat(self: *TargetedEvolution, op_type: usize, success: bool) void {
        if (op_type < 4) { self.operator_stats[op_type].total_attempts += 1;
            if (success) self.operator_stats[op_type].successful_attempts += 1;
            self.operator_stats[op_type].success_rate = @as(f64,@floatFromInt(self.operator_stats[op_type].successful_attempts))/@as(f64,@floatFromInt(self.operator_stats[op_type].total_attempts)); }
    }
    pub fn recordImprovement(self: *TargetedEvolution, improved: bool) void {
        self.improvement_history[self.history_index] = improved;
        self.history_index = (self.history_index + 1) % 100;
    }
    pub fn getImprovementRate(self: *const TargetedEvolution) f64 {
        var c: u64 = 0; for (&self.improvement_history) |v| { if (v) c += 1; }
        return @as(f64,@floatFromInt(c)) / 100.0;
    }
    pub fn adapt(self: *TargetedEvolution) void {
        const rate = self.getImprovementRate();
        if (rate > 0.1) { self.exploration_rate = @max(self.min_exploration_rate, self.exploration_rate * 0.95);
            self.position_targeting_strength = @min(0.9, self.position_targeting_strength * 1.05);
            self.attribute_targeting_strength = @min(0.9, self.attribute_targeting_strength * 1.05); }
        else if (rate < 0.01) { self.exploration_rate = @min(self.max_exploration_rate, self.exploration_rate * 1.1);
            self.position_targeting_strength = @max(0.3, self.position_targeting_strength * 0.95);
            self.attribute_targeting_strength = @max(0.3, self.attribute_targeting_strength * 0.95); }
    }
    pub fn selectMutationTarget(self: *const TargetedEvolution, mp: []const f64, ni: []const f64) MutationTarget {
        _ = self; var bm: u64 = 0; var wp: f64 = std.math.inf(f64); for (mp, 0..) |p, i| { if (p < wp) { wp = p; bm = @intCast(i); } }
        var bn: u64 = 0; var bi: f64 = -1;
        for (ni, 0..) |imp, i| { if (imp > bi) { bi = imp; bn = @intCast(i); } }
        return .{ .module_id = bm, .node_id = bn };
    }
    pub fn selectMutationDirection(self: *const TargetedEvolution, ai: []const f64) usize {
        _ = self; var bi: usize = 0; for (ai, 0..) |v, i| { if (v > ai[bi]) bi = i; }
        return bi;
    }
    pub fn generateCandidate(self: *TargetedEvolution, mp: []const f64, ni: []const f64, ai: []const f64, rng: *std.Random.DefaultPrng) struct { target: MutationTarget, direction: usize, operator_id: usize } {
        if (self.shouldExplore(rng)) {
            const rm = rng.random().uintLessThan(usize, @max(1, mp.len));
            const rn = rng.random().uintLessThan(usize, @max(1, ni.len));
            return .{.target=.{.module_id=@intCast(rm),.node_id=@intCast(rn)}, .direction=rng.random().uintLessThan(usize,@max(1,ai.len)), .operator_id=rng.random().uintLessThan(usize,4)}; }
        const target = self.selectMutationTarget(mp, ni);
        const direction = self.selectMutationDirection(ai);
        const op_id = self.selectOperator(rng);
        return .{.target=target, .direction=direction, .operator_id=op_id};
    }

    /// 精简变异算子（doc8 §1.6, 论文策略3）：选importance最低的冗余节点
    pub fn generatePruningCandidate(self: *const TargetedEvolution, node_importance: []const f64) ?MutationTarget {
        var worst_idx: usize = 0;
        for (node_importance, 0..) |v, i| { if (v < node_importance[worst_idx]) worst_idx = i; }
        if (node_importance.len == 0 or node_importance[worst_idx] > self.prune_threshold) return null;
        return .{ .module_id = 0, .node_id = @intCast(worst_idx) };
    }

    /// 分级变异概率（论文策略4）：关键节点0.1×, 普通1.0×, 冗余2.0×
    pub fn getMutationProbability(self: *const TargetedEvolution, importance: f64) f64 { _ = self;
        if (importance > 0.8) return 0.1;
        if (importance > 0.3) return 1.0;
        return 2.0;
    }
};

// ===== 测试 =====
test "初始化" { const te = TargetedEvolution.init(); try std.testing.expectEqual(@as(f64,0.2), te.exploration_rate); try std.testing.expectEqual(@as(f64,0.5), te.attribute_targeting_strength); }
test "算子统计" {
    var te = TargetedEvolution.init(); te.updateOperatorStat(0,true); te.updateOperatorStat(0,true); te.updateOperatorStat(1,false);
    try std.testing.expect(te.operator_stats[0].success_rate > te.operator_stats[1].success_rate); }
test "自适应改进多降探索" {
    var te = TargetedEvolution.init(); for (0..20) |_| { te.recordImprovement(true); } const b = te.exploration_rate; te.adapt();
    try std.testing.expect(te.exploration_rate <= b); }
test "自适应改进少提探索" {
    var te = TargetedEvolution.init(); for (0..100) |_| { te.recordImprovement(false); } const b = te.exploration_rate; te.adapt();
    try std.testing.expect(te.exploration_rate >= b); }
test "算子选择" {
    var te = TargetedEvolution.init(); var prng = std.Random.DefaultPrng.init(42);
    te.updateOperatorStat(0,true); te.updateOperatorStat(0,true); te.updateOperatorStat(0,true);
    te.updateOperatorStat(3,false); te.updateOperatorStat(3,false);
    var c: [4]u64 = .{0}**4; for (0..100) |_| { const op = te.selectOperator(&prng); if (op < 4) c[op] += 1; }
    try std.testing.expect(c[0] > c[3]); }

test "selectMutationTarget 位置靶向" {
    var te = TargetedEvolution.init();
    const mp = [_]f64{1000,500,200,800}; const ni = [_]f64{0.1,0.5,0.3,0.9,0.2};
    const t = te.selectMutationTarget(&mp, &ni);
    try std.testing.expectEqual(@as(u64,2), t.module_id); try std.testing.expectEqual(@as(u64,3), t.node_id); }
test "selectMutationDirection 属性靶向" {
    var te = TargetedEvolution.init(); const ai = [_]f64{0.2,0.8,0.1,0.5,0.3,0.0,0.4};
    try std.testing.expectEqual(@as(usize,1), te.selectMutationDirection(&ai)); }
test "generateCandidate 生成候选" {
    var te = TargetedEvolution.init(); te.exploration_rate=0; var prng=std.Random.DefaultPrng.init(99);
    const mp=[_]f64{100,200,50,400}; const ni=[_]f64{0.1,0.9,0.5}; const ai=[_]f64{0.3,0.7,0.1,0.5,0.2,0.0,0.4};
    const c = te.generateCandidate(&mp, &ni, &ai, &prng);
    try std.testing.expectEqual(@as(u64,2), c.target.module_id); try std.testing.expect(c.operator_id < 4); }

test "generatePruningCandidate 精简" {
    var te = TargetedEvolution.init(); te.prune_threshold = 0.2;
    const ni = [_]f64{0.5, 0.05, 0.3, 0.01, 0.4};
    const p = te.generatePruningCandidate(&ni);
    try std.testing.expect(p != null);
    if (p) |pr| try std.testing.expectEqual(@as(u64,3), pr.node_id); }

test "getMutationProbability 分级" {
    var te = TargetedEvolution.init();
    try std.testing.expectEqual(@as(f64,0.1), te.getMutationProbability(0.9));
    try std.testing.expectEqual(@as(f64,1.0), te.getMutationProbability(0.5));
    try std.testing.expectEqual(@as(f64,2.0), te.getMutationProbability(0.1)); }
    pub fn gradedMutationProb(self: *TargetedEvolution, is_critical: bool, is_redundant: bool) f64 {
        _ = self;
        // 策略4: 关键节点0.1×、普通节点1.0×、冗余节点2.0×
        if (is_critical) return 0.1;
        if (is_redundant) return 2.0;
        return 1.0;
    }
    pub fn leanMutate(self: *TargetedEvolution, node_count: usize, rng: *std.rand.Random) usize {
        _ = self;
        if (node_count < 3) return 0;
        // Remove a redundant node with low importance score
        const target = rng.intRangeLessThan(usize, 0, node_count);
        return target;
    }
