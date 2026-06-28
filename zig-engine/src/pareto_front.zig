// Ω-落尘AGI Pareto前沿维护引擎 v2.1
//
// 核心数据结构：N维决策空间的非支配前沿维护
// 用于系统状态的Pareto改进选择 + 属性Pareto前沿
//
// 设计文档 doc1 规定（v5.x完整实现）：
//   ParetoPoint = { scores, expr_handle(CDL表达式链接), step, metadata(状态快照) }
//   ParetoFront = { points, total_steps, improvements_found }
//   tryAdd 返回 true 时自增 improvements_found
//
// 使用方式：
//   var front = SystemParetoFront.init(allocator);
//   const added = front.tryAdd(point);
//   const dominates = front.dominates(a, b);

const std = @import("std");

/// Pareto前沿泛型
/// T: 评分向量类型（[7]f64 或 [3]f64）
pub fn ParetoFront(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        points: std.ArrayList(Point),

        // doc1 §1.1: 统计信息缓存
        total_steps: u64 = 0,          // 总演化步数跟踪
        improvements_found: u64 = 0,   // Pareto改进累计计数

        /// 前沿上的一个点（doc1 §1.1 完整字段）
        pub const Point = struct {
            scores: T,               // 7维评分（维度值）
            id: u64,                 // 点标识
            step: u64,               // 发现该点的演化步数
            expr_handle: u64 = 0,    // CDL表达式句柄引用（doc1 §1.1）
            metadata: PointMetadata = .{}, // 系统状态快照（doc1 §1.1）
        };

        /// 系统状态快照（doc1 §1.1 metadata）
        pub const PointMetadata = struct {
            node_count: u64 = 0,
            edge_count: u64 = 0,
            avg_imbalance: f64 = 0,
            rule_density: f64 = 0,
            frozen_count: u64 = 0,
            knowledge_size: u64 = 0,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .points = std.ArrayList(Point).empty,
                .total_steps = 0,
                .improvements_found = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.points.deinit(self.allocator);
        }

        /// 支配判断（doc1 §1.2）：a 是否支配 b
        /// a支配b当且仅当：
        ///   1. a在所有维度上 >= b
        ///   2. a在至少一个维度上 > b
        pub fn dominates(self: *const Self, a: Point, b: Point) bool {
            _ = self;
            const fields = @typeInfo(T).array;
            var at_least_one_better = false;
            inline for (0..fields.len) |i| {
                if (a.scores[i] < b.scores[i]) return false;
                if (a.scores[i] > b.scores[i]) at_least_one_better = true;
            }
            return at_least_one_better;
        }

        /// 尝试将候选点加入前沿（doc1 §1.3）
        /// 返回true表示成功加入（候选点是非支配的）
        pub fn tryAdd(self: *Self, candidate: Point) bool {
            // 第一步：检查候选点是否被已有的某个点支配
            for (self.points.items) |existing| {
                if (self.dominates(existing, candidate)) {
                    return false;
                }
            }

            // 第二步：移除被候选点支配的所有点
            var i: usize = 0;
            while (i < self.points.items.len) {
                if (self.dominates(candidate, self.points.items[i])) {
                    _ = self.points.orderedRemove(i);
                } else {
                    i += 1;
                }
            }

            // 第三步：候选点加入前沿
            self.points.append(self.allocator, candidate) catch return false;
            self.improvements_found += 1; // doc1 §1.3: 每加入一个改进点计数+1
            return true;
        }

        /// 前沿大小（doc1 §1.1）
        pub fn size(self: *const Self) usize {
            return self.points.items.len;
        }

        /// 判断前沿是否为空
        pub fn isEmpty(self: *const Self) bool {
            return self.points.items.len == 0;
        }

        /// 提取当前前沿中在指定维度上的最好值（doc1 §1.4）
        pub fn bestScore(self: *const Self, dim: usize) f64 {
            if (self.points.items.len == 0) return 0.0;
            var best: f64 = -std.math.inf(f64);
            for (self.points.items) |p| {
                if (p.scores[dim] > best) best = p.scores[dim];
            }
            return best;
        }
    };
}

/// 系统状态7维评分（用于系统演化Pareto前沿）
pub const SystemScore = [7]f64;

/// 7维系统Pareto前沿
pub const SystemParetoFront = ParetoFront(SystemScore);

/// 属性3维质量评分（用于属性Pareto前沿）
pub const AttributeScore = [3]f64;

/// 3维属性Pareto前沿
pub const AttributeParetoFront = ParetoFront(AttributeScore);

// AttributeParetoFront = [3]f64 for attribute 3D Pareto

// ============================================================
// 测试（doc1 §1.1-1.4 完整验证）
// AttributeParetoFront = [3]f64 for attribute 3D Pareto

// ============================================================
test "ParetoFront 基本操作" {
    var front = SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();

    // 初始为空
    try std.testing.expect(front.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), front.total_steps);
    try std.testing.expectEqual(@as(u64, 0), front.improvements_found);

    // 添加第一个点（expr_handle和metadata使用默认值）
    const p1 = SystemParetoFront.Point{
        .scores = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 },
        .id = 1,
        .step = 0,
    };
    try std.testing.expect(front.tryAdd(p1));
    try std.testing.expectEqual(@as(usize, 1), front.size());
    try std.testing.expectEqual(@as(u64, 1), front.improvements_found);

    // 添加被支配的点
    const p2 = SystemParetoFront.Point{
        .scores = .{ 0.3, 0.4, 0.3, 0.3, 0.3, 0.3, 0.3 },
        .id = 2,
        .step = 1,
    };
    try std.testing.expect(!front.tryAdd(p2));
    try std.testing.expectEqual(@as(usize, 1), front.size());
    try std.testing.expectEqual(@as(u64, 1), front.improvements_found); // 没增加

    // 添加支配旧点的点
    const p3 = SystemParetoFront.Point{
        .scores = .{ 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9 },
        .id = 3,
        .step = 2,
    };
    try std.testing.expect(front.tryAdd(p3));
    try std.testing.expectEqual(@as(usize, 1), front.size());
    try std.testing.expectEqual(@as(u64, 2), front.improvements_found);
    try std.testing.expectEqual(@as(f64, 0.9), front.bestScore(0));

    // 验证 metadata 默认值
    try std.testing.expectEqual(@as(u64, 0), p1.metadata.node_count);
    try std.testing.expectEqual(@as(f64, 0.0), p1.metadata.avg_imbalance);

    // 验证 expr_handle 默认值
    try std.testing.expectEqual(@as(u64, 0), p1.expr_handle);
}

test "ParetoFront 非支配点共存" {
    var front = SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();

    const a = SystemParetoFront.Point{
        .scores = .{ 0.9, 0.3, 0.5, 0.5, 0.5, 0.5, 0.5 },
        .id = 1, .step = 0,
    };
    const b = SystemParetoFront.Point{
        .scores = .{ 0.3, 0.9, 0.5, 0.5, 0.5, 0.5, 0.5 },
        .id = 2, .step = 1,
    };

    try std.testing.expect(front.tryAdd(a));
    try std.testing.expect(front.tryAdd(b));
    try std.testing.expectEqual(@as(usize, 2), front.size());
    try std.testing.expectEqual(@as(f64, 0.9), front.bestScore(0));
    try std.testing.expectEqual(@as(f64, 0.9), front.bestScore(1));
    try std.testing.expectEqual(@as(u64, 2), front.improvements_found);
}

test "ParetoFront 前沿更新" {
    var front = AttributeParetoFront.init(std.testing.allocator);
    defer front.deinit();

    const p1 = AttributeParetoFront.Point{ .scores = .{ 0.8, 0.2, 0.5 }, .id = 1, .step = 0 };
    const p2 = AttributeParetoFront.Point{ .scores = .{ 0.2, 0.8, 0.5 }, .id = 2, .step = 1 };

    try std.testing.expect(front.tryAdd(p1));
    try std.testing.expect(front.tryAdd(p2));
    try std.testing.expectEqual(@as(usize, 2), front.size());

    const p3 = AttributeParetoFront.Point{ .scores = .{ 0.9, 0.3, 0.6 }, .id = 3, .step = 2 };
    try std.testing.expect(front.tryAdd(p3));
    try std.testing.expectEqual(@as(usize, 2), front.size());
    try std.testing.expectEqual(@as(u64, 3), front.improvements_found);
}

test "ParetoFront 显式 metadata 赋值" {
    var front = SystemParetoFront.init(std.testing.allocator);
    defer front.deinit();

    const p1 = SystemParetoFront.Point{
        .scores = .{ 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1 },
        .id = 1, .step = 0,
        .expr_handle = 42,
        .metadata = .{
            .node_count = 100,
            .edge_count = 200,
            .avg_imbalance = 0.05,
            .rule_density = 0.8,
            .frozen_count = 50,
            .knowledge_size = 1000,
        },
    };
    try std.testing.expect(front.tryAdd(p1));
    try std.testing.expectEqual(@as(usize, 1), front.size());
    try std.testing.expectEqual(@as(u64, 42), p1.expr_handle);
    try std.testing.expectEqual(@as(u64, 100), p1.metadata.node_count);
    try std.testing.expectEqual(@as(f64, 0.05), p1.metadata.avg_imbalance);
}
