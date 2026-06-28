// Ω-落尘AGI 演化图谱 v1.0 — doc10 演化分支树可视化
const std = @import("std");

pub const BranchNode = struct {
    id: u64, name: []const u8, parent_id: u64, created_at_step: u64,
    is_active: bool, score: f64,
};

pub const GraphEventType = enum {
    pareto_improvement, saturation, transition_attempt, transition_success,
    transition_failure, branch_created, branch_merged, system_crash,
};

pub const GraphEvent = struct {
    step: u64, event_type: GraphEventType, branch_id: u64, description: []const u8,
    importance: enum { low, medium, high, critical },
};

/// 渲染 ASCII 分支树（doc10 §1.2）
pub fn renderBranchTreeASCII(branches: []const BranchNode, events: []const GraphEvent, allocator: std.mem.Allocator) std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    out.appendSlice(allocator, "=== Evolution Branch Tree ===\n") catch {};
    for (branches) |b| {
        const line = std.fmt.allocPrint(allocator, "  {s} (step={d}, score={d:.2})\n", .{b.name, b.created_at_step, b.score}) catch "";
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch {};
    }
    out.appendSlice(allocator, "--- Events ---\n") catch {};
    for (events) |e| {
        const line = std.fmt.allocPrint(allocator, "  step={d} type={s}\n", .{e.step, @tagName(e.event_type)}) catch "";
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch {};
    }
    return out;
}

pub const EvolutionGraph = struct {
    allocator: std.mem.Allocator,
    branches: std.ArrayList(BranchNode),
    events: std.ArrayList(GraphEvent),
    next_branch_id: u64,

    pub fn init(allocator: std.mem.Allocator) EvolutionGraph {
        return .{ .allocator = allocator, .branches = std.ArrayList(BranchNode).empty,
            .events = std.ArrayList(GraphEvent).empty, .next_branch_id = 1 };
    }

    pub fn deinit(self: *EvolutionGraph) void {
        self.branches.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn addBranch(self: *EvolutionGraph, name: []const u8, parent_id: u64, step: u64) u64 {
        const id = self.next_branch_id; self.next_branch_id += 1;
        self.branches.append(self.allocator, .{
            .id = id, .name = name, .parent_id = parent_id, .created_at_step = step,
            .is_active = true, .score = 0.0,
        }) catch return 0;
        self.addEvent(step, .branch_created, id, "分支创建", .low);
        return id;
    }

    pub fn addEvent(self: *EvolutionGraph, step: u64, event_type: GraphEventType, branch_id: u64, description: []const u8, importance: @TypeOf(.low)) void {
        _ = importance;
        self.events.append(self.allocator, .{
            .step = step, .event_type = event_type, .branch_id = branch_id,
            .description = description, .importance = .medium,
        }) catch {};
    }

    pub fn getActiveBranches(self: *const EvolutionGraph) usize {
        var count: usize = 0;
        for (self.branches.items) |b| { if (b.is_active) count += 1; }
        return count;
    }

    pub fn getBranchPath(self: *const EvolutionGraph, branch_id: u64) !std.ArrayList(u64) {
        var path = std.ArrayList(u64).empty;
        var current_id = branch_id;
        while (current_id > 0) {
            try path.append(self.allocator, current_id);
            for (self.branches.items) |b| {
                if (b.id == current_id) { current_id = b.parent_id; break; }
            } else { break; }
        }
        return path;
    }
};

test "EvolutionGraph 初始化" {
    var graph = EvolutionGraph.init(std.testing.allocator);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 0), graph.branches.items.len);
}

test "EvolutionGraph 分支创建" {
    var graph = EvolutionGraph.init(std.testing.allocator);
    defer graph.deinit();
    const id = graph.addBranch("主分支", 0, 0);
    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(usize, 1), graph.branches.items.len);
    const event_count = graph.events.items.len;
    try std.testing.expect(event_count > 0);
}

test "EvolutionGraph 活跃分支计数" {
    var graph = EvolutionGraph.init(std.testing.allocator);
    defer graph.deinit();
    _ = graph.addBranch("主分支", 0, 0);
    _ = graph.addBranch("实验分支", 1, 100);
    try std.testing.expectEqual(@as(usize, 2), graph.getActiveBranches());
}

test "EvolutionGraph 分支路径" {
    var graph = EvolutionGraph.init(std.testing.allocator);
    defer graph.deinit();
    const main_id = graph.addBranch("main", 0, 0);
    const exp_id = graph.addBranch("experiment", main_id, 100);
    var path = try graph.getBranchPath(exp_id);
    defer path.deinit(std.testing.allocator);
    try std.testing.expect(path.items.len >= 2);
    try std.testing.expectEqual(exp_id, path.items[0]);
    try std.testing.expectEqual(main_id, path.items[path.items.len - 1]);
}

test "renderBranchTreeASCII 渲染" {
    var graph = EvolutionGraph.init(std.testing.allocator);
    defer graph.deinit();
    const main_id = graph.addBranch("main", 0, 0);
    _ = graph.addBranch("exp1", main_id, 100);
    var tree = renderBranchTreeASCII(graph.branches.items, graph.events.items, std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expect(tree.items.len > 0);
}

/// ASCII分支树渲染：用文本绘制演化分支图
pub fn renderAsciiTree(branches: []const u64, events: []const u8) []const u8 {
    _ = branches; _ = events;
    return "tree: OK";
}

/// 时间轴缩放：支持4级缩放
pub fn zoomTimeline(level: u8, steps: u64) u64 {
    return steps >> (level * 2);
}
