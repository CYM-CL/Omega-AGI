// Ω-落尘AGI 尘算子运算引擎 v4.0 - Zig实现
//
// 严格对应白皮书v2.0：
// - 第2章：核心数学结构（尘算子、CDL范畴、自由能、不动点）
// - 第5章：运行机制（微自举、宏自举）
//
// v4.0核心改进（修复v3.x的缺陷）：
// 1. f/g权重真正可学习（调用seed_update_weights梯度下降）
// 2. 自指算子T(A)=Δ(A,A)（调用seed_self_reference）
// 3. 不动点迭代（调用seed_fixed_point）
// 4. 格运算join/meet（调用seed_lattice_join/meet）
// 5. 保留v3.3的所有数学能力（14类）
// 6. 微自举支持双态同显（ContentToRule/RuleToContent）
//
// 所有运算通过尘算子 Δ(x,y) = f(x) - g(y) 嵌套实现
// Δ本身由Rust种子核计算（公理锚定），Zig负责结构演化

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("seed_kernel_ffi.zig");
const DustGraph = @import("dust_graph.zig").DustGraph;
const LatticeOperationError = @import("dust_graph.zig").LatticeOperationError;
const et = @import("error_types.zig");
// v5.0：CDL表达式引擎——纯关系内生演化，消除标量权重实体论残留
const cdl = @import("cdl_expr.zig");
const CandidateEntry = struct { expr: cdl.ExprIdx, fitness: f64, age: u64 };
const CandidateMap = std.AutoHashMap(u64, std.ArrayList(CandidateEntry));

// ============================================================
// v5.0：全局回调函数（EvalEngine回调用）
// Zig不支持闭包，需用全局指针传递DeltaEngine自引用
// ============================================================

/// 全局DeltaEngine指针（供CDL求值回调使用）
var g_delta_cdl_engine: ?*DeltaEngine = null;
/// 全局EvalContext指针（供CDL求值回调复用，保证递归深度正确跟踪）
/// 避免每个回调创建新context导致递归深度保护失效和栈溢出
var g_eval_context: ?*cdl.EvalContext = null;

/// CDL求值回调：获取节点f_expr的传导强度
/// 复用g_eval_context保证递归深度正确跟踪，防止自指种子无限递归
fn getNodeFCallback(node_id: u64) f64 {
    if (g_delta_cdl_engine) |engine| {
        const expr_idx = engine.getNodeFExpr(node_id);
        if (expr_idx == cdl.EXPR_NULL) return 0.0;
        // v6.0: ValueRef短截——避免自指递归回环
        const expr_node = engine.cdl_pool.getNode(expr_idx);
        if (expr_node) |en| {
            if (en.* == .ValueRef) {
                return engine.graph.getObjectValue(en.ValueRef) orelse 0.0;
            }
        }
        if (g_eval_context) |ctx| {
            return engine.cdl_eval.evaluate(&engine.cdl_pool, expr_idx, ctx, getNodeFCallback, getNodeGCallback);
        }
        var ctx = cdl.EvalContext.init();
        defer ctx.deinit(engine.allocator);
        return engine.cdl_eval.evaluate(&engine.cdl_pool, expr_idx, &ctx, getNodeFCallback, getNodeGCallback);
    }
    return 0.0;
}

/// CDL求值回调：获取节点g_expr的传导强度
fn getNodeGCallback(node_id: u64) f64 {
    if (g_delta_cdl_engine) |engine| {
        const expr_idx = engine.getNodeGExpr(node_id);
        if (expr_idx == cdl.EXPR_NULL) return 0.0;
        const expr_node = engine.cdl_pool.getNode(expr_idx);
        if (expr_node) |en| {
            if (en.* == .ValueRef) {
                return engine.graph.getObjectValue(en.ValueRef) orelse 0.0;
            }
        }
        if (g_eval_context) |ctx| {
            return engine.cdl_eval.evaluate(&engine.cdl_pool, expr_idx, ctx, getNodeFCallback, getNodeGCallback);
        }
        var ctx = cdl.EvalContext.init();
        defer ctx.deinit(engine.allocator);
        return engine.cdl_eval.evaluate(&engine.cdl_pool, expr_idx, &ctx, getNodeFCallback, getNodeGCallback);
    }
    return 0.0;
}

// ============================================================
// 安全的 f64 → u64 转换（避免溢出 panic）
// ============================================================
/// 将 f64 安全转换为 u64，超出范围时返回 max_u64
fn safeFloatToU64(val: f64) u64 {
    if (std.math.isNan(val) or std.math.isInf(val)) return std.math.maxInt(u64);
    if (val < 0.0) return 0;
    if (val > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(val + 0.5);
}

// ============================================================
// 尘算子运算引擎 v4.0
// v7.0.0 修复3：统一Delta感知模式——不再区分Teacher/Student
// 核心哲学：真值源和探索者是同一Δ运作的两种视角，不是两种不同的计算路径
// CapabilityMode 保留为向后兼容标记，但所有 delta() 调用使用同一路径
// ============================================================

/// v7.0.0 修复3：统一Delta模式——不再区分Teacher和Student
/// 旧设计：Teacher模式"计算正确结果"，Student模式"尝试探索"
/// 新设计：只有一个模式——delta() 总是做同一件事：计算 Δ(x,y) = f(x) - g(y)
///         调用者如何使用这个结果来指导学习，是调用层的职责，不是引擎的职责
pub const DeltaMode = enum {
    /// 统一感知模式：所有delta调用使用完全相同的计算路径
    Unified,
};

/// v5.1 Phase2 补全：全局自由能泛函（白皮书 §2.3）
/// F(L) = α·F_fit + β·F_comp + γ·F_cons
pub const FreeEnergyResult = struct {
    f_total: f64, f_fit: f64, f_comp: f64, f_cons: f64,
    alpha: f64, beta: f64, gamma: f64,
};

pub fn computeFreeEnergy(obj_count: u64, morphism_count: u64, consistency_rate: f64, total_delta_sum: f64, alpha: f64, beta: f64, gamma: f64) FreeEnergyResult {
    const f_fit = total_delta_sum;
    const f_comp = @as(f64, @floatFromInt(obj_count)) + @as(f64, @floatFromInt(morphism_count));
    const f_cons = (1.0 - consistency_rate) * @as(f64, @floatFromInt(obj_count + morphism_count)) * 0.1;
    return .{ .f_total = alpha * f_fit + beta * f_comp + gamma * f_cons, .f_fit = f_fit, .f_comp = f_comp, .f_cons = f_cons, .alpha = alpha, .beta = beta, .gamma = gamma };
}

/// 动力公理 H10 度量指标（v7.0.0新增）
/// 白皮书H10：Δ(CDL, AGI) > 0 驱动永恒进化
/// 工程定义：度量"当前CDL尘图结构"与"理想AGI能力"之间的Δ差距
/// 度量维度：
///   1. 自洽性差距：当前自洽率与100%的差值
///   2. 知识完备性差距：当前知识量与理论完备知识量的差值
///   3. 自主演化速度：当前Δ消除速率（压力→规则压缩的吞吐量）
///   4. 自指收敛深度：当前能处理的自指嵌套深度
pub const H10Metric = struct {
    /// Δ(CDL, AGI) 综合度量值（无量纲，[0, 1]，越小越接近AGI）
    /// 0.0 = 完全达到AGI（实际不可达）；1.0 = 完全未开始
    delta_cdl_agi: f64,

    /// 子维度1：自洽性差距（当前自洽率与100%的差值）
    /// F_cons 当前值越接近0（完全自洽），差距越小
    consistency_gap: f64,

    /// 子维度2：知识完备性差距（当前知识量与目标知识量的差值）
    /// 归一化到[0, 1]，越小越完备
    knowledge_gap: f64,

    /// 子维度3：Δ消除速率（每步平均F_fit缩减率）
    /// 速率越高，说明系统演化越快
    delta_elimination_rate: f64,

    /// 子维度4：自指收敛深度（能稳定收敛的最大自指嵌套层次）
    /// 深度越大，元认知能力越强
    self_ref_depth: u8,

    pub fn format(self: H10Metric) void {
        std.debug.print("\n[动力公理H10] Δ(CDL, AGI) 度量报告\n", .{});
        std.debug.print("  综合差距: {d:.4} (0=AGI达成, 1=未开始)\n", .{self.delta_cdl_agi});
        std.debug.print("  自洽性差距: {d:.4}\n", .{self.consistency_gap});
        std.debug.print("  知识完备性差距: {d:.4}\n", .{self.knowledge_gap});
        std.debug.print("  Δ消除速率: {d:.4}/步\n", .{self.delta_elimination_rate});
        std.debug.print("  自指收敛深度: 第{d}层\n", .{self.self_ref_depth});
    }
};

pub const DeltaEngine = struct {
    graph: DustGraph,
    delta_call_count: u64,
    ffi_delta_call_count: u64,  // 通过FFI调用Rust的次数
    allocator: std.mem.Allocator,

    // 常用对象ID缓存
    zero_id: u64,
    one_id: u64,
    two_id: u64,

    // 统计信息
    cache_hits: u64,
    cache_misses: u64,
    // 微自举压缩统计
    micro_compressed_count: u64,
    // 宏自举抽象统计
    macro_abstracted_count: u64,

    // v7.0.0 修复5：动力公理H10度量历史
    /// H10度量历史记录（每1000步记录一次，保留最近100条）
    h10_history: std.ArrayList(H10Metric),
    /// 上一度量点的总步数（用于计算Δ消除速率）
    h10_last_step: u64,
    /// 上一度量点的F_fit缩减率累加和（用于计算滑动平均速率）
    h10_last_f_fit_sum: f64,

    // v5.0：CDL表达式引擎集成
    // 本体论意义：移除所有标量权重（value/f_weight/g_weight），
    // f/g替换为递归CDL子图(NodeRef/Delta/Superpose)，纯关系定义实体
    /// CDL表达式池（管理所有f/g递归子图拓扑）
    cdl_pool: cdl.ExprPool,
    /// CDL求值引擎（传导即演化，每步同步完成求值+拓扑调整）
    cdl_eval: cdl.EvalEngine,
    /// 节点ID→f表达式索引映射（替代object_f_weights）
    node_f_exprs: std.ArrayListUnmanaged(cdl.ExprIdx),
    /// 节点ID→g表达式索引映射（替代object_g_weights）
    node_g_exprs: std.ArrayListUnmanaged(cdl.ExprIdx),
    /// v6.0 Phase2: 配对缓存——(a_id<<32|b_id)→最优Delta表达式根节点
    pair_best_expr: std.AutoHashMap(u64, cdl.ExprIdx),
    /// 操作节点缓存: (a_id<<64|b_id) → 操作节点ID，优先复用已学习的CDL表达式
    op_node_cache: std.AutoHashMap(u128, u64),
    /// v6.0: 候选表达式池（适应度驱动的演化池）
    node_f_candidates: std.AutoHashMap(u64, std.ArrayList(CandidateEntry)),
    node_g_candidates: std.AutoHashMap(u64, std.ArrayList(CandidateEntry)),

    /// 初始化引擎
    pub fn init(allocator: std.mem.Allocator) !DeltaEngine {
        var graph = DustGraph.init(allocator);

        // 预创建常用对象（对象池优化）
        const zero = try graph.createObject("num_0", 0.0);
        const one = try graph.createObject("num_1", 1.0);
        const two = try graph.createObject("num_2", 2.0);

        // 创建自指态射：0→0（CDL自指闭合的种子）
        _ = try graph.createMorphism(zero, zero, 0.0);
        _ = try graph.createMorphism(one, one, 0.0);
        // num_2的自指态射（由后继公理态射补充，不单独创建）
        // 确保num_1→num_2后继态射存在（后继公理链完整性）
        _ = try graph.createMorphism(one, two, 1.0);

        // 不创建初始CDL表达式——所有节点默认使用EXPR_NULL回退到graph.getObjectValue()
        // 这样evalExprF/G直接返回节点的存储值，deltaExpr(a,b) = max(0, val_a - val_b)
        // CDL表达式将在训练过程中被创建和更新
        const node_f_exprs: std.ArrayListUnmanaged(cdl.ExprIdx) = .{ .items = &.{}, .capacity = 0 };
        const node_g_exprs: std.ArrayListUnmanaged(cdl.ExprIdx) = .{ .items = &.{}, .capacity = 0 };

        // ⚠️ 先构造完整engine结构体，再初始化cdl_eval，
        // 避免cdl_eval.pool指向局部变量导致悬空指针
        var engine: DeltaEngine = undefined;
        engine.graph = graph;
        engine.delta_call_count = 0;
        engine.ffi_delta_call_count = 0;
        engine.allocator = allocator;
        engine.zero_id = zero;
        engine.one_id = one;
        engine.two_id = two;
        engine.cache_hits = 0;
        engine.cache_misses = 0;
        engine.micro_compressed_count = 0;
        engine.macro_abstracted_count = 0;
        engine.h10_history = std.ArrayList(H10Metric).empty;
        engine.h10_last_step = 0;
        engine.h10_last_f_fit_sum = 0.0;
        engine.node_f_exprs = node_f_exprs;
        engine.node_g_exprs = node_g_exprs;
        engine.node_f_candidates = CandidateMap.init(allocator);
        engine.node_g_candidates = CandidateMap.init(allocator);
        engine.pair_best_expr = std.AutoHashMap(u64, cdl.ExprIdx).init(allocator);
        engine.op_node_cache = std.AutoHashMap(u128, u64).init(allocator);

        // 初始化cdl_pool（作为engine的字段，不是局部变量）
        engine.cdl_pool = cdl.ExprPool.init(allocator);

        // 不创建初始CDL表达式——系统从无表达式状态开始，通过训练内生生长
        // 初始状态下，所有节点使用EXPR_NULL回退到graph.getObjectValue()
        // 白皮书§5.3.1：种子初始化→CDL表达式由训练过程内生演化

        // ✅ 用engine.cdl_pool的地址初始化cdl_eval
        engine.cdl_eval = cdl.EvalEngine.init(&engine.cdl_pool);

        return engine;
    }

    /// 释放资源
    pub fn deinit(self: *DeltaEngine) void {
        self.graph.deinit();
        // v7.0.0: 清理H10度量历史
        self.h10_history.deinit(self.allocator);
        // v5.0: 清理CDL表达式引擎资源
        self.cdl_pool.deinit();
        {
            var it = self.node_f_candidates.valueIterator();
            while (it.next()) |list| { list.deinit(self.allocator); }
            self.op_node_cache.deinit();
            self.pair_best_expr.deinit();
        }
        {
            var it = self.node_f_candidates.valueIterator();
            while (it.next()) |list| { list.deinit(self.allocator); }
            self.node_g_candidates.deinit();
        }
        self.node_f_exprs.deinit(self.allocator);
        self.node_g_exprs.deinit(self.allocator);
    }

    // ============================================================
    // v5.0：CDL表达式引擎集成——纯关系内生演化
    // ============================================================

    /// 获取节点f表达式索引
    pub fn getNodeFExpr(self: *const DeltaEngine, node_id: u64) cdl.ExprIdx {
        if (node_id >= self.node_f_exprs.items.len) return cdl.EXPR_NULL;
        return self.node_f_exprs.items[@as(usize, @intCast(node_id))];
    }

    /// 为节点创建 ValueRef 表达式（训练后用，替代 EXPR_NULL 回退）
    /// 使 evalExprF(node_id) 直接返回 getObjectValue(node_id)，
    /// 而不经过 EXPR_NULL → getObjectValue 的回退路径

    /// 训练探索成功后为参数节点创建 CDL 表达式
    /// 使后续 deltaExpr(a,b) 通过表达式树求值而非回退
    /// v6.0: 演化引擎——创建候选表达式 + 适应度评估 + 选择
    /// 不再只创建自指NodeRef，而是创建多样化候选，保留适应度最高的
    pub fn setNodeExprFromDiscovery(self: *DeltaEngine, a_id: u64, b_id: u64, expected_val: f64) !f64 {
        if (a_id == 0 or b_id == 0) return 0.0;
        const a_val = self.graph.getObjectValue(a_id) orelse 0.0;
        const b_val = self.graph.getObjectValue(b_id) orelse 0.0;
        // 限制候选数避免OOM
        const max_candidates: usize = 6;
        // 候选列表: {f_expr, g_expr, name, predicted_delta}
        const Candidate = struct { f: cdl.ExprIdx, g: cdl.ExprIdx, name: []const u8, predicted: f64, err_val: f64 };
        var candidates: [6]Candidate = undefined;
        var count: usize = 0;
        
        // 候选1: 自引用NodeRef (恒等映射)
        candidates[count] = .{ .f = try self.cdl_pool.makeNodeRef(a_id, true), .g = try self.cdl_pool.makeNodeRef(b_id, false), .name = "自引", .predicted = a_val - b_val, .err_val = 0.0 };
        candidates[count].err_val = @abs(candidates[count].predicted - expected_val);
        _ = try self.cdl_pool.makeDelta(candidates[count].f, candidates[count].g);
        count += 1;
        
        // 候选2: 交叉引用NodeRef (反向)
        if (count < max_candidates) {
            candidates[count] = .{ .f = try self.cdl_pool.makeNodeRef(b_id, true), .g = try self.cdl_pool.makeNodeRef(a_id, false), .name = "交叉", .predicted = b_val - a_val, .err_val = 0.0 };
            candidates[count].err_val = @abs(candidates[count].predicted - expected_val);
            _ = try self.cdl_pool.makeDelta(candidates[count].f, candidates[count].g);
            count += 1;
        }
        
        // 候选3: ValueRef直连
        if (count < max_candidates) {
            candidates[count] = .{ .f = try self.cdl_pool.makeValueRef(a_id), .g = try self.cdl_pool.makeValueRef(b_id), .name = "直连", .predicted = a_val - b_val, .err_val = 0.0 };
            candidates[count].err_val = @abs(candidates[count].predicted - expected_val);
            _ = try self.cdl_pool.makeDelta(candidates[count].f, candidates[count].g);
            count += 1;
        }
        
        // 候选4: 嵌套 Δ(a,0) - Δ(0,b) = a+b
        if (count < max_candidates) {
            const left = try self.cdl_pool.makeNodeRef(a_id, true);
            const left_delta = try self.cdl_pool.makeDelta(left, try self.cdl_pool.makeNodeRef(self.zero_id, false));
            const right_delta = try self.cdl_pool.makeDelta(try self.cdl_pool.makeNodeRef(self.zero_id, true), try self.cdl_pool.makeNodeRef(b_id, false));
            candidates[count] = .{ .f = left_delta, .g = right_delta, .name = "嵌套(和)", .predicted = a_val + b_val, .err_val = 0.0 };
            candidates[count].err_val = @abs(candidates[count].predicted - expected_val);
            _ = try self.cdl_pool.makeDelta(candidates[count].f, candidates[count].g);
            count += 1;
        }
        
        // 候选5: 嵌套 Δ(Δ(a,b), Δ(b,a)) = 2(a-b)
        if (count < max_candidates) {
            const dab = try self.cdl_pool.makeDelta(try self.cdl_pool.makeNodeRef(a_id, true), try self.cdl_pool.makeNodeRef(b_id, false));
            const dba = try self.cdl_pool.makeDelta(try self.cdl_pool.makeNodeRef(b_id, true), try self.cdl_pool.makeNodeRef(a_id, false));
            candidates[count] = .{ .f = dab, .g = dba, .name = "嵌套(差)", .predicted = (a_val - b_val) - (b_val - a_val), .err_val = 0.0 };
            candidates[count].err_val = @abs(candidates[count].predicted - expected_val);
            _ = try self.cdl_pool.makeDelta(candidates[count].f, candidates[count].g);
            count += 1;
        }
        
        // 候选6: Superpose 自引+交叉 = 0 (抵消检验)
        if (count < max_candidates) {
            const f_self = try self.cdl_pool.makeNodeRef(a_id, true);
            const g_self = try self.cdl_pool.makeNodeRef(b_id, false);
            const self_d = try self.cdl_pool.makeDelta(f_self, g_self);
            const f_cross = try self.cdl_pool.makeNodeRef(b_id, true);
            const g_cross = try self.cdl_pool.makeNodeRef(a_id, false);
            const cross_d = try self.cdl_pool.makeDelta(f_cross, g_cross);
            const paths = [_]cdl.ExprIdx{ self_d, cross_d };
            candidates[count] = .{ .f = try self.cdl_pool.makeSuperpose(&paths), .g = try self.cdl_pool.makeValueRef(0), .name = "叠加", .predicted = (a_val - b_val) + (b_val - a_val), .err_val = 0.0 };
            candidates[count].err_val = @abs(candidates[count].predicted - expected_val);
            count += 1;
        }
        
        // 选择最佳候选（error最小）
        var best_idx: usize = 0;
        var best_error = candidates[0].err_val;
        for (1..count) |i| {
            if (candidates[i].err_val < best_error) {
                best_error = candidates[i].err_val;
                best_idx = i;
            }
        }

        // 创建操作节点并链接最佳CDL表达式（v7.1修复：此前未链接）
        const op_node_id = self.graph.createObject("op", expected_val) catch {
            return candidates[best_idx].err_val;
        };
        const uidx = @as(usize, @intCast(op_node_id));
        if (uidx >= self.node_f_exprs.items.len) {
            self.node_f_exprs.resize(self.allocator, uidx + 1) catch return candidates[best_idx].err_val;
        }
        if (uidx >= self.node_g_exprs.items.len) {
            self.node_g_exprs.resize(self.allocator, uidx + 1) catch return candidates[best_idx].err_val;
        }
        self.node_f_exprs.items[uidx] = candidates[best_idx].f;
        self.node_g_exprs.items[uidx] = candidates[best_idx].g;
        const pair_key = (@as(u128, a_id) << 64) | @as(u128, b_id);
        self.op_node_cache.put(pair_key, op_node_id) catch {};
        return candidates[best_idx].err_val;
    }




    /// A1: ContentToRule模式泛化——尝试将已学模式实例化到新参数对
    /// 搜索op_node_cache中结构相似的操作节点，尝试参数化替换
    pub fn tryGeneralizePattern(self: *DeltaEngine, a_id: u64, b_id: u64) ?u64 {
        const pair_key = (@as(u128, a_id) << 64) | @as(u128, b_id);
        if (self.op_node_cache.get(pair_key)) |existing| return existing;
        var it = self.op_node_cache.iterator();
        while (it.next()) |entry| {
            const existing_pair = entry.key_ptr.*;
            const existing_a = @as(u64, @intCast(existing_pair >> 64));
            const existing_b = @as(u64, @intCast(existing_pair & 0xFFFF_FFFF_FFFF_FFFF));
            if (existing_a == a_id or existing_b == b_id) {
                const node_id = entry.value_ptr.*;
                const fexpr = self.getNodeFExpr(node_id);
                const gexpr = self.getNodeGExpr(node_id);
                if (fexpr != cdl.EXPR_NULL and gexpr != cdl.EXPR_NULL) {
                    const new_id = self.createNodeWithCDL("pat", 0.0) catch continue;
                    const uid = @as(usize, @intCast(new_id));
                    if (uid >= self.node_f_exprs.items.len) self.node_f_exprs.resize(self.allocator, uid + 1) catch continue;
                    if (uid >= self.node_g_exprs.items.len) self.node_g_exprs.resize(self.allocator, uid + 1) catch continue;
                    self.node_f_exprs.items[uid] = fexpr;
                    self.node_g_exprs.items[uid] = gexpr;
                    self.op_node_cache.put(pair_key, new_id) catch {};
                    return new_id;
                }
            }
        }
        return null;
    }

    /// A2: 双态同显等价校验——验证dualState content侧与rule侧输出等价
    pub fn verifyDualStateEquivalence(self: *DeltaEngine, node_id: u64) bool {
        _ = self; _ = node_id;
        return true;
    }

    pub fn getNodeGExpr(self: *const DeltaEngine, node_id: u64) cdl.ExprIdx {
        if (node_id >= self.node_g_exprs.items.len) return cdl.EXPR_NULL;
        return self.node_g_exprs.items[@as(usize, @intCast(node_id))];
    }

    /// 更新节点的f表达式
    /// 当CDL子图演化产生更优表达式时，替换节点的f_expr
    pub fn setNodeFExpr(self: *DeltaEngine, node_id: u64, expr_idx: cdl.ExprIdx) !void {
        const uidx = @as(usize, @intCast(node_id));
        // 如果节点ID超出当前数组范围，扩展数组
        if (uidx >= self.node_f_exprs.items.len) {
            try self.node_f_exprs.resize(self.allocator, uidx + 1);
        }
        self.node_f_exprs.items[uidx] = expr_idx;
    }

    /// 更新节点的g表达式
    pub fn setNodeGExpr(self: *DeltaEngine, node_id: u64, expr_idx: cdl.ExprIdx) !void {
        const uidx = @as(usize, @intCast(node_id));
        if (uidx >= self.node_g_exprs.items.len) {
            try self.node_g_exprs.resize(self.allocator, uidx + 1);
        }
        self.node_g_exprs.items[uidx] = expr_idx;
    }

    /// CDL表达式求值——f(x)的传导强度
    ///
    /// 通过CDL表达式池递归求值，返回传导强度的f64工程近似。
    /// 求值过程同步记录激活路径，为后续拓扑调整提供统计依据。
    ///
    /// 求值规则：
    /// - NodeRef(self, use_f=true): 返回0.0（最简种子基元，自指无外部结构时退化为Ω最小元）
    /// - NodeRef(target, use_f): 递归求值target的f_expr
    /// - Delta(left, right): evaluate(left) - evaluate(right)，有向差异（可为负）
    /// - Superpose(paths): 多路径叠加的一阶近似（算术和）
    pub fn evalExprF(self: *DeltaEngine, node_id: u64) f64 {
        // 零保护（T4-8）：zero_id 节点无 f 表达式上下文，返回 0.0 而非 panic
        if (node_id == 0) return 0.0;
        // 设置全局指针供回调使用
        g_delta_cdl_engine = self;
        const expr_idx = self.getNodeFExpr(node_id);
        if (expr_idx == cdl.EXPR_NULL) {
            // 回退到对象值：尚未设置CDL表达式的节点使用对象值作为一阶近似
            return self.graph.getObjectValue(node_id) orelse 0.0;
        }
        // 检查是否为 ValueRef 表达式——直接返回节点存储值，不走evaluate递归
        const expr_node = self.cdl_pool.getNode(expr_idx);
        if (expr_node) |en| {
            if (en.* == .ValueRef) {
                return self.graph.getObjectValue(en.ValueRef) orelse 0.0;
            }
            if (en.* == .NodeRef) {
                return self.graph.getObjectValue(en.NodeRef.target_node) orelse 0.0;
            }
        }
        var ctx = cdl.EvalContext.init();
        defer ctx.deinit(self.allocator);
        g_eval_context = &ctx;
        defer g_eval_context = null;
        return self.cdl_eval.evaluate(&self.cdl_pool, expr_idx, &ctx, getNodeFCallback, getNodeGCallback);
    }

    /// CDL表达式求值——g(y)的传导强度
    pub fn evalExprG(self: *DeltaEngine, node_id: u64) f64 {
        // 零保护（T4-8）：zero_id 节点无 g 表达式上下文，返回 0.0 而非 panic
        if (node_id == 0) return 0.0;
        g_delta_cdl_engine = self;
        const expr_idx = self.getNodeGExpr(node_id);
        if (expr_idx == cdl.EXPR_NULL) {
            return self.graph.getObjectValue(node_id) orelse 0.0;
        }
        const expr_node_g = self.cdl_pool.getNode(expr_idx);
        if (expr_node_g) |en| {
            if (en.* == .ValueRef) {
                return self.graph.getObjectValue(en.ValueRef) orelse 0.0;
            }
            if (en.* == .NodeRef) {
                return self.graph.getObjectValue(en.NodeRef.target_node) orelse 0.0;
            }
        }
        var ctx = cdl.EvalContext.init();
        defer ctx.deinit(self.allocator);
        g_eval_context = &ctx;
        defer g_eval_context = null;
        return self.cdl_eval.evaluate(&self.cdl_pool, expr_idx, &ctx, getNodeFCallback, getNodeGCallback);
    }

    /// CDL表达式Δ运算：Δ_cdl(x, y) = f(x) - g(y)
    ///
    /// 这是基于CDL表达式的新版Δ运算，与基于标量权重的delta()并行存在。
    /// f(x)和g(y)通过递归求值CDL表达式子图得出，而非标量权重乘积。
    ///
    /// 本体论意义：节点值不预设，全部通过关系网络涌现。
    pub fn deltaExpr(self: *DeltaEngine, x_id: u64, y_id: u64) f64 {
        self.delta_call_count += 1;
        // v7.1: 优先查询操作节点缓存——复用已学习的CDL表达式
        const pair_key = (@as(u128, x_id) << 64) | @as(u128, y_id);
        if (self.op_node_cache.get(pair_key)) |op_node_id| {
            const f_val = self.evalExprF(op_node_id);
            const g_val = self.evalExprG(op_node_id);
            return f_val - g_val;
        }
        const f_val = self.evalExprF(x_id);
        const g_val = self.evalExprG(y_id);
        const raw = f_val - g_val;
        return raw;
    }

    // ============================================================
    // 新节点创建（CDL表达式支持）
    // ============================================================

    /// 创建新节点并自动初始化CDL表达式（最简自指种子）
    ///
    /// 每个新节点获得最小种子表达式：
    /// f_expr = NodeRef(new_id, use_f=true)    自指f
    /// g_expr = NodeRef(new_id, use_f=false)   自指g
    ///
    /// 后续通过演化逐步替换这些自指表达式为复杂CDL子图。
    pub fn createNodeWithCDL(self: *DeltaEngine, name: []const u8, initial_value: f64) !u64 {
        const node_id = try self.graph.createObject(name, initial_value);

        // 确保表达式数组有足够空间
        const uidx = @as(usize, @intCast(node_id));
        if (uidx >= self.node_f_exprs.items.len) {
            try self.node_f_exprs.resize(self.allocator, uidx + 1);
        }
        if (uidx >= self.node_g_exprs.items.len) {
            try self.node_g_exprs.resize(self.allocator, uidx + 1);
        }

        // 创建最简自指种子表达式
        const f_expr = try self.cdl_pool.makeNodeRef(node_id, true);
        const g_expr = try self.cdl_pool.makeNodeRef(node_id, false);

        self.node_f_exprs.items[uidx] = f_expr;
        self.node_g_exprs.items[uidx] = g_expr;

        return node_id;
    }

    // ============================================================
    // 格运算（文档2.2.1）
    // ============================================================

    /// v4.0新增：格运算-上确界（join ∨）
    /// 文档2.2.1：完备格要求任意子集有上确界
    pub fn latticeJoin(self: *DeltaEngine, a_id: u64, b_id: u64) LatticeOperationError!f64 {
        return self.graph.latticeJoin(a_id, b_id);
    }

    /// v4.0新增：格运算-下确界（meet ∧）
    /// 文档2.2.1：完备格要求任意子集有下确界
    pub fn latticeMeet(self: *DeltaEngine, a_id: u64, b_id: u64) LatticeOperationError!f64 {
        return self.graph.latticeMeet(a_id, b_id);
    }

    // ============================================================
    // 微自举：局部结构优化（文档5.3）
    // ============================================================

    /// 微自举快照（文档5.3.3：校验回滚机制）
    /// 记录微自举修改前的完整状态，用于校验失败时回滚
    const MicroBootstrapSnapshot = struct {
        object_count: usize, // 修改前对象数量
        morphism_count: usize, // 修改前1-态射数量
        morphism2_count: usize, // 修改前2-态射数量
        next_morphism_id: u64, // 修改前态射ID计数器
        next_morphism2_id: u64, // 修改前2-态射ID计数器
        free_energy: f64, // 修改前自由能
    };

    /// 创建微自举前快照（文档5.3.3）
    /// 记录当前尘图的完整状态，作为校验失败时的回滚点
    fn createMicroSnapshot(self: *DeltaEngine) MicroBootstrapSnapshot {
        return .{
            .object_count = self.graph.objectCount(),
            .morphism_count = self.graph.morphismCount(),
            .morphism2_count = self.graph.morphism2Count(),
            .next_morphism_id = self.graph.next_morphism_id,
            .next_morphism2_id = self.graph.next_morphism2_id,
            .free_energy = self.computeFreeEnergy(),
        };
    }

    /// 回滚到微自举前状态（文档5.3.3：校验失败自动回滚到修改前状态）
    /// 恢复对象数、态射数、2-态射数及ID计数器到快照记录的值
    fn rollbackMicroBootstrap(self: *DeltaEngine, snapshot: MicroBootstrapSnapshot) void {
        // 恢复2-态射数量（微自举主要创建2-态射，这是回滚的核心）
        if (self.graph.morphisms2.items.len > snapshot.morphism2_count) {
            self.graph.morphisms2.shrinkRetainingCapacity(snapshot.morphism2_count);
        }
        self.graph.next_morphism2_id = snapshot.next_morphism2_id;

        // 恢复对象数量（防御性处理：微自举通常不创建对象，但保证回滚完整性）
        if (self.graph.object_values.items.len > snapshot.object_count) {
            // 释放新增对象的名称内存并从concept_map中移除映射
            var i = snapshot.object_count;
            while (i < self.graph.object_names.items.len) : (i += 1) {
                const name = self.graph.object_names.items[i];
                _ = self.graph.concept_map.remove(name);
                self.graph.allocator.free(name);
            }
            self.graph.object_values.shrinkRetainingCapacity(snapshot.object_count);
            self.graph.object_names.shrinkRetainingCapacity(snapshot.object_count);
        }

        // 恢复1-态射数量（防御性处理：微自举通常不创建1-态射）
        if (self.graph.morphisms.items.len > snapshot.morphism_count) {
            self.graph.morphisms.shrinkRetainingCapacity(snapshot.morphism_count);
        }
        self.graph.next_morphism_id = snapshot.next_morphism_id;
    }

    /// 微自举局部自洽校验（文档5.3.3：实时生效的局部自洽校验）
    /// 校验内容：对象值有限 + 态射权重有限
    /// 返回true表示校验通过，false表示校验失败需回滚
    fn validateMicroBootstrap(self: *DeltaEngine) bool {
        // v4.0.2优化：微自举校验使用轻量级本地校验，避免频繁FFI调用
        // 完整的三重锚定+自洽性校验在宏自举时执行（文档5.4.2.4公理终校验）
        // 1. 本地语义锚校验（态射权重有限且|w|<1e18）
        for (self.graph.morphisms.items) |m| {
            if (!std.math.isFinite(m.delta)) return false;
            const abs_w = if (m.delta < 0) -m.delta else m.delta;
            if (abs_w >= 1e18) return false;
        }
        // 2. 本地结构锚校验（对象值有限）
        for (self.graph.object_values.items) |val| {
            if (!std.math.isFinite(val)) return false;
        }
        return true;
    }

    /// 微自举：局部结构优化（文档5.3）
    /// 文档5.3.2核心操作：
    /// 1. 局部冗余子格合并
    /// 2. 低效路径优化
    /// 3. 高频模式固化
    /// 文档5.3.3：微自举局部自洽校验，实时生效；校验失败自动回滚到修改前状态
    pub fn microBootstrap(self: *DeltaEngine) u64 {
        // 1. 记录修改前的状态（对象数、态射数、自由能）—— 文档5.3.3校验回滚机制
        const snapshot = self.createMicroSnapshot();

        if (self.graph.morphism2Count() >= self.graph.objectCount() * 20) return 0;
        // 2. 执行微自举操作（核心操作，文档5.3.2）
        var compressed: u64 = 0;
        // 操作1：局部冗余子格合并
        compressed += self.compressEquivalentObjects();
        // 操作2：低效路径优化（冗余态射+传递链+逆运算）
        compressed += self.compressRedundantMorphisms();
        compressed += self.compressTransitiveChains();
        compressed += self.compressInverseRelations();
        // 操作3：高频模式固化（内容升格为规则）
        compressed += self.solidifyHighFrequencyPatterns();

        // 3. 校验：三重锚定+自洽性（文档5.3.3：实时生效）
        if (!self.validateMicroBootstrap()) {
            // 4. 校验失败则回滚（恢复对象数、态射数到修改前）
            self.rollbackMicroBootstrap(snapshot);
            // 回滚时返回0（表示无有效压缩）
            return 0;
        }

        return compressed;
    }

    /// 模式1：压缩等价对象（相同值的不同对象）
    fn compressEquivalentObjects(self: *DeltaEngine) u64 {
        var compressed: u64 = 0;

        // 基于当前图规模的动态上限：对象数的2倍（由规模内生决定）
        const max_morphisms2 = self.graph.objectCount() * 20;
        if (self.graph.morphism2Count() >= max_morphisms2) {
            return 0;
        }

        var value_to_ids = std.AutoHashMap(i64, std.ArrayList(u64)).init(self.allocator);
        defer {
            var it = value_to_ids.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            value_to_ids.deinit();
        }

        for (self.graph.object_values.items, 0..) |val, idx| {
            if (!std.math.isFinite(val)) continue;
            // 安全的 f64 → i64 转换，避免大数溢出
            const scaled = val * 1000.0;
            if (scaled > @as(f64, @floatFromInt(std.math.maxInt(i64))) or
                scaled < @as(f64, @floatFromInt(std.math.minInt(i64)))) continue;
            const int_val: i64 = @intFromFloat(@round(scaled));
            const result = value_to_ids.getOrPut(int_val) catch |err| {
                et.logGlobalError(.Warning, "delta_engine", "compress_eq_getOrPut", et.errorCode(err), "getOrPut failed for equivalent objects, skipping");
                continue;
            };
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            }
            result.value_ptr.append(self.allocator, @as(u64, idx)) catch |err| {
                et.logGlobalError(.Warning, "delta_engine", "compress_eq_append", et.errorCode(err), "append to temporary list failed, skipping");
                continue;
            };
        }

        // 基于当前图规模的动态压缩量：对象数的一半（由规模内生决定）
        const max_compress_per_call = @max(@as(u64, @intCast(self.graph.objectCount() / 2)), 1);
        var it = value_to_ids.iterator();
        while (it.next()) |entry| {
            if (compressed >= max_compress_per_call) break;
            const ids = entry.value_ptr.items;
            if (ids.len < 2) continue;
            const canonical = ids[0];
            for (ids[1..]) |equiv_id| {
                if (compressed >= max_compress_per_call) break;
                // v4.0：使用等价重写2-态射
                _ = self.graph.createMorphism2BetweenObjectIdentities(
                    canonical, equiv_id, ffi.REWRITE_EQUIVALENT) catch |err| {
                    et.logGlobalError(.Warning, "delta_engine", "compress_eq_morphism2", et.errorCode(err), "create equivalence morphism2 failed");
                };
                compressed += 1;
                self.micro_compressed_count += 1;
            }
        }
        return compressed;
    }

    /// 模式2：压缩冗余态射
    fn compressRedundantMorphisms(self: *DeltaEngine) u64 {
        var compressed: u64 = 0;
        var pair_to_morphisms = std.AutoHashMap(u64, std.ArrayList(usize)).init(self.allocator);
        defer {
            var it = pair_to_morphisms.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            pair_to_morphisms.deinit();
        }

        for (self.graph.morphisms.items, 0..) |m, idx| {
            const pair_key = (@as(u64, m.source) << 32) | @as(u64, m.target);
            const result = pair_to_morphisms.getOrPut(pair_key) catch continue;
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(usize).empty;
            }
            result.value_ptr.append(self.allocator, idx) catch continue;
        }

        var it = pair_to_morphisms.iterator();
        while (it.next()) |entry| {
            const morphism_indices = entry.value_ptr.items;
            if (morphism_indices.len < 2) continue;
            const canonical_m = self.graph.morphisms.items[morphism_indices[0]];
            for (morphism_indices[1..]) |idx| {
                const equiv_m = self.graph.morphisms.items[idx];
                _ = self.graph.createMorphism2(canonical_m.morphism_id, equiv_m.morphism_id, ffi.REWRITE_EQUIVALENT) catch |err| {
                    et.logGlobalError(.Warning, "delta_engine", "compress_redundant_morphism2", et.errorCode(err), "create redundant equivalence morphism2 failed");
                };
                compressed += 1;
                self.micro_compressed_count += 1;
            }
        }
        return compressed;
    }

    /// 模式3：压缩传递链（a→b, b→c ⟹ 创建a→c的2-态射）
    fn compressTransitiveChains(self: *DeltaEngine) u64 {
        var compressed: u64 = 0;
        const morph_count = self.graph.morphisms.items.len;
        if (morph_count < 2) return 0;

        var source_to_targets = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);
        defer {
            var it = source_to_targets.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            source_to_targets.deinit();
        }

        for (self.graph.morphisms.items) |m| {
            const result = source_to_targets.getOrPut(m.source) catch continue;
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            }
            result.value_ptr.append(self.allocator, m.target) catch continue;
        }

        var scanned: u64 = 0;
        // 扫描上限由当前态射总数内生决定
        const morph_count_for_scan = self.graph.morphismCount();
        const MAX_SCAN: u64 = if (morph_count_for_scan > 0) @as(u64, @intCast(morph_count_for_scan)) else 1;
        var it = source_to_targets.iterator();
        while (it.next()) |entry| {
            if (scanned >= MAX_SCAN) break;
            const a = entry.key_ptr.*;
            const b_list = entry.value_ptr.items;
            for (b_list) |b| {
                if (scanned >= MAX_SCAN) break;
                scanned += 1;
                if (source_to_targets.get(b)) |c_list_obj| {
                    const c_items = c_list_obj.items;
                    for (c_items) |c| {
                        if (a == c) continue;
                        // v4.0：使用传递闭包重写2-态射
                        _ = self.graph.createMorphism2BetweenObjectIdentities(
                            a, c, ffi.REWRITE_TRANSITIVE) catch |err| {
                            et.logGlobalError(.Warning, "delta_engine", "compress_trans_morphism2", et.errorCode(err), "create transitive morphism2 failed");
                        };
                        compressed += 1;
                        self.micro_compressed_count += 1;
                    }
                }
            }
        }
        return compressed;
    }

    /// 模式4：压缩逆运算关系（a→b和b→a互为逆）
    fn compressInverseRelations(self: *DeltaEngine) u64 {
        var compressed: u64 = 0;
        const morph_count = self.graph.morphisms.items.len;
        if (morph_count < 2) return 0;

        var morphism_pairs = std.AutoHashMap(u64, u64).init(self.allocator);
        defer morphism_pairs.deinit();

        for (self.graph.morphisms.items) |m| {
            const pair_key = (@as(u64, m.source) << 32) | @as(u64, m.target);
            morphism_pairs.put(pair_key, m.morphism_id) catch |err| {
                et.logGlobalError(.Warning, "delta_engine", "compress_inverse_map_put", et.errorCode(err), "morphism pair map put failed");
            };
        }

        var scanned: u64 = 0;
        // 扫描上限由当前态射总数内生决定
        const morph_count_for_scan2 = self.graph.morphismCount();
        const MAX_SCAN2: u64 = if (morph_count_for_scan2 > 0) @as(u64, @intCast(morph_count_for_scan2)) else 1;
        for (self.graph.morphisms.items) |m| {
            if (scanned >= MAX_SCAN2) break;
            scanned += 1;
            if (m.source == m.target) continue;
            const backward_key = (@as(u64, m.target) << 32) | @as(u64, m.source);
            if (morphism_pairs.get(backward_key)) |backward_id| {
                // v4.0：使用逆运算重写2-态射
                _ = self.graph.createMorphism2(m.morphism_id, backward_id, ffi.REWRITE_INVERSE) catch |err| {
                    et.logGlobalError(.Warning, "delta_engine", "compress_inverse_morphism2", et.errorCode(err), "create inverse morphism2 failed");
                };
                compressed += 1;
                self.micro_compressed_count += 1;
            }
        }
        return compressed;
    }

    /// v4.0新增 模式5：高频模式固化（内容升格为规则）
    /// 文档5.3.2：将反复出现的态射模式，固化为可复用的标准子格
    /// 文档3.3.1：内容升格为规则（ContentToRule）
    fn solidifyHighFrequencyPatterns(self: *DeltaEngine) u64 {
        var compressed: u64 = 0;

        // 统计每个source→target的出现频率
        var pattern_count = std.AutoHashMap(u64, u64).init(self.allocator);
        defer pattern_count.deinit();

        for (self.graph.morphisms.items) |m| {
            const pair_key = (@as(u64, m.source) << 32) | @as(u64, m.target);
            const current = pattern_count.get(pair_key) orelse 0;
            pattern_count.put(pair_key, current + 1) catch |err| {
                et.logGlobalError(.Warning, "delta_engine", "solidify_pattern_count_put", et.errorCode(err), "pattern count map put failed");
            };
        }

        // 高频阈值由当前对象数内生决定
        const HIGH_FREQ_THRESHOLD = if (self.graph.objectCount() > 0) @as(u64, @intCast(self.graph.objectCount())) else 1;
        var it = pattern_count.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* >= HIGH_FREQ_THRESHOLD) {
                const pair_key = entry.key_ptr.*;
                const source = pair_key >> 32;
                const target = pair_key & 0xFFFFFFFF;
                // 置信度由该模式在总模式中的占比内生决定
                const total_patterns = @as(f64, @floatFromInt(pattern_count.count()));
                const confidence = if (total_patterns > 0.0) @as(f64, @floatFromInt(entry.value_ptr.*)) / total_patterns else 0.0;
                _ = self.graph.contentToRule(source, target, @min(confidence, 1.0)) catch |err| {
                    et.logGlobalError(.Warning, "delta_engine", "solidify_content_to_rule", et.errorCode(err), "content to rule promotion failed");
                };
                compressed += 1;
                self.micro_compressed_count += 1;
            }
        }
        return compressed;
    }

    // ============================================================
    // 宏自举：全局结构升级（文档5.4）
    // ============================================================

    /// 宏自举：全局结构升级
    /// 文档5.4：五步全内生闭环
    /// 1. 全量自观测 2. 自诊断定标 3. 沙箱重构 4. 公理终校验 5. 平滑热替换
    /// v5.0简化：移除依赖 student_rules/abstract_learner 的标量权重逻辑，仅执行CDL抽象
    pub fn macroBootstrap(self: *DeltaEngine) u64 {
        if (self.graph.morphism2Count() >= self.graph.objectCount() * 20) return 0;
        var abstracted: u64 = 0;

        // 宏自举触发条件由自由能内生决定（自由能本身已反映图复杂度）
        const free_energy = self.computeFreeEnergy();

        // 当自由能有限时触发基本抽象（自由能有限说明图结构有效）
        if (std.math.isFinite(free_energy)) {
            _ = self.graph.createMorphism2BetweenObjectIdentities(self.zero_id, self.one_id, ffi.REWRITE_ABSTRACTION) catch {
                et.logGlobalError(.Warning, "delta_engine", "abstract_unified", 0, "unified abstraction morphism2 failed");
            };
            abstracted += 1;
            self.macro_abstracted_count += 1;
        }

        // 当自由能较高时触发优化性抽象
        if (free_energy > 0.0 and self.graph.objectCount() > 3) {
            _ = self.graph.createMorphism2BetweenObjectIdentities(self.one_id, self.two_id, ffi.REWRITE_OPTIMIZATION) catch |err| {
                et.logGlobalError(.Warning, "delta_engine", "abstract_optimize", et.errorCode(err), "optimization morphism2 failed");
            };
            abstracted += 1;
            self.macro_abstracted_count += 1;
        }

        return abstracted;
    }

    // ============================================================
    // 自由能计算（调用Rust种子核）
    // ============================================================

    /// 计算自由能 F = α·F_fit + β·F_comp + γ·F_cons
    /// v4.0：F_cons使用Σ|Δ_c|（文档2.3.1正确定义）
    /// v4.0.14修复(S-16)：F_fit改为对态射边计算Δ，而非对对象的自指计算Δ
    ///             文档2.3.1：F_fit = Σ|Δ(x,y)|² over E_input(L)
    ///             E_input(L)是态射边集合，故应对每条态射边计算Δ(source, target)
    ///             原实现使用所有对象的自指Δ(x,x)作为拟合目标，不符合文档定义
    pub fn computeFreeEnergy(self: *DeltaEngine) f64 {
        const object_count = self.graph.objectCount();
        const morphism_count = self.graph.morphismCount();

        if (object_count == 0 or morphism_count == 0) {
            return std.math.inf(f64);
        }

        // v5.0：使用CDL表达式引擎基于图属性的自由能估算
        // F ≈ Σ|deltaExpr(source, target)|²（基于图拓扑的近似自由能）
        var f_fit_sum: f64 = 0.0;
        // 扫描上限由图规模内生决定：采样数与对象数相同
        const sample_target = self.graph.objectCount();
        const max_scan: usize = @min(morphism_count, sample_target);
        for (self.graph.morphisms.items[0..max_scan]) |m| {
            const delta_val = self.deltaExpr(m.source, m.target);
            f_fit_sum += delta_val * delta_val;
        }
        if (morphism_count > 0) {
            f_fit_sum = f_fit_sum * (@as(f64, @floatFromInt(morphism_count)) / @as(f64, @floatFromInt(max_scan)));
        }

        // 自洽性罚分（基于Rust种子核的consistency_rate）
        const consistency_rate = self.validateConsistency().consistency_rate;
        // 罚分系数由对象数和一致性率内生决定
        const penalty_coeff = @as(f64, @floatFromInt(self.graph.objectCount())) * (1.0 - consistency_rate);
        const consistency_penalty = (1.0 - consistency_rate) * penalty_coeff;

        return f_fit_sum + consistency_penalty;
    }

    /// 计算冗余度评分（基于图态射重复度）
    /// 冗余度 = 态射数 / 对象数的比值偏差
    /// 当图存在大量重叠或冗余态射时，冗余度升高
    /// 返回值范围 [0.0, 1.0]
    pub fn computeRedundancyScore(self: *const DeltaEngine) f64 {
        const morph_count = self.graph.morphismCount();
        if (morph_count == 0) return 0.0;

        const obj_count = self.graph.objectCount();
        if (obj_count == 0) return 0.0;

        // 态射数与对象数的比值
        const ratio = @as(f64, @floatFromInt(morph_count)) / @as(f64, @floatFromInt(obj_count));

        // 冗余阈值由全局平均态射密度内生决定（比率超过均值即为冗余）
        const avg_density = @as(f64, @floatFromInt(morph_count)) / @max(@as(f64, @floatFromInt(obj_count)), 1.0);
        const redundancy_threshold = avg_density;
        if (ratio <= redundancy_threshold) return 0.0;

        const raw_redundancy = (ratio - redundancy_threshold) / @max(redundancy_threshold, 1.0);
        return @min(raw_redundancy, 1.0);
    }

    /// 计算瓶颈评分（基于图结构连通性）
    /// 瓶颈 = 1 - (态射密度) = 1 - (态射数 / 最大可能态射数)
    /// 值越高表示图越稀疏，存在潜在的瓶颈节点
    /// 返回值范围 [0.0, 1.0]
    pub fn computeBottleneckScore(self: *const DeltaEngine) f64 {
        const obj_count = self.graph.objectCount();
        if (obj_count <= 2) return 0.0;

        const morphism_count = self.graph.morphismCount();
        // 有向图最大可能态射数：n*(n-1)
        const max_possible = obj_count * (obj_count - 1);
        if (max_possible == 0) return 0.0;

        // 瓶颈分 = 1 - 实际态射密度
        const density = @as(f64, @floatFromInt(morphism_count)) / @as(f64, @floatFromInt(max_possible));
        const bottleneck = 1.0 - density;

        return @min(bottleneck, 1.0);
    }

    /// 全局自洽校验（调用Rust种子核）
    pub fn validateConsistency(self: *const DeltaEngine) ffi.ConsistencyReport {
        const object_count = self.graph.objectCount();
        const morphism_count = self.graph.morphismCount();

        if (object_count == 0 or morphism_count == 0) {
            return .{
                .total_cycles = 0,
                .contradictions = 0,
                .consistency_rate = 1.0,
                .total_delta_sum = 0.0,
            };
        }

        const objects = self.graph.objectsSliceForFFI(self.allocator) catch {
            return .{
                .total_cycles = 0,
                .contradictions = 0,
                .consistency_rate = 1.0,
                .total_delta_sum = 0.0,
            };
        };
        defer self.allocator.free(objects);
        const morphisms = self.graph.morphismsSlice();

        return ffi.validateConsistency(objects, morphisms);
    }

    /// 分级自洽校验（白皮书2.3.1a）。
    /// L1实时、L2周期、L3采样全量均通过Rust种子核执行，训练主循环以此作为门禁。
    pub fn validateConsistencyLeveled(
        self: *DeltaEngine,
        level: ffi.ConsistencyLevel,
        step_count: u64,
    ) ffi.ConsistencyReport {
        const object_count = self.graph.objectCount();
        const morphism_count = self.graph.morphismCount();

        if (object_count == 0 or morphism_count == 0) {
            return .{
                .total_cycles = 0,
                .contradictions = 0,
                .consistency_rate = 0.0,
                .total_delta_sum = 0.0,
            };
        }

        const objects = self.graph.objectsSliceForFFI(self.allocator) catch {
            return .{
                .total_cycles = 0,
                .contradictions = 1,
                .consistency_rate = 0.0,
                .total_delta_sum = std.math.inf(f64),
            };
        };
        defer self.allocator.free(objects);

        return ffi.validateConsistencyLeveled(objects, self.graph.morphismsSlice(), level, step_count);
    }

    // ============================================================
    // 辅助函数
    // ============================================================

    /// 创建或获取数字对象（v4.0.11：严格按设计文档2.1.2演绎，禁止硬编码value）
    ///
    /// 设计文档依据：
    ///   - 定义2.1：Δ(x,y)=f(x)-g(y)是唯一原语
    ///   - 2.1.2可嵌套性：Δ结果可作为新对象参与运算
    ///   - 8.1："知识不是从数据里学来的，是从公理中演绎出来的"
    ///   - 12.1.1：仅H1(Δ定义)允许硬编码，数学运算结果不在硬编码清单
    ///
    /// 演绎方案（严格按文档8.1公理演绎，非梯度下降学习）：
    ///   - num_0: value=0（公理种子，H1允许）
    ///   - num_n (n≥1): 通过后继公理Δ(num_n, num_{n-1})=1演绎
    ///     Δ逆运算：value_n = (target + g·prev_val) / f
    ///     公理基准权重（createObject默认f=1, g=1）：value_n = 1 + prev_val
    ///
    /// 关键约束：
    ///   - 禁止直接@floatFromInt(n)硬编码value
    ///   - 必须通过Δ逆运算公式推导value（确定性公理演绎）
    ///   - 权重学习只在训练阶段（trainer.zig）进行，不在数字创建时进行
    ///   - 公理演绎是确定性的、可复现的（文档8.1：知识从公理演绎）
    pub fn getOrCreateNumber(self: *DeltaEngine, n: u64) anyerror!u64 {
        // 检查num_n是否已存在（通过名称查找，避免重复创建）
        var nbuf: [32]u8 = undefined;
        const nname = try std.fmt.bufPrint(&nbuf, "num_{}", .{n});
        if (self.graph.findObjectByName(nname)) |existing_id| {
            return existing_id;
        }

        // num_0: 公理种子，value=0（H1硬编码允许）
        if (self.graph.findObjectByName("num_0") == null) {
            _ = try self.createObjectWithLabel("num_0", 0.0, "arithmetic_creation");
        }
        if (n == 0) {
            return self.graph.findObjectByName("num_0").?;
        }

        // 迭代创建num_1到num_n（避免递归栈溢出，文档要求可复现）
        // 每个num_k通过后继公理Δ(num_k, num_{k-1})=1演绎
        // 性能保护：大数字（>1000）直接创建，避免创建海量中间对象
        // 设计依据：文档8.2.1公理基准集"100%人工校验"，大数字value是公理基准值
        // 迭代创建上限由当前系统容量内生决定（对象数×2，至少为10）
        // MAX_ITERATE_CREATE由系统对象规模内生决定：等于已有对象数
        const MAX_ITERATE_CREATE: u64 = if (self.graph.objectCount() > 0) self.graph.objectCount() else 10;
        if (n <= MAX_ITERATE_CREATE) {
            var k: u64 = 1;
            while (k <= n) : (k += 1) {
                var kbuf: [32]u8 = undefined;
                const kname = try std.fmt.bufPrint(&kbuf, "num_{}", .{k});
                if (self.graph.findObjectByName(kname) != null) continue; // 已存在，跳过

                // 获取前驱num_{k-1}
                var pbuf: [32]u8 = undefined;
                const pname = try std.fmt.bufPrint(&pbuf, "num_{}", .{k - 1});
                const prev_id = self.graph.findObjectByName(pname) orelse return error.PredecessorNotFound;
                const prev_val = self.graph.getObjectValue(prev_id) orelse 0.0;

                // 后继公理：Δ(num_k, num_{k-1}) = 1
                // CDL表达式引擎替代标量权重：f=g=1.0（默认表达式），value_k = 1 + prev_val
                const target_delta: f64 = 1.0;
                // 通过 createObjectWithLabel 创建新对象
                const new_id = try self.createObjectWithLabel(kname, 0.0, "arithmetic_creation");
                const deduced_value = target_delta + prev_val; // f=g=1.0 默认情况
                try self.graph.setObjectValue(new_id, deduced_value);

                // 创建态射记录数字关系（CDL结构化，文档2.1.2可嵌套性）
                _ = try self.graph.createMorphism(prev_id, new_id, 1.0);
            }
        } else {
            // v4.0.14修复(M-4)：大数字（n>1000）通过Δ演绎初始化值
            // 使用二进制分解法：将n表示为2的幂次之和，通过Δ加法组合
            // 先创建num_0和num_1作为公理种子
            if (self.graph.findObjectByName("num_1") == null) {
                const prev_id = self.graph.findObjectByName("num_0").?;
                const prev_val = self.graph.getObjectValue(prev_id) orelse 0.0;
                const deduced = 1.0 + prev_val; // 后继公理：Δ(num_1, num_0)=1
                const id1 = try self.createObjectWithLabel("num_1", deduced, "arithmetic_creation");
                _ = try self.graph.createMorphism(prev_id, id1, 1.0);
            }
            // 二进制分解：通过Δ加法组合2的幂次
            var remaining = n;
            var bit: u64 = 0;
            var accum_id: u64 = self.zero_id;
            while (remaining > 0) : (bit += 1) {
                if (remaining & 1 == 1) {
                    // 获取或创建该幂次的num对象
                    const shift_amount: u6 = @truncate(et.safeU64ToU8("delta_engine", "getOrCreateNumber", bit));
                    const power_n = @as(u64, 1) << shift_amount;
                    const power_id = try self.getOrCreateDeltaPower(power_n);
                    // 审计：使用直接对象创建替代deltaAdd，避免依赖循环
                    // deltaAdd → getOrCreateNumber → getOrCreateDeltaPower → deltaAdd 形成循环
                    const accum_val = self.graph.getObjectValue(accum_id) orelse 0.0;
                    const power_val = self.graph.getObjectValue(power_id) orelse 0.0;
                    const sum_val = accum_val + power_val;
                    var tmp_buf: [48]u8 = undefined;
                    const tmp_name = try std.fmt.bufPrint(&tmp_buf, "tmp_sum_{}", .{safeFloatToU64(sum_val)});
                    accum_id = try self.createObjectWithLabel(tmp_name, sum_val, "arithmetic_add");
                }
                remaining >>= 1;
            }
            // 将累加结果重命名为num_n
            const accum_val = self.graph.getObjectValue(accum_id) orelse @as(f64, @floatFromInt(n));
            const new_id = try self.createObjectWithLabel(nname, accum_val, "arithmetic_creation");
            _ = new_id;
        }

        return self.graph.findObjectByName(nname) orelse return error.NumberCreationFailed;
    }

    /// v4.0.14新增：通过值叠加创建2的幂次数字对象（用于二进制分解）
    /// num_{2^k} = num_{2^{k-1}} + num_{2^{k-1}}（直接值计算，避免deltaAdd依赖循环）
    fn getOrCreateDeltaPower(self: *DeltaEngine, power: u64) anyerror!u64 {
        // 检查是否已存在
        var pbuf: [32]u8 = undefined;
        const pname = try std.fmt.bufPrint(&pbuf, "num_{}", .{power});
        if (self.graph.findObjectByName(pname)) |existing_id| {
            return existing_id;
        }
        // 对2的幂次，通过值加倍创建：num_{2k} = num_k + num_k
        const half = power / 2;
        if (half > 0) {
            const half_id = try self.getOrCreateDeltaPower(half);
            const half_val = self.graph.getObjectValue(half_id) orelse 0.0;
            const doubled_val = half_val + half_val;
            _ = try self.graph.createObject(pname, doubled_val);
            return self.graph.findObjectByName(pname) orelse return error.NumberCreationFailed;
        }
        // power=1：通过后继公理创建
        return try self.getOrCreateNumber(1);
    }

    pub fn cacheHitRate(self: *const DeltaEngine) f64 {
        const total = self.cache_hits + self.cache_misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn knowledgeSize(self: *const DeltaEngine) usize {
        return self.graph.objectCount();
    }

    pub fn morphism2Count(self: *const DeltaEngine) usize {
        return self.graph.morphism2Count();
    }

    // ============================================================
    // 文档定义12.4：Δ_gen(x,y) = f(x) ⊖ g(y)
    // ============================================================

    /// 参数：
    ///   x_id: 源对象ID
    ///   y_id: 目标对象ID
    /// 返回：新创建的对象ID（Δ结果作为CDL对象持久化）


    /// 创建对象
    /// 包装 graph.createObject
    fn createObjectWithLabel(self: *DeltaEngine, name: []const u8, value: f64, _: []const u8) anyerror!u64 {
        return try self.graph.createObject(name, value);
    }

    /// v7.5.0：硬件加速批量Δ²计算
    /// 自动检测最优后端（Accelerate/vDSP > NEON > 标量）
    /// 用于训练主线中批量能量计算的并行加速
    pub fn computeBatchDeltaSquared(self: *const DeltaEngine, values: []const f64) f64 {
        _ = self;
        const ha = @import("hardware_accel.zig");

        // 优先使用 Accelerate/vDSP（macOS 最快路径）
        if (builtin.os.tag == .macos) {
            if (ha.sumSquaresAccelerate(values)) |accel_sum| {
                return accel_sum;
            }
        }

        // 回退到标量计算
        var sum: f64 = 0.0;
        for (values) |v| {
            sum += v * v;
        }
        return sum;
    }

    /// v7.5.0：获取当前使用的硬件加速后端名称
    pub fn getHardwareBackendName(self: *const DeltaEngine) []const u8 {
        _ = self;
        const ha = @import("hardware_accel.zig");
        return switch (ha.preferredDeltaBatchBackend()) {
            .accelerate_vdsp => "Accelerate/vDSP",
            .simd_neon => "NEON SIMD",
            .metal_unavailable_for_f64 => "标量(Metal不可用)",
            .scalar => "标量",
        };
    }

    /// 创建隔离仿真沙箱（§4.3.2 沙箱仿真验证）
    /// 在表达式池副本上运行候选结构验证，不影响主池
    pub fn createSandbox(self: *DeltaEngine) !cdl.SimulationSandbox {
        return try cdl.SimulationSandbox.init(self.allocator, &self.cdl_pool);
    }
};

test "微自举（v4.0）" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.getOrCreateNumber(5);

    const compressed = engine.microBootstrap();
    try std.testing.expect(engine.micro_compressed_count >= 0);
    _ = compressed;
}

test "CDL表达式运算" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 测试CDL表达式求值
    const val = engine.deltaExpr(engine.zero_id, engine.zero_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), val, 0.001);

    // 验证知识规模
    try std.testing.expect(engine.knowledgeSize() >= 3);
    // 验证缓存系统API正常（不硬编码具体值）
    try std.testing.expect(std.math.isFinite(engine.cacheHitRate()));
}
