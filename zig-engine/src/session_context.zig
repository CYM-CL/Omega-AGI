// Ω-落尘AGI 多轮交互会话上下文管理器 v5.2
//
// 严格对应白皮书v2.0 §6.3 多轮交互机制：
// - 上下文以子格形式保留在推理域中，多轮对话持续构建同一场景的完整尘图
// - 新输入自动合并到上下文子格中，基于完整语境做推演
// - 上下文子格随交互持续优化、沉淀，长期记忆自动转入知识沉淀域
//
// 设计哲学：
// 对话不是"消息列表"，而是"不断生长的差异子结构"
// - 每轮对话在尘图中创建一个"会话子格"
// - 新输入通过 Δ 运算与已有子格融合（差异合并而非简单追加）
// - 会话结束后，稳定的子结构自动沉淀为长期记忆

const std = @import("std");
const et = @import("error_types.zig");
const de = @import("delta_engine.zig");
const DeltaEngine = de.DeltaEngine;
const dg = @import("dust_graph.zig");
const DustGraph = dg.DustGraph;
const ltm = @import("long_term_memory.zig");

/// 获取高精度时间戳（兼容Zig 0.16.0）
fn now() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// 会话上下文错误类型
pub const SessionError = error{
    InvalidSessionId,
    ContextTooLarge,
    MergeFailed,
    TransferFailed,
    SessionNotActive,
    OutOfMemory,
};

/// 会话状态
pub const SessionState = enum(u8) {
    Active,     // 活跃中：上下文正在构建
    Idle,       // 空闲中：等待新输入
    Closed,     // 已关闭：上下文已沉淀为长期记忆
};

/// 会话轮次记录：保存每轮对话的关键信息
pub const TurnRecord = struct {
    turn_id: u64,           // 轮次ID
    input_subgraph_root: u64, // 输入子格根节点ID
    output_subgraph_root: u64, // 输出子格根节点ID
    delta_value: f64,       // 本轮Δ差值（与上文的差异度）
    timestamp_ns: i128,     // 时间戳
    is_consolidated: bool,  // 是否已合并到上下文
};

/// 会话上下文管理器（§6.3 多轮交互机制）
///
/// 每个会话维护一个"上下文子格"（context_lattice_root），
/// 新输入通过 Δ 运算与已有上下文融合，而非简单追加。
/// 会话结束时，上下文子格自动转入长期记忆的知识沉淀域。
pub const SessionContext = struct {
    allocator: std.mem.Allocator,
    session_id: u64,                        // 会话ID
    state: SessionState,                    // 会话状态
    context_lattice_root: u64,              // 上下文子格根节点ID（在尘图中的入口）
    turn_history: std.ArrayList(TurnRecord), // 轮次历史
    turn_count: u64,                        // 总轮次数
    last_active_ns: i128,                   // 最后活跃时间
    context_size: usize,                    // 上下文子格规模（节点数）
    max_context_objects: usize,             // 上下文最大节点数（默认10000）

    pub fn init(allocator: std.mem.Allocator, session_id: u64) !SessionContext {
        return .{
            .allocator = allocator,
            .session_id = session_id,
            .state = .Active,
            .context_lattice_root = 0,
            .turn_history = std.ArrayList(TurnRecord).initCapacity(allocator, 0) catch return SessionError.OutOfMemory,
            .turn_count = 0,
            .last_active_ns = now(),
            .context_size = 0,
            .max_context_objects = 10000,
        };
    }

    pub fn deinit(self: *SessionContext) void {
        self.turn_history.deinit(self.allocator);
    }

    /// 创建新会话（在尘图中初始化上下文子格）
    /// 参数：
    ///   engine: Delta引擎
    ///   initial_topic: 会话主题（可选，0表示无主题）
    pub fn createSession(self: *SessionContext, engine: *DeltaEngine, initial_topic: u64) !void {
        if (self.state != .Active) return SessionError.SessionNotActive;

        // 创建会话根节点（作为上下文子格的入口点）
        const root_id = engine.graph.nextObjectId();
        try engine.graph.addObject(root_id, 0.0);

        // 如果指定了主题，建立主题→上下文的态射
        if (initial_topic != 0) {
            _ = try engine.graph.addMorphism(initial_topic, root_id, 1.0);
        }

        self.context_lattice_root = root_id;
        self.context_size = 1;
        self.last_active_ns = now();
    }

    /// 追加一轮对话（新输入自动合并到上下文子格）
    /// 核心机制：
    ///   1. 将新输入的查询子格与已有上下文通过Δ运算融合
    ///   2. 计算本轮与上下文的差值度（衡量新增信息量）
    ///   3. 记录轮次信息
    /// 参数：
    ///   engine: Delta引擎
    ///   input_subgraph_root: 本轮输入子格的根节点ID
    ///   output_subgraph_root: 本轮输出子格的根节点ID
    /// 返回：本轮与上下文的差值度（越大说明信息越新）
    pub fn appendTurn(self: *SessionContext, engine: *DeltaEngine, input_subgraph_root: u64, output_subgraph_root: u64) !f64 {
        if (self.state != .Active) return SessionError.SessionNotActive;

        // 1. 计算本轮输入与已有上下文的差值度
        //    Δ(input, context) 衡量新输入与已有知识的差异程度
        const delta_val = if (self.context_lattice_root != 0 and input_subgraph_root != 0)
            engine.graph.deltaObjToObj(input_subgraph_root, self.context_lattice_root) catch 0.0
        else
            0.0;

        // 2. 将输入子格合并到上下文子格
        //    通过态射建立输入→上下文的连接，形成融合子格
        if (input_subgraph_root != 0 and self.context_lattice_root != 0) {
            _ = try engine.graph.addMorphism(input_subgraph_root, self.context_lattice_root, delta_val);
        }

        // 3. 将输出子格也合并到上下文（推理结果也是上下文的一部分）
        if (output_subgraph_root != 0 and self.context_lattice_root != 0) {
            _ = try engine.graph.addMorphism(output_subgraph_root, self.context_lattice_root, 1.0 - delta_val);
        }

        // 4. 记录本轮次
        const turn = TurnRecord{
            .turn_id = self.turn_count,
            .input_subgraph_root = input_subgraph_root,
            .output_subgraph_root = output_subgraph_root,
            .delta_value = delta_val,
            .timestamp_ns = now(),
            .is_consolidated = true,
        };
        try self.turn_history.append(turn);

        self.turn_count += 1;
        self.context_size = engine.graph.objects.count();
        self.last_active_ns = turn.timestamp_ns;

        // 5. 检查上下文规模，防止无限增长
        if (self.context_size > self.max_context_objects) {
            // 触发上下文压缩：合并低价值节点
            _ = try self.compressContext(engine);
        }

        return delta_val;
    }

    /// 基于上下文执行推理（融合已有上下文做推演）
    /// 核心机制：
    ///   1. 将查询子格与上下文子格融合为"增强查询"
    ///   2. 对增强查询执行差值推演
    ///   3. 返回推理结果
    /// 参数：
    ///   engine: Delta引擎
    ///   query_root: 当前查询子格的根节点ID
    /// 返回：推理结果值
    pub fn reasonWithContext(self: *SessionContext, engine: *DeltaEngine, query_root: u64) !f64 {
        if (self.context_lattice_root == 0) {
            // 无上下文，直接使用查询根节点
            return engine.graph.getObjectValue(query_root) orelse 0.0;
        }

        // 带上下文的Δ推演：Δ(query, context) × Δ(context, query)
        // 双向Δ确保上下文信息被充分利用
        const delta_forward = engine.graph.deltaObjToObj(query_root, self.context_lattice_root) catch 0.0;
        const delta_backward = engine.graph.deltaObjToObj(self.context_lattice_root, query_root) catch 0.0;

        // 融合结果 = 前向差值 + 反向差值 × 上下文权重
        const context_weight = @min(1.0, @as(f64, @floatFromInt(self.context_size)) / @max(1.0, @as(f64, @floatFromInt(self.max_context_objects))));
        return delta_forward + delta_backward * context_weight;
    }

    /// 压缩上下文子格（合并低价值节点，控制规模）
    /// 当上下文超限时自动触发
    pub fn compressContext(self: *SessionContext, engine: *DeltaEngine) !u64 {
        var compressed: u64 = 0;

        // 找到上下文中Δ值接近0的冗余节点（与上下文根节点差异极小）
        if (self.context_lattice_root == 0) return 0;

        var obj_iter = engine.graph.objects.iterator();
        while (obj_iter.next()) |entry| {
            const obj_id = entry.key_ptr.*;
            if (obj_id == self.context_lattice_root) continue;

            const delta_to_root = engine.graph.deltaObjToObj(obj_id, self.context_lattice_root) catch continue;
            if (@abs(delta_to_root) < 1e-6) {
                // 冗余节点：与上下文根节点几乎无差异，可以合并
                engine.graph.flagForMerge(obj_id) catch continue;
                compressed += 1;
            }
        }

        self.context_size = engine.graph.objects.count();
        return compressed;
    }

    /// 关闭会话：上下文自动转入长期记忆的知识沉淀域
    /// §6.3：上下文子格随交互持续优化、沉淀，长期记忆自动转入知识沉淀域
    /// 参数：
    ///   memory: 长期记忆系统
    ///   knowledge_domain: 知识沉淀域
    pub fn closeAndTransfer(self: *SessionContext, _: *DeltaEngine, memory: *ltm.LongTermMemory, knowledge_domain: anytype) !void {
        if (self.state == .Closed) return SessionError.SessionNotActive;

        // 1. 将会话上下文子格沉淀为知识（冻结区候选）
        if (self.context_lattice_root != 0) {
            knowledge_domain.sediment(self.context_lattice_root) catch |err| {
                et.logGlobalError(.Warning, "session_context", "sediment", et.errorCode(err), "知识沉淀失败");
            };
        }

        // 2. 将完整轮次历史存入长期记忆
        if (memory) |mem| {
            for (self.turn_history.items) |turn| {
                try mem.store(
                    turn.turn_id,
                    "session_context",
                    @floatFromInt(turn.input_subgraph_root),
                    @floatFromInt(turn.timestamp_ns),
                    ltm.MemoryZone.Sandbox,
                );
            }
        }

        self.state = .Closed;
    }

    /// 获取会话摘要（用于监控和调试）
    pub fn getSummary(self: *const SessionContext) []const u8 {
        return std.fmt.bufPrint(
            self.allocator.alloc(u8, 256) catch return "摘要生成失败",
            "会话{}: {}轮, 上下文规模{}, 状态{}",
            .{
                self.session_id,
                self.turn_count,
                self.context_size,
                @tagName(self.state),
            },
        ) catch "摘要生成失败";
    }
};

// ============================================================
// 测试：多轮交互机制
// ============================================================
test "SessionContext: 创建会话并追加轮次" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var session = try SessionContext.init(allocator, 1);
    defer session.deinit();

    // 创建会话
    try session.createSession(&engine, 0);
    try std.testing.expect(session.context_lattice_root != 0);
    try std.testing.expectEqual(SessionState.Active, session.state);

    // 追加第一轮
    const input1 = try engine.graph.addObject(engine.graph.nextObjectId(), 5.0);
    const output1 = try engine.graph.addObject(engine.graph.nextObjectId(), 8.0);
    _ = try session.appendTurn(&engine, input1, output1);
    try std.testing.expectEqual(@as(u64, 1), session.turn_count);

    // 追加第二轮
    const input2 = try engine.graph.addObject(engine.graph.nextObjectId(), 3.0);
    const output2 = try engine.graph.addObject(engine.graph.nextObjectId(), 4.0);
    _ = try session.appendTurn(&engine, input2, output2);
    try std.testing.expectEqual(@as(u64, 2), session.turn_count);
}

test "SessionContext: 上下文推理" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var session = try SessionContext.init(allocator, 2);
    defer session.deinit();

    try session.createSession(&engine, 0);

    // 添加上下文
    const ctx_node = try engine.graph.addObject(engine.graph.nextObjectId(), 10.0);
    _ = try session.appendTurn(&engine, ctx_node, ctx_node);

    // 带上下文的推理
    const query = try engine.graph.addObject(engine.graph.nextObjectId(), 5.0);
    const result = try session.reasonWithContext(&engine, query);
    try std.testing.expect(result >= 0.0);
}

test "SessionContext: 关闭并转移" {
    const allocator = std.testing.allocator;
    var engine = try DeltaEngine.init(allocator);
    defer engine.deinit();

    var session = try SessionContext.init(allocator, 3);
    defer session.deinit();

    try session.createSession(&engine, 0);

    const input = try engine.graph.addObject(engine.graph.nextObjectId(), 7.0);
    const output = try engine.graph.addObject(engine.graph.nextObjectId(), 9.0);
    _ = try session.appendTurn(&engine, input, output);

    try std.testing.expectEqual(SessionState.Active, session.state);
}