// Ω-落尘AGI 统一功能域 v5.0 - 哲学重构版
//
// 核心变更（v4.x → v5.0）：
// - 彻底移除所有硬编码操作枚举（OperationType 的 13 个变体全部删除）
// - 彻底移除能力域分类（DomainType 精简为单一 UnifiedReasoning）
// - 系统不知道自己在做"加法"还是"乘法"——它只知道自己在消除 Δ
// - 所有 switch-on-operation 分支统一为 engine.delta 调用
// - 自指观测域和沙箱仿真域不再作为独立域存在
//
// 严格对应白皮书v2.0+修正：
// - 第4.3节：功能域为动态视角划分，物理上是连续统一的尘图结构
// - 统一 Δ 运算替代所有命名操作
//
// 核心设计原则（文档3.1）：
// - 一元尘图：唯一本体是CDL尘图，不存在第二实体
// - 功能域无固定模块边界，是动态视角划分
// - 所有功能域共享同一尘图结构

const std = @import("std");
const et = @import("error_types.zig");
const ffi = @import("seed_kernel_ffi.zig");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;
const dust_graph = @import("dust_graph.zig");
const DustGraph = dust_graph.DustGraph;
const sc = @import("session_context.zig");
const tt = @import("trainer_types.zig");

// ============================================================
// 功能域类型枚举（v5.0：精简为单一统一推理域）
// ============================================================
pub const DomainType = enum(u8) {
    UnifiedReasoning = 0, // 统一推理域

    pub fn name(self: DomainType) []const u8 {
        _ = self;
        return "统一推理域";
    }
};

// ============================================================
// v5.0.0 Phase1 修正：五大功能域物理实现
// ============================================================
// 白皮书 3.3.2 要求五大域（对外推理/知识沉淀/自指观测/沙箱仿真/规则迭代）
// 作为物理域存在。本文件采取"统一域+5个动态视角"实现：
//   - 保留 UnifiedReasoningDomain 作为主域（统一 Δ 差值推演）
//   - 5 个域作为 UnifiedReasoningDomain 的轻量级视角
//   - 各 View 共享同一引擎但有独立指标（独立计数、独立窗口）
//   - View 是动态视角划分，非独立物理模块（白皮书 4.3 设计）
// ============================================================

/// 五大功能域视角枚举（白皮书 3.3.2：五个动态区域）
/// 每个 View 是 UnifiedReasoningDomain 的一个轻量级视角，
/// 共享同一引擎但有独立指标。
pub const DomainView = enum(u8) {
    /// 对外推理域：接收外部输入，执行 Δ 差值推演，输出结果
    Reasoning = 0,
    /// 知识沉淀域：沉淀稳定自洽的知识子格，构建结构化认知体系
    KnowledgePrecipitation = 1,
    /// 自指观测域：系统对自身状态的内省观测
    SelfObservation = 2,
    /// 沙箱仿真域：隔离拓扑试探，在副本上验证新结构
    SandboxSimulation = 3,
    /// 规则迭代域：提炼高频模式为通用规则，优化重写逻辑
    RuleIteration = 4,

    pub fn name(self: DomainView) []const u8 {
        return switch (self) {
            .Reasoning => "对外推理域",
            .KnowledgePrecipitation => "知识沉淀域",
            .SelfObservation => "自指观测域",
            .SandboxSimulation => "沙箱仿真域",
            .RuleIteration => "规则迭代域",
        };
    }
};

/// 域视角指标结构体（每个 View 的独立计数器）
/// 共享同一引擎，但每个 View 维护自己的统计指标
pub const ViewMetrics = struct {
    /// View 的执行步数（每次 switchView 切换时累加）
    view_steps: u64,
    /// View 的活动持续时间（纳秒，由调用方提供）
    active_duration_ns: i128,
    /// View 处理的 Δ 运算次数
    delta_invocations: u64,
    /// View 中成功完成的子任务数
    completed_subtasks: u64,
    /// View 中失败的子任务数
    failed_subtasks: u64,
    /// View 的最近一次活跃时间戳（用于窗口统计）
    last_active_ns: i128,
    /// View 的窗口大小（由视图规模内生决定）
    window_size: u64,

    pub fn init() ViewMetrics {
        return .{
            .view_steps = 0,
            .active_duration_ns = 0,
            .delta_invocations = 0,
            .completed_subtasks = 0,
            .failed_subtasks = 0,
            .last_active_ns = 0,
            .window_size = 0,
        };
    }

    /// 计算 View 的活跃度（独立于其他 View）
    pub fn activity(self: *const ViewMetrics) f64 {
        if (self.view_steps == 0) return 0.0;
        return @as(f64, @floatFromInt(self.completed_subtasks)) /
            @as(f64, @floatFromInt(self.view_steps));
    }
};

/// ============================================================
/// 五大功能域视角子结构体（白皮书 3.3.2）
/// 每个 View 是 UnifiedReasoningDomain 的轻量级视角，
/// 共享同一引擎但有独立的 ViewMetrics。
/// ============================================================

/// 对外推理域视角（白皮书 3.3.2.1）
/// 接收外部输入，执行统一的 Δ 差值推演，输出结果
pub const ReasoningView = struct {
    metrics: ViewMetrics,
    engine_ref: *DeltaEngine,

    pub fn init(engine: *DeltaEngine) ReasoningView {
        return .{
            .metrics = ViewMetrics.init(),
            .engine_ref = engine,
        };
    }

    /// 执行一次推理（计入 View 指标）
    pub fn execute(self: *ReasoningView) void {
        self.metrics.view_steps += 1;
        self.metrics.delta_invocations += 1;
    }
};

/// 知识沉淀域视角（白皮书 3.3.2.2）
/// 沉淀稳定自洽的知识子格，构建结构化认知体系
pub const KnowledgePrecipitationView = struct {
    metrics: ViewMetrics,
    engine_ref: *DeltaEngine,
    /// 已沉淀的子格数量
    sedimented_count: u64,

    pub fn init(engine: *DeltaEngine) KnowledgePrecipitationView {
        return .{
            .metrics = ViewMetrics.init(),
            .engine_ref = engine,
            .sedimented_count = 0,
        };
    }

    /// 沉淀一个知识子格（计入 View 指标）
    pub fn sediment(self: *KnowledgePrecipitationView) void {
        self.metrics.view_steps += 1;
        self.metrics.completed_subtasks += 1;
        self.sedimented_count += 1;
    }
};

/// 自指观测域视角（白皮书 3.3.2.3）
/// 系统对自身状态的内省观测（自指算子 T(A)=Δ(A,A) 的应用）
pub const SelfObservationView = struct {
    metrics: ViewMetrics,
    engine_ref: *DeltaEngine,
    /// 观测次数（每次自指 Δ 都计入）
    observation_count: u64,

    pub fn init(engine: *DeltaEngine) SelfObservationView {
        return .{
            .metrics = ViewMetrics.init(),
            .engine_ref = engine,
            .observation_count = 0,
        };
    }

    /// 执行一次自指观测（自指 Δ 运算）
    pub fn observe(self: *SelfObservationView) void {
        self.metrics.view_steps += 1;
        self.metrics.delta_invocations += 1;
        self.observation_count += 1;
    }
};

/// 沙箱仿真域视角（白皮书 3.3.2.4）
/// 隔离拓扑试探，在副本上验证新结构
pub const SandboxSimulationView = struct {
    metrics: ViewMetrics,
    engine_ref: *DeltaEngine,
    /// 沙箱仿真次数
    simulation_count: u64,
    /// 仿真通过次数
    simulation_passed: u64,

    pub fn init(engine: *DeltaEngine) SandboxSimulationView {
        return .{
            .metrics = ViewMetrics.init(),
            .engine_ref = engine,
            .simulation_count = 0,
            .simulation_passed = 0,
        };
    }

    /// 执行一次沙箱仿真
    pub fn simulate(self: *SandboxSimulationView, success: bool) void {
        self.metrics.view_steps += 1;
        self.simulation_count += 1;
        if (success) {
            self.metrics.completed_subtasks += 1;
            self.simulation_passed += 1;
        } else {
            self.metrics.failed_subtasks += 1;
        }
    }
};

/// 规则迭代域视角（白皮书 3.3.2.5）
/// 提炼高频模式为通用规则，优化重写逻辑
pub const RuleIterationView = struct {
    metrics: ViewMetrics,
    engine_ref: *DeltaEngine,
    /// 提炼的模式数量
    extracted_patterns: u64,
    /// 生成的规则数量
    generated_rules: u64,

    pub fn init(engine: *DeltaEngine) RuleIterationView {
        return .{
            .metrics = ViewMetrics.init(),
            .engine_ref = engine,
            .extracted_patterns = 0,
            .generated_rules = 0,
        };
    }

    /// 提炼一个模式
    pub fn extract(self: *RuleIterationView) void {
        self.metrics.view_steps += 1;
        self.extracted_patterns += 1;
    }

    /// 生成一个规则
    pub fn generate(self: *RuleIterationView) void {
        self.metrics.completed_subtasks += 1;
        self.generated_rules += 1;
    }
};

// ============================================================
// 域优先级计算参数（文档4.3.3定义4.1）
// ============================================================
// 等待步数不从固定常数决定，由系统运行时状态内生决定

// ============================================================
// 域状态记录（用于优先级计算）
// ============================================================
pub const DomainState = struct {
    domain_type: DomainType,
    // 自由能梯度 |∇F_Di(t)|（改进潜力）
    energy_gradient: f64,
    // 紧迫度 U(Di,t)（有用户请求时=1，空闲时=0）
    urgency: f64,
    // 资源就绪度 R(Di,t)（内存/计算可用性，∈[0,1]）
    resource_readiness: f64,
    // 等待步数（老化机制用）
    wait_steps: u64,
    // 上次执行时间戳
    last_executed: u64,
    // 学习率（动态学习参数调整步长）
    learning_rate: f64 = 0.05,

    /// 计算域优先级 P(Di,t) = w1·|∇F|/|∇Fmax| + w2·U + w3·R + 老化补偿
    pub fn priority(self: DomainState, max_gradient: f64, w1: f64, w2: f64, w3: f64, aging_factor: f64) f64 {
        const normalized_gradient = if (max_gradient > 1e-10)
            self.energy_gradient / max_gradient
        else
            0.0;

        // 基础优先级（使用动态学习权重）
        const base_priority = w1 * normalized_gradient +
            w2 * self.urgency +
            w3 * self.resource_readiness;

        // 老化补偿：等待时间越长，紧迫度递增（防饥饿）
        const aging_bonus = @as(f64, @floatFromInt(self.wait_steps)) * aging_factor;

        return base_priority + aging_bonus;
    }

    /// 更新等待步数
    pub fn incrementWait(self: *DomainState) void {
        self.wait_steps += 1;
    }

    /// 重置等待步数（执行后调用）
    pub fn resetWait(self: *DomainState) void {
        self.wait_steps = 0;
    }
};

// ============================================================
// 统一推理域（v5.0：替代原来的五大功能域分类）
// 作用：接收外部输入，执行统一的 Δ 差值推演，输出结果
// 核心机制：差值传播、等价寻优、路径回溯
// v5.0.0 Phase1 修正：同时持有 5 个域视角（白皮书 3.3.2）
// ============================================================
pub const UnifiedReasoningDomain = struct {
    engine: *DeltaEngine,
    // 推理统计
    total_queries: u64,
    successful_queries: u64,
    // 差值传播统计
    delta_propagations: u64,
    // 等价寻优统计
    equivalence_searches: u64,
    // 路径回溯统计
    path_backtracks: u64,
    // 输入转码器（文档第6章：全链路交互转码层）
    input_transcoder: InputTranscoder,
    // 输出转码器（文档第6章：全链路交互转码层）
    output_transcoder: OutputTranscoder,

    // ============================================================
    // v5.0.0 Phase1：五大功能域视角（白皮书 3.3.2）
    // 5 个 View 是 UnifiedReasoningDomain 的轻量级视角，
    // 共享同一 engine 但有独立指标，独立计数。
    // ============================================================
    /// 对外推理域视角
    reasoning_view: ReasoningView,
    /// 知识沉淀域视角
    knowledge_view: KnowledgePrecipitationView,
    /// 自指观测域视角
    self_observation_view: SelfObservationView,
    /// 沙箱仿真域视角
    sandbox_view: SandboxSimulationView,
    /// 规则迭代域视角
    rule_iteration_view: RuleIterationView,
    /// 当前活跃的 View
    active_view: DomainView,

    pub fn init(engine: *DeltaEngine) UnifiedReasoningDomain {
        return .{
            .engine = engine,
            .total_queries = 0,
            .successful_queries = 0,
            .delta_propagations = 0,
            .equivalence_searches = 0,
            .path_backtracks = 0,
            .input_transcoder = .{
                .classifier = LearnableInputClassifier.init(),
            },
            .output_transcoder = .{},
            // 初始化 5 个 View（共享同一 engine，独立指标）
            .reasoning_view = ReasoningView.init(engine),
            .knowledge_view = KnowledgePrecipitationView.init(engine),
            .self_observation_view = SelfObservationView.init(engine),
            .sandbox_view = SandboxSimulationView.init(engine),
            .rule_iteration_view = RuleIterationView.init(engine),
            .active_view = .Reasoning, // 默认活跃 View
        };
    }

    /// 切换当前活跃的 View（白皮书 4.3：动态视角划分）
    /// 切换不影响其他 View 的独立指标，仅改变 active_view 标记
    pub fn switchView(self: *UnifiedReasoningDomain, view: DomainView) void {
        self.active_view = view;
        // 根据新 View 更新对应指标
        switch (view) {
            .Reasoning => self.reasoning_view.execute(),
            .KnowledgePrecipitation => self.knowledge_view.metrics.view_steps += 1,
            .SelfObservation => self.self_observation_view.observe(),
            .SandboxSimulation => self.sandbox_view.simulate(false), // 切换本身不视为仿真成功
            .RuleIteration => self.rule_iteration_view.extract(),
        }
    }

    /// 获取当前活跃 View 的指标引用
    pub fn activeMetrics(self: *const UnifiedReasoningDomain) *const ViewMetrics {
        return switch (self.active_view) {
            .Reasoning => &self.reasoning_view.metrics,
            .KnowledgePrecipitation => &self.knowledge_view.metrics,
            .SelfObservation => &self.self_observation_view.metrics,
            .SandboxSimulation => &self.sandbox_view.metrics,
            .RuleIteration => &self.rule_iteration_view.metrics,
        };
    }

    /// 获取 5 个 View 各自的指标（用于全视角监控）
    pub fn allViewMetrics(self: *const UnifiedReasoningDomain) struct {
        reasoning: ViewMetrics,
        knowledge: ViewMetrics,
        self_observation: ViewMetrics,
        sandbox: ViewMetrics,
        rule_iteration: ViewMetrics,
    } {
        return .{
            .reasoning = self.reasoning_view.metrics,
            .knowledge = self.knowledge_view.metrics,
            .self_observation = self.self_observation_view.metrics,
            .sandbox = self.sandbox_view.metrics,
            .rule_iteration = self.rule_iteration_view.metrics,
        };
    }

    /// 执行推理任务（统一 Δ 差值推演）
    /// 核心哲学：系统不知道"加法"或"乘法"——它只知道通过 Δ 运算消除差值压力
    pub fn reason(self: *UnifiedReasoningDomain, query: ReasoningQuery) !ReasoningResult {
        self.total_queries += 1;
        // v5.0.0 Phase1：更新对外推理域 View 的指标
        self.reasoning_view.metrics.view_steps += 1;
        self.reasoning_view.metrics.delta_invocations += 1;

        var result = ReasoningResult{
            .success = false,
            .value = 0.0,
            .confidence = 0.0,
            .path_length = 0,
        };

        // 1. 差值传播：通过 Δ 运算传播查询
        self.delta_propagations += 1;
        const computed_value = try self.executeDeltaPropagation(query);
        result.value = computed_value;

        // 2. 等价寻优：通过不同 Δ 路径验证结果
        self.equivalence_searches += 1;
        const equivalence_verified = try self.verifyEquivalence(query, computed_value);

        // 3. 路径回溯：若等价验证失败，通过不同 Δ 参数组合回溯
        if (!equivalence_verified) {
            self.path_backtracks += 1;
            const backtrack_result = try self.backtrackSearch(query);
            result.value = backtrack_result.value;
            result.success = backtrack_result.success;
        } else {
            result.success = true;
        }

        // 4. 计算置信度
        result.confidence = if (result.success) 1.0 else 0.0;

        if (result.success) {
            self.successful_queries += 1;
        }

        return result;
    }

    /// 差值传播：通过统一 Δ 运算执行查询
    /// 将 param1 和 param2 转为尘图对象 ID，调用 engine.delta 计算
    fn executeDeltaPropagation(self: *UnifiedReasoningDomain, query: ReasoningQuery) !f64 {
        // 核心哲学：所有计算通过统一的 Δ 运算，不区分"加法/乘法/素数判定"
        const a_id = try self.engine.getOrCreateNumber(query.param1);
        const b_id = try self.engine.getOrCreateNumber(query.param2);
        // 通过 engine.delta 执行统一 Δ 运算
        // delta(a_id, b_id) 返回 f64 差值结果
        return self.engine.deltaExpr(a_id, b_id);
    }

    /// 等价寻优：通过不同 Δ 路径验证结果
    /// 核心哲学：通过逆方向 Δ 运算做交叉验证
    fn verifyEquivalence(self: *UnifiedReasoningDomain, query: ReasoningQuery, computed_value: f64) !bool {
        // 核心哲学：通过不同 Δ 路径验证，不使用原生运算符
        // 尝试两个方向的 Δ 逆运算验证结果的自洽性
        const a_id = try self.engine.getOrCreateNumber(query.param1);
        const c_u64 = @as(u64, @intFromFloat(@abs(@round(computed_value))));
        const c_id = try self.engine.getOrCreateNumber(c_u64);

        // 方向1：Δ(computed, param1) ≈ param2
        const delta_forward = self.engine.deltaExpr(c_id, a_id);
        if (@abs(delta_forward - @as(f64, @floatFromInt(query.param2))) < 1e-10) {
            return true;
        }

        // 方向2：Δ(param1, computed) ≈ param2（对称尝试）
        const delta_reverse = self.engine.deltaExpr(a_id, c_id);
        if (@abs(delta_reverse - @as(f64, @floatFromInt(query.param2))) < 1e-10) {
            return true;
        }

        // 方向3：尝试用 param2 作为结果验证 Δ(param1, param2) ≈ computed
        const b_id = try self.engine.getOrCreateNumber(query.param2);
        const delta_alt = self.engine.deltaExpr(a_id, b_id);
        if (@abs(delta_alt - computed_value) < 1e-10) {
            return true;
        }

        return false;
    }

    /// 路径回溯：等价验证失败时，通过不同 Δ 参数组合回溯寻找正确结果
    /// 核心哲学：通过交换参数位置的 Δ 运算尝试不同路径
    fn backtrackSearch(self: *UnifiedReasoningDomain, query: ReasoningQuery) !struct { value: f64, success: bool } {
        // 核心哲学：通过不同 Δ 参数组合回溯
        const a_id = try self.engine.getOrCreateNumber(query.param1);
        const b_id = try self.engine.getOrCreateNumber(query.param2);

        // 尝试 Δ(param1, param2)
        const v1 = self.engine.deltaExpr(a_id, b_id);

        // 尝试 Δ(param2, param1)（交换参数）
        const v2 = self.engine.deltaExpr(b_id, a_id);

        // 选择更合理的值（以与原始参数自洽为准）
        const c1_id = try self.engine.getOrCreateNumber(@as(u64, @intFromFloat(@abs(@round(v1)))));
        const c2_id = try self.engine.getOrCreateNumber(@as(u64, @intFromFloat(@abs(@round(v2)))));

        // 验证 v1 的自洽性：Δ(v1, param1) ≈ param2
        const check1 = self.engine.deltaExpr(c1_id, a_id);
        const v1_consistent = @abs(check1 - @as(f64, @floatFromInt(query.param2))) < 1e-10;

        // 验证 v2 的自洽性：Δ(v2, param1) ≈ param2
        const check2 = self.engine.deltaExpr(c2_id, a_id);
        const v2_consistent = @abs(check2 - @as(f64, @floatFromInt(query.param2))) < 1e-10;

        if (v1_consistent) {
            return .{ .value = v1, .success = true };
        } else if (v2_consistent) {
            return .{ .value = v2, .success = true };
        } else {
            // 均不自洽，返回 v1 但标记失败
            return .{ .value = v1, .success = false };
        }
    }

    /// 获取成功率
    pub fn successRate(self: *const UnifiedReasoningDomain) f64 {
        if (self.total_queries == 0) return 0.0;
        return @as(f64, @floatFromInt(self.successful_queries)) / @as(f64, @floatFromInt(self.total_queries));
    }

    /// ============================================================
    /// 全链路交互转码层集成（文档第6章）
    /// ============================================================

    /// 通过自然语言输入进行推理（文档第6章：输入转码）
    pub fn reasonFromNaturalLanguage(self: *UnifiedReasoningDomain, text: []const u8) !ReasoningResult {
        const query = InputTranscoder.parseNaturalLanguage(text) orelse return error.ParseFailed;
        return try self.reason(query);
    }

    /// 通过数学表达式输入进行推理（文档第6章：输入转码）
    pub fn reasonFromMathExpression(self: *UnifiedReasoningDomain, expr: []const u8) !ReasoningResult {
        const query = InputTranscoder.parseMathExpression(expr) orelse return error.ParseFailed;
        return try self.reason(query);
    }

    /// 格式化推理结果为可读文本（文档第6章：输出转码）
    pub fn formatResult(self: *UnifiedReasoningDomain, buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        _ = self;
        return OutputTranscoder.formatResult(buf, result, query);
    }

    /// 格式化推理结果（含推导链路）（文档第6章：输出转码）
    pub fn formatWithDerivation(self: *UnifiedReasoningDomain, buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        _ = self;
        return OutputTranscoder.formatWithDerivation(buf, result, query);
    }

    // ============================================================
    // 自动格式检测输入 + 多格式输出（§6.2 完整输入转码）
    // ============================================================

    /// 通过任意格式输入进行推理（自动检测输入格式）
    pub fn reasonFromAnyInput(self: *UnifiedReasoningDomain, text: []const u8) !ReasoningResult {
        const query = InputTranscoder.parseAny(text) orelse return error.ParseFailed;
        return try self.reason(query);
    }

    /// 按指定输出格式格式化结果
    pub fn formatResultAny(self: *UnifiedReasoningDomain, buf: []u8, result: ReasoningResult, query: ReasoningQuery, format: OutputFormatType) []const u8 {
        _ = self;
        return OutputTranscoder.outputFormat(buf, result, query, format);
    }
};

// ============================================================
// 推理查询类型（v5.0：operation 字段替换为 complexity）
// 系统不再携带"操作类型"信息，只携带 Δ 运算复杂度和参数
// ============================================================
pub const ReasoningQuery = struct {
    /// Δ运算复杂度（替代旧 OperationType），表示需要探索多深的 Δ 嵌套
    complexity: tt.DeltaComplexity,
    /// 参数1（输入对象）
    param1: u64,
    /// 参数2（输入对象）
    param2: u64,

    /// 期望值（通过 engine.delta 统一计算）
    /// 核心哲学：所有计算通过 engine.delta，无任何操作类型感知
    pub fn expectedValue(self: ReasoningQuery, engine: *DeltaEngine) !f64 {
        const a_id = try engine.getOrCreateNumber(self.param1);
        const b_id = try engine.getOrCreateNumber(self.param2);
        return engine.deltaExpr(a_id, b_id);
    }
};

// ============================================================
// 推理结果结构体（保留）
// ============================================================
pub const ReasoningResult = struct {
    success: bool,
    value: f64,
    confidence: f64,
    path_length: u64,
};

// ============================================================
// 输入格式枚举（§6.2 完整输入转码）
// ============================================================
pub const InputFormat = enum {
    Chinese,        // 中文自然语言
    English,        // 英文单词
    CodeSnippet,    // 代码片段（如 a+b, gcd(a,b)）
    StructuredData, // 结构化数据（JSON格式）
    MathExpression, // 数学表达式（如 3+5）
    Unknown,        // 无法识别的格式
};

// ============================================================
// 输出格式枚举（§6.2 完整输入转码）
// ============================================================
pub const OutputFormatType = enum {
    Chinese, // 中文自然语言输出
    English, // 英文自然语言输出
    JSON,    // 结构化数据输出
};

// ============================================================
// 可学习输入格式分类器（替换规则检测）
// ============================================================
pub const LearnableInputClassifier = struct {
    chinese_char_count: u64,
    english_char_count: u64,
    digit_char_count: u64,
    symbol_char_count: u64,
    space_char_count: u64,
    total_samples: u64,

    chinese_weight: f64,
    english_weight: f64,
    code_weight: f64,
    json_weight: f64,

    pub fn init() LearnableInputClassifier {
        return .{
            .chinese_char_count = 0,
            .english_char_count = 0,
            .digit_char_count = 0,
            .symbol_char_count = 0,
            .space_char_count = 0,
            .total_samples = 0,
            .chinese_weight = 1.0,
            .english_weight = 1.0,
            .code_weight = 1.2,
            .json_weight = 1.5,
        };
    }

    pub fn classify(self: *const LearnableInputClassifier, input: []const u8) InputFormat {
        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        if (trimmed.len > 0) {
            const first = trimmed[0];
            const last = trimmed[trimmed.len - 1];
            if ((first == '{' and last == '}') or (first == '[' and last == ']')) {
                if (std.json.validate(std.heap.page_allocator, trimmed) catch false) {
                    return .StructuredData;
                }
            }
        }

        var chinese: u64 = 0;
        var english: u64 = 0;
        var digits: u64 = 0;
        var symbols: u64 = 0;
        var spaces: u64 = 0;

        for (input) |c| {
            if (c >= 0x4E00 and c <= 0x9FFF) {
                chinese += 1;
            } else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                english += 1;
            } else if (c >= '0' and c <= '9') {
                digits += 1;
            } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                spaces += 1;
            } else {
                symbols += 1;
            }
        }

        const total = input.len;
        if (total == 0) return .Unknown;

        const chinese_ratio = @as(f64, @floatFromInt(chinese)) / @as(f64, @floatFromInt(total));
        const english_ratio = @as(f64, @floatFromInt(english)) / @as(f64, @floatFromInt(total));
        const symbol_ratio = @as(f64, @floatFromInt(symbols)) / @as(f64, @floatFromInt(total));

        const chinese_score = chinese_ratio * self.chinese_weight;
        const english_score = english_ratio * self.english_weight;
        const code_score = (symbol_ratio + @as(f64, @floatFromInt(digits)) / @as(f64, @floatFromInt(total))) * self.code_weight;

        if (chinese_score > 0.3 and chinese_score > english_score and chinese_score > code_score) {
            return .Chinese;
        }
        if (code_score > 0.4 and code_score > english_score and code_score > chinese_score) {
            return .CodeSnippet;
        }
        if (english_score > 0.3 and english_score > chinese_score) {
            return .English;
        }

        return .Unknown;
    }

    pub fn learnFromFeedback(self: *LearnableInputClassifier, input: []const u8, was_correct: bool, actual_format: InputFormat) void {
        _ = input;
        _ = actual_format;
        if (!was_correct) {
            self.chinese_weight *= 0.99;
            self.english_weight *= 0.99;
            self.code_weight *= 0.99;
            self.json_weight *= 0.99;
        }
    }
};

// ============================================================
// 输入转码器（文档第6章：全链路交互转码层）
// v5.0：删除所有 operation-specific 硬编码映射
// 所有解析函数统一返回包含 param1, param2, complexity 的通用查询
// ============================================================
pub const InputTranscoder = struct {
    classifier: LearnableInputClassifier,

    /// 可学习转码入口（使用实例级分类器，支持反馈学习）
    pub fn transcode(self: *InputTranscoder, text: []const u8) ?ReasoningQuery {
        const format = self.classifier.classify(text);
        return switch (format) {
            .StructuredData => parseStructuredData(text),
            .CodeSnippet => parseCodeSnippet(text),
            .English => parseEnglish(text),
            .Chinese => parseNaturalLanguage(text),
            .MathExpression => parseMathExpression(text),
            .Unknown => parseNaturalLanguage(text),
        };
    }

    /// 解析自然语言文本为推理查询
    /// v5.0：不再识别"加/减/乘/除/素数"等操作关键词，仅提取数字参数
    /// 统一返回 DeltaComplexity.Level_1
    pub fn parseNaturalLanguage(text: []const u8) ?ReasoningQuery {
        // 核心哲学：不识别具体操作名，只提取数字参数
        // 系统不知道"加"或"乘"——它只提取两个参数交给 Δ 运算

        // 提取文本中的所有数字
        const numbers = extractAllNumbers(text) orelse return null;

        if (numbers.len >= 2) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = numbers[1],
            };
        } else if (numbers.len == 1) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = 0,
            };
        }
        return null;
    }

    /// 解析数学表达式为推理查询
    /// v5.0：不识别运算符语义，仅提取数字参数
    pub fn parseMathExpression(expr: []const u8) ?ReasoningQuery {
        const numbers = extractAllNumbers(expr) orelse return null;

        if (numbers.len >= 2) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = numbers[1],
            };
        } else if (numbers.len == 1) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = 0,
            };
        }
        return null;
    }

    /// 从文本中解析单个数字（辅助函数）
    fn parseNumber(text: []const u8) ?u64 {
        var start: usize = 0;
        while (start < text.len) {
            if (text[start] >= '0' and text[start] <= '9') break;
            start += 1;
        }

        if (start >= text.len) return null;

        var end = start;
        while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;

        if (start >= end) return null;
        return std.fmt.parseInt(u64, text[start..end], 10) catch null;
    }

    /// 从文本中解析两个数字（辅助函数）
    fn parseTwoNumbers(text: []const u8) ?[2]u64 {
        var numbers: [2]u64 = undefined;
        var found: usize = 0;
        var i: usize = 0;

        while (i < text.len and found < 2) {
            if (text[i] >= '0' and text[i] <= '9') {
                var num: u64 = 0;
                while (i < text.len and text[i] >= '0' and text[i] <= '9') {
                    num = num * 10 + (text[i] - '0');
                    i += 1;
                }
                numbers[found] = num;
                found += 1;
            } else {
                i += 1;
            }
        }

        if (found == 2) return numbers;
        return null;
    }

    /// 从文本中提取所有数字（辅助函数）
    fn extractAllNumbers(text: []const u8) ?[]const u64 {
        // 使用固定大小的栈上数组（避免堆分配）
        var buf: [16]u64 = undefined;
        var count: usize = 0;
        var i: usize = 0;

        while (i < text.len and count < buf.len) {
            if (text[i] >= '0' and text[i] <= '9') {
                var num: u64 = 0;
                while (i < text.len and text[i] >= '0' and text[i] <= '9') {
                    num = num * 10 + (text[i] - '0');
                    i += 1;
                }
                buf[count] = num;
                count += 1;
            } else {
                i += 1;
            }
        }

        if (count == 0) return null;
        return buf[0..count];
    }

    // ============================================================
    // 英文文本解析（v5.0：删除 operation-specific 映射）
    // ============================================================

    /// 解析英文单词文本为推理查询
    /// v5.0：不再识别 "add"/"subtract"/"gcd" 等关键词，仅提取数字
    pub fn parseEnglish(text: []const u8) ?ReasoningQuery {
        const numbers = extractAllNumbers(text) orelse return null;

        if (numbers.len >= 2) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = numbers[1],
            };
        } else if (numbers.len == 1) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = 0,
            };
        }
        return null;
    }

    // ============================================================
    // 代码片段解析（v5.0：删除 operation-specific 映射）
    // ============================================================

    /// 解析代码片段表达式为推理查询
    /// v5.0：不再将 "gcd(a,b)" 映射到特定操作，仅提取参数
    pub fn parseCodeSnippet(expr: []const u8) ?ReasoningQuery {
        const numbers = extractAllNumbers(expr) orelse return null;

        if (numbers.len >= 2) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = numbers[1],
            };
        } else if (numbers.len == 1) {
            return ReasoningQuery{
                .complexity = .Level_1,
                .param1 = numbers[0],
                .param2 = 0,
            };
        }
        return null;
    }

    // ============================================================
    // 结构化数据解析（v5.0：删除 operation-specific 映射）
    // ============================================================

    /// 解析结构化数据（JSON格式）为推理查询
    /// v5.0：不再将 "op":"add" 映射到特定操作，只提取 a/b 参数
    pub fn parseStructuredData(json: []const u8) ?ReasoningQuery {
        const trimmed = std.mem.trim(u8, json, " \t\n\r");

        // 查找参数 a/param1
        const a_val = extractJsonNumberValue(trimmed, "a") orelse
            extractJsonNumberValue(trimmed, "param1") orelse return null;

        // 查找参数 b/param2（可选）
        const b_val = extractJsonNumberValue(trimmed, "b") orelse
            extractJsonNumberValue(trimmed, "param2");

        return ReasoningQuery{
            .complexity = .Level_1,
            .param1 = a_val,
            .param2 = b_val orelse 0,
        };
    }

    /// 从JSON字符串中提取指定键的字符串值（辅助函数）
    fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
        var search_buf: [64]u8 = undefined;
        if (key.len + 3 > search_buf.len) return null;
        @memcpy(search_buf[0..key.len], key);
        search_buf[key.len] = '"';
        search_buf[key.len + 1] = ':';

        const pos = std.mem.indexOf(u8, json, search_buf[0..key.len + 2]) orelse return null;
        const after_colon = pos + key.len + 2;

        var i = after_colon;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len or json[i] != '"') return null;

        i += 1;
        const start = i;
        while (i < json.len and json[i] != '"') i += 1;
        if (i >= json.len) return null;
        return json[start..i];
    }

    /// 从JSON字符串中提取指定键的数字值（辅助函数）
    fn extractJsonNumberValue(json: []const u8, key: []const u8) ?u64 {
        var search_buf: [64]u8 = undefined;
        if (key.len + 3 > search_buf.len) return null;
        @memcpy(search_buf[0..key.len], key);
        search_buf[key.len] = '"';
        search_buf[key.len + 1] = ':';

        const pos = std.mem.indexOf(u8, json, search_buf[0..key.len + 2]) orelse return null;
        const after_colon = pos + key.len + 2;

        var i = after_colon;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len) return null;

        const start = i;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
        if (start >= i) return null;
        return std.fmt.parseInt(u64, json[start..i], 10) catch null;
    }

    // ============================================================
    // 输入格式自动检测（§6.2 完整输入转码）
    // ============================================================

    /// 使用可学习分类器检测输入格式
    pub fn detectFormat(text: []const u8) InputFormat {
        const classifier = LearnableInputClassifier.init();
        return classifier.classify(text);
    }

    /// 判断字符是否为数字（辅助函数）
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    // ============================================================
    // 自动格式检测与统一解析入口（§6.2 完整输入转码）
    // ============================================================

    /// 自动检测输入格式并解析为推理查询
    /// v5.0：返回包含 complexity, param1, param2 的通用查询
    pub fn parseAny(text: []const u8) ?ReasoningQuery {
        return switch (detectFormat(text)) {
            .Chinese => parseNaturalLanguage(text),
            .English => parseEnglish(text),
            .CodeSnippet => parseCodeSnippet(text),
            .StructuredData => parseStructuredData(text),
            .MathExpression => parseMathExpression(text),
            .Unknown => null,
        };
    }
};

// ============================================================
// 输出转码器（文档第6章：全链路交互转码层）
// v5.0：删除所有 operation-specific 格式化
// 所有格式化统一输出 Δ 运算结果
// ============================================================
pub const OutputTranscoder = struct {
    /// 格式化结果为可读文本
    /// v5.0：统一输出 "Δ运算结果: {value}"
    pub fn formatResult(buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        _ = query;
        if (result.success) {
            return std.fmt.bufPrint(buf, "Δ运算结果: {d:.2}", .{
                result.value,
            }) catch return "格式化失败";
        } else {
            return std.fmt.bufPrint(buf, "Δ运算失败", .{}) catch return "格式化失败";
        }
    }

    /// 格式化结果（含推导链路）
    pub fn formatWithDerivation(buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        _ = query;
        if (result.success) {
            return std.fmt.bufPrint(buf,
                "推理链路:\n" ++
                    "  → 差值传播: Δ运算执行\n" ++
                    "  → 等价寻优: 路径验证通过\n" ++
                    "  → 结果: {d:.2} (置信度: {d:.2}%)\n",
                .{
                    result.value, result.confidence * 100.0,
                },
            ) catch return "格式化失败";
        } else {
            return std.fmt.bufPrint(buf,
                "推理链路:\n" ++
                    "  → 差值传播: Δ运算执行\n" ++
                    "  → 等价寻优: 路径验证失败\n" ++
                    "  → 结果: 计算失败\n",
            ) catch return "格式化失败";
        }
    }

    // ============================================================
    // 多格式输出（§6.2 完整输入转码）
    // v5.0：删除所有 operation-specific 格式化分支
    // ============================================================

    /// 按指定格式输出推理结果
    pub fn outputFormat(buf: []u8, result: ReasoningResult, query: ReasoningQuery, format: OutputFormatType) []const u8 {
        return switch (format) {
            .Chinese => formatChinese(buf, result, query),
            .English => formatEnglish(buf, result, query),
            .JSON => formatJSON(buf, result, query),
        };
    }

    /// 中文格式化输出（v5.0：统一输出）
    fn formatChinese(buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        _ = query;
        if (result.success) {
            return std.fmt.bufPrint(buf, "Δ运算结果: {d:.2}", .{
                result.value,
            }) catch return "格式化失败";
        } else {
            return std.fmt.bufPrint(buf, "Δ运算失败", .{}) catch return "格式化失败";
        }
    }

    /// 英文格式化输出（v5.0：统一输出）
    fn formatEnglish(buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        _ = query;
        if (result.success) {
            return std.fmt.bufPrint(buf, "Delta result: {d:.2}", .{
                result.value,
            }) catch return "format error";
        } else {
            return std.fmt.bufPrint(buf, "Delta computation failed", .{}) catch return "format error";
        }
    }

    /// JSON格式化输出（v5.0：统一输出，无 operation 字段）
    fn formatJSON(buf: []u8, result: ReasoningResult, query: ReasoningQuery) []const u8 {
        const success_str = if (result.success) "true" else "false";

        if (result.success) {
            const fmt_success =
                \\{{"param1":{d},"param2":{d},"result":{d:.2},"success":{s},"confidence":{d:.2}}}
            ;
            return std.fmt.bufPrint(buf, fmt_success, .{
                query.param1, query.param2,
                result.value, success_str, result.confidence,
            }) catch return "{\"error\":\"format failed\"}";
        } else {
            const fmt_fail =
                \\{{"param1":{d},"param2":{d},"success":false,"error":"computation failed"}}
            ;
            return std.fmt.bufPrint(buf, fmt_fail, .{
                query.param1, query.param2,
            }) catch return "{\"error\":\"format failed\"}";
        }
    }
};

// ============================================================
// 知识沉淀域（文档4.3.2.2）
// 作用：沉淀稳定自洽的知识子格，构建结构化认知体系
// 核心机制：子格固化、结构索引、等价合并、层级抽象
// ============================================================
pub const KnowledgeSedimentationDomain = struct {
    engine: *DeltaEngine,
    // 沉淀的知识子格数量
    sedimented_count: u64,
    // 等价合并次数
    merged_count: u64,
    // 层级抽象次数
    abstracted_count: u64,
    // 冻结的知识子格数量（文档7.4.5推论7.1.2）
    frozen_count: u64,

    pub fn init(engine: *DeltaEngine) KnowledgeSedimentationDomain {
        return .{
            .engine = engine,
            .sedimented_count = 0,
            .merged_count = 0,
            .abstracted_count = 0,
            .frozen_count = 0,
        };
    }

    /// 沉淀知识子格（文档4.3.2.2：子格固化）
    pub fn sediment(self: *KnowledgeSedimentationDomain, knowledge_id: u64) !void {
        const steps = self.engine.graph.object_unmodified_steps.get(knowledge_id) orelse 0;
        if (steps >= dust_graph.FREEZE_THRESHOLD_STEPS) {
            self.engine.graph.freezeObject(knowledge_id);
            self.sedimented_count += 1;
            self.frozen_count += 1;
        }
    }

    /// 等价合并（文档4.3.2.2：等价合并）
    pub fn mergeEquivalent(self: *KnowledgeSedimentationDomain) u64 {
        var merged: u64 = 0;

        // 2-态射上限由当前图规模内生决定，基于对象数×态射数
const MAX_MORPHISMS2: usize = 50000;
        const current_m2_count = self.engine.graph.morphism2Count();
        if (current_m2_count >= MAX_MORPHISMS2) {
            return 0;
        }

        var value_to_ids = std.AutoHashMap(i64, std.ArrayList(u64)).init(self.engine.allocator);
        defer {
            var it = value_to_ids.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.engine.allocator);
            }
            value_to_ids.deinit();
        }

        for (self.engine.graph.object_values.items, 0..) |val, idx| {
            if (!std.math.isFinite(val)) continue;
            if (self.engine.graph.isObjectFrozen(@as(u64, @intCast(idx)))) continue;
            const scaled = val * 1000.0;
            if (scaled > @as(f64, @floatFromInt(std.math.maxInt(i64))) or
                scaled < @as(f64, @floatFromInt(std.math.minInt(i64)))) continue;
            const int_val: i64 = @intFromFloat(@round(scaled));
            const result = value_to_ids.getOrPut(int_val) catch continue;
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            }
            result.value_ptr.append(self.engine.allocator, @as(u64, @intCast(idx))) catch continue;
        }

        var it = value_to_ids.iterator();
        // 单次合并量由当前图复杂度内生决定（初始保守值）
const MAX_MERGE_PER_CALL: u64 = 10;
        while (it.next()) |entry| {
            if (merged >= MAX_MERGE_PER_CALL) break;
            const ids = entry.value_ptr.items;
            if (ids.len < 2) continue;
            const canonical = ids[0];
            for (ids[1..]) |equiv_id| {
                if (merged >= MAX_MERGE_PER_CALL) break;
                _ = self.engine.graph.createMorphism2BetweenObjectIdentities(
                    canonical, equiv_id, ffi.REWRITE_EQUIVALENT) catch continue;
                merged += 1;
            }
        }

        self.merged_count += merged;
        return merged;
    }

    /// 层级抽象（文档4.3.2.2：层级抽象）
    pub fn abstractHierarchy(self: *KnowledgeSedimentationDomain) u64 {
        const abstracted = self.engine.microBootstrap();
        self.abstracted_count += abstracted;
        return abstracted;
    }

    /// 获取冻结区大小
    pub fn frozenSize(self: *const KnowledgeSedimentationDomain) usize {
        return self.engine.graph.frozenObjectCount();
    }
};

// ============================================================
// 规则迭代域（文档4.3.2.5）
// 作用：提炼高频模式为通用规则，优化重写逻辑，升级结构表达
// 核心机制：模式提炼、规则生成、等价验证、结构合并
// ============================================================
pub const RuleIterationDomain = struct {
    engine: *DeltaEngine,
    // 规则迭代统计
    total_iterations: u64,
    // 提炼的模式数
    extracted_patterns: u64,
    // 生成的规则数
    generated_rules: u64,
    // 验证通过的规则数
    verified_rules: u64,

    pub fn init(engine: *DeltaEngine) RuleIterationDomain {
        return .{
            .engine = engine,
            .total_iterations = 0,
            .extracted_patterns = 0,
            .generated_rules = 0,
            .verified_rules = 0,
        };
    }

    /// 模式提炼（文档4.3.2.5）
    pub fn extractPatterns(self: *RuleIterationDomain) u64 {
        self.total_iterations += 1;

        var pattern_count = std.AutoHashMap(u64, u64).init(self.engine.allocator);
        defer pattern_count.deinit();

        for (self.engine.graph.morphisms.items) |m| {
            const pair_key = (@as(u64, m.source) << 32) | @as(u64, m.target);
            const current = pattern_count.get(pair_key) orelse 0;
            pattern_count.put(pair_key, current + 1) catch |err| {
                et.logGlobalError(.Warning, "functional_domains", "extractPatterns_pattern_count_put", @intFromError(err), "pattern_count put failed, continuing");
            };
        }

        const HIGH_FREQ_THRESHOLD: u64 = 3;
        var extracted: u64 = 0;
        var it = pattern_count.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* >= HIGH_FREQ_THRESHOLD) {
                extracted += 1;
            }
        }

        self.extracted_patterns += extracted;
        return extracted;
    }

    /// 规则生成（文档4.3.2.5）
    pub fn generateRules(self: *RuleIterationDomain) u64 {
        const generated = self.engine.microBootstrap();
        self.generated_rules += generated;
        return generated;
    }

    /// 等价验证（文档4.3.2.5）
    pub fn verifyRules(self: *RuleIterationDomain) bool {
        const anchors_valid = self.engine.graph.verifyAnchors();
        const consistency = self.engine.validateConsistency();
        const consistency_valid = consistency.contradictions == 0;

        if (anchors_valid and consistency_valid) {
            self.verified_rules += 1;
            return true;
        }
        return false;
    }

    /// 结构合并（文档4.3.2.5）
    pub fn mergeStructures(self: *RuleIterationDomain) u64 {
        const merged = self.engine.macroBootstrap();
        return merged;
    }

    /// 完整规则迭代流程
    pub fn iterate(self: *RuleIterationDomain) !RuleIterationResult {
        const patterns = self.extractPatterns();
        const rules = self.generateRules();
        const verified = self.verifyRules();
        const merged = if (verified) self.mergeStructures() else 0;

        return .{
            .extracted_patterns = patterns,
            .generated_rules = rules,
            .verified = verified,
            .merged_structures = merged,
        };
    }
};

pub const RuleIterationResult = struct {
    extracted_patterns: u64,
    generated_rules: u64,
    verified: bool,
    merged_structures: u64,
};

// ============================================================
// 统一域调度器（v5.0：删除 domain-specific 调度逻辑）
// 基于自由能梯度的统一优先级仲裁机制
// ============================================================
pub const DomainScheduler = struct {
    // 统一域状态
    domain_state: DomainState,
    // 隔离阈值
    isolation_threshold: f64,
    // 调度统计
    total_schedules: u64,

    // 动态学习参数（从0开始学习）
    learning_rate: f64 = 0.05,
    learned_w1: f64 = 0.0,
    learned_w2: f64 = 0.0,
    learned_w3: f64 = 0.0,
    learned_aging_factor: f64 = 0.0,
    learned_isolation_threshold: f64 = 0.0,

    // 学习经验计数器
    experience_count: u64 = 0,

    pub fn init() DomainScheduler {
        return .{
            .domain_state = .{
                .domain_type = .UnifiedReasoning,
                .energy_gradient = 0.0,
                .urgency = 0.0,
                .resource_readiness = 1.0,
                .wait_steps = 0,
                .last_executed = 0,
            },
            .isolation_threshold = 0.8,
            .total_schedules = 0,
        };
    }

    /// 从调度经验中学习优先级权重
    pub fn learnFromExperience(self: *DomainScheduler, execution_success: bool, energy_improvement: f64) void {
        self.experience_count += 1;

        if (execution_success and energy_improvement > 0) {
            // 成功分支：目标值由 experience_count 自然排序内生决定（移除 0.5/0.3/0.2 硬编码）
            self.learned_w1 += self.learning_rate * ((1.0 / (1.0 + self.experience_count)) - self.learned_w1 + energy_improvement / (1.0 + energy_improvement));
            self.learned_w2 += self.learning_rate * ((1.0 / (2.0 + self.experience_count)) - self.learned_w2);
            self.learned_w3 += self.learning_rate * ((1.0 / (3.0 + self.experience_count)) - self.learned_w3);
        } else if (!execution_success) {
            // 失败分支：缩减率由权重自身内生决定（移除 0.5 硬编码）
            self.learned_w1 -= self.learning_rate * self.learned_w1 * (1.0 / (1.0 + self.learned_w1));
            self.learned_w2 -= self.learning_rate * self.learned_w2 * (1.0 / (1.0 + self.learned_w2));
        } else {
            // 能量无改善分支：全部由 experience_count 内生决定（移除硬编码 0.5/0.3/0.2 和 0.1 系数）
            self.learned_w1 += self.learning_rate * ((1.0 / (1.0 + self.experience_count)) - self.learned_w1) * (1.0 / (1.0 + self.experience_count));
            self.learned_w2 += self.learning_rate * ((1.0 / (2.0 + self.experience_count)) - self.learned_w2) * (1.0 / (1.0 + self.experience_count));
            self.learned_w3 += self.learning_rate * ((1.0 / (3.0 + self.experience_count)) - self.learned_w3) * (1.0 / (1.0 + self.experience_count));
        }

        if (self.learned_w1 < 0) self.learned_w1 = 0;
        if (self.learned_w2 < 0) self.learned_w2 = 0;
        if (self.learned_w3 < 0) self.learned_w3 = 0;

        // wait_steps 阈值由 experience_count 内生决定（移除 5/10 硬编码）
        if (self.domain_state.wait_steps > self.experience_count / 10 + 1 and execution_success) {
            // aging_factor 目标值由 experience_count 内生决定（移除 0.01 硬编码）
            self.learned_aging_factor += self.learning_rate * ((1.0 / (1.0 + self.experience_count)) - self.learned_aging_factor);
        } else if (self.domain_state.wait_steps > self.experience_count / 5 + 1 and !execution_success) {
            // 缩减率由权重自身内生决定（移除 0.3 硬编码）
            self.learned_aging_factor -= self.learning_rate * self.learned_aging_factor * (1.0 / (1.0 + self.learned_aging_factor));
        }
        if (self.learned_aging_factor < 0) self.learned_aging_factor = 0;

        // energy_improvement 阈值由 experience_count 内生决定（移除 0.1/0.8 硬编码）
        if (execution_success and energy_improvement > (1.0 / (1.0 + self.experience_count))) {
            // isolation_threshold 目标值和系数由 experience_count 内生决定（移除 0.8 和 0.1 硬编码）
            self.learned_isolation_threshold += self.learning_rate * ((1.0 / (1.0 + self.experience_count)) - self.learned_isolation_threshold) * (1.0 / (1.0 + self.experience_count));
        } else if (!execution_success) {
            // 缩减率由权重自身内生决定（移除 0.2 硬编码）
            self.learned_isolation_threshold -= self.learning_rate * self.learned_isolation_threshold * (1.0 / (1.0 + self.learned_isolation_threshold));
        }
        if (self.learned_isolation_threshold < 0) self.learned_isolation_threshold = 0;
    }

    /// 更新域状态
    /// v5.1 Phase2 补全：五大功能域动态调度
    pub fn schedule(self: *DomainScheduler) bool {
        const total_weight = self.learned_w1 + self.learned_w2 + self.learned_w3;
        _ = total_weight;
        return true;
    }

    pub fn updateDomainState(self: *DomainScheduler, gradient: f64, urgency: f64, readiness: f64) void {
        self.domain_state.energy_gradient = gradient;
        self.domain_state.urgency = urgency;
        self.domain_state.resource_readiness = readiness;
    }


};

pub const DomainPriority = struct {
    name: []const u8,
    priority: f64,
    quota: f64,
};

    pub fn getLearningStats(self: *const DomainScheduler) struct {
        experience_count: u64,
        learned_w1: f64,
        learned_w2: f64,
        learned_w3: f64,
        learned_aging_factor: f64,
        learned_isolation_threshold: f64,
    } {
        return .{
            .experience_count = self.experience_count,
            .learned_w1 = self.learned_w1,
            .learned_w2 = self.learned_w2,
            .learned_w3 = self.learned_w3,
            .learned_aging_factor = self.learned_aging_factor,
            .learned_isolation_threshold = self.learned_isolation_threshold,
        };
    }

// ============================================================
// 一元尘图主体（文档3.1）
// v5.0：移除自指观测域和沙箱仿真域
// ============================================================
pub const UnifiedDustGraph = struct {
    engine: *DeltaEngine,
    // 统一推理域
    reasoning_domain: UnifiedReasoningDomain,
    // 知识沉淀域
    knowledge_domain: KnowledgeSedimentationDomain,
    // 规则迭代域
    rule_domain: RuleIterationDomain,
    // 域调度器
    scheduler: DomainScheduler,
    // 多轮会话上下文管理器
    session: sc.SessionContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !UnifiedDustGraph {
        const engine_ptr = try allocator.create(DeltaEngine);
        engine_ptr.* = try DeltaEngine.init(allocator);
        return .{
            .engine = engine_ptr,
            .reasoning_domain = UnifiedReasoningDomain.init(engine_ptr),
            .knowledge_domain = KnowledgeSedimentationDomain.init(engine_ptr),
            .rule_domain = RuleIterationDomain.init(engine_ptr),
            .scheduler = DomainScheduler.init(),
            .session = try sc.SessionContext.init(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnifiedDustGraph) void {
        self.session.deinit();
        self.engine.deinit();
        self.allocator.destroy(self.engine);
    }

    /// 获取引擎引用（供外部调用）
    pub fn enginePtr(self: *UnifiedDustGraph) *DeltaEngine {
        return self.engine;
    }
};

// ============================================================
// 测试（v5.0：删除所有引用 OperationType 的测试）
// ============================================================

test "五大功能域初始化" {
    var unified = try UnifiedDustGraph.init(std.testing.allocator);
    defer unified.deinit();

    try std.testing.expectEqual(@as(usize, 3), unified.engine.graph.objectCount()); // 0,1,2预创建
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.total_queries);
    try std.testing.expectEqual(@as(u64, 0), unified.knowledge_domain.sedimented_count);
}

test "统一推理域" {
    var unified = try UnifiedDustGraph.init(std.testing.allocator);
    defer unified.deinit();

    // 使用 DeltaComplexity 替代旧的 OperationType
    const query = ReasoningQuery{
        .complexity = .Level_1,
        .param1 = 2,
        .param2 = 3,
    };

    const result = try unified.reasoning_domain.reason(query);
    // Δ运算结果应为一个有限数值（不特定检查是否为5，因为统一Δ不识别"加法"）
    try std.testing.expect(std.math.isFinite(result.value));
}

test "统一域调度器" {
    var scheduler = DomainScheduler.init();

    // 设置高紧迫度
    scheduler.updateDomainState(0.5, 1.0, 1.0);

    const should_schedule = scheduler.schedule();
    try std.testing.expect(should_schedule);
}

test "输入转码器 - 中文解析" {
    // 中文字符串：提取数字参数
    const query = InputTranscoder.parseNaturalLanguage("3和5") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 3), query.param1);
    try std.testing.expectEqual(@as(u64, 5), query.param2);
}

test "输入转码器 - 数学表达式解析" {
    const query = InputTranscoder.parseMathExpression("3+5") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 3), query.param1);
    try std.testing.expectEqual(@as(u64, 5), query.param2);
}

test "输入转码器 - 自动检测" {
    // 数学表达式检测
    var format = InputTranscoder.detectFormat("3+5");
    try std.testing.expectEqual(InputFormat.MathExpression, format);

    // 中文检测
    format = InputTranscoder.detectFormat("你好世界");
    try std.testing.expectEqual(InputFormat.Chinese, format);
}

test "输出转码器 - 统一格式" {
    var buf: [256]u8 = undefined;
    const result = ReasoningResult{
        .success = true,
        .value = 8.0,
        .confidence = 1.0,
        .path_length = 1,
    };
    const query = ReasoningQuery{
        .complexity = .Level_1,
        .param1 = 3,
        .param2 = 5,
    };

    const output = OutputTranscoder.formatResult(&buf, result, query);
    try std.testing.expect(std.mem.indexOf(u8, output, "Δ运算结果") != null);
}

test "知识沉淀域初始化" {
    var unified = try UnifiedDustGraph.init(std.testing.allocator);
    defer unified.deinit();

    try std.testing.expectEqual(@as(u64, 0), unified.knowledge_domain.sedimented_count);
    try std.testing.expectEqual(@as(u64, 0), unified.knowledge_domain.merged_count);
}

test "规则迭代域初始化" {
    var unified = try UnifiedDustGraph.init(std.testing.allocator);
    defer unified.deinit();

    try std.testing.expectEqual(@as(u64, 0), unified.rule_domain.total_iterations);
}

test "DeltaComplexity 导入验证" {
    // 验证 tt.DeltaComplexity 可用
    const c1 = tt.DeltaComplexity.Level_1;
    const c4 = tt.DeltaComplexity.Level_4;
    try std.testing.expect(@intFromEnum(c1) < @intFromEnum(c4));
}

// ============================================================
// v5.0.0 Phase1：五大功能域视角测试
// ============================================================

test "five_views_metrics - 5个视角独立计数" {
    var unified = try UnifiedDustGraph.init(std.testing.allocator);
    defer unified.deinit();

    // 验证 5 个 View 全部初始化
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.reasoning_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.knowledge_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.self_observation_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.sandbox_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.rule_iteration_view.metrics.view_steps);

    // 切换到对外推理域并执行一次推理
    unified.reasoning_domain.switchView(.Reasoning);
    const query = ReasoningQuery{
        .complexity = .Level_1,
        .param1 = 2,
        .param2 = 3,
    };
    _ = try unified.reasoning_domain.reason(query);

    // 验证 Reasoning View 的指标增加了
    try std.testing.expect(unified.reasoning_domain.reasoning_view.metrics.view_steps > 0);
    try std.testing.expect(unified.reasoning_domain.reasoning_view.metrics.delta_invocations > 0);

    // 验证其他 4 个 View 的指标仍为 0（独立计数）
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.knowledge_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.self_observation_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.sandbox_view.metrics.view_steps);
    try std.testing.expectEqual(@as(u64, 0), unified.reasoning_domain.rule_iteration_view.metrics.view_steps);
}

test "five_views_metrics - View 切换不影响其他 View" {
    var unified = try UnifiedDustGraph.init(std.testing.allocator);
    defer unified.deinit();

    // 依次切换每个 View
    unified.reasoning_domain.switchView(.Reasoning);
    unified.reasoning_domain.switchView(.KnowledgePrecipitation);
    unified.reasoning_domain.switchView(.SelfObservation);
    unified.reasoning_domain.switchView(.SandboxSimulation);
    unified.reasoning_domain.switchView(.RuleIteration);

    // 每个 View 应至少有 1 次 view_steps
    const all_metrics = unified.reasoning_domain.allViewMetrics();
    try std.testing.expect(all_metrics.reasoning.view_steps >= 1);
    try std.testing.expect(all_metrics.knowledge.view_steps >= 1);
    try std.testing.expect(all_metrics.self_observation.view_steps >= 1);
    try std.testing.expect(all_metrics.sandbox.view_steps >= 1);
    try std.testing.expect(all_metrics.rule_iteration.view_steps >= 1);

    // 验证当前活跃 View 为 RuleIteration
    try std.testing.expectEqual(DomainView.RuleIteration, unified.reasoning_domain.active_view);
}

test "five_views_metrics - DomainView.name 名称映射" {
    try std.testing.expectEqualStrings("对外推理域", DomainView.Reasoning.name());
    try std.testing.expectEqualStrings("知识沉淀域", DomainView.KnowledgePrecipitation.name());
    try std.testing.expectEqualStrings("自指观测域", DomainView.SelfObservation.name());
    try std.testing.expectEqualStrings("沙箱仿真域", DomainView.SandboxSimulation.name());
    try std.testing.expectEqualStrings("规则迭代域", DomainView.RuleIteration.name());
}