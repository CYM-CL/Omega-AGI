// 演化回放调试系统 v5.1 — Phase2 补全（白皮书 doc9 §1）
const std = @import("std");

pub const Snapshot = struct {
    step: u64,
    object_count: u64,
    morphism_count: u64,
    frozen_count: u64,
    knowledge_size: u64,
    consistency_rate: f64,
};

pub const EvolutionDebugger = struct {
    allocator: std.mem.Allocator,
    snapshots: std.ArrayList(Snapshot),

    pub fn init(allocator: std.mem.Allocator) EvolutionDebugger {
        return .{ .allocator = allocator, .snapshots = std.ArrayList(Snapshot).empty };
    }

    pub fn deinit(self: *EvolutionDebugger) void {
        self.snapshots.deinit(self.allocator);
    }

    pub fn saveSnapshot(self: *EvolutionDebugger, step: u64, obj_count: u64, mor_count: u64, frozen: u64, knowledge: u64, consistency: f64) !void {
        try self.snapshots.append(self.allocator, .{ .step = step, .object_count = obj_count, .morphism_count = mor_count, .frozen_count = frozen, .knowledge_size = knowledge, .consistency_rate = consistency });
    }

    pub fn loadSnapshot(self: *const EvolutionDebugger, step: u64) ?Snapshot {
        for (self.snapshots.items) |s| {
            if (s.step == step) return s;
        }
        return null;
    }

    pub fn diffSnapshots(self: *const EvolutionDebugger, a: u64, b: u64) void {
        const sa = self.loadSnapshot(a);
        const sb = self.loadSnapshot(b);
        if (sa == null or sb == null) {
            std.debug.print("  [diff] 快照 {d} 或 {d} 不存在\n", .{a, b});
            return;
        }
        const sa_v = sa.?;
        const sb_v = sb.?;
        std.debug.print("  [diff] 步{d} → 步{d}:\n", .{a, b});
        std.debug.print("    对象: {d} → {d} (Δ{d})\n", .{sa_v.object_count, sb_v.object_count, @as(i64, @intCast(sb_v.object_count)) - @as(i64, @intCast(sa_v.object_count))});
        std.debug.print("    态射: {d} → {d} (Δ{d})\n", .{sa_v.morphism_count, sb_v.morphism_count, @as(i64, @intCast(sb_v.morphism_count)) - @as(i64, @intCast(sa_v.morphism_count))});
        std.debug.print("    冻结: {d} → {d}\n", .{sa_v.frozen_count, sb_v.frozen_count});
        std.debug.print("    自洽率: {d:.4} → {d:.4}\n", .{sa_v.consistency_rate, sb_v.consistency_rate});
    }
};
