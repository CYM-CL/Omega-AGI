const std = @import("std");
const sm64 = @import("splitmix64.zig");

pub const StructuralAttribute = struct { id: usize, name: []const u8, value: f64, correlation: f64, importance: f64, complexity: usize, active: bool };
pub const NetworkSnapshot = struct { node_count: u64, edge_count: u64, avg_imbalance: f64, modularity: f64, avg_path_length: f64, clustering_coeff: f64, throughput: f64, rule_density: f64, self_ref_depth: f64, feedback_density: f64, imbalance_variance: f64, imbalance_skewness: f64 };
pub const HistoryEntry = struct { step: u64, values: [12]f64, persistence: f64 };
pub const HISTORY_LIMIT: usize = 100;
pub const UnaryOp = enum { identity, negate, abs, square, sqrt, log, normalize };
pub const BinaryOp = enum { add, subtract, multiply, divide, max, min, weighted_avg };

pub const AttributePool = struct {
    allocator: std.mem.Allocator,
    attributes: std.ArrayList(StructuralAttribute),
    snapshot_history: std.ArrayList(HistoryEntry),
    dimension_change_count: u64,
    rng: sm64.SplitMix64,

    pub fn init(allocator: std.mem.Allocator, seed: u64) AttributePool {
        return .{
            .allocator = allocator,
            .attributes = std.ArrayList(StructuralAttribute).empty,
            .snapshot_history = std.ArrayList(HistoryEntry).empty,
            .dimension_change_count = 0,
            .rng = sm64.SplitMix64.init(seed),
        };
    }
    pub fn deinit(self: *AttributePool) void {
        self.attributes.deinit(self.allocator);
        self.snapshot_history.deinit(self.allocator);
    }
    pub fn registerSnapshot(self: *AttributePool, values: [12]f64, persistence: f64) void {
        self.snapshot_history.append(self.allocator, .{ .step = self.snapshot_history.items.len, .values = values, .persistence = persistence }) catch {};
        if (self.snapshot_history.items.len > HISTORY_LIMIT) { _ = self.snapshot_history.orderedRemove(0); }
    }
    pub fn discoverDimensions(self: *AttributePool) void {
        if (self.snapshot_history.items.len < 5) return;
        const p = self.snapshot_history.items[self.snapshot_history.items.len - 1].persistence;
        for (0..self.attributes.items.len) |i| {
            var sum_x: f64 = 0; var sum_y: f64 = 0; var sum_xy: f64 = 0;
            var sum_x2: f64 = 0; var sum_y2: f64 = 0;
            const limit = @min(self.snapshot_history.items.len, @as(usize, 100));
            const start_idx = if (self.snapshot_history.items.len > 100) self.snapshot_history.items.len - 100 else @as(usize, 0);
            for (self.snapshot_history.items[start_idx..limit]) |entry| {
                const x = entry.values[i];
                const y = entry.persistence;
                sum_x += x; sum_y += y; sum_xy += x * y;
                sum_x2 += x * x; sum_y2 += y * y;
            }
            const n = @as(f64, @floatFromInt(limit - start_idx));
            if (n > 1) {
                const num = n * sum_xy - sum_x * sum_y;
                const den = @sqrt(@abs(n * sum_x2 - sum_x * sum_x) * @abs(n * sum_y2 - sum_y * sum_y));
                const corr = if (den > 1e-9) num / den else 0.0;
                self.attributes.items[i].correlation = self.attributes.items[i].correlation * 0.9 + @abs(corr) * 0.1;
                self.attributes.items[i].importance = @abs(corr) * (1.0 / (1.0 + p));
            }
        }
    }

    pub fn generateNewAttribute(self: *AttributePool) ?usize {
        if (self.attributes.items.len >= 50) return null;
        const cnt = self.attributes.items.len;
        const cnt_u64 = @as(u64, @intCast(cnt));

        // 随机选择策略：0=一元运算, 1=二元运算, 2=新基础属性
        const strategy = self.rng.nextRange(3);
        const id = cnt;

        const result = blk: {
            if (strategy == 0 and cnt >= 1) {
                // 一元运算：随机选择一个源属性
                const a_idx = self.rng.nextRange(cnt_u64);
                const src = &self.attributes.items[@intCast(a_idx)];
                // 随机选择一元运算：negate 或 abs
                const op = self.rng.nextRange(2);
                const v = if (op == 0) -src.value else @abs(src.value);
                const name = if (op == 0) "attr_neg" else "attr_abs";
                break :blk .{ .value = v, .name = name, .complexity = src.complexity + 1 };
            } else if (strategy == 1 and cnt >= 2) {
                // 二元运算：随机选择两个不同的源属性
                const a_idx = self.rng.nextRange(cnt_u64);
                var b_idx = self.rng.nextRange(cnt_u64);
                // 确保两个索引不同
                while (b_idx == a_idx) {
                    b_idx = self.rng.nextRange(cnt_u64);
                }
                const src_a = &self.attributes.items[@intCast(a_idx)];
                const src_b = &self.attributes.items[@intCast(b_idx)];
                // 随机选择二元运算：add 或 multiply
                const op = self.rng.nextRange(2);
                const v = if (op == 0) src_a.value + src_b.value else src_a.value * src_b.value;
                const name = if (op == 0) "attr_add" else "attr_mul";
                break :blk .{ .value = v, .name = name, .complexity = @max(src_a.complexity, src_b.complexity) + 1 };
            } else {
                // 生成新的基础属性（用随机值初始化）
                const v = self.rng.nextFloat() * 2.0 - 1.0; // [-1, 1]
                break :blk .{ .value = v, .name = "attr_new", .complexity = @as(usize, 1) };
            }
        };

        self.attributes.append(self.allocator, .{
            .id = @intCast(id),
            .name = result.name,
            .value = result.value,
            .correlation = 0,
            .importance = 0,
            .complexity = result.complexity,
            .active = true,
        }) catch return null;
        return id;
    }
    pub fn selectActiveDimensions(self: *AttributePool) [7]usize {
        const n = self.attributes.items.len;
        if (n < 7) {
            var r: [7]usize = undefined;
            for (0..7) |i| r[i] = if (i < n) i else 0;
            return r;
        }
        // Farthest-point sampling: select 7 most diverse attributes
        var selected: [7]usize = undefined;
        var used = [_]bool{false} ** 128;
        selected[0] = 0; used[0] = true;
        for (1..7) |k| {
            var best_d: f64 = -1; var best_j: usize = 0;
            for (0..n) |j| {
                if (used[j]) continue;
                var min_d: f64 = 1e18;
                for (0..k) |m| {
                    const a = &self.attributes.items[j];
                    const b = &self.attributes.items[selected[m]];
                    const dd = @abs(a.correlation - b.correlation) + @abs(a.importance - b.importance) + @abs(@as(f64, @floatFromInt(a.complexity - b.complexity)));
                    if (dd < min_d) min_d = dd;
                }
                if (min_d > best_d) { best_d = min_d; best_j = j; }
            }
            selected[k] = best_j; used[best_j] = true;
        }
        return selected;
    }
};

pub fn computeAttributes(snapshot: *const NetworkSnapshot) [12]f64 {
    return .{
        @as(f64, @floatFromInt(snapshot.node_count)),
        @as(f64, @floatFromInt(snapshot.edge_count)),
        snapshot.avg_imbalance,
        snapshot.imbalance_variance,
        snapshot.imbalance_skewness,
        snapshot.modularity,
        snapshot.avg_path_length,
        snapshot.clustering_coeff,
        snapshot.throughput,
        snapshot.rule_density,
        snapshot.self_ref_depth,
        snapshot.feedback_density,
    };
}

pub fn computeSparsity(snapshot: *const NetworkSnapshot) f64 {
    if (snapshot.node_count == 0) return 0.0;
    const edge_max = snapshot.node_count * (snapshot.node_count - 1);
    const active_ratio = if (edge_max > 0)
        @as(f64, @floatFromInt(snapshot.edge_count)) / @as(f64, @floatFromInt(edge_max))
    else 0.0;
    return 1.0 - active_ratio;
}
