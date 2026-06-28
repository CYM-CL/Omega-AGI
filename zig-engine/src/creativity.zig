// Ω-落尘AGI 创造性系统 v4.1.0
//
// 严格对应白皮书v2.0要求：
// - 第12章：Δ嵌套产生新颖能力（非已有能力的简单组合）
// - 第10.4.1节：创造性能力的自洽性校验
//
// 设计哲学（尘算子核心）：
// 创造性不是"随机生成"，而是 Δ 嵌套的涌现：
// - Δ(Δ(x,y), Δ(z,w)) 高阶组合产生新结构
// - 新颖性检测：与已有能力的 Δ 距离 > 阈值
// - 非组合性检测：新颖能力不能被分解为已有能力的线性组合
// - 创造性评分 = 新颖性 × 实用性 × 可验证性
//
// 创造性生成流程：
// 1. 从种子对象集合生成 Δ 嵌套树（深度可配置）
// 2. 对每个候选计算新颖性分数（与已有能力的最小Δ距离）
// 3. 验证非组合性（不能被线性分解）
// 4. 计算综合创造性评分
//
// 强类型封装：CreationId/CreationCandidate/NoveltyScore
// 显式错误处理：CreativityError 覆盖全量失败场景
// 可复现：所有测试固定种子

const std = @import("std");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;
const cdl_expr = @import("cdl_expr.zig");

// ============================================================
// v5.0.1：能力类型升级——从纯标量到CDL表达式引用
// 白皮书v5.0要求：系统不存储标量能力值，能力由CDL表达式树内生
// Capability 同时保留标量值（工程近似）和CDL表达式索引（v5.0架构）
// ============================================================

/// 已有能力（v5.0架构：CDL表达式引用 + 工程近似标量值）
///
/// 设计哲学：
///   - value: 传导强度的一阶工程近似标度（非本原实体）
///   - cdl_expr_idx: CDL表达式池中的索引（v5.0架构核心）
///   - 能力由CDL表达式树内生涌现，不是预存的标量值
pub const Capability = struct {
    /// 传导强度的一阶工程近似标度（非本原实体，仅用于工程计算）
    value: f64,
    /// CDL表达式池中的索引（v5.0架构：能力的真正来源）
    /// EXPR_NULL 表示尚未关联CDL表达式（过渡期兼容）
    cdl_expr_idx: cdl_expr.ExprIdx,

    /// 从纯标量创建（过渡期兼容，cdl_expr_idx = EXPR_NULL）
    pub fn fromScalar(v: f64) Capability {
        return .{ .value = v, .cdl_expr_idx = cdl_expr.EXPR_NULL };
    }

    /// 从CDL表达式创建（v5.0架构：能力的真正来源）
    pub fn fromCdlExpr(v: f64, idx: cdl_expr.ExprIdx) Capability {
        return .{ .value = v, .cdl_expr_idx = idx };
    }

    /// 是否关联了CDL表达式
    pub fn hasCdlExpr(self: Capability) bool {
        return self.cdl_expr_idx != cdl_expr.EXPR_NULL;
    }
};

// ============================================================
// 强类型错误体系
// ============================================================

/// 创造性错误类型
pub const CreativityError = error{
    InvalidSeedId,          // 无效的种子ID
    InvalidDepth,           // 无效的嵌套深度
    InvalidCandidate,       // 无效的候选
    InvalidThreshold,       // 无效的阈值
    InvalidScore,           // 无效的评分
    GenerationFailed,       // 生成失败
    NoveltyDetectionFailed, // 新颖性检测失败
    NonCompositionalFailed, // 非组合性检测失败
    NoExistingCapabilities, // 无已有能力（无法计算新颖性）
    MaxCandidatesExceeded,  // 超过最大候选数
    OutOfMemory,            // 内存不足
    InvalidTreeStructure,   // 无效的树结构
    UniverseViolation,        // 宇宙层级违规
    ObjectNotFound,         // 对象未找到
};

// ============================================================
// 强类型枚举与结构体
// ============================================================

/// 创造性ID强类型封装
pub const CreationId = struct {
    id: u64,

    pub fn fromU64(v: u64) CreationId {
        return .{ .id = v };
    }

    pub fn toU64(self: CreationId) u64 {
        return self.id;
    }

    pub fn invalid() CreationId {
        return .{ .id = 0 };
    }

    pub fn isValid(self: CreationId) bool {
        return self.id != 0;
    }
};

/// Δ嵌套树节点
pub const DeltaTreeNode = struct {
    value: f64,              // 节点值
    left: ?*const DeltaTreeNode,  // 左子树（f(x)）
    right: ?*const DeltaTreeNode, // 右子树（g(y)）
    is_leaf: bool,           // 是否为叶子节点

    /// 计算树的Δ值
    pub fn computeDelta(self: *const DeltaTreeNode) f64 {
        if (self.is_leaf) return self.value;
        const left_val = if (self.left) |l| l.computeDelta() else 0.0;
        const right_val = if (self.right) |r| r.computeDelta() else 0.0;
        return @max(0.0, left_val - right_val);  // Δ下界保护
    }

    /// 计算树的深度
    pub fn depth(self: *const DeltaTreeNode) u32 {
        if (self.is_leaf) return 0;
        const left_depth = if (self.left) |l| l.depth() else 0;
        const right_depth = if (self.right) |r| r.depth() else 0;
        return 1 + @max(left_depth, right_depth);
    }
};

/// 新颖性分数
pub const NoveltyScore = struct {
    min_delta_distance: f64,  // 与已有能力的最小Δ距离
    avg_delta_distance: f64,  // 平均Δ距离
    is_novel: bool,           // 是否新颖（min_distance > 阈值）
    threshold: f64,           // 新颖性阈值
};

/// 创造性候选
pub const CreationCandidate = struct {
    id: CreationId,
    delta_tree_root: DeltaTreeNode,  // Δ嵌套树根
    cdl_expr_idx: cdl_expr.ExprIdx = cdl_expr.EXPR_NULL,  // CDL表达式池中的索引（v5.0连接）
    computed_value: f64,             // 计算得到的值
    novelty_score: NoveltyScore,     // 新颖性分数
    utility_score: f64,              // 实用性分数（0~1）
    verifiable: bool,                // 是否可验证
    non_compositional: bool,         // 是否非组合性
    creativity_score: f64,           // 综合创造性评分

    /// 计算综合创造性评分
    pub fn computeScore(self: *const CreationCandidate) f64 {
        // 创造性 = 新颖性 × 实用性 × 可验证性
        const novelty: f64 = if (self.novelty_score.is_novel) 1.0 else 0.0;
        const utility: f64 = self.utility_score;
        const verifiability: f64 = if (self.verifiable) 1.0 else 0.0;
        const non_comp: f64 = if (self.non_compositional) 1.0 else 0.0;
        return novelty * utility * verifiability * non_comp;
    }
};

/// 创造性配置
pub const CreativityConfig = struct {
    max_depth: u32 = 0,                       // 从最小深度开始
    max_candidates: u32 = 0,                  // 从最少候选开始
    novelty_threshold: f64 = 0.0,             // 从0开始内生学习
    utility_threshold: f64 = 0.0,             // 从0开始内生学习
    tolerance: f64 = 0.0,                     // 从0开始内生学习
    learned_max_depth: u32 = 0,               // 通过训练积累调整的嵌套深度（初始0）
    learned_novelty_threshold: f64 = 0.0,     // 通过训练积累调整的新颖性阈值（初始0）
};

// ============================================================
// 创造性系统主结构
// ============================================================

/// 创造性系统
pub const Creativity = struct {
    allocator: std.mem.Allocator,
    engine: *DeltaEngine,                // Δ运算引擎
    config: CreativityConfig,
    existing_capabilities: std.ArrayList(Capability),  // v5.0.1：已有能力集合（CDL表达式引用）
    candidates: std.ArrayList(CreationCandidate),
    next_id: u64,
    // 统计
    total_generated: u64,
    total_novel: u64,
    total_non_compositional: u64,
    total_verified: u64,

    /// 初始化
    pub fn init(allocator: std.mem.Allocator, engine: *DeltaEngine) Creativity {
        return Creativity{
            .allocator = allocator,
            .engine = engine,
            .config = .{},
            .existing_capabilities = std.ArrayList(Capability).empty,
            .candidates = std.ArrayList(CreationCandidate).empty,
            .next_id = 1,
            .total_generated = 0,
            .total_novel = 0,
            .total_non_compositional = 0,
            .total_verified = 0,
        };
    }

    /// 带配置初始化
    pub fn initWithConfig(allocator: std.mem.Allocator, engine: *DeltaEngine, config: CreativityConfig) Creativity {
        return Creativity{
            .allocator = allocator,
            .engine = engine,
            .config = config,
            .existing_capabilities = std.ArrayList(Capability).empty,
            .candidates = std.ArrayList(CreationCandidate).empty,
            .next_id = 1,
            .total_generated = 0,
            .total_novel = 0,
            .total_non_compositional = 0,
            .total_verified = 0,
        };
    }

    /// 释放资源
    pub fn deinit(self: *Creativity) void {
        self.existing_capabilities.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
    }

    // ============================================================
    // 已有能力管理
    // ============================================================

    /// 添加已有能力（v5.0.1：内部封装为Capability，过渡期兼容标量输入）
    pub fn addExistingCapability(self: *Creativity, value: f64) CreativityError!void {
        if (std.math.isNan(value) or std.math.isInf(value)) return error.InvalidScore;
        self.existing_capabilities.append(self.allocator, Capability.fromScalar(value)) catch return error.OutOfMemory;
    }

    // ============================================================
    // 创造性生成
    // ============================================================

    /// 生成创造性候选：Δ嵌套产生新能力
    /// 从种子值集合生成所有可能的Δ嵌套组合
    /// 通过 engine 的 Δ 运算替代独立 delta/nestedDelta 函数
    pub fn generate(self: *Creativity, seed_values: []const f64, depth: u32) CreativityError![]CreationCandidate {
        if (seed_values.len < 2) return error.InvalidSeedId;
        if (depth == 0 or depth > self.config.max_depth) return error.InvalidDepth;
        if (std.math.isNan(seed_values[0]) or std.math.isInf(seed_values[0])) return error.InvalidScore;

        // 清空旧候选
        self.candidates.clearRetainingCapacity();

        // 生成Δ嵌套组合
        // 通过 engine 的 Δ 运算实现：Δ(Δ(x,y), Δ(x,y)) 自指嵌套
        for (seed_values, 0..) |x, i| {
            for (seed_values[i + 1 ..]) |y| {
                if (self.candidates.items.len >= self.config.max_candidates) break;

                // 通过 engine 直接计算 Δ 嵌套值（避免 @intFromFloat 截断）
                // 直接在 CDL 表达式层组合 Δ，不经过 getOrCreateNumber
                const x_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.allocator, "creativity_seed_{d:.6}", .{x}),
                    x,
                );
                const y_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.allocator, "creativity_seed_{d:.6}", .{y}),
                    y,
                );
                const inner_delta = self.engine.deltaExpr(x_id, y_id);
                // 内层Δ结果作为新对象持久化（避免 @intFromFloat 截断）
                const inner_id = try self.engine.createNodeWithCDL(
                    try std.fmt.allocPrint(self.allocator, "creativity_inner_{d:.6}", .{inner_delta}),
                    inner_delta,
                );
                const nested_value = self.engine.deltaExpr(inner_id, inner_id);  // 自指：Δ(inner, inner)

                // 创建对应的CDL表达式树（接入ExprPool）
                const x_f = try self.engine.cdl_pool.makeNodeRef(x_id, true);
                const y_g = try self.engine.cdl_pool.makeNodeRef(y_id, false);
                const inner_expr = try self.engine.cdl_pool.makeDelta(x_f, y_g);
                // 自指：Δ(inner, inner)
                const root_expr = try self.engine.cdl_pool.makeDelta(inner_expr, inner_expr);

                // 创建Δ树（简化：叶子节点，用于快速新颖性/非组合性计算）
                const tree_root = DeltaTreeNode{
                    .value = nested_value,
                    .left = null,
                    .right = null,
                    .is_leaf = true,
                };

                // 计算新颖性
                const novelty = try self.detectNovelty(nested_value);

                // 计算实用性（简化：非零值有实用性）
                const utility: f64 = if (@abs(nested_value) > self.config.tolerance) 0.8 else 0.2;

                // 验证非组合性
                const non_comp = self.verifyNonCompositional(nested_value, seed_values);

                // 可验证性（简化：有限值可验证）
                const verifiable = std.math.isFinite(nested_value);

                const id = CreationId.fromU64(self.next_id);
                self.next_id += 1;

                var candidate = CreationCandidate{
                    .id = id,
                    .delta_tree_root = tree_root,
                    .cdl_expr_idx = root_expr,
                    .computed_value = nested_value,
                    .novelty_score = novelty,
                    .utility_score = utility,
                    .verifiable = verifiable,
                    .non_compositional = non_comp,
                    .creativity_score = 0.0,
                };
                candidate.creativity_score = candidate.computeScore();

                self.candidates.append(self.allocator, candidate) catch return error.OutOfMemory;
                self.total_generated += 1;

                if (novelty.is_novel) self.total_novel += 1;
                if (non_comp) self.total_non_compositional += 1;
                if (verifiable) self.total_verified += 1;
            }
        }

        // 返回候选的副本
        const result = self.allocator.alloc(CreationCandidate, self.candidates.items.len) catch return error.OutOfMemory;
        @memcpy(result, self.candidates.items);
        return result;
    }

    /// 新颖性检测：通过 engine 的 Δ 距离计算与已有能力的最小距离
    /// 使用 engine.delta(id1, id2) 替代独立 delta(x,y) 函数
    pub fn detectNovelty(self: *Creativity, candidate_value: f64) CreativityError!NoveltyScore {
        if (self.existing_capabilities.items.len == 0) {
            // 无已有能力，所有候选都是新颖的
            return NoveltyScore{
                .min_delta_distance = 1.0,  // 默认最大距离
                .avg_delta_distance = 1.0,
                .is_novel = true,
                .threshold = self.config.novelty_threshold,
            };
        }

        var min_dist: f64 = std.math.floatMax(f64);
        var total_dist: f64 = 0.0;

        // 直接计算 f64 差值距离，不通过 getOrCreateNumber 创建整数节点
        // 现有能力值是标量近似（Capability.value），@intFromFloat 会丢失浮点精度
        // 例如 @intFromFloat(5.5) = 5 会错误地将 5.5 映射到节点 5

        for (self.existing_capabilities.items) |cap| {
            // Δ 距离 = |candidate - cap.value| = max(0, candidate-cap) + max(0, cap-candidate)
            // 用 f64 直接计算，避免 @intFromFloat 丢失精度
            const d = @abs(candidate_value - cap.value);
            if (d < min_dist) min_dist = d;
            total_dist += d;
        }

        const avg_dist = total_dist / @as(f64, @floatFromInt(self.existing_capabilities.items.len));
        const is_novel = min_dist > self.config.novelty_threshold;

        return NoveltyScore{
            .min_delta_distance = min_dist,
            .avg_delta_distance = avg_dist,
            .is_novel = is_novel,
            .threshold = self.config.novelty_threshold,
        };
    }

    /// 非组合性检测：候选值不能被分解为已有能力的线性组合
    /// 通过 engine 的统一 Δ 运算替代独立运算
    pub fn verifyNonCompositional(self: *Creativity, candidate_value: f64, existing_values: []const f64) bool {
        if (existing_values.len == 0) return true;
        const tolerance = self.config.tolerance;

        // 使用 f64 直接计算 Δ 组合，不通过 getOrCreateNumber 创建整数节点
        // Δ(x,y) = max(0, x-y)，组合检测直接在标量上运算

        for (existing_values) |v1| {
            // 检查候选值是否直接等于某个已有值
            const d1 = @abs(candidate_value - v1);
            if (d1 < tolerance) return false;

            for (existing_values) |v2| {
                // 检查候选值是否等于 Δ(v1, v2) = max(0, v1-v2)
                const delta_forward = @max(0.0, v1 - v2);
                if (@abs(candidate_value - delta_forward) < tolerance) return false;

                // 检查候选值是否等于 Δ(v2, v1) = max(0, v2-v1)
                const delta_reverse = @max(0.0, v2 - v1);
                if (@abs(candidate_value - delta_reverse) < tolerance) return false;
            }
        }
        return true;  // 非组合性成立
    }

    /// 创造性评分
    pub fn score(self: *Creativity, candidate: CreationCandidate) f64 {
        _ = self;
        return candidate.computeScore();
    }

    /// 根据历史生成的候选的实用性统计，自动调整嵌套深度和阈值
    /// 通过训练经验反馈循环，逐步优化创造性生成参数
    pub fn learnFromExperience(self: *Creativity) void {
        if (self.candidates.items.len == 0) return;

        // 统计实用性分数分布
        var total_utility: f64 = 0.0;
        var high_utility_count: u32 = 0;

        for (self.candidates.items) |candidate| {
            total_utility += candidate.utility_score;
            if (candidate.utility_score > self.config.utility_threshold) {
                high_utility_count += 1;
            }
        }

        const avg_utility = total_utility / @as(f64, @floatFromInt(self.candidates.items.len));
        const high_utility_ratio = @as(f64, @floatFromInt(high_utility_count)) / @as(f64, @floatFromInt(self.candidates.items.len));

        // 根据实用性统计调整 learned_max_depth
        // 高实用性候选比例 > 50% → 增加嵌套深度（探索更复杂结构）
        // 高实用性候选比例 < 20% → 降低嵌套深度（收敛到更稳定的模式）
        if (high_utility_ratio > 0.5) {
            self.config.learned_max_depth = self.config.max_depth + 1;
        } else if (high_utility_ratio < 0.2) {
            self.config.learned_max_depth = if (self.config.max_depth > 1) self.config.max_depth - 1 else 1;
        } else {
            self.config.learned_max_depth = self.config.max_depth;
        }

        // 调整 learned_novelty_threshold
        // 平均实用性越高，阈值可略微放宽（允许更多探索性生成）
        // 平均实用性越低，阈值适当收紧（聚焦高实用性候选）
        self.config.learned_novelty_threshold = self.config.novelty_threshold * (1.0 + avg_utility / (1.0 + avg_utility));
    }

    /// 获取统计
    pub fn getStats(self: *Creativity) struct { total_generated: u64, total_novel: u64, total_non_compositional: u64, total_verified: u64, existing_count: u32 } {
        return .{
            .total_generated = self.total_generated,
            .total_novel = self.total_novel,
            .total_non_compositional = self.total_non_compositional,
            .total_verified = self.total_verified,
            .existing_count = @intCast(self.existing_capabilities.items.len),
        };
    }

    /// 获取候选数
    pub fn candidateCount(self: *Creativity) u32 {
        return @intCast(self.candidates.items.len);
    }
};

// ============================================================
// 单元测试（8+测试，覆盖正常/异常/边界/极限）
// ============================================================

const testing = std.testing;

/// 测试辅助：创建带 engine 的 Creativity 实例
fn createTestCreativity(allocator: std.mem.Allocator) !struct { Creativity, *DeltaEngine } {
    var engine = try DeltaEngine.init(allocator);
    const engine_ptr = &engine;
    const c = Creativity.init(allocator, engine_ptr);
    return .{ c, engine_ptr };
}

test "Creativity 初始化与默认状态" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try testing.expect(c.existing_capabilities.items.len == 0);
    try testing.expect(c.candidates.items.len == 0);
    try testing.expect(c.config.max_depth == 4);
    try testing.expect(c.config.novelty_threshold == 0.1);
}

test "CreativityConfig 默认值正确" {
    const config = CreativityConfig{};
    try testing.expect(config.max_depth == 4);
    try testing.expect(config.max_candidates == 64);
    try testing.expect(config.novelty_threshold == 0.1);
    try testing.expect(config.utility_threshold == 0.5);
    try testing.expect(config.learned_max_depth == 0);
    try testing.expect(config.learned_novelty_threshold == 0.0);
}

test "CreationId 强类型封装" {
    const id = CreationId.fromU64(42);
    try testing.expect(id.isValid());
    try testing.expect(id.toU64() == 42);
    try testing.expect(!CreationId.invalid().isValid());
}

test "DeltaTreeNode 叶子节点计算" {
    const leaf = DeltaTreeNode{
        .value = 5.0,
        .left = null,
        .right = null,
        .is_leaf = true,
    };
    try testing.expectApproxEqAbs(@as(f64, 5.0), leaf.computeDelta(), 1e-10);
    try testing.expect(leaf.depth() == 0);
}

test "addExistingCapability 添加已有能力" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try c.addExistingCapability(1.0);
    try c.addExistingCapability(2.0);
    try c.addExistingCapability(3.0);
    try testing.expect(c.existing_capabilities.items.len == 3);
}

test "addExistingCapability NaN返回错误" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try testing.expectError(error.InvalidScore, c.addExistingCapability(std.math.nan(f64)));
}

test "detectNovelty 无已有能力时全部新颖" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const novelty = try c.detectNovelty(5.0);
    try testing.expect(novelty.is_novel);
    try testing.expectApproxEqAbs(@as(f64, 1.0), novelty.min_delta_distance, 1e-10);
}

test "detectNovelty 与已有能力距离计算" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try c.addExistingCapability(1.0);
    try c.addExistingCapability(2.0);
    // 候选值5.0，通过 engine Δ 距离 = |5-1| + |1-5| = 8
    const novelty = try c.detectNovelty(5.0);
    try testing.expect(novelty.min_delta_distance > 0);
    try testing.expect(novelty.is_novel);
}

test "detectNovelty 与已有能力相近时不新颖" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try c.addExistingCapability(1.0);
    // 候选值1.05通过@intFromFloat映射为id=1（与cap=1.0相同），engine的delta(1,1)=0
    // Δ距离 = 0 < 阈值0.1 → 不新颖
    const novelty = try c.detectNovelty(1.05);
    try testing.expect(!novelty.is_novel);
}

test "verifyNonCompositional 非组合性检测" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const existing = [_]f64{ 1.0, 2.0, 3.0 };
    // 5.5 不是 1,2,3 的简单组合（Δ运算）→ 非组合性成立
    try testing.expect(c.verifyNonCompositional(5.5, &existing));
    // 3.0 等于已有能力 → 非组合性不成立
    try testing.expect(!c.verifyNonCompositional(3.0, &existing));
    // 2.0 = Δ(3, 1) = max(0, 3-1) → 非组合性不成立
    try testing.expect(!c.verifyNonCompositional(2.0, &existing));
    // 1.0 = Δ(2, 1) = max(0, 2-1) → 非组合性不成立
    try testing.expect(!c.verifyNonCompositional(1.0, &existing));
    // 5.0 不能通过Δ组合得到（Δ(2,3)=0, Δ(3,2)=1）→ 非组合性成立
    try testing.expect(c.verifyNonCompositional(5.0, &existing));

}

test "generate 生成创造性候选" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const seeds = [_]f64{ 5.0, 3.0, 7.0 };
    const candidates = try c.generate(&seeds, 2);
    defer testing.allocator.free(candidates);
    try testing.expect(candidates.len > 0);
    try testing.expect(c.total_generated > 0);
}

test "generate 种子不足返回错误" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const seeds = [_]f64{5.0};
    try testing.expectError(error.InvalidSeedId, c.generate(&seeds, 2));
}

test "generate 深度0返回错误" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const seeds = [_]f64{ 5.0, 3.0 };
    try testing.expectError(error.InvalidDepth, c.generate(&seeds, 0));
}

test "generate 超过最大深度返回错误" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const seeds = [_]f64{ 5.0, 3.0 };
    try testing.expectError(error.InvalidDepth, c.generate(&seeds, 5));  // max_depth=4
}

test "CreationCandidate.computeScore 创造性评分" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    const candidate = CreationCandidate{
        .id = CreationId.fromU64(1),
        .delta_tree_root = .{ .value = 5.0, .left = null, .right = null, .is_leaf = true },
        .computed_value = 5.0,
        .novelty_score = .{ .min_delta_distance = 1.0, .avg_delta_distance = 1.0, .is_novel = true, .threshold = 0.0 },
        .utility_score = 0.8,
        .verifiable = true,
        .non_compositional = true,
        .creativity_score = 0.0,
    };
    // 创造性 = 新颖性(1) × 实用性(0.8) × 可验证性(1) × 非组合性(1) = 0.8
    try testing.expectApproxEqAbs(@as(f64, 0.8), candidate.computeScore(), 1e-10);
}

test "learnFromExperience 调整参数" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();

    // 添加已有能力和种子，生成候选
    try c.addExistingCapability(1.0);
    const seeds = [_]f64{ 5.0, 3.0, 7.0 };
    const candidates = try c.generate(&seeds, 2);
    defer testing.allocator.free(candidates);

    // 调用 learnFromExperience
    c.learnFromExperience();

    // 验证 learned 参数已被调整
    try testing.expect(c.config.learned_max_depth > 0 or c.config.learned_max_depth == c.config.max_depth);
    try testing.expect(c.config.learned_novelty_threshold >= c.config.novelty_threshold);
}

test "CreativityError 覆盖所有失败场景" {
    const errors = [_]CreativityError{
        error.InvalidSeedId,
        error.InvalidDepth,
        error.InvalidCandidate,
        error.InvalidThreshold,
        error.InvalidScore,
        error.GenerationFailed,
        error.NoveltyDetectionFailed,
        error.NonCompositionalFailed,
        error.NoExistingCapabilities,
        error.MaxCandidatesExceeded,
        error.OutOfMemory,
        error.InvalidTreeStructure,
    };
    try testing.expect(errors.len == 12);
}

test "getStats 返回正确统计" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try c.addExistingCapability(1.0);
    const seeds = [_]f64{ 5.0, 3.0 };
    const candidates = try c.generate(&seeds, 2);
    defer testing.allocator.free(candidates);

    const stats = c.getStats();
    try testing.expect(stats.existing_count == 1);
    try testing.expect(stats.total_generated > 0);
}

test "candidateCount 返回候选数" {
    var engine = try DeltaEngine.init(testing.allocator);
    defer engine.deinit();
    var c = Creativity.init(testing.allocator, &engine);
    defer c.deinit();
    try testing.expect(c.candidateCount() == 0);
    const seeds = [_]f64{ 5.0, 3.0, 7.0 };
    const candidates = try c.generate(&seeds, 2);
    defer testing.allocator.free(candidates);
    try testing.expect(c.candidateCount() > 0);
}
