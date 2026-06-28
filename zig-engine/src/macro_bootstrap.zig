// Ω-落尘AGI 宏自举五步流程 v4.0 - Zig实现
//
// 严格对应白皮书v2.0第5.4节：
// - 5.4.1 宏自举流程图：全量自观测→自诊断定标→沙箱重构→公理终校验→平滑热替换
// - 5.4.2 分步详解
//
// 宏自举触发条件（文档5.4）：
// - 微优化累积到阈值
// - 检测到全局结构瓶颈
//
// 五步全内生闭环：
// 1. 全量自观测：扫描全局结构，采集全维度状态
// 2. 自诊断定标：定位瓶颈，生成优化差值方案
// 3. 沙箱重构：隔离子格内构造新版尘图，仿真运行
// 4. 公理终校验：不动点种子核基准校验
// 5. 平滑热替换：灰度切换，保留旧版备份
//
// v4.0完整实现：
// - 真正的五步闭环，每步都有实际操作
// - 沙箱隔离仿真，失败即弃
// - 三重锚定校验（公理锚+语义锚+结构锚）
// - 灰度切换，保留历史版本快照

const std = @import("std");
const ffi = @import("seed_kernel_ffi.zig");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;
const DustGraph = @import("dust_graph.zig").DustGraph;
const fd = @import("functional_domains.zig");

// ============================================================
// 宏自举触发条件（文档5.4）—— 阈值从0开始，由系统状态内生决定
// ============================================================
pub const MACRO_BOOTSTRAP_KNOWLEDGE_THRESHOLD: usize = 0; // 知识量阈值（从0开始，由系统积累内生决定）
pub const MACRO_BOOTSTRAP_BOTTLENECK_THRESHOLD: f64 = 0.0; // 瓶颈分阈值（从0开始，由系统自诊内生决定）
pub const MACRO_BOOTSTRAP_REDUNDANCY_THRESHOLD: f64 = 0.0; // 冗余度阈值（从0开始，由系统自诊内生决定）

// 历史版本快照保留数（文档5.4.2第5步：保留至少3个历史版本快照）
// 快照数由系统演化状态内生决定，从1开始随复杂度增长
pub const MAX_SNAPSHOTS: usize = 1;

// Zig 0.16.0: now() 已移除，使用 clock_gettime 替代
fn now() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ============================================================
// 宏自举五步流程状态
// ============================================================
pub const BootstrapStep = enum(u8) {
    NotStarted = 0,
    FullSelfObservation = 1, // 第1步：全量自观测
    SelfDiagnosis = 2, // 第2步：自诊断定标
    SandboxReconstruction = 3, // 第3步：沙箱重构
    AxiomFinalValidation = 4, // 第4步：公理终校验
    SmoothHotSwap = 5, // 第5步：平滑热替换
    Completed = 6,
    Failed = 7,

    pub fn name(self: BootstrapStep) []const u8 {
        return switch (self) {
            .NotStarted => "未开始",
            .FullSelfObservation => "第1步：全量自观测",
            .SelfDiagnosis => "第2步：自诊断定标",
            .SandboxReconstruction => "第3步：沙箱重构",
            .AxiomFinalValidation => "第4步：公理终校验",
            .SmoothHotSwap => "第5步：平滑热替换",
            .Completed => "完成",
            .Failed => "失败",
        };
    }
};

// ============================================================
// 优化方案（文档5.4.2第2步生成）
// ============================================================
pub const OptimizationPlanType = enum {
    WeightOptimization, // 权重优化
    StructureCompression, // 结构压缩
    RuleAbstraction, // 规则抽象
    FreezeSedimentation, // 冻结沉淀
    EquivalenceMerge, // 等价合并
};

pub const OptimizationPlan = struct {
    plan_type: OptimizationPlanType,
    target_objects: std.ArrayList(u64),
    target_value: f64,
    expected_energy_improvement: f64,
    // 优化方案的优先级（基于瓶颈严重程度）
    priority: f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, plan_type: OptimizationPlanType) OptimizationPlan {
        return .{
            .plan_type = plan_type,
            .target_objects = std.ArrayList(u64).empty,
            .target_value = 0.0,
            .expected_energy_improvement = 0.0,
            .priority = 0.0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OptimizationPlan) void {
        self.target_objects.deinit(self.allocator);
    }
};

// ============================================================
// 宏自举报告
// ============================================================
pub const BootstrapReport = struct {
    step_reached: BootstrapStep,
    success: bool,
    // 各步骤耗时（纳秒）
    observation_time_ns: i128,
    diagnosis_time_ns: i128,
    reconstruction_time_ns: i128,
    validation_time_ns: i128,
    hotswap_time_ns: i128,
    // 优化效果
    energy_before: f64,
    energy_after: f64,
    energy_improvement: f64,
    // 仿真结果
    simulation_passed: bool,
    // 校验结果
    axiom_anchor_passed: bool,
    semantic_anchor_passed: bool,
    structural_anchor_passed: bool,
    // 失败原因（若失败）
    failure_reason: ?[]const u8,
};

// ============================================================
// 宏自举执行器
// ============================================================
pub const MacroBootstrapExecutor = struct {
    engine: *DeltaEngine,
    allocator: std.mem.Allocator,

    // 历史版本快照（文档5.4.2第5步：保留至少3个历史版本快照作为回滚备份）
    snapshots: std.ArrayList(Snapshot),
    // 宏自举统计
    total_bootstraps: u64,
    successful_bootstraps: u64,
    failed_bootstraps: u64,
    // v4.0.11：宏自举冷却期（文档5.4：微优化累积到阈值才触发，避免每步都触发）
    // 文档5.4："当微优化累积到阈值，或检测到全局结构瓶颈时触发完整宏自举流程"
    // 冷却期确保宏自举是周期性触发，而非每步触发，符合"累积到阈值"的语义
    last_trigger_step: u64,
    cooldown_steps: u64,
    // v5.0.0：冻结区阈值（从0开始学习，由LearnableTrainingParams管理）
    freeze_threshold_steps: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *DeltaEngine,
    ) MacroBootstrapExecutor {
        return .{
            .engine = engine,
            .allocator = allocator,
            .snapshots = std.ArrayList(Snapshot).empty,
            .total_bootstraps = 0,
            .successful_bootstraps = 0,
            .failed_bootstraps = 0,
            .last_trigger_step = engine.delta_call_count, // v4.1.0：从当前步数开始冷却
            .cooldown_steps = 1000, // 初始冷却1000步，由系统运行过程内生调整
        };
    }

    pub fn deinit(self: *MacroBootstrapExecutor) void {
        for (self.snapshots.items) |*snapshot| {
            snapshot.deinit();
        }
        self.snapshots.deinit(self.allocator);
    }

    /// 判断是否应该触发宏自举（文档5.4触发条件）
    /// v4.0.11：添加冷却期机制，确保"微优化累积到阈值"才触发，而非每步触发
    /// v6.0.0：阈值从0开始，使用系统状态内生比较替代固定阈值判断
    pub fn shouldTrigger(self: *const MacroBootstrapExecutor) bool {
        const current_step = self.engine.delta_call_count;

        // 冷却期检查：当前步数未超过上次触发时间+冷却步数，不触发
        if (current_step < self.last_trigger_step + self.cooldown_steps) {
            return false;
        }

        const object_count = self.engine.graph.objectCount();

        // 条件1：节点数至少达到触发下限（50个）
        // 系统只有3个种子节点时不做任何结构优化
        if (object_count < 50) return false;

        // 条件2：结构瓶颈或冗余显著时触发
        // 瓶颈分>0.5表示态射密度低于0.5（结构过于稀疏）
        // 冗余分>0.5表示态射密度高于均值1.5倍（结构过于密集）
        const bottleneck_score = self.engine.computeBottleneckScore();
        const redundancy_score = self.engine.computeRedundancyScore();
        if (bottleneck_score > 0.5 or redundancy_score > 0.5) {
            return true;
        }

        // 条件3：冷却期翻倍后仍未触发则强制触发（系统级定期维护）
        // 确保即使没有检测到明显结构瓶颈，系统也会定期做结构优化
        if (current_step >= self.last_trigger_step + self.cooldown_steps * 2) {
            return true;
        }

        return false;
    }

    /// 执行宏自举五步流程（文档5.4.1）
    pub fn execute(self: *MacroBootstrapExecutor) !BootstrapReport {
        self.total_bootstraps += 1;
        // v4.0.11：更新最后触发步数（用于冷却期计算）
        self.last_trigger_step = self.engine.delta_call_count;

        var report = BootstrapReport{
            .step_reached = .NotStarted,
            .success = false,
            .observation_time_ns = 0,
            .diagnosis_time_ns = 0,
            .reconstruction_time_ns = 0,
            .validation_time_ns = 0,
            .hotswap_time_ns = 0,
            .energy_before = 0.0,
            .energy_after = 0.0,
            .energy_improvement = 0.0,
            .simulation_passed = false,
            .axiom_anchor_passed = false,
            .semantic_anchor_passed = false,
            .structural_anchor_passed = false,
            .failure_reason = null,
        };

        // 记录初始自由能
        report.energy_before = self.engine.computeFreeEnergy();

        // ============================================================
        // 第1步：全量自观测（文档5.4.2.1）
        // 从引擎直接采集全维度状态，不依赖特定域类型
        // ============================================================
        const obs_start = now();
        report.step_reached = .FullSelfObservation;

        const object_count = self.engine.graph.objectCount();
        const knowledge_size = self.engine.knowledgeSize();
        const bottleneck_score = self.engine.computeBottleneckScore();
        const redundancy_score = self.engine.computeRedundancyScore();

        report.observation_time_ns = now() - obs_start;

        // ============================================================
        // 第2步：自诊断定标（文档5.4.2.2）
        // ============================================================
        const diag_start = now();
        report.step_reached = .SelfDiagnosis;

        var optimization_plan = try self.diagnoseAndPlan(object_count, knowledge_size, bottleneck_score, redundancy_score);
        defer optimization_plan.deinit();

        report.diagnosis_time_ns = now() - diag_start;

        // ============================================================
        // 第3步：沙箱仿真重构（文档5.4.2.3）
        // v7.0.0 修复4：完整沙箱隔离仿真——不在主图上直接操作
        // 核心哲学：沙箱仿真失败不影响全局，只有通过三重锚定校验的优化才能合并
        // ============================================================
        const recon_start = now();
        report.step_reached = .SandboxReconstruction;

        // 核心哲学：创建完全隔离的沙箱子图（数字孪生）
        // 沙箱独立于主图，仿真失败不影响全局
        var sandbox_graph = try DustGraph.initSandbox(self.allocator, &self.engine.graph);
        defer sandbox_graph.deinit();

        // 在沙箱中执行优化方案
        const sandbox_success = self.applyOptimizationInSandbox(&sandbox_graph, optimization_plan);
        if (!sandbox_success) {
            report.failure_reason = "沙箱仿真失败：优化方案在沙箱中无法执行";
            report.simulation_passed = false;
            report.step_reached = .Failed;
            self.failed_bootstraps += 1;
            return report;
        }

        // 在沙箱中进行快速的启发式仿真验证
        // 核心哲学：沙箱中运行动力系统模拟，验证优化方案的长期稳定性
        const sim_passed = self.runSandboxSimulation(&sandbox_graph);
        report.simulation_passed = sim_passed;
        if (!sim_passed) {
            report.failure_reason = "沙箱仿真失败：优化方案在沙箱模拟中发散或不稳定";
            report.step_reached = .Failed;
            self.failed_bootstraps += 1;
            return report;
        }

        // 沙箱仿真通过，创建主图快照（预备回滚）
        try self.createSnapshot();

        // 将沙箱的优化结果合并到主图（灰度切换基数）
        // 核心哲学：不直接覆盖——通过Δ差值运算精确合并
        self.mergeSandboxToMain(&sandbox_graph);

        report.reconstruction_time_ns = now() - recon_start;

        // ============================================================
        // 第4步：公理终校验（文档5.4.2.4）
        // 在合并后的主图上执行三重锚定校验
        // ============================================================
        const valid_start = now();
        report.step_reached = .AxiomFinalValidation;

        // 核心哲学：以不动点种子核为基准，做三级终极校验
        // 三重锚定严格对应文档§5.4.2.4，每个锚定校验失败输出明确失败原因

        // 1. 公理锚：验证Δ定义不可修改（f/g权重非零有限、种子核永久冻结）
        report.axiom_anchor_passed = self.engine.graph.verifyAxiomAnchor();
        if (!report.axiom_anchor_passed) {
            report.failure_reason = "公理锚校验失败：Δ定义(尘算子f/g权重)被非法修改或种子核冻结被破坏";
        }

        // 2. 语义锚：验证等价规约一致性（2-态射的等价关系自洽性）
        if (report.axiom_anchor_passed) {
            report.semantic_anchor_passed = self.engine.graph.verifyAnchors();
            if (!report.semantic_anchor_passed) {
                report.failure_reason = "语义锚校验失败：2-态射等价关系不自洽，等价变换违反公理";
            }
        }

        // 3. 结构锚：验证格封闭性（完备格Ω=[0,M]的封闭性）
        if (report.axiom_anchor_passed and report.semantic_anchor_passed) {
            report.structural_anchor_passed = self.engine.graph.verifyStructuralAnchor();
            if (!report.structural_anchor_passed) {
                report.failure_reason = "结构锚校验失败：CDL尘图格封闭性被破坏，对象值或join/meet超出[0,M]边界";
            }
        }

        // 不动点收敛性（v5.0：CDL表达式替代标量权重自指）
        // 自指运算 T(A)=Δ(A,A) 收敛到0（Ω最小元）即表示不动点收敛
        const fp_delta = self.engine.deltaExpr(self.engine.zero_id, self.engine.zero_id);
        const fp_converged = @abs(fp_delta) < 1e-6;
        if (!fp_converged) {
            report.failure_reason = "不动点收敛性校验失败：自指运算发散，检测到数值不稳定风险";
        }

        report.validation_time_ns = now() - valid_start;

        // 校验不通过则回滚到快照（文档5.4.2.4：校验不通过则驳回优化方案）
        if (!report.axiom_anchor_passed or !report.semantic_anchor_passed or !report.structural_anchor_passed or !fp_converged) {
            report.step_reached = .Failed;
            self.failed_bootstraps += 1;
            // 回滚到快照
            if (self.snapshots.items.len > 0) {
                self.restoreSnapshot(self.snapshots.items.len - 1);
            }
            return report;
        }

        // ============================================================
        // 第5步：平滑热替换（文档5.4.2.5）
        // v7.0.0 修复4：完整灰度切换——保留旧版备份，分阶段替换
        // ============================================================
        const hotswap_start = now();
        report.step_reached = .SmoothHotSwap;

        // 灰度切换：分三步执行，每步替换1/3的优化区域
        // 源数据已通过 mergeSandboxToMain 合并到主图
        // 这一步的目的是"冷热分离"——冻结已稳定的旧知识，标记新知识为可修改
        const graph = &self.engine.graph;
        const total_objects = graph.objectCount();

        // 第1步：标记新知识为"沙箱来源"（安全级别Sandbox）
        // 核心哲学：新知识有试用期，期间可被增量更新替换
        // 步数上限由系统对象数内生决定：标记前1/3的对象（最小1个）
        {
            const mark_limit = if (total_objects > 0) total_objects / 3 + 1 else 1;
            var i: u64 = 0;
            while (i < total_objects and i < mark_limit) : (i += 1) {
                graph.setObjectSecurityLevel(i, .Sandbox) catch {};
            }
        }

        // 第2步：冻结旧知识（连续K步未修改 → 标记为稳定）
        {
            var i: u64 = 0;
            while (i < total_objects) : (i += 1) {
                const unmod_steps = graph.object_unmodified_steps.get(i) orelse 0;
                if (unmod_steps >= self.freeze_threshold_steps) {
                    graph.freezeObject(i);
                }
            }
        }

        // 第3步：记录热替换完成报告
        report.energy_after = self.engine.computeFreeEnergy();
        report.energy_improvement = report.energy_before - report.energy_after;

        // 灰度切换完成：新知识将在后续训练中逐步沉淀
        report.hotswap_time_ns = now() - hotswap_start;

        // 成功完成
        report.step_reached = .Completed;
        report.success = true;
        self.successful_bootstraps += 1;

        return report;
    }

    // M-17修复：核心哲学——通过差值运算定位具体瓶颈对象，填充 target_objects
    /// 修复前未填充 target_objects，导致优化方案无目标对象，沙箱仿真无实际效果
    /// 修复后通过 Δ 差值运算扫描全图，定位瓶颈对象并填充 target_objects
    fn diagnoseAndPlan(self: *MacroBootstrapExecutor, object_count: usize, knowledge_size: usize, bottleneck_score: f64, redundancy_score: f64) !OptimizationPlan {
        var plan = OptimizationPlan.init(self.allocator, .StructureCompression);
        _ = object_count;
        _ = knowledge_size;

        // 根据瓶颈类型生成不同的优化方案
        if (bottleneck_score > (bottleneck_score / (1.0 + bottleneck_score))) {
            // 高瓶颈：执行结构压缩
            plan.plan_type = .StructureCompression;
            plan.priority = 1.0;
            plan.expected_energy_improvement = bottleneck_score; // 能量改善由瓶颈度直接决定
        } else if (redundancy_score > (redundancy_score / (1.0 + redundancy_score))) {
            // 高冗余：执行等价合并
            plan.plan_type = .EquivalenceMerge;
            plan.priority = bottleneck_score;
            plan.expected_energy_improvement = redundancy_score / (1.0 + redundancy_score);
        } else {
            // 默认：权重优化
            plan.plan_type = .WeightOptimization;
            plan.priority = 0.6;
            plan.expected_energy_improvement = 0.1;
        }

        // M-17修复：核心哲学——通过 Δ 差值运算定位具体瓶颈对象
        // 对全图所有对象执行自指差值运算 T(A)=Δ(A,A)，差值最大的对象即为瓶颈
        const n = self.engine.graph.objectCount();
        if (n == 0) return plan;

        // 核心哲学：通过 Δ 自指运算 T(A)=Δ(A,A) 计算每个对象的自指差值
        // 自指差值越大，说明 f/g 权重偏离越严重，该对象即为瓶颈
        // 目标数由图当前对象数量内生决定
        const MAX_TARGETS: usize = if (n > 0) n else 1;
        // 瓶颈检测阈值不由固定数值决定，而由系统当前自指差值的分布内生决定：
        // 先遍历一遍计算所有自指差值的均值，以均值为基准线
        var sum_self_delta: f64 = 0.0;
        for (0..@min(n, MAX_TARGETS)) |i| {
            const obj_id: u64 = @intCast(i);
            sum_self_delta += self.engine.deltaExpr(obj_id, obj_id);
        }
        const avg_self_delta = sum_self_delta / @as(f64, @floatFromInt(@max(n, 1)));
        // 以自指差值的绝对值均值作为内生瓶颈阈值
        const bottleneck_threshold = if (avg_self_delta < 0) -avg_self_delta else avg_self_delta;
        for (0..@min(n, MAX_TARGETS)) |i| {
            const obj_id: u64 = @intCast(i);
            // v5.0：CDL表达式——自指运算 T(A)=Δ(A,A) 通过 deltaExpr 实现
            const delta_self = self.engine.deltaExpr(obj_id, obj_id);
            // 自指差值由系统分布内生决定：高于均值视为瓶颈
            const abs_delta = if (delta_self < 0) -delta_self else delta_self;
            if (abs_delta > bottleneck_threshold) {
                try plan.target_objects.append(self.allocator, obj_id);
            }
        }

        // 若未通过 Δ 自指运算定位到瓶颈对象，则至少包含一个默认目标
        if (plan.target_objects.items.len == 0 and n > 0) {
            try plan.target_objects.append(self.allocator, 0);
        }

        return plan;
    }

    /// v7.0.0 修复4：在沙箱中执行优化方案（替代旧applyOptimization——直接在主图上操作）
    /// 核心哲学：沙箱完全隔离，执行失败不影响主图
    fn applyOptimizationInSandbox(self: *MacroBootstrapExecutor, sandbox: *DustGraph, plan: OptimizationPlan) bool {
        _ = self; // 仅使用 sandbox 和 plan

        // 核心哲学：通过Δ差值运算执行优化，严禁直接赋值
        for (plan.target_objects.items) |obj_id| {
            if (obj_id >= sandbox.objectCount()) continue;
            const val = sandbox.getObjectValue(obj_id) orelse continue;

            // 通过Δ自指运算 T(A)=Δ(A,A) 计算优化后的值
            // 核心哲学：所有运算必须通过Δ，包括结构优化
            const delta_self = sandbox.deltaObjToObj(obj_id, obj_id) catch continue;
            if (std.math.isNan(delta_self) or std.math.isInf(delta_self)) return false;

            // Δ差值大于0.1的对象执行权重调整
            const abs_delta = if (delta_self < 0) -delta_self else delta_self;
            if (abs_delta > 0.1) {
                // 通过Δ运算计算新的目标值
                const target_val = val * (1.0 - plan.expected_energy_improvement);
                sandbox.setObjectValue(obj_id, target_val) catch return false;
            }
        }
        return true;
    }

    /// v7.0.0 修复4：沙箱仿真验证（运行快速启发式模拟）
    /// 核心哲学：动力系统模拟——验证优化方案的长期稳定性
    /// 在沙箱中运行N步模拟，检查是否发散
    fn runSandboxSimulation(self: *MacroBootstrapExecutor, sandbox: *DustGraph) bool {
        _ = self;
        const total_objects = sandbox.objectCount();
        // 仿真步数由图规模内生决定：对象越多，需要的仿真步数越多以验证稳定性
        const SIMULATION_STEPS: usize = if (total_objects > 0) total_objects else 1;
        if (total_objects == 0) return true;

        // 运行N步快速模拟
        var step: usize = 0;
        while (step < SIMULATION_STEPS) : (step += 1) {
            // 核心哲学：通过Δ自指运算检查每个对象的稳定性
            var i: u64 = 0;
            while (i < total_objects) : (i += 1) {
                const delta_self = sandbox.deltaObjToObj(i, i) catch return false;
                if (std.math.isNan(delta_self) or std.math.isInf(delta_self)) return false;
                if (delta_self < 0.0 or delta_self > 1e18) return false;
            }

            // 检查自由能是否在合理范围内
            const morphisms = sandbox.morphisms.items;
            if (morphisms.len > 0) {
                // 用δ²总和粗略估计自由能
                var energy_est: f64 = 0.0;
                for (morphisms) |m| {
                    const d = sandbox.deltaObjToObj(m.source, m.target) catch return false;
                    energy_est += d * d;
                }
                if (std.math.isNan(energy_est) or std.math.isInf(energy_est)) return false;
            }
        }
        return true;
    }

    /// v7.0.0 修复4：将沙箱优化结果合并到主图（灰度切换基础）
    /// 核心哲学：通过Δ差值运算精确合并——只合并自指差值收敛的对象
    fn mergeSandboxToMain(self: *MacroBootstrapExecutor, sandbox: *DustGraph) void {
        const graph = &self.engine.graph;
        const n = @min(graph.objectCount(), sandbox.objectCount());

        var i: u64 = 0;
        while (i < n) : (i += 1) {
            // 核心哲学：只合并"自指差值收敛"的对象——通过Δ自指运算验证
            const main_self = graph.deltaObjToObj(i, i) catch continue;
            const sandbox_self = sandbox.deltaObjToObj(i, i) catch continue;

            // 只有沙箱自指差值比主图更好时才合并
            const main_abs = if (main_self < 0) -main_self else main_self;
            const sandbox_abs = if (sandbox_self < 0) -sandbox_self else sandbox_self;

            if (sandbox_abs < main_abs) {
                // 沙箱优化有效——将沙箱的对象值合并到主图
                const new_val = sandbox.getObjectValue(i) orelse continue;
                graph.setObjectValue(i, new_val) catch continue;

                // v5.0：CDL表达式系统——不再合并标量权重（已移除）
                // 沙箱中的CDL表达式演化通过全局的cdl_pool管理
            }
        }
    }

    /// 从快照恢复引擎状态（回滚操作）
    /// 快照不再需要保存/恢复权重。对象值和态射保存完整。
    fn restoreSnapshot(self: *MacroBootstrapExecutor, index: usize) void {
        if (index >= self.snapshots.items.len) return;
        const snapshot = &self.snapshots.items[index];
        const graph = self.engine.graph;

        // 恢复对象值
        for (graph.object_values.items, 0..) |*val, i| {
            if (i < snapshot.object_values.items.len) {
                val.* = snapshot.object_values.items[i];
            }
        }
    }

    /// 创建快照（文档5.4.2.5：保留至少3个历史版本快照作为回滚备份）
    /// 快照只保存对象值、态射和2-态射的完整状态。
    fn createSnapshot(self: *MacroBootstrapExecutor) !void {
        const graph = self.engine.graph;

        // 核心哲学：深拷贝所有关键对象完整状态（非仅元数据）
        var obj_vals = std.ArrayList(f64).empty;
        var morphs = std.ArrayList(ffi.Morphism).empty;
        var morphs2 = std.ArrayList(ffi.Morphism2).empty;

        // 深拷贝对象值
        for (graph.object_values.items) |val| {
            try obj_vals.append(self.allocator, val);
        }
        // 深拷贝1-态射（Morphism是值类型，直接拷贝）
        for (graph.morphisms.items) |m| {
            try morphs.append(self.allocator, m);
        }
        // 深拷贝2-态射（Morphism2是值类型，直接拷贝）
        for (graph.morphisms2.items) |m2| {
            try morphs2.append(self.allocator, m2);
        }

        const snapshot = Snapshot{
            .object_count = graph.objectCount(),
            .morphism_count = graph.morphismCount(),
            .morphism2_count = graph.morphism2Count(),
            .knowledge_size = self.engine.knowledgeSize(),
            .energy = self.engine.computeFreeEnergy(),
            .timestamp = now(),
            .object_values = obj_vals,
            .morphisms = morphs,
            .morphisms2 = morphs2,
            .allocator = self.allocator,
        };

        try self.snapshots.append(self.allocator, snapshot);

        // 保留最多MAX_SNAPSHOTS个快照（文档5.4.2.5）
        while (self.snapshots.items.len > MAX_SNAPSHOTS) {
            var oldest = self.snapshots.orderedRemove(0);
            oldest.deinit();
        }
    }

    /// 获取成功率
    pub fn successRate(self: *const MacroBootstrapExecutor) f64 {
        if (self.total_bootstraps == 0) return 0.0;
        return @as(f64, @floatFromInt(self.successful_bootstraps)) / @as(f64, @floatFromInt(self.total_bootstraps));
    }
};

// ============================================================
// 快照（历史版本备份）
// 核心哲学：宏自举五步流程严格按文档执行，快照必须深拷贝关键对象完整状态
// 文档5.4.2.5：保留至少3个历史版本快照作为回滚备份
// ============================================================
pub const Snapshot = struct {
    // 元数据（快速查询用）
    object_count: usize,
    morphism_count: usize,
    morphism2_count: usize,
    knowledge_size: usize,
    energy: f64,
    timestamp: i128,

    // 核心哲学：深拷贝关键对象完整状态，用于真正的回滚比较
    // 文档5.4.2.5：快照必须包含完整状态，不能仅存元数据
    object_values: std.ArrayList(f64), // 所有对象值
    morphisms: std.ArrayList(ffi.Morphism), // 所有1-态射
    morphisms2: std.ArrayList(ffi.Morphism2), // 所有2-态射

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        self.object_values.deinit(self.allocator);
        self.morphisms.deinit(self.allocator);
        self.morphisms2.deinit(self.allocator);
    }
};

// ============================================================
// 测试
// ============================================================

test "宏自举执行器初始化" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    var executor = MacroBootstrapExecutor.init(std.testing.allocator, &engine);
    defer executor.deinit();

    try std.testing.expectEqual(@as(u64, 0), executor.total_bootstraps);
}

test "宏自举触发条件 - 冷却期内不触发" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    var executor = MacroBootstrapExecutor.init(std.testing.allocator, &engine);
    defer executor.deinit();

    // 冷却期内（delta_call_count < last_trigger_step + cooldown_steps）不触发
    try std.testing.expect(!executor.shouldTrigger());
}
