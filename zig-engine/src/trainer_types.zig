// Ω-落尘AGI 训练类型定义 v5.0.0 - 哲学重构版
//
// 核心变更（v4.0.10 → v5.0.0）：
// 彻底移除所有硬编码能力枚举（TaskType的26个变体全部删除），
// 践行"所有能力不是写进去的"核心理念。
//
// 新设计：
// - 系统不知道自己在做"加法"还是"乘法"——它只知道自己在消除Δ
// - 唯一保留的枚举是Δ运算的阶数（操作复杂度），而非能力名称
// - 能力是Δ闭环（压力→筛选→压缩→固化）涌现的产物，不是代码分支
//
// 严格对应白皮书v2.0+修正：
// - 第7章：CL-SCT+训练机制（修正：去掉能力分类，统一为Δ压力学习）
// - 文档7.3：训练阶段（修正：不再分能力域，只分Δ复杂度级）
// - 文档7.4：训练参数
// - 核心哲学：所有能力都不是"写进去"的

const std = @import("std");

// ============================================================
// 自由能权重（白皮书v2.0第2章）
// γ=10.0 表示自洽优先（善 > 真 > 美）
// 初始值全部设为 0，由 LearnableTrainingParams 从零内生学习
// ============================================================

// ============================================================
// CL-SCT+ 训练参数（文档7.4）
// 初始值全部设为 0，由 LearnableTrainingParams 从零内生学习
// ============================================================

// ============================================================
// 可学习训练参数（从默认初始值开始，通过训练经验自适应调整）
// ============================================================

/// 可学习的训练参数（从默认值开始，通过训练经验自适应调整）
/// 遵循核心定义守恒原则：初始值全部设为 0，由系统从零内生学习
pub const LearnableTrainingParams = struct {
    // 自由能权重（从0开始学习，通过训练经验自适应调整）
    alpha: f64 = 0.0,        // F_fit 权重（从0开始学习）
    beta: f64 = 0.0,         // F_comp 权重（从0开始学习）
    gamma: f64 = 0.0,        // F_cons 权重（从0开始学习）

    // 触发阈值（从0开始学习，通过实际训练经验逐步学会合适的阈值）
    micro_bootstrap_threshold: f64 = 0.0,   // 微自举触发阈值（从0开始学习）
    macro_bootstrap_threshold: usize = 0,   // 宏自举触发阈值（从0开始学习）
    freeze_threshold_steps: u64 = 0,        // 冻结区阈值（从0开始学习）

    // v5.0.0：Δ搜索参数（可学习）
    /// Δ路径探索时的最大尝试次数（从0开始逐步增加）
    max_discovery_attempts: u64 = 0,
    /// 发现新模式的置信度阈值（从0开始学习）
    discovery_confidence_threshold: f64 = 0.0,

    // 模拟退火常数（从0开始学习）
    annealing_c: f64 = 0.0,  // 退火常数c（从0开始学习）

    // 学习率（从0开始，由系统内生决定）
    learning_rate: f64 = 0.0,

    /// 根据训练反馈更新参数
    /// 参数：
    ///   - consensus_score: 当前训练的共识(W)系数（[0,1]，越大越好）
    ///   - cache_hit_rate: 当前缓存命中率
    ///   - knowledge_size: 当前知识量
    pub fn learnFromTraining(
        self: *LearnableTrainingParams,
        consensus_score: f64,
        cache_hit_rate: f64,
        knowledge_size: usize,
    ) void {
        // v5.0.0：基于共识(W)而不是准确率调整参数
        // 共识(W)越高，说明Δ消除能力越强

        // 缓存命中率高时，微自举阈值自适应提高
        if (cache_hit_rate > self.micro_bootstrap_threshold) {
            self.micro_bootstrap_threshold += self.learning_rate * (cache_hit_rate - self.micro_bootstrap_threshold);
        }
        // 知识量大时，宏自举阈值自适应调整
        if (knowledge_size > self.macro_bootstrap_threshold) {
            self.macro_bootstrap_threshold = knowledge_size;
        }
        // 共识(W)高时，增加探索尝试次数（学得更快）
        if (consensus_score > self.micro_bootstrap_threshold) {
            self.max_discovery_attempts = self.max_discovery_attempts + 1;
        }
        // 共识(W)低时，增加置信度阈值（要求更高的自洽性）
        if (consensus_score < self.micro_bootstrap_threshold * 0.5) {
            self.discovery_confidence_threshold += self.learning_rate * (1.0 - consensus_score);
        }
    }
};

/// 默认训练参数实例（全部从0开始）
pub const DEFAULT_TRAINING_PARAMS: LearnableTrainingParams = .{};

// ============================================================
// 训练阶段枚举（文档7.3）
// ============================================================
pub const TrainingPhase = enum(u8) {
    L1_RuleSolidification = 0, // 阶段一：基底收敛训练（L1规则固化期）
    L2_SandboxBootstrap = 1, // 阶段二：双闭环自举训练（L2沙箱自举期）
    L3_FullFusion = 2, // 阶段三：永续内生演化（L3全融合期）

    pub fn name(self: TrainingPhase) []const u8 {
        return switch (self) {
            .L1_RuleSolidification => "L1规则固化期",
            .L2_SandboxBootstrap => "L2沙箱自举期",
            .L3_FullFusion => "L3全融合期",
        };
    }
};

// ============================================================
// Δ运算复杂度等级（v5.0.0替代TaskType）
//
// 核心设计哲学转变：
//   旧设计：TaskType.Addition / TaskType.Multiplication 等26种硬编码能力
//   新设计：ΔComplexity 仅描述运算的复杂度，不描述"是什么运算"
//
//   系统不区分"加法"和"乘法"——它只知道：
//     - Level_1: 单次Δ运算（最基础）
//     - Level_2: Δ的逆运算（需要递归/迭代一步）
//     - Level_3: Δ的多层嵌套（需要递归/迭代多步）
//     - Level_4: 混合Δ路径（多路径搜索）
//
//   能力名称（加法/乘法/素数判定等）是外部观察者给予的标签，
//   不是系统内部的枚举值。系统只追踪"能否消除Δ压力"。
// ============================================================

/// Δ运算复杂度等级 —— 唯一保留的"类型"信息
/// 系统不知道自己在做什么运算，只知道自己需要探索多深的Δ嵌套
pub const DeltaComplexity = enum(u8) {
    Level_1 = 1,  // 单次Δ运算：Δ(a,b)
    Level_2 = 2,  // Δ逆运算：需要1层递归/迭代
    Level_3 = 3,  // 多层Δ嵌套：需要递归/迭代多步
    Level_4 = 4,  // 混合Δ路径：多路径搜索与等价验证

    pub fn name(self: DeltaComplexity) []const u8 {
        return switch (self) {
            .Level_1 => "Δ-单次运算",
            .Level_2 => "Δ-逆运算",
            .Level_3 => "Δ-多层嵌套",
            .Level_4 => "Δ-混合路径",
        };
    }

    /// 从数值创建
    pub fn fromU8(v: u8) DeltaComplexity {
        if (v >= 4) return .Level_4;
        if (v <= 1) return .Level_1;
        return @enumFromInt(v);
    }
};

// ============================================================
// 训练任务（v5.0.0重构：去掉task_type字段！
//
// 旧设计：TrainingTask { task_type: TaskType, param1, param2, difficulty }
//   训练循环根据 task_type 进入26个不同分支，每个分支调用不同的delta函数。
//   这本质上是在"写进去"能力——代码里有26种能力的处理逻辑。
//
// 新设计：TrainingTask { param1, param2, complexity }
//   训练循环只有一个分支：统一的Δ压力学习。
//   系统不知道 param1=3, param2=4 应该做加法——它只知道：
//   1. 需要在CDL图中找到从 (3,4) 到 (output) 的Δ路径
//   2. 测量 F_fit = Δ(output, expected) 的差值压力
//   3. 如果 F_fit > 0，搜索新的Δ路径来消除这个压力
// ============================================================

/// 训练任务 —— 不再携带"能力类型"信息
pub const TrainingTask = struct {
    /// 参数1（输入对象）
    param1: u64,
    /// 参数2（输入对象）
    param2: u64,
    /// Δ运算复杂度（影响搜索空间和训练目标，但不指定做什么运算）
    complexity: DeltaComplexity,
};

/// 任务结果结构体
pub const TaskResult = struct {
    /// v5.0.0：共识(W)替代准确率（衡量Δ消除程度而非"做对了几道加法题"）
    /// F_fit_reduction = 1 - (F_fit_after / F_fit_before)，越高越好
    consensus_score: f64,
    /// Student是否成功找到了Δ路径
    discovered: bool,
    /// 探索尝试次数
    discovery_attempts: u64,
    /// 是否使用了已有规则（缓存命中）
    used_existing_rule: bool,
    energy_before: f64,
    energy_after: f64,
};

// ============================================================
// 训练记录（v5.0.0：去掉task_type字段）
// ============================================================
pub const TrainingRecord = struct {
    step: u64,
    phase: TrainingPhase,
    /// v5.0.0：不记录能力类型，只记录Δ复杂度
    complexity: DeltaComplexity,
    energy: f64,
    object_count: usize,
    delta_calls: u64,
    /// v5.0.0：共识(W)系数替代分类准确率
    consensus_score: f64,
    cache_hit_rate: f64,
    knowledge_size: usize,
    micro_bootstrap_triggered: bool,
    macro_bootstrap_triggered: bool,
    compression_rate: f64,
    temperature: f64, // 模拟退火温度
    frozen_count: usize, // 冻结区大小
    accepted: bool, // 模拟退火是否接受
    /// v5.0.0：新增——Student是否自主发现
    discovered: bool,
};

// ============================================================
// 训练统计（v5.0.0：去掉域特定统计，改为Δ度量指标）
// ============================================================
pub const TrainingStats = struct {
    total_steps: u64,
    total_delta_calls: u64,
    micro_bootstrap_count: u64,
    macro_bootstrap_count: u64,
    /// v5.0.0：平均共识(W)
    avg_consensus: f64,
    /// v5.0.0：自主发现率（Student自主找到Δ路径的比例）
    discovery_rate: f64,
    final_energy: f64,
    final_object_count: usize,
    final_cache_hit_rate: f64,
    final_knowledge_size: usize,
    final_compression_rate: f64,
    final_frozen_count: usize,
    total_discovered: u64,     // 自主发现次数
    total_attempted: u64,      // 总尝试次数
    l1_steps: u64,
    l2_steps: u64,
    l3_steps: u64,
    acceptance_rate: f64, // 模拟退火接受率
};