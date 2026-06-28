// 可视化仪表盘 v5.1 — Phase2 补全（白皮书 doc8 §2）
const std = @import("std");

pub fn renderDashboard(obj_count: u64, morphism_count: u64, frozen_count: u64, knowledge_size: u64, pareto_front_size: usize, saturation_progress: f64, free_energy: f64, consistency: f64) void {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("  Ω-落尘AGI 系统仪表盘\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  对象数: {d:8}  态射数: {d:8}  冻结: {d:8}\n", .{obj_count, morphism_count, frozen_count});
    std.debug.print("  知识量: {d:8}  前沿点: {d:8}\n", .{knowledge_size, pareto_front_size});
    std.debug.print("  自由能: {d:.4}  自洽率: {d:.4}%\n", .{free_energy, consistency * 100.0});
    std.debug.print("  饱和进度: [{s}{s}] {d:.1}%\n", .{
        "=" ** @as(usize, @intFromFloat(saturation_progress * 20)),
        " " ** @as(usize, @intFromFloat((1.0 - saturation_progress) * 20)),
        saturation_progress * 100.0,
    });
    std.debug.print("========================================\n\n", .{});
}

pub fn renderParetoProjection(scores: []const [7]f64) void {
    std.debug.print("  Pareto 前沿投影 (dim0 × dim1):\n", .{});
    for (scores) |s| {
        const x = @as(usize, @intFromFloat(s[0] * 10));
        const y = @as(usize, @intFromFloat(s[1] * 10));
        std.debug.print("    ({d:.2},{d:.2}) ", .{s[0], s[1]});
        for (0..@min(y, @as(usize, 10))) |_| { std.debug.print(" ", .{}); }
        std.debug.print("*\n", .{});
        _ = x;
    }
}
