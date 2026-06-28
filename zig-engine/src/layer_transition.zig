// Ω-落尘AGI 层级跃迁引擎 v2.0 — doc2+doc3 Phase 2 完整实现
const std = @import("std");

pub const ParetoPoint = struct { scores: [7]f64, id: u64, step: u64, expr_handle: u64, metadata: ParetoMetadata };
pub const ParetoMetadata = struct { node_count: u64 = 0, edge_count: u64 = 0, avg_imbalance: f64 = 0, rule_density: f64 = 0, frozen_count: u64 = 0, knowledge_size: u64 = 0 };

pub const PortId = u64;
pub const SuperNode = struct {
    /// v7.1: 内部网络打包——打包时保存的完整内部结构
    base_scores: [7]f64,
    inner_node_ids: std.ArrayList(u64),
    input_port: PortId,
    output_port: PortId,
    origin_front_point: ParetoPoint,
    created_at_step: u64,
    inner_node_count: u64,
    inner_edge_count: u64,
    avg_imbalance: f64
};
pub const DimensionDef = struct { id: usize, name: []const u8, description: []const u8 };
pub const DimensionRecombination = struct { preserved: [5]usize, eliminated: [2]usize, new_dimensions: [2]DimensionDef };
pub const TransitionFailureType = enum { survival, front_effectiveness, dimension_quality, instability };
pub const TransitionFailureCounts = struct { survival: u64 = 0, front: u64 = 0, dim: u64 = 0, instability: u64 = 0 };

pub const Layer = struct { level: u64, super_nodes: std.ArrayList(SuperNode), created_at_step: u64, dimension_recombination: DimensionRecombination };

pub const TransitionVerification = struct { survival_ok: bool, front_ok: bool, dimension_ok: bool,
    pub fn allOk(self: *const TransitionVerification) bool { return self.survival_ok and self.front_ok and self.dimension_ok; } };

pub const TransitionExperience = struct { level: u64, success: bool, failure_type: ?TransitionFailureType, params_before: TransitionParams, params_after: TransitionParams, step: u64 };

pub const TransitionParams = struct {
    min_front_size: usize = 20, preserved_dim_count: usize = 5, new_dim_count: usize = 2,
    initial_network_size: usize = 5, coupling_density: f64 = 0.3,
};

pub const TransitionTuner = struct {
    min_front_size: usize = 20,
    preserved_dim_count: usize = 5,
    new_dim_count: usize = 2,
    initial_network_size: usize = 5,
    coupling_density: f64 = 0.3,

    /// 根据失败类型调整参数
    pub fn adjustForFailure(self: *TransitionTuner, ft: TransitionFailureType) void {
        switch (ft) {
            .survival => {
                self.min_front_size += 5;
                self.initial_network_size = @max(3, self.initial_network_size - 1);
            },
            .front_effectiveness => {
                self.min_front_size += 10;
                self.preserved_dim_count = @min(7, self.preserved_dim_count + 1);
            },
            .dimension_quality => {
                self.new_dim_count += 1;
            },
            .instability => {
                self.coupling_density = @max(0.1, self.coupling_density - 0.1);
                self.min_front_size += 5;
            },
        }
    }

    /// 成功后适当降低门槛
    pub fn adjustForSuccess(self: *TransitionTuner) void {
        self.min_front_size = @max(10, self.min_front_size -| 5);
    }
};

const WeightedIndex = struct { idx: usize, w: f64 };

pub fn checkTransitionPreconditions(front_size: usize, wh: []const [7]f64, min_sz: usize, thr: f64) bool {
    if (front_size < min_sz) return false;
    if (wh.len < 3) return false;
    const lat = wh[wh.len - 1];
    for (wh[wh.len - 3 ..]) |p| { for (0..7) |j| { if (@abs(lat[j] - p[j]) > thr) return false; } }
    return true;
}

pub fn verifyTransition(ly: *const Layer, old_sz: usize, old_best: [7]f64) TransitionVerification {
    const sv = ly.level > 0 and ly.super_nodes.items.len > 0;
    var fok = (old_sz < 5);
    if (old_sz >= 5) { var mr: f64 = 0; for (ly.super_nodes.items) |sn| { for (0..7) |d| {
        const dl = sn.base_scores[d] - old_best[d]; if (dl < mr) mr = dl; } } fok = mr >= -0.3; }
    return .{ .survival_ok = sv, .front_ok = fok, .dimension_ok = ly.dimension_recombination.new_dimensions.len == 2 };
}

/// 跃迁失败诊断：分析验证结果确定失败类型
pub fn diagnoseFailure(v: TransitionVerification) TransitionFailureType {
    if (!v.survival_ok) return .survival;
    if (!v.front_ok) return .front_effectiveness;
    if (!v.dimension_ok) return .dimension_quality;
    return .instability;
}

/// 模块化一致性: combined / mean(individual)
pub fn computeModularCoherence(sn: []const SuperNode) f64 {
    if (sn.len == 0) return 1.0;
    if (sn.len <= 1) return 1.0;
    var it: f64 = 0; for (sn) |s| { const sb = 1.0/(1.0+@abs(s.avg_imbalance));
        const ef = if (s.inner_edge_count>0) @as(f64,@floatFromInt(s.inner_edge_count))/@max(1,@as(f64,@floatFromInt(s.inner_node_count))) else 0.1;
        it += sb * ef; }
    const ex = it / @as(f64,@floatFromInt(sn.len)); var cb: f64 = 1.0;
    for (sn) |s| { cb *= 1.0 / (1.0 + @abs(s.avg_imbalance)); }
    return @min(1.0, (cb / @max(0.01, ex)) / 1.5);
}

/// 层级有效深度: 递归遍历各层，depth += ln(compression_ratio) 当 compression_ratio > 1
pub fn computeHierarchyDepth(lv: u64, nc: []const u64) f64 {
    if (nc.len < 2) return 0;
    if (nc.len < 2) return @min(1.0, @as(f64, @floatFromInt(lv)) / 5.0);
    var t: f64 = 0; for (1..nc.len) |i| { const r = @as(f64,@floatFromInt(nc[i-1]))/@max(1,@as(f64,@floatFromInt(nc[i]))); if (r > 1.0) t += @log(r); }
    return @min(1.0, t / 5.0);
}

// ===== 测试 =====
test "Engine init" { var e = LayerTransitionEngine.init(std.testing.allocator); defer e.deinit(); try std.testing.expectEqual(@as(u64,1), e.current_level); }
test "packFront metadata" {
    var e = LayerTransitionEngine.init(std.testing.allocator);
    defer e.deinit();
    const p0_scores = [7]f64{0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3};
    const p0 = ParetoPoint{
        .scores = p0_scores,
        .id = 1,
        .step = 0,
        .expr_handle = 42,
        .metadata = .{ .node_count = 100, .edge_count = 200 },
    };
    const pts = [_]ParetoPoint{p0};
    var n = try e.packFrontToSuperNodes(&pts, 0);
    defer e.deinitSuperNodes(&n); // 正确释放每个 SuperNode 的 inner_node_ids
    try std.testing.expectEqual(@as(u64, 100), n.items[0].inner_node_count);
}
test "maybeTransition small front" {
    var e = LayerTransitionEngine.init(std.testing.allocator); defer e.deinit();
    const p0_scores = [_]f64{0.5}**7;
    const p1_scores = [7]f64{0.6,0.4,0.5,0.5,0.5,0.5,0.5};
    const pts = [_]ParetoPoint{ParetoPoint{.scores=p0_scores,.id=1,.step=0,.expr_handle=0,.metadata=.{}}, ParetoPoint{.scores=p1_scores,.id=2,.step=1,.expr_handle=0,.metadata=.{}}};
    try std.testing.expect((try e.maybeTransition(&pts, [_]f64{0.1}**7, &.{[_]f64{0.1}**7, [_]f64{0.1}**7, [_]f64{0.1}**7}, 0, true)) == null); }
test "verifyTransition check" {
    var nd = std.ArrayList(SuperNode).empty; defer nd.deinit(std.testing.allocator);
    var ly = Layer{.level=2,.super_nodes=nd,.created_at_step=0,.dimension_recombination=.{.preserved=.{0,1,2,3,4},.eliminated=.{5,6},.new_dimensions=.{.{.id=0,.name="a",.description=""},.{.id=1,.name="b",.description=""}}}};
    try std.testing.expect(!verifyTransition(&ly, 0, [_]f64{0}**7).survival_ok); }
test "diagnoseFailure types" {
    try std.testing.expectEqual(.survival, diagnoseFailure(.{.survival_ok=false,.front_ok=false,.dimension_ok=false}));
    try std.testing.expectEqual(.front_effectiveness, diagnoseFailure(.{.survival_ok=true,.front_ok=false,.dimension_ok=false})); }
test "TransitionTuner adjust" {
    var t = TransitionTuner{};
    t.adjustForFailure(.survival);
    // survival: min_front_size += 5 (20 -> 25), initial_network_size -= 1 (5 -> 4)
    try std.testing.expectEqual(@as(usize, 4), t.initial_network_size);
    try std.testing.expectEqual(@as(usize, 25), t.min_front_size);
}
test "computeModularCoherence v2" {
    var nd = std.ArrayList(SuperNode).empty;
    defer nd.deinit(std.testing.allocator);
    try nd.append(std.testing.allocator, .{
        .base_scores = [_]f64{0.9} ** 7,
        .inner_node_ids = std.ArrayList(u64).empty,
        .input_port = 0,
        .output_port = 0,
        .origin_front_point = ParetoPoint{
            .scores = [_]f64{0.9} ** 7,
            .id = 1,
            .step = 0,
            .expr_handle = 0,
            .metadata = .{},
        },
        .created_at_step = 0,
        .inner_node_count = 10,
        .inner_edge_count = 20,
        .avg_imbalance = 0.1,
    });
    try nd.append(std.testing.allocator, .{
        .base_scores = [_]f64{0.8} ** 7,
        .inner_node_ids = std.ArrayList(u64).empty,
        .input_port = 0,
        .output_port = 0,
        .origin_front_point = ParetoPoint{
            .scores = [_]f64{0.8} ** 7,
            .id = 2,
            .step = 0,
            .expr_handle = 0,
            .metadata = .{},
        },
        .created_at_step = 0,
        .inner_node_count = 20,
        .inner_edge_count = 30,
        .avg_imbalance = 0.2,
    });
    try std.testing.expect(computeModularCoherence(nd.items) > 0);
}
test "computeHierarchyDepth v2" {
    try std.testing.expect(0 < computeHierarchyDepth(3, &.{1000,200,50,10}) and computeHierarchyDepth(3, &.{1000,200,50,10}) <= 1.0); }
test "recommendParams" {
    var e = LayerTransitionEngine.init(std.testing.allocator); defer e.deinit();
    e.experiences.append(e.allocator, .{.level=2,.success=true,.failure_type=null,.params_before=.{.min_front_size=30},.params_after=.{},.step=100}) catch {};
    try std.testing.expectEqual(@as(usize,30), e.recommendParams(2).min_front_size); }
pub const LayerTransitionEngine = struct {
    allocator: std.mem.Allocator,
    current_level: u64,
    transition_count: u64,
    params: TransitionParams,
    experiences: std.ArrayList(TransitionExperience),
    tuner: TransitionTuner,
    failure_counts: TransitionFailureCounts,

    pub fn init(allocator: std.mem.Allocator) LayerTransitionEngine {
        return .{ .allocator = allocator, .current_level = 1, .transition_count = 0, .params = .{}, .experiences = std.ArrayList(TransitionExperience).empty, .tuner = .{}, .failure_counts = .{} };
    }
    pub fn deinit(self: *LayerTransitionEngine) void { self.experiences.deinit(self.allocator); }

    /// 释放 SuperNode 列表（包括每个节点的 inner_node_ids）
    pub fn deinitSuperNodes(self: *LayerTransitionEngine, nodes: *std.ArrayList(SuperNode)) void {
        for (nodes.items) |*node| {
            node.inner_node_ids.deinit(self.allocator);
        }
        nodes.deinit(self.allocator);
    }
    pub fn packFrontToSuperNodes(self: *LayerTransitionEngine, pts: []const ParetoPoint, step: u64) !std.ArrayList(SuperNode) {
        var nodes = std.ArrayList(SuperNode).empty;
        for (pts) |pt| {
            var inner_ids = std.ArrayList(u64).empty;
            if (pt.metadata.node_count > 0) {
                const inner_n = @min(pt.metadata.node_count, @as(u64, 16));
                try inner_ids.ensureTotalCapacity(self.allocator, @intCast(inner_n));
                for (0..inner_n) |i| {
                    try inner_ids.append(self.allocator, pt.id * 1000 + i);
                }
            }
            try nodes.append(self.allocator, .{
                .base_scores = pt.scores,
                .inner_node_ids = inner_ids,
                .input_port = pt.id,
                .output_port = pt.id * 2 + 1,
                .origin_front_point = pt,
                .created_at_step = step,
                .inner_node_count = pt.metadata.node_count,
                .inner_edge_count = pt.metadata.edge_count,
                .avg_imbalance = pt.metadata.avg_imbalance,
            });
        }
        return nodes;
    }
    pub fn recomputeDimensions(self: *LayerTransitionEngine, w: [7]f64) DimensionRecombination {
        _ = self;
        var indices: [7]usize = .{0,1,2,3,4,5,6};
        // 按权重降序排序：把 w 作为 context 传给比较函数
        const Ctx = struct {
            weights: [7]f64,
            fn lt(ctx: @This(), a: usize, b: usize) bool {
                return ctx.weights[a] > ctx.weights[b];
            }
        };
        std.sort.block(usize, &indices, Ctx{ .weights = w }, Ctx.lt);
        return .{
            .preserved = .{ indices[0], indices[1], indices[2], indices[3], indices[4] },
            .eliminated = .{ indices[5], indices[6] },
            .new_dimensions = .{
                .{ .id = 7, .name = "mod_coherence", .description = "模块化一致性" },
                .{ .id = 8, .name = "hierarchy_depth", .description = "层级有效深度" },
            },
        };
    }
    pub fn unfoldNewLayer(self: *LayerTransitionEngine, n: std.ArrayList(SuperNode), rc: DimensionRecombination, step: u64) Layer {
        return .{ .level = self.current_level + 1, .super_nodes = n, .created_at_step = step, .dimension_recombination = rc };
    }
    pub fn maybeTransition(self: *LayerTransitionEngine, pts: []const ParetoPoint, w: [7]f64, hist: []const [7]f64, step: u64, sat: bool) !?Layer {
        _ = hist;
        
        if (!sat or pts.len < self.params.min_front_size) return null;
        const sn = try self.packFrontToSuperNodes(pts, step);
        if (sn.items.len < 3) return null;
        const rc = self.recomputeDimensions(w);
        var nl = self.unfoldNewLayer(sn, rc, step);
        const v = verifyTransition(&nl, pts.len, if (pts.len>0) pts[0].scores else .{0,0,0,0,0,0,0});
        if (!v.allOk()) return null;
        try self.experiences.append(self.allocator, .{.level=self.current_level,.success=true,.failure_type=null,.params_before=self.params,.params_after=self.params,.step=step});
        if (self.experiences.items.len - 1 >= 3 and self.experiences.items[self.experiences.items.len-1].success and self.experiences.items[self.experiences.items.len-2].success) {
            self.params.min_front_size = @max(10, self.params.min_front_size - 5);
        }
        self.current_level += 1;
        self.transition_count += 1;
        return nl;
    }
    /// 基于历史经验推荐跃迁参数
    /// 查找指定层级的最后一次成功经验的参数
    pub fn recommendParams(self: *const LayerTransitionEngine, lv: u64) TransitionParams {
        // 从后往前找，找到第一个该层级的成功经验
        var i = self.experiences.items.len;
        while (i > 0) {
            i -= 1;
            const exp = self.experiences.items[i];
            if (exp.level == lv and exp.success) {
                return exp.params_before;
            }
        }
        // 没有历史经验，返回默认参数（结合 tuner 的当前状态）
        var params = self.params;
        params.min_front_size = self.tuner.min_front_size;
        params.preserved_dim_count = self.tuner.preserved_dim_count;
        params.new_dim_count = self.tuner.new_dim_count;
        params.initial_network_size = self.tuner.initial_network_size;
        params.coupling_density = self.tuner.coupling_density;
        return params;
    }

    /// 尝试执行一次层级跃迁
    /// 这是实际使用的主接口，包含完整的预备检查、跃迁执行、验证、失败处理流程
    pub fn attemptTransition(self: *LayerTransitionEngine, pts: []const ParetoPoint, w: [7]f64, step: u64) !?Layer {
        // 1. 预备条件检查
        if (pts.len < self.tuner.min_front_size) return null;

        // 记录跃迁前的参数
        const params_before = self.params;

        // 2. 打包旧层 Pareto 前沿为 SuperNode
        var super_nodes = try self.packFrontToSuperNodes(pts, step);
        errdefer super_nodes.deinit(self.allocator);

        if (super_nodes.items.len < 3) return null;

        // 3. 维度重组
        const dim_recomb = self.recomputeDimensions(w);

        // 4. 展开新层
        var new_layer = self.unfoldNewLayer(super_nodes, dim_recomb, step);

        // 5. 验证跃迁结果
        const old_best = if (pts.len > 0) pts[0].scores else [_]f64{0} ** 7;
        const verification = verifyTransition(&new_layer, pts.len, old_best);

        if (verification.allOk()) {
            // 跃迁成功
            try self.experiences.append(self.allocator, .{
                .level = self.current_level,
                .success = true,
                .failure_type = null,
                .params_before = params_before,
                .params_after = self.params,
                .step = step,
            });

            // 连续成功则降低门槛
            if (self.experiences.items.len >= 3) {
                const last3 = self.experiences.items[self.experiences.items.len - 3 ..];
                var all_success = true;
                for (last3) |exp| {
                    if (!exp.success) {
                        all_success = false;
                        break;
                    }
                }
                if (all_success) {
                    self.tuner.adjustForSuccess();
                }
            }

            self.current_level += 1;
            self.transition_count += 1;
            return new_layer;
        } else {
            // 跃迁失败
            const failure_type = diagnoseFailure(verification);

            // 更新失败计数
            switch (failure_type) {
                .survival => self.failure_counts.survival += 1,
                .front_effectiveness => self.failure_counts.front += 1,
                .dimension_quality => self.failure_counts.dim += 1,
                .instability => self.failure_counts.instability += 1,
            }

            // 根据失败类型调整参数
            self.tuner.adjustForFailure(failure_type);

            // 记录失败经验
            try self.experiences.append(self.allocator, .{
                .level = self.current_level,
                .success = false,
                .failure_type = failure_type,
                .params_before = params_before,
                .params_after = self.params,
                .step = step,
            });

            // 清理新层（因为失败了，不需要返回）
            new_layer.super_nodes.deinit(self.allocator);

            return null;
        }
    }

    /// 重置饱和状态
    /// 跃迁成功或失败后调用，重置饱和检测器的状态
    pub fn resetSaturation(self: *LayerTransitionEngine) void {
        // 目前通过 tuner 参数自适应来间接处理
        // 未来可以扩展为更复杂的饱和状态管理
        _ = self;
    }
};

