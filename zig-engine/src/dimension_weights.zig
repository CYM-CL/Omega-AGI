// Ω-落尘AGI 维度权重系统 v1.0
//
// 对应 doc1 §3：维度权重内生演化机制
// 包含 3 个核心功能：
//   1. computeDimensionWeights — 维度重要性权重计算（前沿评分方差法）
//   2. isParetoImprovementSoft — 软Pareto改进判断（加权下降量）
//   3. computeDropThreshold — 下降阈值计算（前沿分散度）
//
// 设计文档（doc1 §3）原文使用扰动法测权重（扰动维度→测持久度变化），
// 当前实现使用 Pareto 前沿评分方差作为近似，待 System 抽象完备后升级为扰动法。
//   if (isParetoImprovementSoft(old_pt, cand_pt, weights, threshold)) { ... }

const std = @import("std");
const pf = @import("pareto_front.zig");

/// 计算7维权重（doc1 §3.2）
/// 基于Pareto前沿上各维度的评分分布：维度方差越大→区分度越高→权重越高
/// 归一化使权重之和为1
pub fn computeDimensionWeights(front: *const pf.SystemParetoFront) [7]f64 {
    if (front.points.items.len < 2) return .{1.0 / 7.0} ** 7;

    var variances: [7]f64 = .{0} ** 7;
    var means: [7]f64 = .{0} ** 7;
    const n = @as(f64, @floatFromInt(front.points.items.len));

    // 均值
    for (front.points.items) |p| { for (0..7) |d| means[d] += p.scores[d]; }
    for (0..7) |d| means[d] /= n;

    // 方差
    for (front.points.items) |p| { for (0..7) |d| {
        const diff = p.scores[d] - means[d];
        variances[d] += diff * diff;
    } }
    for (0..7) |d| variances[d] /= n;

    // 归一化
    var total: f64 = 0;
    for (0..7) |d| total += variances[d];
    if (total < 1e-9) return .{1.0 / 7.0} ** 7;
    for (0..7) |d| variances[d] /= total;
    return variances;
}

/// 软Pareto改进判断（doc1 §3.3）
/// 条件1：至少一个维度严格提升
/// 条件2：加权总下降量不超过阈值
pub fn isParetoImprovementSoft(
    old_scores: [7]f64,
    candidate_scores: [7]f64,
    weights: [7]f64,
    threshold: f64,
) bool {
    var total_drop: f64 = 0.0;
    var has_improvement = false;
    for (0..7) |i| {
        const diff = candidate_scores[i] - old_scores[i];
        if (diff > 0) has_improvement = true;
        if (diff < 0) total_drop += -diff * weights[i];
    }
    return has_improvement and total_drop <= threshold;
}

/// 计算软Pareto下降阈值（doc1 §3.5）
/// 阈值 = 前沿上点之间加权平均距离 × 0.1
pub fn computeDropThreshold(front: *const pf.SystemParetoFront, weights: [7]f64) f64 {
    if (front.points.items.len < 2) return 0.1;
    const n = front.points.items.len;
    var total_weighted_dist: f64 = 0;
    var pairs: f64 = 0;
    for (0..n) |i| {
        for (i + 1..n) |j| {
            var dist: f64 = 0;
            for (0..7) |d| {
                const diff = front.points.items[i].scores[d] - front.points.items[j].scores[d];
                dist += diff * diff * weights[d];
            }
            total_weighted_dist += @sqrt(dist);
            pairs += 1;
        }
    }
    const avg_dist = if (pairs > 0) total_weighted_dist / pairs else 0.1;
    return @max(0.01, avg_dist * 0.1);
}

// ============================================================
// 测试（doc1 §3 完整验证）
// ============================================================
test "computeDimensionWeights 等权重" {
    var front = pf.SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();
    const weights = computeDimensionWeights(&front);
    try std.testing.expectEqual(@as(f64, 1.0 / 7.0), weights[0]);
}

test "computeDimensionWeights 方差权重" {
    var front = pf.SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();
    // 维度0方差大（[0.9, 0.1]），维度1方差小（[0.4, 0.5]）
    // 注意：两个点必须在Pareto意义上互不支配，否则tryAdd会拒绝第二个点
    // 点1在dim0占优(0.9>0.1)，点2在dim1占优(0.5>0.4) → 互不支配
    _ = front.tryAdd(.{ .scores = .{0.9, 0.4, 0.5, 0.5, 0.5, 0.5, 0.5}, .id = 1, .step = 0 });
    _ = front.tryAdd(.{ .scores = .{0.1, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5}, .id = 2, .step = 1 });
    const weights = computeDimensionWeights(&front);
    try std.testing.expect(weights[0] > weights[1]);
}

test "isParetoImprovementSoft 正常提升" {
    const old = [_]f64{0.3, 0.4, 0.5, 0.5, 0.5, 0.5, 0.5};
    const cand = [_]f64{0.4, 0.4, 0.5, 0.5, 0.5, 0.5, 0.5};
    var front = pf.SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();
    const weights = [_]f64{0.2, 0.2, 0.1, 0.1, 0.1, 0.1, 0.2};
    try std.testing.expect(isParetoImprovementSoft(old, cand, weights, 0.1));
}

test "isParetoImprovementSoft 下降过高被拒" {
    const old = [_]f64{0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5};
    // 维度0提升0.1，但维度1下降0.5×权重0.3=0.15，超过阈值0.1
    const cand = [_]f64{0.6, 0.0, 0.5, 0.5, 0.5, 0.5, 0.5};
    var front = pf.SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();
    const weights = [_]f64{0.2, 0.3, 0.1, 0.1, 0.1, 0.1, 0.1};
    try std.testing.expect(!isParetoImprovementSoft(old, cand, weights, 0.1));
}

test "computeDropThreshold 基本计算" {
    var front = pf.SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();
    // 两个相似的点→阈值小
    _ = front.tryAdd(.{ .scores = .{0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5}, .id = 1, .step = 0 });
    _ = front.tryAdd(.{ .scores = .{0.4, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5}, .id = 2, .step = 1 });
    const weights = [_]f64{1.0/7.0} ** 7;
    const threshold = computeDropThreshold(&front, weights);
    try std.testing.expect(threshold > 0);
    try std.testing.expect(threshold < 0.5);
}
