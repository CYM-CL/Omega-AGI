// Ω-落尘AGI 持久度估计 v2.0 — doc6+doc7 完整实现
// Items 1.6-1.9: 模块持久度/节点重要性/薄弱检测/校准
const std = @import("std");

pub const PerturbationSpec = struct {
    node_fraction: f64 = 0.1, value_perturb_ratio: f64 = 0.2,
};
pub const PersistenceEstimate = struct {
    estimated_lifetime: f64, stability_score: f64,
    recovery_speed: f64, resilience: f64, diverging: bool,
};
pub const WeakPoint = struct {
    index: usize, persistence: f64, criticality: f64,
};
pub const CalibrationParams = struct {
    slope: f64, intercept: f64, r_squared: f64,
};
/// 全局持久度估计（doc6 §1.4）
pub fn estimatePersistence(imbalance_curve: []const f64, observation_steps: usize) PersistenceEstimate {
    if (imbalance_curve.len < 10) return .{ .estimated_lifetime = 10.0, .stability_score = 0.0, .recovery_speed = 0.0, .resilience = 0.0, .diverging = true };
    const steps = @min(observation_steps, imbalance_curve.len);
    const initial = imbalance_curve[0];
    if (initial < 1e-9) return .{ .estimated_lifetime = 1000.0, .stability_score = 1.0, .recovery_speed = 1.0, .resilience = 1.0, .diverging = false };
    const final_start = if (steps >= 10) steps - 10 else 0;
    var final_sum: f64 = 0;
    for (final_start..steps) |i| { final_sum += imbalance_curve[i]; }
    const final_avg = final_sum / @as(f64, @floatFromInt(steps - final_start));
    const resilience = @max(0.0, 1.0 - @abs(final_avg - initial) / initial);
    var min_val = initial;
    for (imbalance_curve[0..steps]) |v| { if (v < min_val) min_val = v; }
    const recovery_speed = 1.0 - min_val / @max(initial, 1e-9);
    const trend_window = @min(20, steps / 2);
    var trend: f64 = 0.0;
    if (trend_window > 1) { trend = computeTrend(imbalance_curve[steps - trend_window .. steps]); }
    const diverging = trend > 0.01;
    const stability_score = @max(0.0, @min(1.0, 0.5*resilience + 0.3*recovery_speed + (if (diverging) @as(f64, 0.0) else @as(f64, 0.2))));
    const estimated_lifetime = @exp(2.0 + 5.0 * stability_score);
    return .{ .estimated_lifetime = estimated_lifetime, .stability_score = stability_score, .recovery_speed = recovery_speed, .resilience = resilience, .diverging = diverging };
}

/// 模块级持久度估计（doc7 §2.3）
/// 模块级持久度估计：使用模块不平衡度曲线估计持久度
/// obs: 观测步数
pub fn estimateModulePersistence(module_curve: []const f64, obs: usize) PersistenceEstimate {
    // 复用全局算法，由调用方提供模块局部的扰动后不平衡曲线
    return estimatePersistence(module_curve, obs);
}

/// 节点重要性估计（doc7 §2.3）
pub fn estimateNodeImportance(global_with: f64, global_without: f64) f64 {
    if (global_with < 1e-9) return 0.0;
    return @max(0.0, (global_with - global_without) / global_with);
}

/// 薄弱环节检测（doc7 §2.4）
pub fn findWeakestPoints(module_persistences: []const f64, global_persistence: f64, top_n: usize, allocator: std.mem.Allocator) std.ArrayList(WeakPoint) {
    var result = std.ArrayList(WeakPoint).empty;
    if (module_persistences.len == 0) return result;
    for (module_persistences, 0..) |pers, i| {
        const crit = if (pers > 0) @min(100.0, global_persistence / pers) else 100.0;
        result.append(allocator, .{ .index = i, .persistence = pers, .criticality = crit }) catch {};
    }
    // 按关键度降序排列
    if (result.items.len > 1) {
        std.sort.block(WeakPoint, result.items, {}, struct {
            fn lessThan(_: void, a: WeakPoint, b: WeakPoint) bool { return a.criticality > b.criticality; }
        }.lessThan);
    }
    if (result.items.len > top_n) result.shrinkAndFree(allocator, top_n);
    return result;
}

/// 自校准（doc6 §1.6）：线性回归 actual = a * estimated + b
/// 持久度自校准：线性回归 estimated = slope * actual + intercept
/// v7.1: 实现实际的最小二乘拟合
pub fn calibrateEstimator(estimated: []const f64, actual: []const f64) CalibrationParams {
    const n = @as(f64, @floatFromInt(@min(estimated.len, actual.len)));
    if (n < 3) return .{ .slope = 1.0, .intercept = 0.0, .r_squared = 0.0 };
    var sum_x: f64 = 0; var sum_y: f64 = 0;
    var sum_xy: f64 = 0; var sum_xx: f64 = 0; var sum_yy: f64 = 0;
    for (0..@as(usize, @intFromFloat(n))) |i| {
        const x = estimated[i]; const y = actual[i];
        sum_x += x; sum_y += y; sum_xy += x*y; sum_xx += x*x; sum_yy += y*y;
    }
    const slope = (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x + 1e-9);
    const intercept = (sum_y - slope * sum_x) / n;
    const ss_res = sum_yy - intercept * sum_y - slope * sum_xy;
    const ss_tot = sum_yy - sum_y * sum_y / n;
    const r_squared = if (ss_tot > 1e-9) 1.0 - ss_res / ss_tot else 0.0;
    return .{ .slope = slope, .intercept = intercept, .r_squared = @max(0.0, r_squared) };
}

// ========== 测试 ==========
test "持久度估计——稳定系统" {
    var curve: [50]f64 = undefined;
    for (0..50) |i| { curve[i] = 0.5 - @as(f64, @floatFromInt(i))*0.01; }
    const r = estimatePersistence(&curve, 50);
    try std.testing.expect(r.stability_score > 0.5); try std.testing.expect(!r.diverging);
}
test "持久度估计——发散系统" {
    var curve: [50]f64 = undefined;
    for (0..50) |i| { curve[i] = 0.3 + @as(f64, @floatFromInt(i))*0.02; }
    const r = estimatePersistence(&curve, 50);
    try std.testing.expect(r.diverging); try std.testing.expect(r.stability_score < 0.5);
}
test "持久度估计——短序列降级" {
    var curve: [3]f64 = .{1.0, 0.8, 0.6};
    const r = estimatePersistence(&curve, 50);
    try std.testing.expect(r.diverging); try std.testing.expect(r.estimated_lifetime < 100);
}

test "estimateModulePersistence 模块持久度" {
    var curve: [30]f64 = undefined;
    for (0..30) |i| { curve[i] = 0.4 - @as(f64, @floatFromInt(i))*0.005; }
    const r = estimateModulePersistence(&curve, 30);
    try std.testing.expect(r.estimated_lifetime > 0);
}

test "estimateNodeImportance 节点重要性" {
    const imp = estimateNodeImportance(500.0, 200.0);
    try std.testing.expect(imp > 0.5);
    try std.testing.expect(imp < 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), estimateNodeImportance(0.0, 0.0));
}

test "findWeakestPoints 薄弱检测" {
    const persistences = [_]f64{1000, 500, 200, 800};
    var result = findWeakestPoints(&persistences, 1000, 2, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.items[0].index);
}

pub fn computePerturbationStability(scores_before: []const f64, scores_after: []const f64) f64 {
    const n = @min(scores_before.len, scores_after.len);
    if (n == 0) return 0.0;
    var total: f64 = 0;
    for (0..n) |i| {
        if (@abs(scores_before[i]) < 1e-9) { total += 1.0; }
        else { total += @max(0.0, 1.0 - @abs(scores_after[i] - scores_before[i]) / @abs(scores_before[i])); }
    }
    return total / @as(f64, @floatFromInt(n));
}

test "computePerturbationStability 扰动稳定性" {
    const before = [_]f64{100, 200, 300, 400, 500};
    const after  = [_]f64{98, 205, 295, 410, 490};
    const stab = computePerturbationStability(&before, &after);
    try std.testing.expect(stab > 0.9);
    try std.testing.expect(stab < 1.0);
}

test "calibrateEstimator 自校准" {
    const est = [_]f64{100, 200, 300, 400, 500};
    const act = [_]f64{95, 210, 290, 410, 505};
    const c = calibrateEstimator(&est, &act);
    try std.testing.expect(c.slope > 0.9); try std.testing.expect(c.slope < 1.1);
    try std.testing.expect(c.r_squared > 0.9);
}
 /// doc6 §1.4 趋势计算：返回最后 N 个数据点的相对变化斜率
 pub fn computeTrend(curve: []const f64) f64 {
     if (curve.len < 4) return 0.0;
     const half = curve.len / 2;
     var first_half: f64 = 0; var second_half: f64 = 0;
     for (0..half) |i| { first_half += curve[i]; }
     for (half..curve.len) |i| { second_half += curve[i]; }
     const fh_avg = first_half / @as(f64, @floatFromInt(half));
     const sh_avg = second_half / @as(f64, @floatFromInt(curve.len - half));
     const initial = if (curve.len > 0) curve[0] else 1.0;
     return (sh_avg - fh_avg) / @max(@abs(initial), 1e-9);
 }
 
