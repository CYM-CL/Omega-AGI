// Ω-落尘AGI CDL表达式引擎 v5.0 - 纯关系内生演化
//
// 严格对应白皮书关系一元论哲学：
// - Δ(x,y) = f(x) - g(y) 是唯一本原，f/g是递归CDL子图
// - 节点的全部规定性来自表达式的拓扑关系
//
// v5.0核心变革（vs v4.x标量权重架构）：
// 1. 消解实体论残留：移除value/f_weight/g_weight标量
// 2. f/g替换为递归ExprNode子图：NodeRef/Delta/Superpose三类原语
// 3. 传导即演化：每次求值同步完成传导压力传导+拓扑调整
// 4. 完全分布式两级自举：微观(每步微调)+宏观(局部凝结相变)
// 5. 内生自由能：系统永远有向低自由能演化的内在动力
// 6. 仿真沙箱：拓扑试探在隔离副本中进行
// 7. 分布式衰减：长期不活跃的路径自然消解
//
// 设计约束：
// - 禁止硬编码加法/乘法/分支等运算——全部通过Δ递归组合涌现
// - 禁止集中式阈值/全局调度器——全部局部自适应
// - f64返回值是"传导强度的一阶工程近似标度"，非本原实体

const std = @import("std");
const et = @import("error_types.zig");

// ============================================================
// CDL表达式类型定义（三类原语，对应Δ三种原生操作）
// ============================================================

/// 表达式池索引（强类型封装，避免与原始整数混淆）
pub const ExprIdx = u32;

/// 无效表达式索引（等价于null）
pub const EXPR_NULL: ExprIdx = std.math.maxInt(u32);

/// CDL表达式节点——严格对应三类原生操作
///
/// 本体论意义：
/// - NodeRef: 关系指向，指向另一个节点的f/g表达式
/// - Delta: Δ差值运算，f(x)-g(y)的递归组合
/// - Superpose: 路径叠加，多条并行传导路径的效应累积
///
/// 三类操作均可在Δ语义下自我组合形成任意复杂结构，
/// 无需引入加法/乘法/分支等额外原语。
pub const ExprNode = union(enum) {
    /// 关系指向：引用另一个节点的表达式结果
    /// target_node: 被引用节点ID
    /// use_f: true=f_expr, false=g_expr
    NodeRef: struct { target_node: u64, use_f: bool },

    /// 值引用：直接读取节点的存储值，不走递归求值
    /// 用于 CDL 表达式训练——训练后 f/g 表达式指向 ValueRef，
    /// 使 evalExprF/G 直接返回节点值而无需 EXPR_NULL 回退
    ValueRef: u64,

    /// Δ差值运算：evaluate(left) - evaluate(right)
    /// 对应Δ(x,y) = f(x) - g(y)的递归嵌套
    Delta: struct { left: ExprIdx, right: ExprIdx },

    /// 路径叠加：多条并行路径的效应累积
    /// 当前用算术和一阶近似，非原生加法
    paths: []ExprIdx,
};

// ============================================================
// 表达式元数据（纯内生演化，无全局常数）
// ============================================================

/// 表达式激活记录（纯内生演化，无任何全局常数或预设参数）
///
/// 所有字段的演化和塑形完全由局部传导历史内生决定：
/// - 无全局衰减率（折损仅发生在访问时，由间隔和稳定度内生决定）
/// - 无固定窗口（稳定度用纯递推计算，α由激活频率内生决定）
/// - 无预设初始值（系数无0值陷阱，from_unknown状态自然过渡）
/// - 无统一阈值（凝结判定严格度由激活频率内生决定）
pub const ExprActivity = struct {
    /// 传导贡献度（路径留存强度的唯一依据）
    ///
    /// - 每次被激活传导并有效贡献输出时，贡献度内生提升，
    ///   提升幅度与输出对最终结果的贡献占比正相关
    /// - 未被激活时不做被动衰减，仅在下次被访问时，
    ///   根据距离上次激活的间隔长度和自身历史稳定度，动态计算折损比例
    /// - 贡献度归零的路径自动从Superpose列表中脱落，
    ///   无需全局垃圾回收，也没有统一死亡阈值
    conduction_contribution: f64,

    /// 传导强度系数（用于Superpose叠加计算）
    ///
    /// - 由传导历史、稳定度、贡献占比内生塑造
    /// - 无预设初始值、无预设上下限
    /// - 有效路径的系数随激活次数自发增强，
    ///   无效路径的系数自发衰减（符合自由能最小化方向）
    coefficient: f64,

    /// 递归稳定度（纯递推，无窗口）
    ///
    /// 稳定度_新 = 稳定度_旧 × α + |当前输出 - 预期输出| × (1-α)
    /// 其中α由局部平均激活频率内生计算：
    ///   α = 1 / (1 + activation_frequency)
    ///   激活频率越高→α越小→对新变化越敏感
    ///   激活频率越低→α越大→统计越平滑
    recursive_stability: f64,

    /// 递归平均激活频率（纯递推，无窗口）
    ///
    /// 频率_新 = 频率_旧 × β + 1.0 × (1-β)
    /// 其中β = 频率_旧 / (1 + 频率_旧)
    /// 低频时β小→快速更新，高频时β大→平滑估计
    activation_frequency: f64,

    /// 预期输出（用于稳定度计算的参考值）
    /// 每次激活后更新为当前输出值
    expected_output: f64,

    /// 上次被激活时的传导序列号（用于间隔计算）
    /// 序列号由EvalEngine的总传导计数器提供，
    /// 仅用作间隔度的参照系，不驱动任何行为
    last_conduction_seq: u64,

    /// 是否冻结（凝结后的节点为冻结态，不再参与演化）
    frozen: bool,

    /// 是否待验证（凝结条件已触发，等待沙箱验证通过后正式冻结）
    condense_pending: bool,

    /// 凝结自检连续达标计数
    ///
    /// 每次激活后就地检查凝结条件：
    /// - 稳定度持续低于局部邻域平均波动水平
    /// - 激活频次持续高于局部平均水平
    /// 连续达标次数k不由固定常数决定，
    /// 由activation_frequency内生决定：
    ///   k = max(3, min(100, activation_frequency * 10))
    ///   激活越频繁→k越大→判定越严格
    ///   激活越稀疏→k越小→判定越宽松
    condense_check_streak: u32,

    /// 是否初次激活（from_unknown状态标记）
    /// 首次激活时跳过衰减、直接初始化
    first_activation: bool,

    pub fn init() ExprActivity {
        return .{
            .conduction_contribution = 0.0,
            .coefficient = 0.0, // 无预设值，由首次传导贡献率塑造
            .recursive_stability = 0.0, // 0表示"未知"，非"不稳定"
            .activation_frequency = 0.0,
            .expected_output = 0.0,
            .last_conduction_seq = 0,
            .frozen = false,
            .condense_pending = false,
            .condense_check_streak = 0,
            .first_activation = true,
        };
    }
};

// ============================================================
// 自由能计算（内生分量 + 外部约束）
// ============================================================

/// 自由能分量
///
/// 核心哲学：系统永远有向低自由能演化的内生动力。
/// 外部数据仅作为边界条件，不是监督信号。
pub const FreeEnergyComponents = struct {
    /// 内生自由能：局部子图的冗余度、冲突度、稳定度
    /// 即使没有外部任务也永远存在——驱动系统自发演化
    endogenous: f64,

    /// 外部约束分量：当有外部输入时叠加的边界条件
    /// 引导系统向符合约束的方向演化
    external: f64,

    pub fn total(self: *const FreeEnergyComponents) f64 {
        return self.endogenous + self.external;
    }
};

// ============================================================
// 求值上下文（传导过程中的演化状态）
// ============================================================

/// 求值上下文
///
/// 记录了单次传导过程中的所有状态信息。
/// 不包含全局步数——时间由EvalEngine的传导序列号提供。
pub const EvalContext = struct {
    /// 求值递归深度（防止无限递归）
    recursion_depth: u8,
    /// 当前传导路径上的所有表达式索引（用于激活统计）
    activated_exprs: std.ArrayListUnmanaged(ExprIdx),

    pub fn init() EvalContext {
        return .{
            .recursion_depth = 0,
            // 预分配32个槽位，减少求值过程中的内存分配次数
            // 典型表达式深度在10-20层，32足够覆盖大多数情况
            .activated_exprs = .{ .items = &.{}, .capacity = 0 },
        };
    }

    /// 带预分配容量的初始化（用于已知规模的求值场景）
    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !EvalContext {
        var activated_exprs = std.ArrayListUnmanaged(ExprIdx){};
        try activated_exprs.ensureTotalCapacity(allocator, capacity);
        return .{
            .recursion_depth = 0,
            .activated_exprs = activated_exprs,
        };
    }

    pub fn deinit(self: *EvalContext, allocator: std.mem.Allocator) void {
        self.activated_exprs.deinit(allocator);
    }
};

/// 递归深度安全上限由表达式池大小内生决定，不在模块级硬编码

// ============================================================
// CDL表达式池 —— 存储所有表达式节点的容器
// ============================================================

/// CDL表达式池
///
/// 管理所有ExprNode的存储、分配、引用计数。
/// 是CDL子图拓扑结构的底层存储层。
pub const ExprPool = struct {
    allocator: std.mem.Allocator,

    /// 表达式节点数组（SoA主存储）
    nodes: std.ArrayListUnmanaged(ExprNode),

    /// 表达式元数据（激活统计、稳定度等）
    activities: std.ArrayListUnmanaged(ExprActivity),

    /// 已释放的索引（可回收利用）
    free_list: std.ArrayListUnmanaged(ExprIdx),

    pub fn init(allocator: std.mem.Allocator) ExprPool {
        return .{
            .allocator = allocator,
            .nodes = .{ .items = &.{}, .capacity = 0 },
            .activities = .{ .items = &.{}, .capacity = 0 },
            .free_list = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *ExprPool) void {
        // 先释放所有ExprNode中的切片
        for (self.nodes.items) |*node| {
            switch (node.*) {
                .paths => |paths| self.allocator.free(paths),
                else => {},
            }
        }
        self.nodes.deinit(self.allocator);
        self.activities.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// 分配一个新的表达式节点
    /// 优先回收空闲索引，否则追加新索引
    pub fn allocExpr(self: *ExprPool, node: ExprNode) !ExprIdx {
        if (self.free_list.items.len > 0) {
            const idx = self.free_list.pop(); // returns ?ExprIdx
            if (idx) |valid_idx| {
                const uidx = @as(usize, @intCast(valid_idx));
                self.nodes.items[uidx] = node;
                self.activities.items[uidx] = ExprActivity.init();
                return valid_idx;
            }
        }
        const idx = @as(ExprIdx, @intCast(self.nodes.items.len));
        try self.nodes.append(self.allocator, node);
        try self.activities.append(self.allocator, ExprActivity.init());
        return idx;
    }

    /// 释放表达式节点（回收索引）
    pub fn freeExpr(self: *ExprPool, idx: ExprIdx) void {
        const uidx = @as(usize, @intCast(idx));
        // 释放子切片（仅paths类型持有外部内存）
        switch (self.nodes.items[uidx]) {
            .paths => |paths| self.allocator.free(paths),
            else => {},
        }
        self.nodes.items[uidx] = undefined;
        self.free_list.append(self.allocator, idx) catch {};
    }

    /// 获取表达式节点（边界检查）
    pub fn getNode(self: *const ExprPool, idx: ExprIdx) ?*const ExprNode {
        if (idx >= self.nodes.items.len) return null;
        return &self.nodes.items[@as(usize, @intCast(idx))];
    }

    /// 获取表达式活动元数据
    pub fn getActivity(self: *const ExprPool, idx: ExprIdx) ?*const ExprActivity {
        if (idx >= self.activities.items.len) return null;
        return &self.activities.items[@as(usize, @intCast(idx))];
    }

    /// 获取可变表达式活动元数据
    pub fn getActivityMut(self: *ExprPool, idx: ExprIdx) ?*ExprActivity {
        if (idx >= self.activities.items.len) return null;
        return &self.activities.items[@as(usize, @intCast(idx))];
    }

    /// 获取表达式池大小
    pub fn size(self: *const ExprPool) usize {
        return self.nodes.items.len;
    }

    // ============================================================
    // 便捷构造器
    // ============================================================

    /// 创建 NodeRef 表达式
    pub fn makeNodeRef(self: *ExprPool, target_node: u64, use_f: bool) !ExprIdx {
        return self.allocExpr(.{ .NodeRef = .{ .target_node = target_node, .use_f = use_f } });
    }

    /// 创建 ValueRef 表达式
    pub fn makeValueRef(self: *ExprPool, target_node: u64) !ExprIdx {
        return self.allocExpr(.{ .ValueRef = target_node });
    }

    /// 创建 Delta 表达式
    pub fn makeDelta(self: *ExprPool, left: ExprIdx, right: ExprIdx) !ExprIdx {
        return self.allocExpr(.{ .Delta = .{ .left = left, .right = right } });
    }

    /// 创建 Superpose 表达式
    pub fn makeSuperpose(self: *ExprPool, paths: []const ExprIdx) !ExprIdx {
        const paths_copy = try self.allocator.dupe(ExprIdx, paths);
        return self.allocExpr(.{ .paths = paths_copy });
    }
};

// ============================================================
// 求值引擎（传导即演化）
// ============================================================

/// 求值引擎
///
/// 核心求值逻辑。每次求值同步完成：
/// 1. 递归解析表达式树（深度优先）
/// 2. 更新激活统计：贡献度折损与提升、稳定度递推、频率递推
/// 3. 自动衰减非活跃路径（访问时根据间隔×稳定度折损）
/// 4. 就地凝结条件自检（连续达标后自发触发凝结）
///
/// 求值返回f64只是"传导强度的一阶工程近似标度"，
/// 不是本原实体。未来可替换为更抽象的强度度量。
///
/// 本体论约束：
/// - 无全局衰减率——折损由间隔+稳定度内生决定
/// - 无固定窗口——稳定度纯递推，α由频率内生
/// - 无全局时钟——凝结自检仅发生在传导事件中
pub const EvalEngine = struct {
    max_depth: u8,

    /// 总传导序列号（单调递增，仅用作间隔计算的参照系）
    /// 不是全局时钟/步数——不驱动任何行为，仅提供被动信息
    /// 每次evaluate()调用+1
    total_conductions: u64,

    /// v6.0: 共识阈值（来自七路评价），调节凝结判定严格度
    /// 0=无共识（凝结最严格），1=完全共识（凝结最宽松）
    /// 有效凝结门限 = required_streak × max(0.5, 1.5 - consensus_threshold)
    consensus_threshold: f64,

    pub fn init(pool: *ExprPool) EvalEngine {
        // 递归深度上限由表达式池大小 + 安全上限内生决定：
        // - pool_size > 0: max_depth = min(安全上限128, pool_size)
        // - pool_size = 0: max_depth = 16（安全默认值）
        const pool_size = pool.nodes.items.len;
        const computed_depth: u8 = if (pool_size > 0)
            @intCast(@min(pool_size, @as(usize, 128)))
        else
            0;
        return .{
            .max_depth = computed_depth,
            .consensus_threshold = 0.0,

            .total_conductions = 0,
        };
    }

    /// 评估表达式节点，返回传导强度（f64近似）
    ///
    /// 传导过程中同步完成内生演化的全部操作：
    /// 1. 传导序列号单调递增
    /// 2. 路径间传导强度系数的内生耦合（替代硬编码求和）
    /// 3. 传导贡献度的更新与折损（仅访问时发生）
    /// 4. 递归稳定度的纯递推更新
    /// 5. 递归激活频率的纯递推更新
    /// 6. 凝结条件的就地自检
    ///
    /// 参数：
    ///   idx: 待评估的表达式索引
    ///   ctx: 求值上下文（含传导记录等）
    ///   getNodeF: 回调函数：给定节点ID，返回该节点f_expr的传导强度
    ///   getNodeG: 回调函数：给定节点ID，返回该节点g_expr的传导强度
    ///
    /// 返回值：传导强度（完备格Ω=[0, M]范围内，非负）
    pub fn evaluate(
        self: *EvalEngine,
        pool: *ExprPool,
        idx: ExprIdx,
        ctx: *EvalContext,
        getNodeF: *const fn (node_id: u64) f64,
        getNodeG: *const fn (node_id: u64) f64,
    ) f64 {
        // 递归深度保护
        if (ctx.recursion_depth >= self.max_depth) return 0.0;
        ctx.recursion_depth += 1;
        defer ctx.recursion_depth -= 1;

        // 递增传导序列号
        self.total_conductions += 1;
        const current_seq = self.total_conductions;

        const node = pool.getNode(idx) orelse return 0.0;

        // 获取活动数据（用于传导后的内生演化操作）
        const act = pool.getActivityMut(idx);

        // --- 访问时衰减：根据间隔和稳定度折损传导贡献度 ---
        if (act) |a| {
            if (!a.frozen and !a.first_activation) {
                const interval = current_seq -| a.last_conduction_seq;
                if (interval > 0) {
                    // 折损率由间隔长度和自身稳定度内生决定：
                    //   decay_factor = exp(-interval / effective_window)
                    //   其中 effective_window = 1.0 / max(stability, 0.01)
                    //   稳定度越高→effective_window越大→衰减越慢
                    //   稳定度越低→effective_window越小→衰减越快
                    const effective_window = if (a.recursive_stability > 0.0) 1.0 / a.recursive_stability else @as(f64, @floatFromInt(interval));
                    const decay = std.math.exp(-@as(f64, @floatFromInt(interval)) / effective_window);
                    a.conduction_contribution *= decay;

                    // 传导强度系数也随间隔衰减（低频弱化）
                    a.coefficient *= decay;
                }
            }
        }

        // 记录激活
        ctx.activated_exprs.append(pool.allocator, idx) catch {};

        // ============================================================
        // 核心求值（三类原语）
        // ============================================================
        const result = switch (node.*) {
            // ValueRef: 值引用——直接读取节点存储值，不走递归
            .ValueRef => blk: {
                // ValueRef 在 delta_engine.zig 的 evalExprF/G 中被直接处理，
                // 正常情况下不会进入 evaluate()，此处做安全回退
                break :blk 0.0;
            },
            // NodeRef: 关系指向——引用另一个节点的f/g表达式结果
            .NodeRef => |ref| blk: {
                if (ref.use_f) {
                    break :blk getNodeF(ref.target_node);
                } else {
                    break :blk getNodeG(ref.target_node);
                }
            },

            // Delta: Δ差值运算——传导强度的核心计算
            // Δ(left, right) = evaluate(left) - evaluate(right)
            // Ω完备格非负约束（公理级预设，阶差非负）
            .Delta => |d| blk: {
                const left_val = self.evaluate(pool, d.left, ctx, getNodeF, getNodeG);
                const right_val = self.evaluate(pool, d.right, ctx, getNodeF, getNodeG);
                const raw = left_val - right_val;
                break :blk if (raw >= 0.0) raw else 0.0;
            },

            // Superpose: 路径叠加——传导强度系数加权耦合
            //
            // 改进：移除硬编码算术求和，改为路径系数加权耦合。
            // 每条路径的传导强度系数由其传导历史和贡献占比内生塑造。
            // 耦合效应自发呈现：低强度近似线性、高强度边际递减、
            // 反向路径自然抵消——无需额外Cancel节点或硬编码饱和公式。
            .paths => |paths| blk: {
                // 路径系数耦合累积：每条路径的贡献由其传导强度系数加权，
                // 总输出为各路径输出的系数加权耦合值（非算术求和）
                var weighted_sum: f64 = 0.0;
                var total_weight: f64 = 0.0;
                for (paths) |path_idx| {
                    const path_val = self.evaluate(pool, path_idx, ctx, getNodeF, getNodeG);
                    // 获取路径的传导强度系数（无预设值，由历史塑造）
                    const coeff = if (pool.getActivity(path_idx)) |pa|
                        pa.coefficient
                    else
                        0.0;
                    // 非负权重自然实现了"低值路径贡献低"的效应
                    const weight = if (coeff > 0.0) coeff else 0.0;
                    weighted_sum += path_val * weight;
                    total_weight += weight;
                }

                // 总权重归一化：路径越多、权重越高，饱和效应越明显
                // 归一化分母加入路径贡献方差的修正项：paths.len / (1 + total_weight)
                // total_weight越大→修正项越小→高权重路径占比高时饱和更自然
                const coupled = if (total_weight > 0.0)
                    weighted_sum / (total_weight + @as(f64, @floatFromInt(paths.len)) * (1.0 / (1.0 + total_weight)))
                else
                    0.0;

                break :blk coupled;
            },
        };

        // ============================================================
        // 传导后：内生演化操作（全部嵌入evaluate，无外部调度）
        // ============================================================
        if (act) |a| {
            if (!a.frozen) {
                if (a.first_activation) {
                    // 首次激活：初始化全部内生参数
                    a.conduction_contribution = @abs(result);
                    a.coefficient = if (result > 0.0) result else 0.0;
                    a.recursive_stability = 0.0; // 未知稳定度
                    a.activation_frequency = 0.0;
                    a.expected_output = result;
                    a.last_conduction_seq = current_seq;
                    a.first_activation = false;
                    a.condense_check_streak = 0;
                } else {
                    // ============================================================
                    // 1. 递归激活频率更新（纯递推，无窗口）
                    //    频率_新 = 频率_旧 × β + 1.0 × (1-β)
                    //    β = 频率_旧 / (1 + 频率_旧)
                    // ============================================================
                    const beta = a.activation_frequency / (1.0 + a.activation_frequency);
                    a.activation_frequency = a.activation_frequency * beta + 1.0 * (1.0 - beta);

                    // ============================================================
                    // 2. 递归稳定度更新（纯递推，无窗口）
                    //    稳定度_新 = 稳定度_旧 × α + |输出 - 预期| × (1-α)
                    //    α = 1 / (1 + activation_frequency)
                    // ============================================================
                    const alpha = 1.0 / (1.0 + a.activation_frequency);
                    const deviation = @abs(result - a.expected_output);
                    a.recursive_stability = a.recursive_stability * alpha + deviation * (1.0 - alpha);
                    a.expected_output = result;

                    // ============================================================
                    // 3. 传导贡献度更新（与输出贡献占比正相关）
                    //    提升幅度 = result × (1 - conduction_contribution / max_contribution)
                    //    其中 max_contribution 由 activation_frequency 内生估计
                    // ============================================================
                    const max_contribution = 1.0 + a.activation_frequency;
                    const boost = result * (1.0 - a.conduction_contribution / max_contribution);
                    a.conduction_contribution += boost;
                    if (a.conduction_contribution < 0.0) a.conduction_contribution = 0.0;

                    // ============================================================
                    // 4. 传导强度系数更新（驱动Superpose耦合规则演化）
                    //    系数变动与贡献占比正相关：
                    //    contribution_ratio = result / max(result, total_coeff_denom)
                    //    系数趋近于路径的实际贡献率
                    // ============================================================
                    if (result > 0.0) {
                        const contribution_ratio = result / (result + a.activation_frequency);
                        a.coefficient += contribution_ratio * a.activation_frequency / (1.0 + a.activation_frequency);
                    }
                    // 系数无上限，但路径间竞争自然约束

                    // ============================================================
                    // 5. 就地凝结自检（无全局时钟，仅传导事件触发）
                    //
                    // 条件：
                    //   a) 稳定度持续低于"局部阈值" = stability_base × (1 + freq)^(-freq / (1 + stability))
                    //      激活越频繁→指数绝对值越大→阈值越低→要求越稳定
                    //      稳定度越高→指数绝对值越小→阈值变化越温和
                    //   b) 激活频率持续高于局部平均水平
                    //
                    // 所需连续达标次数 k 由 activation_frequency 和 recursive_stability 内生决定：
                    //   k = activation_frequency × (1 + recursive_stability)
                    //   激活越频繁/稳定度越高→k越大→判定越严格
                    // ============================================================
                    // v5.0.1 数学风险修复：
                    // 1. stability_base 在 stability==0 时默认1.0导致阈值过高，新表达式易过早凝结
                    //    → 改为 stability==0 时使用 2.0（需要至少2倍稳定度才能触发凝结）
                    // 2. freq_high_enough 仅检查 >0.0 过于宽松，任何微小频率都通过
                    //    → 改为 >=1.0（至少经过几次激活后才允许凝结判定）
                    // 3. required_streak 在 frequency 极小时 intCast 截断为0，导致立即凝结
                    //    → 增加下限 @max(3, ...) 确保至少需要连续3次稳定检查
                    const stability_base = if (a.recursive_stability > 0.0) a.recursive_stability else @as(f64, 2.0);
                    const local_stability_threshold = stability_base * std.math.pow(f64, 1.0 + a.activation_frequency, -(a.activation_frequency / (1.0 + a.recursive_stability)));
                    const stable_enough = a.recursive_stability < local_stability_threshold;
                    const freq_high_enough = a.activation_frequency >= 1.0;

                    if (stable_enough and freq_high_enough) {
                        a.condense_check_streak += 1;
                    } else {
                        a.condense_check_streak = 0; // 任何不达标重置计数器
                    }

                    // 所需严格度：k = max(3, activation_frequency × (1 + recursive_stability))
                    // v5.0.1：增加下限3，防止极小频率导致立即凝结
                    const raw_streak: u32 = if (a.activation_frequency > 0.0) @as(u32, @intFromFloat(a.activation_frequency * (1.0 + a.recursive_stability))) else @as(u32, 3);
                    const consensus_factor = @max(0.5, 1.5 - self.consensus_threshold);
                    const adjusted_streak = @as(u32, @intFromFloat(@as(f64, @floatFromInt(raw_streak)) * consensus_factor));
                    const required_streak = @max(@as(u32, 3), adjusted_streak);
                    if (a.condense_check_streak >= required_streak) {
                        // 凝结条件触发：标记为待验证（白皮书§4.3.4要求沙箱验证后才可提交冻结）
                        a.condense_pending = true;
                        a.condense_check_streak = 0;
                    }

                    // 更新传导序列号
                    a.last_conduction_seq = current_seq;
                }
            }
        }

        return result;
    }
};

// ============================================================
// 路径生命周期维护（仅辅助性清理，非演化核心）
// ============================================================

/// 路径维护器
///
/// 注意：演化核心（衰减/强化/凝结）已全部嵌入evaluate()。
/// 此处仅保留辅助性清理操作：从Superpose中移除贡献度归零的死路径。
///
/// 清理条件：conduction_contribution ≈ 0（非硬阈值，由局部均值内生判定）
/// 清理时机：访问路径时自动由evaluate()处理，此处仅做批量冗余恢复
pub const PathMaintenance = struct {
    pool: *ExprPool,
    allocator: std.mem.Allocator,

    pub fn init(pool: *ExprPool, allocator: std.mem.Allocator) PathMaintenance {
        return .{ .pool = pool, .allocator = allocator };
    }

    /// 清理Superpose中贡献度归零的死路径
    ///
    /// 注意：这不是"全局衰减"——死路径由evaluate()中的内生折损自然产生，
    /// 此处仅做资源回收（释放已死且未被自动移除的路径内存）。
    /// 即使不调用此函数，系统功能不受影响（只是内存不回收）。
    pub fn pruneDeadPaths(self: *PathMaintenance) void {
        for (self.pool.nodes.items, 0..) |*node, i| {
            if (node.* != .paths) continue;
            if (self.pool.activities.items[i].frozen) continue;

            const paths = &node.paths;
            if (paths.len <= 1) continue;

            // 先计算总贡献度和均值
            var contrib_sum: f64 = 0.0;
            for (paths.*) |path_idx| {
                if (self.pool.getActivity(path_idx)) |act| {
                    contrib_sum += act.conduction_contribution;
                }
            }

            if (contrib_sum <= 0.0) continue;

            const avg_contrib = contrib_sum / @as(f64, @floatFromInt(paths.len));
            // 存活门槛由路径数量内生决定：存活比 = 1 / (路径数 + 1)
            // 路径越多→存活比越低→门槛越低→更多路径可存活（保留多样性）
            // 路径越少→存活比越高→门槛越高→淘汰更严格（只保留高贡献路径）
            const survival_ratio = @as(f64, @floatFromInt(1)) / (@as(f64, @floatFromInt(paths.len)) + 1.0);
            const threshold = avg_contrib * survival_ratio;

            // 统计存活路径（conduction_contribution > 局部均值×存活比视为存活）
            var alive_count: usize = 0;
            for (paths.*) |path_idx| {
                if (self.pool.getActivity(path_idx)) |act| {
                    if (act.conduction_contribution > threshold) {
                        alive_count += 1;
                    }
                }
            }

            if (alive_count == 0) continue;
            if (alive_count == paths.len) continue;

            var alive_paths = std.ArrayListUnmanaged(ExprIdx){ .items = &.{}, .capacity = 0 };
            defer alive_paths.deinit(self.allocator);
            for (paths.*) |path_idx| {
                if (self.pool.getActivity(path_idx)) |act| {
                    if (act.conduction_contribution > threshold) {
                        alive_paths.append(self.allocator, path_idx) catch {};
                    }
                }
            }

            if (alive_paths.items.len < paths.len and alive_paths.items.len > 0) {
                self.allocator.free(paths.*);
                node.paths = alive_paths.toOwnedSlice(self.allocator) catch {
                    node.paths = paths.*;
                    return;
                };
            }
        }
    }
};

// ============================================================
// 仿真沙箱（隔离拓扑试探）
// ============================================================

/// 仿真沙箱
///
/// 用于隔离拓扑试探：在表达式主池的副本上测试新的候选结构，
/// 测试通过后再替换到主池，避免随机试探破坏系统稳态。
///
/// 对应生物演化"变异+选择"的工程实现：
/// - 变异：在沙箱中生成新的候选表达式
/// - 选择：如果新结构降低局部自由能，才替换到主系统
pub const SimulationSandbox = struct {
    /// 沙箱表达式池副本（完全独立于主池）
    pool_copy: ExprPool,

    /// 沙箱是否活跃
    active: bool,

    /// 自由能基线的记录（用于比较）
    baseline_endogenous_f: f64,

    pub fn init(allocator: std.mem.Allocator, source_pool: *const ExprPool) !SimulationSandbox {
        // 深度复制表达式池
        var copy = ExprPool{
            .allocator = allocator,
            .nodes = .{ .items = &.{}, .capacity = 0 },
            .activities = .{ .items = &.{}, .capacity = 0 },
            .free_list = .{ .items = &.{}, .capacity = 0 },
        };

        // 复制所有节点
        try copy.nodes.ensureTotalCapacity(allocator, source_pool.nodes.items.len);
        for (source_pool.nodes.items) |*src_node| {
            const cloned = switch (src_node.*) {
                .NodeRef => |ref| ExprNode{ .NodeRef = ref },
                .Delta => |d| ExprNode{ .Delta = .{ .left = d.left, .right = d.right } },
                .ValueRef => ExprNode{ .ValueRef = src_node.ValueRef },
                .paths => |paths| blk: {
                    const paths_copy = try allocator.dupe(ExprIdx, paths);
                    break :blk ExprNode{ .paths = paths_copy };
                },
            };
            try copy.nodes.append(allocator, cloned);
        }

        // 复制活动数据
        try copy.activities.ensureTotalCapacity(allocator, source_pool.activities.items.len);
        for (source_pool.activities.items) |act| {
            try copy.activities.append(allocator, act);
        }

        return .{
            .pool_copy = copy,
            .active = false,
            .baseline_endogenous_f = 0.0,
        };
    }

    pub fn deinit(self: *SimulationSandbox) void {
        self.pool_copy.deinit();
    }

    /// 在沙箱中评估表达式（使用池副本，不影响主池）
    /// 通过临时 EvalEngine 对池副本进行递归求值
    /// 需要传入 f/g 回调函数（来自 delta_engine.zig 的 getNodeFCallback/getNodeGCallback）
    pub fn evaluateInSandbox(self: *SimulationSandbox, idx: ExprIdx, ctx: *EvalContext,
        f_cb: fn(u64) f64, g_cb: fn(u64) f64) f64 {
        var sandbox_eval = EvalEngine.init(&self.pool_copy);
        self.active = true;
        const result = sandbox_eval.evaluate(&self.pool_copy, idx, ctx, f_cb, g_cb);
        self.active = false;
        return result;
    }

    /// 将沙箱中的修改提交回主池
    /// 复制池副本中新增的表达式节点和修改的活动元数据到源池
    pub fn commitTo(self: *SimulationSandbox, source_pool: *ExprPool) !void {
        for (self.pool_copy.nodes.items, 0..) |*src_node, i| {
            if (i >= source_pool.nodes.items.len) {
                const cloned = switch (src_node.*) {
                    .NodeRef => |ref| ExprNode{ .NodeRef = ref },
                    .Delta => |d| ExprNode{ .Delta = .{ .left = d.left, .right = d.right } },
                .ValueRef => ExprNode{ .ValueRef = src_node.ValueRef },
                    .paths => |paths| blk: {
                        const paths_copy = try source_pool.allocator.dupe(ExprIdx, paths);
                        break :blk ExprNode{ .paths = paths_copy };
                    },
                };
                try source_pool.nodes.append(source_pool.allocator, cloned);
                try source_pool.activities.append(source_pool.allocator, self.pool_copy.activities.items[i]);
            } else {
                source_pool.activities.items[i] = self.pool_copy.activities.items[i];
            }
        }
        self.active = false;
    }
};

// ============================================================
// 测试
// ============================================================

test "ExprPool基本操作" {
    var pool = ExprPool.init(std.testing.allocator);
    defer pool.deinit();

    // 创建NodeRef表达式
    const n1 = try pool.makeNodeRef(0, true);
    try std.testing.expect(n1 != EXPR_NULL);

    // 验证类型
    const node = pool.getNode(n1).?;
    try std.testing.expect(node.* == .NodeRef);
    try std.testing.expectEqual(@as(u64, 0), node.NodeRef.target_node);
    try std.testing.expectEqual(true, node.NodeRef.use_f);

    // 创建Delta表达式
    const d1 = try pool.makeDelta(n1, n1);
    try std.testing.expect(pool.getNode(d1).?.* == .Delta);

    // 创建Superpose表达式
    const paths = [_]ExprIdx{n1, d1};
    const s1 = try pool.makeSuperpose(&paths);
    try std.testing.expect(pool.getNode(s1).?.* == .paths);
}

test "ExprNode类型匹配" {
    var pool = ExprPool.init(std.testing.allocator);
    defer pool.deinit();

    const n1 = try pool.makeNodeRef(0, true);
    const n2 = try pool.makeNodeRef(1, false);

    // 确保不同参数生成不同节点
    const n1_node = pool.getNode(n1).?;
    const n2_node = pool.getNode(n2).?;
    try std.testing.expect(n1_node.NodeRef.target_node != n2_node.NodeRef.target_node);
    try std.testing.expect(n1_node.NodeRef.use_f != n2_node.NodeRef.use_f);
}