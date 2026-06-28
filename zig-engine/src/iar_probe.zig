// Ω-落尘AGI IAR三轴探针系统 v1.0
//
// 对应论文策略5：IAR式探针系统
// 三轴诊断：效果轴(MIP)、计算轴(DTR)、稳定轴(Jaccard)
//
// 核心诊断指标：
//   1. 关键节点稀疏度 = 关键节点数 / 总节点数
//   2. 包含比率 IR = 效果关键节点 ∩ 计算密集节点 / 效果关键节点
//   3. 稳定性指数 = 扰动前后关键节点集合的 Jaccard 相似度

const std = @import("std");

/// 单节点三轴探针数据
pub const IARNodeProbe = struct {
    node_id: u64,
    effect_score: f64,
    compute_score: f64,
    stability_score: f64,
    is_critical: bool,
    is_compute_dense: bool,
};

/// 系统级 IAR 诊断报告
pub const IARDiagnosticReport = struct {
    /// 三轴聚合指标
    critical_node_sparsity: f64,
    inclusion_ratio: f64,
    stability_index: f64,
    /// 各探针节点列表
    probes: std.ArrayList(IARNodeProbe),
    /// 诊断结论
    is_genuine_evolution: bool,
    diagnostic_message: []const u8,
};

/// IAR 探针系统
pub const IARProbe = struct {
    allocator: std.mem.Allocator,
    probes: std.ArrayList(IARNodeProbe),

    pub fn init(allocator: std.mem.Allocator) IARProbe {
        return .{ .allocator = allocator, .probes = std.ArrayList(IARNodeProbe).empty };
    }

    pub fn deinit(self: *IARProbe) void {
        self.probes.deinit(self.allocator);
    }

    /// 探查单个节点
    pub fn probeNode(self: *IARProbe, node_id: u64, effect: f64, compute: f64, stability: f64) void {
        self.probes.append(self.allocator, .{
            .node_id = node_id,
            .effect_score = effect,
            .compute_score = compute,
            .stability_score = stability,
            .is_critical = effect > 0.5,
            .is_compute_dense = compute > 0.5,
        }) catch {};
    }

    /// 生成诊断报告
    pub fn diagnose(self: *const IARProbe) IARDiagnosticReport {
        const total: usize = self.probes.items.len;
        if (total == 0) return .{
            .critical_node_sparsity = 1.0,
            .inclusion_ratio = 0.0,
            .stability_index = 0.0,
            .probes = std.ArrayList(IARNodeProbe).empty,
            .is_genuine_evolution = false,
            .diagnostic_message = "无探针数据",
        };

        var critical_count: usize = 0;
        var compute_dense_count: usize = 0;
        var effect_and_compute: usize = 0;
        var sum_stability: f64 = 0;
        var stability_samples: usize = 0;

        for (self.probes.items) |p| {
            if (p.is_critical) {
                critical_count += 1;
                if (p.is_compute_dense) effect_and_compute += 1;
            }
            if (p.is_compute_dense) compute_dense_count += 1;
            if (p.stability_score >= 0) {
                sum_stability += p.stability_score;
                stability_samples += 1;
            }
        }

        const nf = @as(f64, @floatFromInt(total));
        const sparsity = if (critical_count > 0)
            1.0 - @as(f64, @floatFromInt(critical_count)) / nf
        else
            1.0;
        const ir = if (critical_count > 0)
            @as(f64, @floatFromInt(effect_and_compute)) / @as(f64, @floatFromInt(critical_count))
        else
            0.0;
        const stability_idx = if (stability_samples > 0)
            sum_stability / @as(f64, @floatFromInt(stability_samples))
        else
            0.0;

        const genuine = sparsity < 0.95 and ir > 0.3 and stability_idx > 0.5;
        const msg = if (genuine)
            "真演化：关键节点稀疏且稳定，效果与计算高度重合"
        else if (sparsity >= 0.95)
            "假演化：无关键节点，系统未形成有效结构"
        else if (ir <= 0.3)
            "低效演化：效果关键节点与计算密集节点重合度低"
        else
            "不稳定演化：关键节点扰动下变化过大";

        return .{
            .critical_node_sparsity = sparsity,
            .inclusion_ratio = ir,
            .stability_index = stability_idx,
            .probes = self.probes,
            .is_genuine_evolution = genuine,
            .diagnostic_message = msg,
        };
    }

    /// 清除所有探针数据
    pub fn clear(self: *IARProbe) void {
        self.probes.clearRetainingCapacity();
    }

    /// 计算两个节点集合的Jaccard相似度
    pub fn jaccardSimilarity(a: []const u64, b: []const u64) f64 {
        var intersection: usize = 0;
        for (a) |id_a| {
            for (b) |id_b| {
                if (id_a == id_b) { intersection += 1; break; }
            }
        }
        const union_size = a.len + b.len - intersection;
        if (union_size == 0) return 1.0;
        return @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_size));
    }
};

// ============================================================
// 测试
// ============================================================
test "IARProbe 初始化" {
    var probe = IARProbe.init(std.testing.allocator);
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 0), probe.probes.items.len);
}

test "IARProbe 单节点探查" {
    var probe = IARProbe.init(std.testing.allocator);
    defer probe.deinit();
    probe.probeNode(1, 0.8, 0.9, 0.7);
    probe.probeNode(2, 0.2, 0.3, 0.9);
    try std.testing.expectEqual(@as(usize, 2), probe.probes.items.len);
}

test "IARProbe 真演化诊断" {
    var probe = IARProbe.init(std.testing.allocator);
    defer probe.deinit();
    // 模拟真演化：关键节点稀疏(2/10=0.2)，效果与计算重合(IR高)，稳定
    for (0..8) |i| probe.probeNode(i, 0.1, 0.1, 0.8);
    probe.probeNode(8, 0.9, 0.8, 0.7); // 效果关键 + 计算密集
    probe.probeNode(9, 0.8, 0.7, 0.6); // 效果关键 + 计算密集
    const report = probe.diagnose();
    try std.testing.expect(report.is_genuine_evolution);
}

test "IARProbe 假演化诊断" {
    var probe = IARProbe.init(std.testing.allocator);
    defer probe.deinit();
    // 模拟假演化：所有节点都是非关键
    for (0..10) |i| probe.probeNode(i, 0.1, 0.1, 0.0);
    const report = probe.diagnose();
    try std.testing.expect(!report.is_genuine_evolution);
}

test "IARProbe Jaccard相似度" {
    const a = [_]u64{1, 2, 3, 4};
    const b = [_]u64{3, 4, 5, 6};
    const jac = IARProbe.jaccardSimilarity(&a, &b);
    // 交集{3,4}=2, 并集{1,2,3,4,5,6}=6, J=2/6=0.333...
    try std.testing.expect(@abs(jac - 2.0/6.0) < 0.001);
}
