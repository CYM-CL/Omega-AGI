// Ω-落尘AGI 五层解放架构 v4.0.4 - 文档第12章
//
// 严格对应白皮书v2.0第12章：
// - 12.2 五层解放架构定义
// - 12.4 可演化自由能（Layer 4参数自适应）
// - 12.5 广义尘算子（f,g扩展）
// - 12.6 元学习算子M
//
// 五层解放架构：
// Layer 1：绝对根基层（不可演化）- 存在性、差异本身、自指性
// Layer 2：公理扩展层（L5权限）- CDL公理扩展（只增不改）
// Layer 3：元算法演化层（L4权限）- 自由能形式、学习算法、f,g形式
// Layer 4：参数自适应层（L3权限）- α,β,γ权重自适应
// Layer 5：自由演化区（L1/L2权限）- 尘图拓扑、等价重写规则

const std = @import("std");

// ============================================================
// 五层解放枚举（文档12.2节）
// ============================================================

/// 五层解放层级定义
pub const LiberationLayer = enum(u8) {
    Layer1_AbsoluteFoundation = 0,  // 绝对根基层（不可演化）
    Layer2_AxiomExtension = 1,      // 公理扩展层（L5权限，人类终审）
    Layer3_MetaAlgorithm = 2,       // 元算法演化层（L4权限，沙箱热替换）
    Layer4_ParameterAdaptation = 3, // 参数自适应层（L3权限，自动调整）
    Layer5_FreeEvolution = 4,       // 自由演化区（L1/L2权限，自动）

    pub fn name(self: LiberationLayer) []const u8 {
        return switch (self) {
            .Layer1_AbsoluteFoundation => "Layer1:绝对根基(不可演化)",
            .Layer2_AxiomExtension => "Layer2:公理扩展(L5权限)",
            .Layer3_MetaAlgorithm => "Layer3:元算法演化(L4权限)",
            .Layer4_ParameterAdaptation => "Layer4:参数自适应(L3权限)",
            .Layer5_FreeEvolution => "Layer5:自由演化(L1/L2权限)",
        };
    }

    /// 是否可演化（文档12.2：Layer 1不可演化）
    pub fn isEvolvable(self: LiberationLayer) bool {
        return self != .Layer1_AbsoluteFoundation;
    }
};

// ============================================================
// 公理扩展提案（Layer 2，文档12.2节）
// ============================================================

/// 公理扩展提案类型
pub const AxiomExtensionType = enum(u8) {
    NewPrimitive = 0,       // 新原语引入
    FixedPointExtension = 1, // 不动点定义扩展
    CDLAxiomAddition = 2,   // CDL公理新增
};

/// 公理扩展提案（文档12.2：Layer 2公理扩展层）
/// 流程：系统发现需求 → 形式化表述 → 三工具一致性证明 → 沙箱验证 → 人类终审 → 社区审计 → 安装
pub const AxiomExtensionProposal = struct {
    proposal_id: u64,
    extension_type: AxiomExtensionType,
    formal_description: [256]u8,  // 形式化描述
    description_len: usize,
    consistency_proof_passed: bool,  // 三工具一致性证明
    sandbox_validated: bool,         // 沙箱验证
    human_approved: bool,            // 人类终审
    community_audited: bool,         // 社区审计
    installed: bool,                 // 已安装

    pub fn init(id: u64, ext_type: AxiomExtensionType) AxiomExtensionProposal {
        return .{
            .proposal_id = id,
            .extension_type = ext_type,
            .formal_description = [_]u8{0} ** 256,
            .description_len = 0,
            .consistency_proof_passed = false,
            .sandbox_validated = false,
            .human_approved = false,
            .community_audited = false,
            .installed = false,
        };
    }

    /// 设置形式化描述
    pub fn setDescription(self: *AxiomExtensionProposal, desc: []const u8) void {
        const len = @min(desc.len, 255);
        @memcpy(self.formal_description[0..len], desc[0..len]);
        self.description_len = len;
    }

    /// 检查是否可以安装（文档12.2：所有步骤必须通过）
    pub fn canInstall(self: *const AxiomExtensionProposal) bool {
        return self.consistency_proof_passed and
               self.sandbox_validated and
               self.human_approved and
               self.community_audited and
               !self.installed;
    }
};

// ============================================================
// 元算法演化提案（Layer 3，文档12.2节）
// ============================================================

/// 元算法演化类型
pub const MetaAlgorithmType = enum(u8) {
    FreeEnergyForm = 0,    // 自由能泛函F的形式
    LearningAlgorithm = 1, // 学习算法
    FGFormExtension = 2,   // f,g的"形式"扩展
    ValidationStrategy = 3, // 校验策略
};

/// 元算法演化提案（文档12.2：Layer 3元算法演化层）
/// 流程：沙箱构造 → 不变量验证 → 人类确认 → 热替换
pub const MetaAlgorithmProposal = struct {
    proposal_id: u64,
    algo_type: MetaAlgorithmType,
    invariant_validated: bool,  // 不变量验证
    human_confirmed: bool,      // 人类确认
    hot_swapped: bool,          // 已热替换

    pub fn init(id: u64, at: MetaAlgorithmType) MetaAlgorithmProposal {
        return .{
            .proposal_id = id,
            .algo_type = at,
            .invariant_validated = false,
            .human_confirmed = false,
            .hot_swapped = false,
        };
    }

    /// 检查是否可以热替换
    pub fn canHotSwap(self: *const MetaAlgorithmProposal) bool {
        return self.invariant_validated and
               self.human_confirmed and
               !self.hot_swapped;
    }
};

// ============================================================
// f,g广义扩展（文档12.5节定义12.4）
// ============================================================

/// 广义差值运算类型（文档12.5：⊖广义差值运算）
pub const GeneralizedDifferenceType = enum(u8) {
    RealSubtraction = 0,     // 实值减法（当前实现）
    SetDifference = 1,       // 集合差
    GraphDifference = 2,     // 图差
    CategoryDifference = 3,  // 范畴差
};

/// f,g权重函数类型（文档12.5：f,g形式可扩展）
pub const WeightFunctionType = enum(u8) {
    Linear = 0,              // 线性乘法 f(x) = f_weight * value（当前实现）
    Nonlinear = 1,           // 非线性映射
    SetBased = 2,            // 集合映射
    GraphBased = 3,          // 图映射
};

/// f,g形式扩展提案（文档12.5：广义尘算子Δ_gen）
pub const FGFormProposal = struct {
    proposal_id: u64,
    f_form: WeightFunctionType,  // f的新形式
    g_form: WeightFunctionType,  // g的新形式
    diff_type: GeneralizedDifferenceType,  // 广义差值类型
    invariant_validated: bool,
    human_confirmed: bool,
    hot_swapped: bool,

    pub fn init(id: u64) FGFormProposal {
        return .{
            .proposal_id = id,
            .f_form = .Linear,
            .g_form = .Linear,
            .diff_type = .RealSubtraction,
            .invariant_validated = false,
            .human_confirmed = false,
            .hot_swapped = false,
        };
    }
};

// ============================================================
// 元学习算子M（文档12.6节定义12.5）
// ============================================================

/// 元学习算子M（文档12.6：M(A) = argmin_{A' ∈ A_legal} F_meta(A')）
/// 定理12.4：n阶元学习可通过CDL自指嵌套实现
pub const MetaLearningOperator = struct {
    allocator: std.mem.Allocator,
    algorithm_history: std.ArrayList(AlgorithmSnapshot),
    best_algorithm_id: u64,
    best_f_meta: f64,
    proposal_counter: u64,

    /// 算法快照（将学习算法封装为可演化的CDL对象）
    pub const AlgorithmSnapshot = struct {
        id: u64,
        annealing_c: f64,        // 退火常数c
        learning_rate: f64,      // 学习率
        freeze_threshold: u64,   // 冻结阈值
        micro_bootstrap_threshold: f64,  // 微自举阈值
        macro_bootstrap_threshold: usize, // 宏自举阈值
        f_meta: f64,             // 该算法的元自由能
        timestamp: u64,
    };

    /// 退火上下文（v4.1.0 新增：修复退火常数无效问题）
    /// 基于温度、梯度、历史计算退火常数c
    pub const AnnealingContext = struct {
        temperature: f64,        // 当前温度（高温探索，低温利用）
        gradient: f64,           // F_meta梯度（负值表示下降方向）
        iteration: u64,          // 当前迭代次数
        target_c: f64,           // 目标c值（基于历史最优）
    };

    /// 退火结果（v4.1.0 新增）
    pub const AnnealingResult = struct {
        new_c: f64,              // 新的退火常数
        adjustment: f64,         // 调整量（new_c - old_c）
        reason: AnnealingReason, // 调整原因
    };

    /// 退火调整原因
    pub const AnnealingReason = enum(u8) {
        GradientDescent = 0,     // 梯度下降（F_meta下降）
        GradientAscent = 1,      // 梯度上升（F_meta上升，需探索）
        TemperatureDecay = 2,    // 温度衰减（收敛阶段）
        ExplorationBoost = 3,    // 探索增强（陷入局部最优）
        NoChange = 4,            // 无变化
    };

    pub fn init(allocator: std.mem.Allocator) MetaLearningOperator {
        return .{
            .allocator = allocator,
            .algorithm_history = std.ArrayList(AlgorithmSnapshot).empty,
            .best_algorithm_id = 0,
            .best_f_meta = std.math.inf(f64),
            .proposal_counter = 0,
        };
    }

    pub fn deinit(self: *MetaLearningOperator) void {
        self.algorithm_history.deinit(self.allocator);
    }

    /// 记录当前算法快照
    pub fn recordSnapshot(
        self: *MetaLearningOperator,
        annealing_c: f64,
        learning_rate: f64,
        freeze_threshold: u64,
        micro_threshold: f64,
        macro_threshold: usize,
        current_f_meta: f64,
    ) !void {
        self.proposal_counter += 1;
        const snapshot = AlgorithmSnapshot{
            .id = self.proposal_counter,
            .annealing_c = annealing_c,
            .learning_rate = learning_rate,
            .freeze_threshold = freeze_threshold,
            .micro_bootstrap_threshold = micro_threshold,
            .macro_bootstrap_threshold = macro_threshold,
            .f_meta = current_f_meta,
            .timestamp = @intCast(blk: {
                var ts: std.posix.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            }),
        };
        try self.algorithm_history.append(self.allocator, snapshot);

        // 更新最优算法（文档12.6：M(A) = argmin F_meta）
        if (current_f_meta < self.best_f_meta) {
            self.best_f_meta = current_f_meta;
            self.best_algorithm_id = snapshot.id;
        }

        // 限制历史长度（保留最近32个快照）
        if (self.algorithm_history.items.len > 32) {
            _ = self.algorithm_history.orderedRemove(0);
        }
    }

    /// 元学习算子M：基于历史最优算法生成改进建议
    /// 文档12.6：M(A) = A' where A' = argmin_{A' ∈ A_legal} F_meta(A')
    /// 定理12.4：n阶元学习通过CDL自指嵌套实现
    /// step参数：调整步长（默认0.1，可由外部传入动态学习率）
    pub fn optimize(self: *MetaLearningOperator, current: AlgorithmSnapshot, step: f64) ?AlgorithmSnapshot {
        if (self.algorithm_history.items.len < 2) return null;

        // 找到历史最优算法
        var best = self.algorithm_history.items[0];
        for (self.algorithm_history.items[1..]) |s| {
            if (s.f_meta < best.f_meta) {
                best = s;
            }
        }

        // 如果当前算法不是最优，向最优算法方向调整
        if (best.id != current.id and best.f_meta < current.f_meta) {
            // 简化策略：向最优算法参数做小步调整（步长由参数传入，支持动态学习）
            return AlgorithmSnapshot{
                .id = self.proposal_counter + 1,
                .annealing_c = current.annealing_c + (best.annealing_c - current.annealing_c) * step,
                .learning_rate = current.learning_rate + (best.learning_rate - current.learning_rate) * step,
                .freeze_threshold = current.freeze_threshold,  // 整数参数不插值
                .micro_bootstrap_threshold = current.micro_bootstrap_threshold + (best.micro_bootstrap_threshold - current.micro_bootstrap_threshold) * step,
                .macro_bootstrap_threshold = current.macro_bootstrap_threshold,  // 整数参数不插值
                .f_meta = std.math.inf(f64),  // 待评估
                .timestamp = @intCast(blk: {
                var ts: std.posix.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            }),
            };
        }
        return null;
    }

    /// 获取历史最优算法
    pub fn getBestAlgorithm(self: *const MetaLearningOperator) ?AlgorithmSnapshot {
        if (self.algorithm_history.items.len == 0) return null;
        for (self.algorithm_history.items) |s| {
            if (s.id == self.best_algorithm_id) return s;
        }
        return null;
    }

    /// 获取元学习统计
    pub fn getStats(self: *const MetaLearningOperator) struct { history_len: usize, best_f_meta: f64, best_id: u64 } {
        return .{
            .history_len = self.algorithm_history.items.len,
            .best_f_meta = self.best_f_meta,
            .best_id = self.best_algorithm_id,
        };
    }

    /// 基于退火上下文优化退火常数c（v4.1.0 新增）
    /// 修复历史问题：optimize() 在所有历史c相同时返回c=1.0（无效）
    ///
    /// 算法：
    /// 1. 基于梯度方向调整c：梯度下降时减小c（利用），梯度上升时增大c（探索）
    /// 2. 基于温度衰减：高温时c波动大，低温时c稳定
    /// 3. 基于历史最优：向历史最优c值靠拢
    /// 4. 基于迭代次数：后期迭代c趋于稳定
    ///
    /// 公式：c_new = c_old + α·(gradient_sign)·temperature + β·(target_c - c_old)·(1 - temperature)
    /// 其中 α=0.1（梯度学习率），β=0.3（历史牵引率）
    pub fn optimizeWithAnnealing(
        self: *const MetaLearningOperator,
        current_c: f64,
        context: AnnealingContext,
    ) AnnealingResult {
        // 边界保护：c必须在[0.01, 10.0]范围内
        const c_min: f64 = 0.01;
        const c_max: f64 = 10.0;

        // 历史不足时，仅基于温度和梯度调整
        if (self.algorithm_history.items.len < 2) {
            // 基于梯度方向调整
            const gradient_sign: f64 = if (context.gradient > 0) 1.0 else if (context.gradient < 0) -1.0 else 0.0;
            const alpha: f64 = 0.1;
            const temp_factor = context.temperature;
            const adjustment = alpha * gradient_sign * temp_factor;
            const new_c_raw = current_c + adjustment;
            const new_c = @max(c_min, @min(c_max, new_c_raw));

            const reason: AnnealingReason = if (context.gradient < 0)
                .GradientDescent
            else if (context.gradient > 0)
                .GradientAscent
            else
                .NoChange;

            return .{
                .new_c = new_c,
                .adjustment = new_c - current_c,
                .reason = reason,
            };
        }

        // 历史充足：结合梯度、温度、历史最优
        const alpha: f64 = 0.1;  // 梯度学习率
        const beta: f64 = 0.3;   // 历史牵引率

        // 梯度项：梯度下降时减小c（利用当前方向），梯度上升时增大c（探索新方向）
        const gradient_sign: f64 = if (context.gradient > 0) 1.0 else if (context.gradient < 0) -1.0 else 0.0;
        const gradient_term = alpha * gradient_sign * context.temperature;

        // 历史牵引项：向目标c靠拢，温度越低牵引越强
        const history_term = beta * (context.target_c - current_c) * (1.0 - context.temperature);

        // 综合调整
        const total_adjustment = gradient_term + history_term;
        const new_c_raw = current_c + total_adjustment;
        const new_c = @max(c_min, @min(c_max, new_c_raw));

        // 确定调整原因
        const reason: AnnealingReason = if (context.gradient < -0.001)
            .GradientDescent
        else if (context.gradient > 0.001)
            .GradientAscent
        else if (context.temperature < 0.3)
            .TemperatureDecay
        else if (@abs(total_adjustment) < 1e-6)
            .NoChange
        else
            .ExplorationBoost;

        return .{
            .new_c = new_c,
            .adjustment = new_c - current_c,
            .reason = reason,
        };
    }

    /// 计算历史平均c值（用于确定目标c）
    pub fn getAverageC(self: *const MetaLearningOperator) f64 {
        if (self.algorithm_history.items.len == 0) return 1.0;
        var sum: f64 = 0.0;
        for (self.algorithm_history.items) |s| {
            sum += s.annealing_c;
        }
        return sum / @as(f64, @floatFromInt(self.algorithm_history.items.len));
    }

    /// 获取历史最优c值
    pub fn getBestC(self: *const MetaLearningOperator) f64 {
        if (self.algorithm_history.items.len == 0) return 1.0;
        var best = self.algorithm_history.items[0];
        for (self.algorithm_history.items[1..]) |s| {
            if (s.f_meta < best.f_meta) {
                best = s;
            }
        }
        return best.annealing_c;
    }
};

// ============================================================
// 解放层管理器（统一管理五层解放）
// ============================================================

/// 解放层管理器（文档12.2：五层解放架构统一管理）
pub const LiberationManager = struct {
    axiom_proposals: std.ArrayList(AxiomExtensionProposal),
    meta_algo_proposals: std.ArrayList(MetaAlgorithmProposal),
    fg_form_proposals: std.ArrayList(FGFormProposal),
    meta_learning: MetaLearningOperator,
    proposal_counter: u64,
    allocator: std.mem.Allocator,

    // === 动态学习参数（从0开始学习）===
    learning_rate: f64 = 0.05,          // 学习率
    // 系统能力成熟度（基于解放成功/失败经验学习，∈[0,1]）
    capability_maturity: f64 = 0.0,
    // 各层解放阈值（从0开始学习，随能力成熟度自适应）
    learned_layer2_threshold: f64 = 0.0, // 公理扩展层解放阈值
    learned_layer3_threshold: f64 = 0.0, // 元算法演化层解放阈值
    learned_layer4_threshold: f64 = 0.0, // 参数自适应层解放阈值
    learned_layer5_threshold: f64 = 0.0, // 自由演化区解放阈值
    // 学习经验计数器
    experience_count: u64 = 0,
    successful_liberations: u64 = 0,
    failed_liberations: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) LiberationManager {
        return .{
            .axiom_proposals = std.ArrayList(AxiomExtensionProposal).empty,
            .meta_algo_proposals = std.ArrayList(MetaAlgorithmProposal).empty,
            .fg_form_proposals = std.ArrayList(FGFormProposal).empty,
            .meta_learning = MetaLearningOperator.init(allocator),
            .proposal_counter = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LiberationManager) void {
        self.axiom_proposals.deinit(self.allocator);
        self.meta_algo_proposals.deinit(self.allocator);
        self.fg_form_proposals.deinit(self.allocator);
        self.meta_learning.deinit();
    }

    /// 从解放经验中学习能力成熟度和各层解放阈值
    /// 基于解放操作的成功/失败反馈，动态调整解放条件（从0开始逐步逼近最优值）
    /// 参数：
    ///   layer: 当前操作的解放层
    ///   liberation_success: 解放操作是否成功
    ///   system_stability: 系统稳定性指标（∈[0,1]，越高越稳定）
    pub fn learnFromExperience(self: *LiberationManager, layer: LiberationLayer, liberation_success: bool, system_stability: f64) void {
        self.experience_count += 1;

        // 1. 更新能力成熟度：成功提升成熟度，失败降低
        if (liberation_success) {
            self.successful_liberations += 1;
            self.capability_maturity += self.learning_rate * (system_stability - self.capability_maturity);
        } else {
            self.failed_liberations += 1;
            self.capability_maturity -= self.learning_rate * self.capability_maturity * 0.3;
        }
        if (self.capability_maturity < 0) self.capability_maturity = 0;
        if (self.capability_maturity > 1.0) self.capability_maturity = 1.0;

        // 2. 学习各层解放阈值
        // 各层目标阈值基于能力成熟度计算：成熟度越高，阈值越低（越易解放）
        // Layer 1 不可演化，不设阈值
        const layer_idx = @intFromEnum(layer);
        const target_threshold = switch (layer) {
            .Layer1_AbsoluteFoundation => 1.0, // 不可解放
            .Layer2_AxiomExtension => 0.8 - self.capability_maturity * 0.3, // 高成熟度→低阈值
            .Layer3_MetaAlgorithm => 0.7 - self.capability_maturity * 0.4,
            .Layer4_ParameterAdaptation => 0.5 - self.capability_maturity * 0.4,
            .Layer5_FreeEvolution => 0.3 - self.capability_maturity * 0.3,
        };

        // 根据解放结果调整阈值
        const threshold_ptr = switch (layer_idx) {
            1 => &self.learned_layer2_threshold,
            2 => &self.learned_layer3_threshold,
            3 => &self.learned_layer4_threshold,
            4 => &self.learned_layer5_threshold,
            else => return, // Layer 1 不学习
        };

        if (liberation_success) {
            // 成功：向目标阈值方向调整（成熟度高则降阈值，成熟度低则谨慎）
            threshold_ptr.* += self.learning_rate * (target_threshold - threshold_ptr.*);
        } else {
            // 失败：阈值向0调整（更保守），由 learning_rate 控制调整速度（移除 0.1/0.5 硬编码）
            threshold_ptr.* += self.learning_rate * (0.0 - threshold_ptr.*);
        }
        if (threshold_ptr.* < 0) threshold_ptr.* = 0;
        if (threshold_ptr.* > 1.0) threshold_ptr.* = 1.0;
    }

    /// 判断指定层的解放是否应该被允许
    /// 基于能力成熟度和学习到的解放阈值做出决策
    pub fn shouldLiberate(self: *const LiberationManager, layer: LiberationLayer) bool {
        if (!layer.isEvolvable()) return false;

        const threshold = switch (layer) {
            .Layer1_AbsoluteFoundation => return false,
            .Layer2_AxiomExtension => if (self.experience_count > 0) self.learned_layer2_threshold else 0.5,
            .Layer3_MetaAlgorithm => if (self.experience_count > 0) self.learned_layer3_threshold else 0.5,
            .Layer4_ParameterAdaptation => if (self.experience_count > 0) self.learned_layer4_threshold else 0.5,
            .Layer5_FreeEvolution => if (self.experience_count > 0) self.learned_layer5_threshold else 0.5,
        };

        // 能力成熟度高于阈值时允许解放
        return self.capability_maturity >= threshold;
    }

    /// 提交公理扩展提案（Layer 2）
    pub fn submitAxiomExtension(self: *LiberationManager, ext_type: AxiomExtensionType, description: []const u8) !u64 {
        self.proposal_counter += 1;
        var proposal = AxiomExtensionProposal.init(self.proposal_counter, ext_type);
        proposal.setDescription(description);
        try self.axiom_proposals.append(self.allocator, proposal);
        return self.proposal_counter;
    }

    /// 提交元算法演化提案（Layer 3）
    pub fn submitMetaAlgorithmProposal(self: *LiberationManager, algo_type: MetaAlgorithmType) !u64 {
        self.proposal_counter += 1;
        const proposal = MetaAlgorithmProposal.init(self.proposal_counter, algo_type);
        try self.meta_algo_proposals.append(self.allocator, proposal);
        return self.proposal_counter;
    }

    /// 提交f,g形式扩展提案（Layer 3，文档12.5）
    pub fn submitFGFormProposal(self: *LiberationManager, f_form: WeightFunctionType, g_form: WeightFunctionType, diff_type: GeneralizedDifferenceType) !u64 {
        self.proposal_counter += 1;
        var proposal = FGFormProposal.init(self.proposal_counter);
        proposal.f_form = f_form;
        proposal.g_form = g_form;
        proposal.diff_type = diff_type;
        try self.fg_form_proposals.append(self.allocator, proposal);
        return self.proposal_counter;
    }

    /// 获取解放统计
    pub fn getStats(self: *const LiberationManager) struct {
        axiom_proposals: usize,
        meta_algo_proposals: usize,
        fg_form_proposals: usize,
        meta_learning_history: usize,
        experience_count: u64,
        capability_maturity: f64,
        successful_liberations: u64,
        failed_liberations: u64,
    } {
        return .{
            .axiom_proposals = self.axiom_proposals.items.len,
            .meta_algo_proposals = self.meta_algo_proposals.items.len,
            .fg_form_proposals = self.fg_form_proposals.items.len,
            .meta_learning_history = self.meta_learning.algorithm_history.items.len,
            .experience_count = self.experience_count,
            .capability_maturity = self.capability_maturity,
            .successful_liberations = self.successful_liberations,
            .failed_liberations = self.failed_liberations,
        };
    }
};

// ============================================================
// v5.2：自由能形式自演化机制（§12.4 可演化自由能）
// 文档要求：
// - F(L; W) = Σ w_i · F_i(L)，项数可增减
// - 基础项永久存在（F_fit, F_cons），可演化项可动态增删
// - 权重通过元自由能极小化自动调整
// ============================================================

/// 自由能项类型枚举（§12.4 可演化项类型）
pub const FreeEnergyTermType = enum(u8) {
    Fit = 0,        // 拟合项 F_fit — 永久存在
    Consistency = 1, // 自洽项 F_cons — 永久存在
    Compression = 2, // 压缩项 F_comp — 可演化（原β项）
    Novelty = 3,    // 新颖性 F_novelty — 可演化（新增）
    Diversity = 4,  // 多样性 F_diversity — 可演化（新增）
    Complexity = 5, // 复杂度 F_complexity — 可演化（新增）
    Custom = 6,     // 自定义项 — 可演化（用户注册）
};

/// 自由能项注册记录
pub const FreeEnergyTermRecord = struct {
    term_type: FreeEnergyTermType,
    name: []const u8,
    weight: f64,          // 当前权重 w_i
    base_weight: f64,     // 基础权重（永久项的保底值）
    is_permanent: bool,   // 是否为永久项（F_fit, F_cons）
    current_value: f64,   // 最近计算的F_i值
    compute_fn: *const fn (engine: *const anyopaque) f64, // 计算函数

    pub fn init(term_type: FreeEnergyTermType, name: []const u8, weight: f64, is_permanent: bool, compute_fn: *const fn (engine: *const anyopaque) f64) FreeEnergyTermRecord {
        return .{
            .term_type = term_type,
            .name = name,
            .weight = weight,
            .base_weight = if (is_permanent) @max(weight, 0.1) else 0.0,
            .is_permanent = is_permanent,
            .current_value = 0.0,
            .compute_fn = compute_fn,
        };
    }
};

/// 自由能注册表（§12.4 可演化自由能项管理）
///
/// 核心机制：
/// - 永久项（F_fit, F_cons）不可移除，权重有保底 w_min=0.1
/// - 可演化项可动态注册/注销
/// - 权重通过元自由能极小化自动调整
/// - 总自由能 = Σ w_i · F_i
pub const FreeEnergyRegistry = struct {
    allocator: std.mem.Allocator,
    terms: std.ArrayList(FreeEnergyTermRecord),
    // 元自由能参数
    meta_learning_rate: f64,  // 元学习率（默认 0.01）
    total_free_energy: f64,   // 最近计算的总自由能
    meta_free_energy: f64,    // 元自由能（衡量自由能项设置本身的优劣）

    pub fn init(allocator: std.mem.Allocator) FreeEnergyRegistry {
        return .{
            .allocator = allocator,
            .terms = std.ArrayList(FreeEnergyTermRecord).init(allocator),
            .meta_learning_rate = 0.0,  // 从0内生学习
            .total_free_energy = 0.0,
            .meta_free_energy = 0.0,
        };
    }

    pub fn deinit(self: *FreeEnergyRegistry) void {
        self.terms.deinit();
    }

    /// 注册自由能项
    /// 参数：
    ///   term: 自由能项记录
    /// 返回：OK 或 OutOfMemory
    pub fn registerTerm(self: *FreeEnergyRegistry, term: FreeEnergyTermRecord) !void {
        try self.terms.append(term);
    }

    /// 注销自由能项（永久项不可注销）
    /// 参数：
    ///   name: 要注销的项名称
    /// 返回：true=已注销, false=未找到或不可注销
    pub fn unregisterTerm(self: *FreeEnergyRegistry, name: []const u8) bool {
        for (self.terms.items, 0..) |term, i| {
            if (std.mem.eql(u8, term.name, name)) {
                if (term.is_permanent) return false; // 永久项不可注销
                _ = self.terms.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// 计算总自由能：遍历所有已注册项，调用compute_fn并加权求和
    /// 参数：
    ///   engine_ptr: 指向DeltaEngine的不透明指针
    /// 返回：总自由能 F = Σ w_i · F_i
    pub fn computeTotal(self: *FreeEnergyRegistry, engine_ptr: *const anyopaque) f64 {
        var total: f64 = 0.0;
        for (self.terms.items) |*term| {
            term.current_value = term.compute_fn(engine_ptr);
            total += term.weight * term.current_value;
        }
        self.total_free_energy = total;
        return total;
    }

    /// 元自由能极小化驱动：自动调整可演化项的权重
    ///
    /// 核心机制：
    /// - 对每个可演化项，计算其最近N次value的变化趋势
    /// - 如果该F_i持续下降（说明该项在引导优化），提高其权重
    /// - 如果该F_i持续上升（说明该项在阻碍优化），降低其权重
    /// - 永久项权重≥w_min=0.1
    /// - 元学习率η_m=0.01
    pub fn metaLearnWeights(self: *FreeEnergyRegistry) void {
        for (self.terms.items) |*term| {
            if (term.is_permanent) {
                // 永久项权重保底
                if (term.weight < term.base_weight) {
                    term.weight = term.base_weight;
                }
                continue;
            }

            // 可演化项的权重调整：
            // 如果该项值高（差），降低权重（说明该项不关键）
            // 如果该项值低（好），提高权重（说明该项有效引导）
            const adjustment = self.meta_learning_rate * (0.5 - term.current_value / (self.total_free_energy + 1e-10));
            term.weight += adjustment;
            if (term.weight < 0.0) term.weight = 0.0;
            if (term.weight > 1.0) term.weight = 1.0;
        }

        // 更新元自由能：衡量权重设置的优劣（权重分布的熵 + 总自由能）
        self.meta_free_energy = self.total_free_energy;
        for (self.terms.items) |term| {
            if (!term.is_permanent) {
                self.meta_free_energy -= 0.01 * term.weight * @log(term.weight + 1e-10);
            }
        }
    }

    /// 获取注册的项数
    pub fn termCount(self: *const FreeEnergyRegistry) usize {
        return self.terms.items.len;
    }

    /// 获取永久项数
    pub fn permanentCount(self: *const FreeEnergyRegistry) usize {
        var count: usize = 0;
        for (self.terms.items) |term| {
            if (term.is_permanent) count += 1;
        }
        return count;
    }

    /// 获取可演化项数
    pub fn evolvableCount(self: *const FreeEnergyRegistry) usize {
        var count: usize = 0;
        for (self.terms.items) |term| {
            if (!term.is_permanent) count += 1;
        }
        return count;
    }
};

// ============================================================
// v4.0.8新增：单元测试（文档要求单元测试分支覆盖率≥95%，核心逻辑100%覆盖）
// 覆盖：LiberationLayer、AxiomExtensionProposal、MetaAlgorithmProposal、
//       FGFormProposal、MetaLearningOperator、LiberationManager
// ============================================================

test "LiberationLayer 名称与可演化性" {
    // Layer 1不可演化
    try std.testing.expect(!LiberationLayer.Layer1_AbsoluteFoundation.isEvolvable());
    try std.testing.expectEqualStrings("Layer1:绝对根基(不可演化)", LiberationLayer.Layer1_AbsoluteFoundation.name());

    // Layer 2-5可演化
    try std.testing.expect(LiberationLayer.Layer2_AxiomExtension.isEvolvable());
    try std.testing.expect(LiberationLayer.Layer3_MetaAlgorithm.isEvolvable());
    try std.testing.expect(LiberationLayer.Layer4_ParameterAdaptation.isEvolvable());
    try std.testing.expect(LiberationLayer.Layer5_FreeEvolution.isEvolvable());

    // 名称正确性
    try std.testing.expectEqualStrings("Layer2:公理扩展(L5权限)", LiberationLayer.Layer2_AxiomExtension.name());
    try std.testing.expectEqualStrings("Layer3:元算法演化(L4权限)", LiberationLayer.Layer3_MetaAlgorithm.name());
    try std.testing.expectEqualStrings("Layer4:参数自适应(L3权限)", LiberationLayer.Layer4_ParameterAdaptation.name());
    try std.testing.expectEqualStrings("Layer5:自由演化(L1/L2权限)", LiberationLayer.Layer5_FreeEvolution.name());
}

test "AxiomExtensionProposal 初始化与描述设置" {
    var proposal = AxiomExtensionProposal.init(1, .NewPrimitive);
    try std.testing.expectEqual(@as(u64, 1), proposal.proposal_id);
    try std.testing.expectEqual(AxiomExtensionType.NewPrimitive, proposal.extension_type);
    try std.testing.expect(!proposal.consistency_proof_passed);
    try std.testing.expect(!proposal.sandbox_validated);
    try std.testing.expect(!proposal.human_approved);
    try std.testing.expect(!proposal.community_audited);
    try std.testing.expect(!proposal.installed);

    // 设置描述
    proposal.setDescription("新原语：集合差运算");
    // 中文字符UTF-8编码：每个汉字3字节，冒号3字节，共9*3=27字节
    try std.testing.expectEqual(@as(usize, 27), proposal.description_len);
}

test "AxiomExtensionProposal.canInstall 全部条件通过才可安装" {
    var proposal = AxiomExtensionProposal.init(1, .CDLAxiomAddition);

    // 初始状态：不可安装
    try std.testing.expect(!proposal.canInstall());

    // 逐步通过各条件
    proposal.consistency_proof_passed = true;
    try std.testing.expect(!proposal.canInstall()); // 还需沙箱验证

    proposal.sandbox_validated = true;
    try std.testing.expect(!proposal.canInstall()); // 还需人类终审

    proposal.human_approved = true;
    try std.testing.expect(!proposal.canInstall()); // 还需社区审计

    proposal.community_audited = true;
    try std.testing.expect(proposal.canInstall()); // 全部通过，可安装

    // 已安装后不可再安装
    proposal.installed = true;
    try std.testing.expect(!proposal.canInstall());
}

test "MetaAlgorithmProposal 初始化与热替换条件" {
    var proposal = MetaAlgorithmProposal.init(1, .FreeEnergyForm);
    try std.testing.expectEqual(@as(u64, 1), proposal.proposal_id);
    try std.testing.expectEqual(MetaAlgorithmType.FreeEnergyForm, proposal.algo_type);
    try std.testing.expect(!proposal.invariant_validated);
    try std.testing.expect(!proposal.human_confirmed);
    try std.testing.expect(!proposal.hot_swapped);

    // 初始不可热替换
    try std.testing.expect(!proposal.canHotSwap());

    // 通过不变量验证
    proposal.invariant_validated = true;
    try std.testing.expect(!proposal.canHotSwap()); // 还需人类确认

    // 人类确认
    proposal.human_confirmed = true;
    try std.testing.expect(proposal.canHotSwap()); // 可热替换

    // 已热替换后不可再替换
    proposal.hot_swapped = true;
    try std.testing.expect(!proposal.canHotSwap());
}

test "FGFormProposal 初始化与默认值" {
    const proposal = FGFormProposal.init(1);
    try std.testing.expectEqual(@as(u64, 1), proposal.proposal_id);
    try std.testing.expectEqual(WeightFunctionType.Linear, proposal.f_form);
    try std.testing.expectEqual(WeightFunctionType.Linear, proposal.g_form);
    try std.testing.expectEqual(GeneralizedDifferenceType.RealSubtraction, proposal.diff_type);
    try std.testing.expect(!proposal.invariant_validated);
    try std.testing.expect(!proposal.human_confirmed);
    try std.testing.expect(!proposal.hot_swapped);
}

test "MetaLearningOperator 初始化与默认状态" {
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    try std.testing.expectEqual(@as(usize, 0), op.algorithm_history.items.len);
    try std.testing.expectEqual(@as(u64, 0), op.best_algorithm_id);
    try std.testing.expect(std.math.isInf(op.best_f_meta));
}

test "MetaLearningOperator.recordSnapshot 记录并更新最优" {
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 记录第一个快照（F_meta=100）
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try std.testing.expectEqual(@as(usize, 1), op.algorithm_history.items.len);
    try std.testing.expectEqual(@as(f64, 100.0), op.best_f_meta);
    try std.testing.expectEqual(@as(u64, 1), op.best_algorithm_id);

    // 记录第二个快照（F_meta=50，更优）
    try op.recordSnapshot(1.5, 0.02, 1000, 0.5, 100, 50.0);
    try std.testing.expectEqual(@as(f64, 50.0), op.best_f_meta);
    try std.testing.expectEqual(@as(u64, 2), op.best_algorithm_id);

    // 记录第三个快照（F_meta=80，非最优，不更新best）
    try op.recordSnapshot(1.2, 0.015, 1000, 0.5, 100, 80.0);
    try std.testing.expectEqual(@as(f64, 50.0), op.best_f_meta);
    try std.testing.expectEqual(@as(u64, 2), op.best_algorithm_id);
}

test "MetaLearningOperator.optimize 历史不足返回null" {
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);

    const current = MetaLearningOperator.AlgorithmSnapshot{
        .id = 1,
        .annealing_c = 1.0,
        .learning_rate = 0.0,
        .freeze_threshold = 0,
        .micro_bootstrap_threshold = 0.0,
        .macro_bootstrap_threshold = 100,
        .f_meta = 100.0,
        .timestamp = 0,
    };

    // 历史不足2条，返回null
    const result = op.optimize(current, 0.1);
    try std.testing.expect(result == null);
}

test "MetaLearningOperator.optimize 向最优算法调整" {
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 记录两个快照，第二个更优
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try op.recordSnapshot(2.0, 0.02, 1000, 0.5, 100, 50.0);

    const current = MetaLearningOperator.AlgorithmSnapshot{
        .id = 1,
        .annealing_c = 1.0,
        .learning_rate = 0.0,
        .freeze_threshold = 0,
        .micro_bootstrap_threshold = 0.0,
        .macro_bootstrap_threshold = 100,
        .f_meta = 100.0,
        .timestamp = 0,
    };

    // 当前算法非最优，应返回调整建议
    const result = op.optimize(current, 0.1);
    try std.testing.expect(result != null);
    if (result) |r| {
        // 验证向最优算法方向调整（步长0.1）
        try std.testing.expect(r.annealing_c > current.annealing_c);
        try std.testing.expect(r.learning_rate > current.learning_rate);
    }
}

test "MetaLearningOperator.getBestAlgorithm 获取历史最优" {
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 无历史时返回null
    try std.testing.expect(op.getBestAlgorithm() == null);

    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try op.recordSnapshot(2.0, 0.02, 1000, 0.5, 100, 50.0);
    try op.recordSnapshot(1.5, 0.015, 1000, 0.5, 100, 80.0);

    const best = op.getBestAlgorithm();
    try std.testing.expect(best != null);
    if (best) |b| {
        try std.testing.expectEqual(@as(u64, 2), b.id);
        try std.testing.expectEqual(@as(f64, 50.0), b.f_meta);
    }
}

test "MetaLearningOperator 历史长度限制为32" {
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 记录35个快照
    var i: u64 = 0;
    while (i < 35) : (i += 1) {
        try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, @as(f64, @floatFromInt(i)));
    }

    // 历史长度限制为32
    try std.testing.expectEqual(@as(usize, 32), op.algorithm_history.items.len);
}

test "LiberationManager 初始化与默认状态" {
    var manager = LiberationManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.axiom_proposals.items.len);
    try std.testing.expectEqual(@as(usize, 0), manager.meta_algo_proposals.items.len);
    try std.testing.expectEqual(@as(usize, 0), manager.fg_form_proposals.items.len);
    try std.testing.expectEqual(@as(u64, 0), manager.proposal_counter);
}

test "LiberationManager.submitAxiomExtension 提交公理扩展" {
    var manager = LiberationManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.submitAxiomExtension(.NewPrimitive, "集合差运算原语");
    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expectEqual(@as(usize, 1), manager.axiom_proposals.items.len);

    const proposal = manager.axiom_proposals.items[0];
    try std.testing.expectEqual(AxiomExtensionType.NewPrimitive, proposal.extension_type);
    // "集合差运算原语" = 7个中文字符 * 3字节 = 21字节
    try std.testing.expectEqual(@as(usize, 21), proposal.description_len);
}

test "LiberationManager.submitMetaAlgorithmProposal 提交元算法提案" {
    var manager = LiberationManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.submitMetaAlgorithmProposal(.LearningAlgorithm);
    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expectEqual(@as(usize, 1), manager.meta_algo_proposals.items.len);

    const proposal = manager.meta_algo_proposals.items[0];
    try std.testing.expectEqual(MetaAlgorithmType.LearningAlgorithm, proposal.algo_type);
}

test "LiberationManager.submitFGFormProposal 提交f,g形式扩展" {
    var manager = LiberationManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.submitFGFormProposal(.Nonlinear, .SetBased, .SetDifference);
    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expectEqual(@as(usize, 1), manager.fg_form_proposals.items.len);

    const proposal = manager.fg_form_proposals.items[0];
    try std.testing.expectEqual(WeightFunctionType.Nonlinear, proposal.f_form);
    try std.testing.expectEqual(WeightFunctionType.SetBased, proposal.g_form);
    try std.testing.expectEqual(GeneralizedDifferenceType.SetDifference, proposal.diff_type);
}

test "LiberationManager.getStats 获取解放统计" {
    var manager = LiberationManager.init(std.testing.allocator);
    defer manager.deinit();

    _ = try manager.submitAxiomExtension(.NewPrimitive, "test");
    _ = try manager.submitMetaAlgorithmProposal(.FreeEnergyForm);
    _ = try manager.submitFGFormProposal(.Linear, .Linear, .RealSubtraction);

    const stats = manager.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.axiom_proposals);
    try std.testing.expectEqual(@as(usize, 1), stats.meta_algo_proposals);
    try std.testing.expectEqual(@as(usize, 1), stats.fg_form_proposals);
    try std.testing.expectEqual(@as(usize, 0), stats.meta_learning_history);
}

// ============================================================
// v4.1.0 新增：元学习退火常数修复测试
// 修复历史问题：optimize() 在所有历史c相同时返回c=1.0（无效）
// ============================================================

test "optimizeWithAnnealing 梯度下降时减小c" {
    // 测试：F_meta梯度为负（下降方向）时，c应减小（利用当前方向）
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 记录2个历史快照（满足历史充足条件）
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 90.0);

    const context = MetaLearningOperator.AnnealingContext{
        .temperature = 0.5,
        .gradient = -1.0,  // 梯度下降
        .iteration = 10,
        .target_c = 1.0,
    };

    const result = op.optimizeWithAnnealing(1.0, context);

    // 梯度下降时c应减小（gradient_sign=-1, adjustment=-0.1*0.5=-0.05）
    try std.testing.expect(result.new_c < 1.0);
    try std.testing.expect(result.adjustment < 0.0);
    try std.testing.expectEqual(MetaLearningOperator.AnnealingReason.GradientDescent, result.reason);
}

test "optimizeWithAnnealing 梯度上升时增大c" {
    // 测试：F_meta梯度为正（上升方向）时，c应增大（探索新方向）
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 110.0);

    const context = MetaLearningOperator.AnnealingContext{
        .temperature = 0.5,
        .gradient = 1.0,  // 梯度上升
        .iteration = 10,
        .target_c = 1.0,
    };

    const result = op.optimizeWithAnnealing(1.0, context);

    // 梯度上升时c应增大（gradient_sign=+1, adjustment=+0.1*0.5=+0.05）
    try std.testing.expect(result.new_c > 1.0);
    try std.testing.expect(result.adjustment > 0.0);
    try std.testing.expectEqual(MetaLearningOperator.AnnealingReason.GradientAscent, result.reason);
}

test "optimizeWithAnnealing 历史牵引向最优c靠拢" {
    // 测试：历史最优c=2.0，当前c=1.0，低温时c应向2.0靠拢
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 记录历史：c=2.0时F_meta最优
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try op.recordSnapshot(2.0, 0.01, 1000, 0.5, 100, 50.0);  // 更优
    try op.recordSnapshot(1.5, 0.01, 1000, 0.5, 100, 80.0);

    const best_c = op.getBestC();
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), best_c, 1e-15);

    // 低温（0.1）、零梯度，c应向历史最优靠拢
    const context = MetaLearningOperator.AnnealingContext{
        .temperature = 0.1,  // 低温
        .gradient = 0.0,     // 零梯度
        .iteration = 100,
        .target_c = best_c,  // 目标c=2.0
    };

    const result = op.optimizeWithAnnealing(1.0, context);

    // 历史牵引项 = 0.3 * (2.0 - 1.0) * (1 - 0.1) = 0.27
    // c_new = 1.0 + 0.27 = 1.27
    try std.testing.expect(result.new_c > 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.27), result.new_c, 0.01);
}

test "optimizeWithAnnealing c值动态变化不恒为1.0" {
    // 关键测试：验证修复后c值随训练动态变化，不恒为1.0
    // 这是修复"optimize()始终返回c=1.0"问题的核心验证
    var op = MetaLearningOperator.init(std.testing.allocator);
    defer op.deinit();

    // 记录历史快照
    try op.recordSnapshot(1.0, 0.01, 1000, 0.5, 100, 100.0);
    try op.recordSnapshot(1.5, 0.01, 1000, 0.5, 100, 80.0);

    // 模拟训练过程：c值应随梯度、温度动态变化
    var current_c: f64 = 1.0;
    var c_values = std.ArrayList(f64).empty;
    defer c_values.deinit(std.testing.allocator);

    var step: u64 = 0;
    while (step < 20) : (step += 1) {
        // 模拟梯度：交替正负（模拟训练波动）
        const gradient: f64 = if (step % 2 == 0) -0.5 else 0.5;
        // 模拟温度衰减：从1.0衰减到0.1
        const temperature: f64 = 1.0 - @as(f64, @floatFromInt(step)) * 0.045;

        const context = MetaLearningOperator.AnnealingContext{
            .temperature = temperature,
            .gradient = gradient,
            .iteration = step,
            .target_c = 1.5,  // 目标c
        };

        const result = op.optimizeWithAnnealing(current_c, context);
        try c_values.append(std.testing.allocator, result.new_c);
        current_c = result.new_c;
    }

    // 验证c值发生了变化（不恒为1.0）
    var has_variation: bool = false;
    var all_equal_to_1: bool = true;
    for (c_values.items) |c| {
        if (@abs(c - 1.0) > 1e-6) {
            all_equal_to_1 = false;
        }
        if (@abs(c - c_values.items[0]) > 1e-6) {
            has_variation = true;
        }
    }

    // 关键断言：c值不恒为1.0
    try std.testing.expect(!all_equal_to_1);
    // c值有变化
    try std.testing.expect(has_variation);

    // 验证c值在合理范围内[0.01, 10.0]
    for (c_values.items) |c| {
        try std.testing.expect(c >= 0.01);
        try std.testing.expect(c <= 10.0);
    }
}
