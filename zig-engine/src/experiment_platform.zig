// 多分支实验平台 v5.1 — Phase2 补全（白皮书 doc9 §2）
const std = @import("std");

pub const ExperimentBranch = struct {
    name: []const u8,
    step: u64,
    obj_count: u64,
    knowledge_size: u64,
    free_energy: f64,
    consistency: f64,
};

pub const ExperimentPlatform = struct {
    allocator: std.mem.Allocator,
    branches: std.ArrayList(ExperimentBranch),

    pub fn init(allocator: std.mem.Allocator) ExperimentPlatform {
        return .{ .allocator = allocator, .branches = std.ArrayList(ExperimentBranch).empty };
    }

    pub fn deinit(self: *ExperimentPlatform) void {
        self.branches.deinit(self.allocator);
    }

    pub fn runExperiment(self: *ExperimentPlatform, name: []const u8, step: u64, obj_count: u64, knowledge: u64, free_energy: f64, consistency: f64) !void {
        try self.branches.append(self.allocator, .{ .name = name, .step = step, .obj_count = obj_count, .knowledge_size = knowledge, .free_energy = free_energy, .consistency = consistency });
    }

    pub fn compareExperiments(self: *const ExperimentPlatform) void {
        if (self.branches.items.len == 0) return;
        std.debug.print("\n[实验对比] {d} 个分支:\n", .{self.branches.items.len});
        for (self.branches.items, 0..) |b, i| {
            std.debug.print("  {d}. {s}: step={d} obj={d} knowledge={d} F={d:.4} 自洽率={d:.4}\n", .{i+1, b.name, b.step, b.obj_count, b.knowledge_size, b.free_energy, b.consistency});
        }
    }
};
