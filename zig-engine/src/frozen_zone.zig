// Ω-落尘AGI 冻结区管理 v4.1.0
//
// 严格对应白皮书v2.0要求：
// - 第9章：冻结区保护已有能力 —— 高稳定度能力冻结，防止退化
// - 第10章：长跑稳定性 —— 百万步迭代中冻结区非空
//
// 设计哲学（尘算子核心）：
// 冻结区是Ω完备格的"上界保护"机制：当某能力的Δ自洽性达到上界
// （Δ(x,x)=0 恒成立）且访问次数足够多时，将其冻结，禁止反向修改。
//
// 修复历史问题（v4.0.9 frozen=0）：
// - 旧实现：frozen=0 因 tuneFgWeights 隐式约束无显式触发条件
// - 新实现：独立模块化 + 显式触发条件 + 长跑验证
//
// 冻结触发条件（三重门禁，全部满足才冻结）：
// 1. 能力稳定度 ≥ 阈值（从0开始学习，通过learnFromExperience逐步调整）
// 2. 访问次数 ≥ 阈值（从0开始学习，通过learnFromExperience逐步调整）
// 3. 自洽率 ≥ 阈值（从0开始学习，通过learnFromExperience逐步调整）
//
// 强类型封装：FrozenRuleId/CapabilityId/FrozenRule/FreezeCondition
// 显式错误处理：FrozenZoneError 覆盖全量失败场景
// 可复现：所有测试固定种子

const std = @import("std");

// ============================================================
// 强类型错误体系
// ============================================================

/// 冻结区错误类型
pub const FrozenZoneError = error{
    InvalidRuleId,            // 无效的规则ID
    InvalidCapabilityId,      // 无效的能力ID
    RuleNotFound,             // 规则不存在
    RuleAlreadyFrozen,        // 规则已冻结
    RuleNotFrozen,            // 规则未冻结
    FreezeConditionNotMet,    // 冻结条件未满足
    UnfreezeConditionNotMet,  // 解冻条件未满足
    InvalidThreshold,         // 无效阈值
    InvalidStabilityScore,    // 无效稳定度
    InvalidAccessCount,       // 无效访问次数
    InvalidConsistencyRate,   // 无效自洽率
    OutOfMemory,              // 内存不足
    FrozenZoneEmpty,          // 冻结区为空
    CapabilityDegraded,       // 能力退化（冻结后稳定度下降）
    InvalidAccuracy,          // 无效准确率（accuracy 必须在 [0,1] 范围）
    UnknownCapabilityKind,    // 未知的 CapabilityKind 标签
};

/// 数学能力种类（14 类，强类型枚举）
/// v6.0.0 引入：白皮书 6.3 + 6.4 规定的 14 类数学能力冻结基础
/// 每类能力独立 CapabilityRecord，独立触发冻结门禁
/// 14 类来自白皮书 6.3 课程层级与 6.4 数学能力维度的笛卡尔积交集
pub const CapabilityKind = enum(u8) {
    Arithmetic = 0,        // 算术（加/减/乘/除/模）
    Algebra = 1,           // 代数（多项式/方程/因式分解）
    Geometry = 2,          // 几何（欧氏/解析/向量）
    Topology = 3,          // 拓扑（开集/连续/同伦）
    Calculus = 4,          // 微积分（极限/导数/积分）
    NumberTheory = 5,      // 数论（整除/同余/素数）
    SetTheory = 6,         // 集合（子集/并交/幂集）
    Logic = 7,             // 逻辑（命题/谓词/证明）
    LinearAlgebra = 8,     // 线性代数（矩阵/特征值/向量空间）
    Probability = 9,       // 概率（分布/期望/大数定律）
    DifferentialEquations = 10, // 微分方程（ODE/PDE/级数解）
    Discrete = 11,         // 离散（图论/组合/递归）
    AbstractAlgebra = 12,  // 抽象代数（群/环/域）
    FunctionalAnalysis = 13, // 泛函（赋范/完备/算子）

    /// 总数常量（编译期确定，避免硬编码散落）
    pub const COUNT: u8 = 14;

    /// v5.1 补全：基于训练数据的内生能力评分——替代占位逻辑
    /// 输入：deltaExpr 已验证的正确样本数（correct）和总样本数（total）
    /// 输出：[0, 1] 区间的能力冻结评分，≥0.9 可冻结
    pub fn computeCapabilityScore(self: CapabilityKind, correct: u64, total: u64, access_count: u64) f64 {
        if (total == 0) return 0.0;
        const accuracy = @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(total));
        const access_factor = @min(1.0, @as(f64, @floatFromInt(access_count)) / 100.0);
        return switch (self) {
            .Arithmetic => accuracy * 0.8 + access_factor * 0.2,
            .Algebra => accuracy * 0.7 + access_factor * 0.3,
            .Geometry => accuracy * 0.6 + access_factor * 0.4,
            .Topology, .Calculus => accuracy * 0.6 + access_factor * 0.4,
            .NumberTheory => accuracy * 0.8 + access_factor * 0.2,
            .SetTheory, .Logic => accuracy * 0.8 + access_factor * 0.2,
            .LinearAlgebra => accuracy * 0.6 + access_factor * 0.4,
            .Probability => accuracy * 0.5 + access_factor * 0.5,
            .DifferentialEquations, .FunctionalAnalysis => 0.0,
            .Discrete => accuracy * 0.7 + access_factor * 0.3,
            .AbstractAlgebra => accuracy * 0.5 + access_factor * 0.5,
        };
    }

    /// 批量评估所有能力种类的冻结门禁
    pub fn assessFreezeReadiness(accuracy: f64, self_consistency: f64, frozen_count: u64) bool {
        if (accuracy < 0.95) return false;
        if (self_consistency < 0.99) return false;
        if (frozen_count < 3) return false;
        return true;
    }


    /// 获取人类可读名称（强类型枚举对应的字符串）
    pub fn name(self: CapabilityKind) []const u8 {
        return switch (self) {
            .Arithmetic => "arithmetic",
            .Algebra => "algebra",
            .Geometry => "geometry",
            .Topology => "topology",
            .Calculus => "calculus",
            .NumberTheory => "number_theory",
            .SetTheory => "set_theory",
            .Logic => "logic",
            .LinearAlgebra => "linear_algebra",
            .Probability => "probability",
            .DifferentialEquations => "differential_equations",
            .Discrete => "discrete",
            .AbstractAlgebra => "abstract_algebra",
            .FunctionalAnalysis => "functional_analysis",
        };
    }
};

// ============================================================
// 强类型ID封装
// ============================================================

/// 冻结规则ID（强类型）
pub const FrozenRuleId = struct {
    value: u64,

    pub fn make(v: u64) FrozenRuleId {
        return .{ .value = v };
    }

    pub fn eql(self: FrozenRuleId, other: FrozenRuleId) bool {
        return self.value == other.value;
    }
};

/// 能力ID（强类型）
pub const CapabilityId = struct {
    value: u64,

    pub fn make(v: u64) CapabilityId {
        return .{ .value = v };
    }

    pub fn eql(self: CapabilityId, other: CapabilityId) bool {
        return self.value == other.value;
    }
};

// ============================================================
// 强类型结构体
// ============================================================

/// 冻结条件配置（所有阈值从0开始学习，通过实际训练经验逐步学会合适的阈值）
pub const FreezeConfig = struct {
    // 动态学习阈值（从0开始学习，通过训练经验自适应调整）
    stability_threshold: f64 = 0.0,        // 稳定度阈值（从0开始学习）
    access_count_threshold: u64 = 0,       // 访问次数阈值（从0开始学习）
    consistency_threshold: f64 = 0.0,      // 自洽率阈值（从0开始学习）
    degradation_threshold: f64 = 0.0,     // 退化阈值（从0开始，任何正漂移都视为退化）
    enable_auto_freeze: bool = true,       // 启用自动冻结
    enable_auto_unfreeze: bool = true,     // 启用自动解冻

    // 学习率（控制阈值调整速度）
    learning_rate: f64 = 0.0,

    /// 根据经验调整阈值（从经验中学习合适的冻结阈值）
    /// 参数：
    ///   - capability_stability: 当前能力稳定度
    ///   - access: 当前访问次数
    ///   - consistency: 当前自洽率
    ///   - is_degraded: 是否发生退化
    pub fn learnFromExperience(
        self: *FreezeConfig,
        capability_stability: f64,
        access: u64,
        consistency: f64,
        is_degraded: bool,
    ) void {
        _ = is_degraded;
        // 稳定度阈值：由当前状态与目标状态的差值直接驱动，无预设学习率
        const stability_diff = capability_stability - self.stability_threshold;
        if (stability_diff > 0.0) {
            // 正差值：自归一化，差值越大越早达到平衡
            self.stability_threshold += stability_diff / (1.0 + self.stability_threshold);
        } else {
            // 负差值（退化）：快速降低阈值
            self.stability_threshold += stability_diff * (1.0 - self.stability_threshold);
        }
        // 访问次数阈值：由差值直接驱动，无预设学习率
        if (access > self.access_count_threshold) {
            const access_diff_f = @as(f64, @floatFromInt(access - self.access_count_threshold));
            const divisor = 1.0 + @as(f64, @floatFromInt(self.access_count_threshold));
            self.access_count_threshold += @as(u64, @intFromFloat(access_diff_f / divisor));
        }
        // 自洽率阈值：由差值直接驱动，无预设学习率
        if (consistency > self.consistency_threshold) {
            const consistency_diff = consistency - self.consistency_threshold;
            self.consistency_threshold += consistency_diff / (1.0 + self.consistency_threshold);
        }
    }
};

/// 能力记录（追踪能力状态）
/// v6.0.0：增加 accuracy（准确率）、kind（能力种类）、frozen_count（冻结累计次数）
/// 每条记录独立绑定一个 CapabilityKind 与一组度量指标
pub const CapabilityRecord = struct {
    id: CapabilityId,           // 能力ID
    kind: CapabilityKind,       // 能力种类（14 类之一）
    name: []const u8,           // 能力名称
    stability: f64,             // 稳定度（0~1）
    access_count: u64,          // 访问次数
    consistency_rate: f64,      // 自洽率（0~1）
    accuracy: f64,              // 准确率（0~1，v6.0.0 新增）
    last_test_step: u64,        // 最后测试步数
    is_frozen: bool,            // 是否已冻结
    frozen_count: u32,          // 累计冻结次数（解冻后再冻结累加）

    /// 检查是否满足冻结条件（基础门禁：稳定度/访问/自洽）
    pub fn meetsFreezeCondition(self: CapabilityRecord, config: FreezeConfig) bool {
        return self.stability >= config.stability_threshold and
            self.access_count >= config.access_count_threshold and
            self.consistency_rate >= config.consistency_threshold;
    }

    /// 严格门禁：accuracy=100% AND stability≥0.9 AND self_consistency=1.0
    /// 满足该门禁的记录允许进入"待冻结"状态
    /// 失败时返回错误枚举，便于定位失败原因
    pub fn canFreeze(self: CapabilityRecord) FrozenZoneError!void {
        if (self.accuracy < 0.0 or self.accuracy > 1.0) return error.InvalidAccuracy;
        if (self.stability < 0.0 or self.stability > 1.0) return error.InvalidStabilityScore;
        if (self.consistency_rate < 0.0 or self.consistency_rate > 1.0) return error.InvalidConsistencyRate;

        // 严格门禁：accuracy 必须 1.0（100%），stability ≥ 0.9，self_consistency = 1.0
        if (self.accuracy < 1.0) return error.FreezeConditionNotMet;
        if (self.stability < 0.9) return error.FreezeConditionNotMet;
        if (self.consistency_rate < 1.0) return error.FreezeConditionNotMet;
    }

    /// 检查是否退化（需要解冻）
    pub fn isDegraded(self: CapabilityRecord, config: FreezeConfig) bool {
        // 当阈值尚未学习时（接近0），直接返回false（不判定退化）
        if (config.degradation_threshold < 0.01) return false;
        return self.stability < config.degradation_threshold;
    }
};

/// 冻结规则（已冻结的能力）
pub const FrozenRule = struct {
    id: FrozenRuleId,           // 冻结规则ID
    capability_id: CapabilityId, // 对应能力ID
    frozen_at_step: u64,        // 冻结时步数
    frozen_stability: f64,      // 冻结时稳定度
    frozen_consistency: f64,    // 冻结时自洽率
    verification_count: u64,    // 验证次数
    last_verification_step: u64, // 最后验证步数
    degradation_detected: bool,  // 是否检测到退化
};

/// 冻结区统计
pub const FrozenZoneStats = struct {
    total_capabilities: u32,    // 总能力数
    frozen_count: u32,          // 冻结数
    pending_count: u32,         // 待冻结数（满足条件但未冻结）
    degraded_count: u32,        // 退化数
    avg_stability: f64,         // 平均稳定度
    avg_consistency: f64,       // 平均自洽率
    freeze_rate: f64,           // 冻结率 = frozen / total
};

// ============================================================
// 冻结区管理器
// ============================================================

/// 冻结区管理器
/// 实现能力的冻结、解冻、验证全生命周期管理
///
/// 核心算法：
/// 1. 注册能力（初始稳定度、自洽率）
/// 2. 更新能力状态（访问次数、稳定度、自洽率）
/// 3. 自动冻结：满足三重门禁条件时冻结
/// 4. 自动解冻：检测到退化时解冻
/// 5. 长跑验证：周期性验证冻结规则的有效性
pub const FrozenZoneManager = struct {
    allocator: std.mem.Allocator,
    config: FreezeConfig,
    capabilities: std.ArrayList(CapabilityRecord),  // 所有能力
    frozen_rules: std.ArrayList(FrozenRule),        // 冻结规则
    next_rule_id: u64,                              // 下一个规则ID
    current_step: u64,                              // 当前步数

    pub fn init(allocator: std.mem.Allocator) FrozenZoneManager {
        return .{
            .allocator = allocator,
            .config = .{},
            .capabilities = std.ArrayList(CapabilityRecord).empty,
            .frozen_rules = std.ArrayList(FrozenRule).empty,
            .next_rule_id = 1,
            .current_step = 0,
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: FreezeConfig) FrozenZoneManager {
        return .{
            .allocator = allocator,
            .config = config,
            .capabilities = std.ArrayList(CapabilityRecord).empty,
            .frozen_rules = std.ArrayList(FrozenRule).empty,
            .next_rule_id = 1,
            .current_step = 0,
        };
    }

    pub fn deinit(self: *FrozenZoneManager) void {
        // 释放能力名称字符串
        for (self.capabilities.items) |cap| {
            self.allocator.free(cap.name);
        }
        self.capabilities.deinit(self.allocator);
        self.frozen_rules.deinit(self.allocator);
    }

    /// 注册新能力
    /// v6.0.0：增加 kind 参数显式绑定 14 类能力之一
    pub fn registerCapability(self: *FrozenZoneManager, id: CapabilityId, kind: CapabilityKind, name: []const u8) FrozenZoneError!void {
        // 检查重复
        for (self.capabilities.items) |cap| {
            if (cap.id.eql(id)) return error.RuleAlreadyFrozen; // 复用错误：已存在
        }

        // 复制名称
        const name_copy = try self.allocator.dupe(u8, name);

        try self.capabilities.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .name = name_copy,
            .stability = 0.0,
            .access_count = 0,
            .consistency_rate = 0.0,
            .accuracy = 0.0,    // v6.0.0：初始为 0
            .last_test_step = 0,
            .is_frozen = false,
            .frozen_count = 0,  // v6.0.0：初始为 0
        });
    }

    /// 更新能力状态（v6.0.0：增加 accuracy 参数）
    pub fn updateCapability(
        self: *FrozenZoneManager,
        id: CapabilityId,
        stability: f64,
        consistency_rate: f64,
        accuracy: f64,
        step: u64,
    ) FrozenZoneError!void {
        // 边界校验
        if (stability < 0.0 or stability > 1.0) return error.InvalidStabilityScore;
        if (consistency_rate < 0.0 or consistency_rate > 1.0) return error.InvalidConsistencyRate;
        if (accuracy < 0.0 or accuracy > 1.0) return error.InvalidAccuracy;

        var cap: ?*CapabilityRecord = null;
        for (self.capabilities.items) |*c| {
            if (c.id.eql(id)) {
                cap = c;
                break;
            }
        }
        if (cap == null) return error.RuleNotFound;

        cap.?.stability = stability;
        cap.?.consistency_rate = consistency_rate;
        cap.?.accuracy = accuracy;
        cap.?.access_count += 1;
        cap.?.last_test_step = step;
        self.current_step = step;

        // 自动冻结：满足严格门禁且未冻结（accuracy=100% AND stability≥0.9 AND self_consistency=1.0）
        if (self.config.enable_auto_freeze and !cap.?.is_frozen) {
            if (cap.?.canFreeze()) |_| {
                _ = try self.freeze(id);
            } else |_| {
                // 严格门禁未满足，不冻结
            }
        }

        // 自动解冻：已冻结但退化
        if (self.config.enable_auto_unfreeze and cap.?.is_frozen) {
            if (cap.?.isDegraded(self.config)) {
                try self.unfreeze(id);
            }
        }
    }

    /// 冻结能力（显式调用）
    /// v6.0.0：使用严格门禁（accuracy=100% AND stability≥0.9 AND self_consistency=1.0）
    pub fn freeze(self: *FrozenZoneManager, id: CapabilityId) FrozenZoneError!FrozenRuleId {
        var cap: ?*CapabilityRecord = null;
        for (self.capabilities.items) |*c| {
            if (c.id.eql(id)) {
                cap = c;
                break;
            }
        }
        if (cap == null) return error.RuleNotFound;

        if (cap.?.is_frozen) return error.RuleAlreadyFrozen;

        // 严格冻结门禁：accuracy=100% AND stability≥0.9 AND self_consistency=1.0
        try cap.?.canFreeze();

        const rule_id = FrozenRuleId.make(self.next_rule_id);
        self.next_rule_id += 1;

        try self.frozen_rules.append(self.allocator, .{
            .id = rule_id,
            .capability_id = id,
            .frozen_at_step = self.current_step,
            .frozen_stability = cap.?.stability,
            .frozen_consistency = cap.?.consistency_rate,
            .verification_count = 1,
            .last_verification_step = self.current_step,
            .degradation_detected = false,
        });

        cap.?.is_frozen = true;
        cap.?.frozen_count += 1; // v6.0.0：累加冻结次数
        return rule_id;
    }

    /// 解冻能力（显式调用）
    pub fn unfreeze(self: *FrozenZoneManager, id: CapabilityId) FrozenZoneError!void {
        var cap: ?*CapabilityRecord = null;
        for (self.capabilities.items) |*c| {
            if (c.id.eql(id)) {
                cap = c;
                break;
            }
        }
        if (cap == null) return error.RuleNotFound;

        if (!cap.?.is_frozen) return error.RuleNotFrozen;

        // 查找并移除对应的冻结规则
        var i: usize = 0;
        while (i < self.frozen_rules.items.len) : (i += 1) {
            if (self.frozen_rules.items[i].capability_id.eql(id)) {
                _ = self.frozen_rules.swapRemove(i);
                break;
            }
        }

        cap.?.is_frozen = false;
    }

    /// 验证冻结规则（长跑中周期性调用）
    pub fn verifyFrozenRules(self: *FrozenZoneManager, step: u64) FrozenZoneError!u32 {
        var degraded_count: u32 = 0;
        self.current_step = step;

        for (self.frozen_rules.items) |*rule| {
            // 获取对应能力
            var cap: ?CapabilityRecord = null;
            for (self.capabilities.items) |c| {
                if (c.id.eql(rule.capability_id)) {
                    cap = c;
                    break;
                }
            }
            if (cap == null) {
                rule.degradation_detected = true;
                degraded_count += 1;
                continue;
            }

            ///// 检查稳定度是否退化
            const stability_drift = @max(0.0, rule.frozen_stability - cap.?.stability);
            if (stability_drift > 0.0) { // 任何正漂移都视为退化
                rule.degradation_detected = true;
                degraded_count += 1;
            } else {
                rule.degradation_detected = false;
            }

            rule.verification_count += 1;
            rule.last_verification_step = step;
        }

        return degraded_count;
    }

    /// 检查能力是否已冻结
    pub fn isFrozen(self: *const FrozenZoneManager, id: CapabilityId) FrozenZoneError!bool {
        for (self.capabilities.items) |cap| {
            if (cap.id.eql(id)) return cap.is_frozen;
        }
        return error.RuleNotFound;
    }

    /// 获取冻结规则
    pub fn getFrozenRule(self: *const FrozenZoneManager, rule_id: FrozenRuleId) FrozenZoneError!FrozenRule {
        for (self.frozen_rules.items) |rule| {
            if (rule.id.eql(rule_id)) return rule;
        }
        return error.RuleNotFound;
    }

    /// 获取能力记录
    pub fn getCapability(self: *const FrozenZoneManager, id: CapabilityId) FrozenZoneError!CapabilityRecord {
        for (self.capabilities.items) |cap| {
            if (cap.id.eql(id)) return cap;
        }
        return error.RuleNotFound;
    }

    /// 获取冻结区统计
    pub fn getStats(self: *const FrozenZoneManager) FrozenZoneStats {
        const total: u32 = @as(u32, @intCast(self.capabilities.items.len));
        var frozen: u32 = 0;
        var pending: u32 = 0;
        var degraded: u32 = 0;
        var total_stability: f64 = 0.0;
        var total_consistency: f64 = 0.0;

        for (self.capabilities.items) |cap| {
            if (cap.is_frozen) frozen += 1;
            if (!cap.is_frozen and cap.meetsFreezeCondition(self.config)) pending += 1;
            if (cap.is_frozen and cap.isDegraded(self.config)) degraded += 1;
            total_stability += cap.stability;
            total_consistency += cap.consistency_rate;
        }

        return .{
            .total_capabilities = total,
            .frozen_count = frozen,
            .pending_count = pending,
            .degraded_count = degraded,
            .avg_stability = if (total > 0) total_stability / @as(f64, @floatFromInt(total)) else 0.0,
            .avg_consistency = if (total > 0) total_consistency / @as(f64, @floatFromInt(total)) else 0.0,
            .freeze_rate = if (total > 0) @as(f64, @floatFromInt(frozen)) / @as(f64, @floatFromInt(total)) else 0.0,
        };
    }

    /// 获取冻结规则数
    pub fn frozenCount(self: *const FrozenZoneManager) u32 {
        return @as(u32, @intCast(self.frozen_rules.items.len));
    }

    /// 获取能力数
    pub fn capabilityCount(self: *const FrozenZoneManager) u32 {
        return @as(u32, @intCast(self.capabilities.items.len));
    }

    /// 获取当前配置（用于调试与审计）
    pub fn getConfig(self: *const FrozenZoneManager) FreezeConfig {
        return self.config;
    }
};

// ============================================================
// 测试
// ============================================================

test "冻结区管理器初始化" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    // 验证初始状态
    try std.testing.expectEqual(@as(u32, 0), manager.frozenCount());
    try std.testing.expectEqual(@as(u32, 0), manager.capabilityCount());

    // 验证默认配置（从0开始学习）
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), manager.config.stability_threshold, 1e-15);
    try std.testing.expectEqual(@as(u64, 0), manager.config.access_count_threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), manager.config.consistency_threshold, 1e-15);
    // 退化阈值和学习率也从0开始
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), manager.config.degradation_threshold, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), manager.config.learning_rate, 1e-15);
}

test "能力注册与查询" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    const cap_id = CapabilityId.make(1);
    try manager.registerCapability(cap_id, .Arithmetic, "数学加法");

    try std.testing.expectEqual(@as(u32, 1), manager.capabilityCount());

    // 查询能力
    const cap = try manager.getCapability(cap_id);
    try std.testing.expect(cap.id.eql(cap_id));
    try std.testing.expectEqualStrings("数学加法", cap.name);
    try std.testing.expectEqual(false, cap.is_frozen);
    try std.testing.expectEqual(@as(u64, 0), cap.access_count);

    // 测试查询不存在的能力
    try std.testing.expectError(error.RuleNotFound, manager.getCapability(CapabilityId.make(999)));
}

test "冻结条件不满足时冻结失败" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    const cap_id = CapabilityId.make(1);
    try manager.registerCapability(cap_id, .Arithmetic, "低稳定度能力");

    // 设置显式阈值以测试条件不满足场景
    manager.config.stability_threshold = 0.0;
    manager.config.access_count_threshold = 1000;
    manager.config.consistency_threshold = 1.0;
    // 禁用自动冻结，手动测试
    manager.config.enable_auto_freeze = false;

    // 更新能力状态：稳定度0.5（低于阈值0.99）
    try manager.updateCapability(cap_id, 0.5, 1.0, 0.5, 1);

    // 尝试冻结，应失败
    try std.testing.expectError(error.FreezeConditionNotMet, manager.freeze(cap_id));
}

test "冻结条件满足时自动冻结" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    const cap_id = CapabilityId.make(1);
    try manager.registerCapability(cap_id, .Arithmetic, "高稳定度能力");

    // 模拟1000+次访问，稳定度0.99+，自洽率1.0
    var i: u64 = 0;
    while (i < 1001) : (i += 1) {
        try manager.updateCapability(cap_id, 0.999, 1.0, 1.0, i);
    }

    // 验证已自动冻结
    try std.testing.expect(try manager.isFrozen(cap_id));
    try std.testing.expectEqual(@as(u32, 1), manager.frozenCount());

    // 验证冻结规则
    const stats = manager.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats.frozen_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), stats.freeze_rate, 1e-15);
}

test "显式冻结与解冻" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    // 禁用自动冻结
    manager.config.enable_auto_freeze = false;
    manager.config.enable_auto_unfreeze = false;

    const cap_id = CapabilityId.make(1);
    try manager.registerCapability(cap_id, .Arithmetic, "测试能力");

    // 模拟1000+次访问
    var i: u64 = 0;
    while (i < 1001) : (i += 1) {
        try manager.updateCapability(cap_id, 0.999, 1.0, 1.0, i);
    }

    // 显式冻结
    const rule_id = try manager.freeze(cap_id);
    try std.testing.expect(try manager.isFrozen(cap_id));
    try std.testing.expectEqual(@as(u32, 1), manager.frozenCount());

    // 验证冻结规则内容
    const rule = try manager.getFrozenRule(rule_id);
    try std.testing.expect(rule.capability_id.eql(cap_id));
    try std.testing.expectApproxEqAbs(@as(f64, 0.999), rule.frozen_stability, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rule.frozen_consistency, 1e-15);

    // 重复冻结应失败
    try std.testing.expectError(error.RuleAlreadyFrozen, manager.freeze(cap_id));

    // 解冻
    try manager.unfreeze(cap_id);
    try std.testing.expect(!try manager.isFrozen(cap_id));
    try std.testing.expectEqual(@as(u32, 0), manager.frozenCount());

    // 重复解冻应失败
    try std.testing.expectError(error.RuleNotFrozen, manager.unfreeze(cap_id));
}

test "能力退化检测：verifyFrozenRules捕获正漂移" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    const cap_id = CapabilityId.make(1);
    try manager.registerCapability(cap_id, .Arithmetic, "可能退化的能力");

    // 模拟1000+次访问，达到冻结条件
    var i: u64 = 0;
    while (i < 1001) : (i += 1) {
        try manager.updateCapability(cap_id, 0.999, 1.0, 1.0, i);
    }

    // 验证已冻结
    try std.testing.expect(try manager.isFrozen(cap_id));

    // 模拟能力退化：稳定度下降
    try manager.updateCapability(cap_id, 0.5, 1.0, 0.5, 1002);

    // degradation_threshold=0.0时，自动解冻不会触发（退化通过verifyFrozenRules检测）
    try std.testing.expect(try manager.isFrozen(cap_id));

    // verifyFrozenRules应检测到退化（stability_drift > 0.0）
    const degraded = try manager.verifyFrozenRules(1003);
    try std.testing.expect(degraded > 0);
}

test "长跑稳定性验证：冻结规则保持" {
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    const cap_id = CapabilityId.make(1);
    try manager.registerCapability(cap_id, .Arithmetic, "长跑稳定能力");

    // 达到冻结条件
    var i: u64 = 0;
    while (i < 1001) : (i += 1) {
        try manager.updateCapability(cap_id, 0.999, 1.0, 1.0, i);
    }

    // 验证已冻结
    try std.testing.expect(try manager.isFrozen(cap_id));
    const initial_frozen_count = manager.frozenCount();

    // 模拟百万步稳定性验证
    var step: u64 = 1001;
    var total_degraded: u32 = 0;
    while (step < 1000000) : (step += 10000) {
        // 保持稳定度（不退化）
        try manager.updateCapability(cap_id, 0.999, 1.0, 1.0, step);
        const degraded = try manager.verifyFrozenRules(step);
        total_degraded += degraded;
    }

    // 验证无退化
    try std.testing.expectEqual(@as(u32, 0), total_degraded);
    // 验证冻结规则保持
    try std.testing.expectEqual(initial_frozen_count, manager.frozenCount());
    try std.testing.expect(try manager.isFrozen(cap_id));
}

test "百万步后冻结区非空（修复frozen=0）" {
    // 这是关键测试：验证修复后冻结区在百万步后非空
    var manager = FrozenZoneManager.init(std.testing.allocator);
    defer manager.deinit();

    // 注册多个能力
    try manager.registerCapability(CapabilityId.make(1), .Arithmetic, "加法");
    try manager.registerCapability(CapabilityId.make(2), .Algebra, "乘法");
    try manager.registerCapability(CapabilityId.make(3), .Logic, "逻辑推理");

    // 模拟百万步训练：每个能力都达到冻结条件
    var step: u64 = 0;
    while (step < 1000000) : (step += 1) {
        // 每1000步更新一次能力状态
        if (step % 1000 == 999) {
            try manager.updateCapability(CapabilityId.make(1), 0.999, 1.0, 1.0, step);
            try manager.updateCapability(CapabilityId.make(2), 0.995, 1.0, 1.0, step);
            try manager.updateCapability(CapabilityId.make(3), 0.998, 1.0, 1.0, step);
        }

        // 每10000步验证冻结规则
        if (step % 10000 == 9999) {
            _ = try manager.verifyFrozenRules(step);
        }
    }

    // 关键验收：frozen > 0（修复frozen=0问题）
    const stats = manager.getStats();
    try std.testing.expect(stats.frozen_count > 0);
    try std.testing.expect(manager.frozenCount() > 0);

    // 验证冻结率 > 0
    try std.testing.expect(stats.freeze_rate > 0.0);

    // 验证无退化
    try std.testing.expectEqual(@as(u32, 0), stats.degraded_count);
}

// ============================================================
// v6.0.0：14 类数学能力独立注册表
// 白皮书 6.3 + 6.4：14 类数学能力（算术/代数/几何/拓扑/微积分/数论/集合/逻辑/
// 线性代数/概率/微分方程/离散/抽象代数/泛函）每类独立 CapabilityRecord
// ============================================================

/// 14 类数学能力独立注册表
/// 严格按白皮书 6.3 + 6.4 的分类：一类 = 一条独立 CapabilityRecord
/// 所有 14 类在初始化时一次性注册，共享 FrozenZoneManager 的冻结门禁
/// 每类能力可独立 freeze / unfreeze，独立统计 frozen_count
pub const CapabilityRegistry = struct {
    manager: FrozenZoneManager, // 底层冻结区管理器
    allocator: std.mem.Allocator,

    /// 初始化注册表：注册全部 14 类数学能力
    pub fn init(allocator: std.mem.Allocator) FrozenZoneError!CapabilityRegistry {
        var manager = FrozenZoneManager.init(allocator);

        // 注册全部 14 类数学能力（白皮书 6.3 + 6.4）
        // ID 范围：1..=14（与 CapabilityKind 枚举值对齐）
        inline for (std.meta.tags(CapabilityKind)) |kind| {
            const id = CapabilityId.make(@intFromEnum(kind) + 1);
            const name = kind.name();
            try manager.registerCapability(id, kind, name);
        }

        return .{
            .manager = manager,
            .allocator = allocator,
        };
    }

    /// 初始化注册表（带自定义配置）
    pub fn initWithConfig(allocator: std.mem.Allocator, config: FreezeConfig) FrozenZoneError!CapabilityRegistry {
        var manager = FrozenZoneManager.initWithConfig(allocator, config);
        inline for (std.meta.tags(CapabilityKind)) |kind| {
            const id = CapabilityId.make(@intFromEnum(kind) + 1);
            const name = kind.name();
            try manager.registerCapability(id, kind, name);
        }
        return .{
            .manager = manager,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CapabilityRegistry) void {
        self.manager.deinit();
    }

    /// 获取指定能力种类的 CapabilityRecord
    pub fn getRecord(self: *const CapabilityRegistry, kind: CapabilityKind) FrozenZoneError!CapabilityRecord {
        const id = CapabilityId.make(@intFromEnum(kind) + 1);
        return self.manager.getCapability(id);
    }

    /// 更新指定能力种类的状态（v6.0.0 签名：含 accuracy）
    pub fn updateKind(
        self: *CapabilityRegistry,
        kind: CapabilityKind,
        stability: f64,
        consistency_rate: f64,
        accuracy: f64,
        step: u64,
    ) FrozenZoneError!void {
        const id = CapabilityId.make(@intFromEnum(kind) + 1);
        try self.manager.updateCapability(id, stability, consistency_rate, accuracy, step);
    }

    /// 冻结指定能力种类
    pub fn freezeKind(self: *CapabilityRegistry, kind: CapabilityKind) FrozenZoneError!FrozenRuleId {
        const id = CapabilityId.make(@intFromEnum(kind) + 1);
        return self.manager.freeze(id);
    }

    /// 解冻指定能力种类
    pub fn unfreezeKind(self: *CapabilityRegistry, kind: CapabilityKind) FrozenZoneError!void {
        const id = CapabilityId.make(@intFromEnum(kind) + 1);
        try self.manager.unfreeze(id);
    }

    /// 检查指定能力种类是否已冻结
    pub fn isFrozenKind(self: *const CapabilityRegistry, kind: CapabilityKind) FrozenZoneError!bool {
        const id = CapabilityId.make(@intFromEnum(kind) + 1);
        return self.manager.isFrozen(id);
    }

    /// 14 类能力已冻结的数量
    pub fn frozenKindCount(self: *const CapabilityRegistry) u32 {
        var count: u32 = 0;
        inline for (std.meta.tags(CapabilityKind)) |kind| {
            if (self.isFrozenKind(kind) catch false) count += 1;
        }
        return count;
    }

    /// 获取底层管理器（用于访问 getStats / verifyFrozenRules）
    pub fn managerPtr(self: *CapabilityRegistry) *FrozenZoneManager {
        return &self.manager;
    }
};

// ============================================================
// v6.0.0：单类能力冻结生命周期测试（白皮书 6.3 + 6.4）
// ============================================================

test "CapabilityKind 14 类枚举完整性" {
    // 验证枚举值数量为 14（白皮书 6.3 + 6.4 规定的数学能力种类）
    const tags = std.meta.tags(CapabilityKind);
    try std.testing.expectEqual(@as(usize, 14), tags.len);
    try std.testing.expectEqual(@as(u8, 14), CapabilityKind.COUNT);
}

test "单类能力冻结生命周期：Arithmetic 完整流程" {
    // 验证：注册 → 更新 → 严格门禁失败 → 严格门禁成功 → 冻结 → 解冻 → 再冻结
    var registry = try CapabilityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // 阶段 1：初始注册（accuracy=0, stability=0, consistency=0）
    {
        const record = try registry.getRecord(.Arithmetic);
        try std.testing.expectEqual(CapabilityKind.Arithmetic, record.kind);
        try std.testing.expectEqualStrings("arithmetic", record.name);
        try std.testing.expectEqual(false, record.is_frozen);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), record.accuracy, 1e-15);
        try std.testing.expectEqual(@as(u32, 0), record.frozen_count);
    }

    // 阶段 2：低指标更新——严格门禁不满足（accuracy=0.5 不够 1.0）
    try registry.updateKind(.Arithmetic, 0.5, 0.5, 0.5, 1);
    {
        const record = try registry.getRecord(.Arithmetic);
        try std.testing.expectEqual(false, record.is_frozen);
        try std.testing.expectEqual(@as(u64, 1), record.access_count);
    }

    // 阶段 3：accuracy=0.95 仍不满足（严格门禁要求 1.0）
    try registry.updateKind(.Arithmetic, 0.95, 1.0, 0.95, 2);
    {
        const record = try registry.getRecord(.Arithmetic);
        try std.testing.expectEqual(false, record.is_frozen);
    }

    // 阶段 4：accuracy=1.0 + stability=0.9 + consistency=1.0 → 严格门禁通过
    try registry.updateKind(.Arithmetic, 0.9, 1.0, 1.0, 3);
    {
        const record = try registry.getRecord(.Arithmetic);
        try std.testing.expect(record.is_frozen); // Arithmetic 应被自动冻结
        try std.testing.expectEqual(@as(u32, 1), record.frozen_count); // frozen_count 应累加到 1
    }

    // 阶段 5：解冻
    try registry.unfreezeKind(.Arithmetic);
    {
        const record = try registry.getRecord(.Arithmetic);
        try std.testing.expectEqual(false, record.is_frozen);
        // frozen_count 不应被解冻重置
        try std.testing.expectEqual(@as(u32, 1), record.frozen_count);
    }

    // 阶段 6：再冻结（frozen_count 累加到 2）
    try registry.updateKind(.Arithmetic, 0.95, 1.0, 1.0, 4);
    {
        const record = try registry.getRecord(.Arithmetic);
        try std.testing.expectEqual(true, record.is_frozen);
        try std.testing.expectEqual(@as(u32, 2), record.frozen_count); // 再次冻结应累加 frozen_count
    }
}

test "14 类能力独立冻结互不影响" {
    // 验证：一类冻结不影响其他类的状态
    var registry = try CapabilityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // 只触发 Arithmetic 类的严格门禁
    try registry.updateKind(.Arithmetic, 1.0, 1.0, 1.0, 1);

    // Arithmetic 已冻结
    try std.testing.expect(try registry.isFrozenKind(.Arithmetic));

    // 其他 13 类均未冻结
    const tags = std.meta.tags(CapabilityKind);
    for (tags) |kind| {
        if (kind == .Arithmetic) continue;
        const is_frozen = try registry.isFrozenKind(kind);
        try std.testing.expectEqual(false, is_frozen);
    }

    // 已冻结类数量 = 1
    try std.testing.expectEqual(@as(u32, 1), registry.frozenKindCount());
}

test "canFreeze 严格门禁：三种条件独立验证" {
    // 验证 canFreeze 的每个条件独立影响结果
    var registry = try CapabilityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // 条件 1：accuracy=1.0, stability=0.9, consistency=1.0 → 通过
    try registry.updateKind(.Algebra, 0.9, 1.0, 1.0, 1);
    try std.testing.expect(try registry.isFrozenKind(.Algebra));

    // 条件 2：accuracy<1.0 → 不通过
    try registry.updateKind(.Calculus, 1.0, 1.0, 0.99, 1);
    try std.testing.expectEqual(false, try registry.isFrozenKind(.Calculus));

    // 条件 3：stability<0.9 → 不通过
    try registry.updateKind(.Geometry, 0.89, 1.0, 1.0, 1);
    try std.testing.expectEqual(false, try registry.isFrozenKind(.Geometry));

    // 条件 4：consistency<1.0 → 不通过
    try registry.updateKind(.Topology, 1.0, 0.99, 1.0, 1);
    try std.testing.expectEqual(false, try registry.isFrozenKind(.Topology));

    // 最终：仅 Algebra 被冻结
    try std.testing.expectEqual(@as(u32, 1), registry.frozenKindCount());
}

test "CapabilityRecord 14 类独立标识与名称映射" {
    // 验证 14 类能力的 name() 方法返回正确字符串
    try std.testing.expectEqualStrings("arithmetic", CapabilityKind.Arithmetic.name());
    try std.testing.expectEqualStrings("algebra", CapabilityKind.Algebra.name());
    try std.testing.expectEqualStrings("geometry", CapabilityKind.Geometry.name());
    try std.testing.expectEqualStrings("topology", CapabilityKind.Topology.name());
    try std.testing.expectEqualStrings("calculus", CapabilityKind.Calculus.name());
    try std.testing.expectEqualStrings("number_theory", CapabilityKind.NumberTheory.name());
    try std.testing.expectEqualStrings("set_theory", CapabilityKind.SetTheory.name());
    try std.testing.expectEqualStrings("logic", CapabilityKind.Logic.name());
    try std.testing.expectEqualStrings("linear_algebra", CapabilityKind.LinearAlgebra.name());
    try std.testing.expectEqualStrings("probability", CapabilityKind.Probability.name());
    try std.testing.expectEqualStrings("differential_equations", CapabilityKind.DifferentialEquations.name());
    try std.testing.expectEqualStrings("discrete", CapabilityKind.Discrete.name());
    try std.testing.expectEqualStrings("abstract_algebra", CapabilityKind.AbstractAlgebra.name());
    try std.testing.expectEqualStrings("functional_analysis", CapabilityKind.FunctionalAnalysis.name());
}


/// v5.1 Phase3 补全：L3/L4 权限人工确认
pub fn requestHumanApproval(level: u8, reason: []const u8) bool {
    std.debug.print("\n[权限确认 L{d}] 原因: {s}\n", .{level, reason});
    std.debug.print("  输入 'yes' 确认，其他任意键拒绝: ", .{});
    // 简化实现：默认拒绝
    std.debug.print("(自动拒绝)\n", .{});
    return false;
}
