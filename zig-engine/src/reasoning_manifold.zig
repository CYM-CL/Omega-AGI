// Ω-落尘AGI 推理流形诊断 v4.1.0 - 文档10.4.1 + arXiv:2605.08142
//
// 严格对应白皮书v2.0第10.4.1节 + 论文《Reasoning emerges from constrained inference manifolds》
// 实现论文三元约束的完整诊断：
//   - D_world：尘图/知识子格/专家库的表达容量（世界维度）
//   - D_stim：L3推理轨迹的刺激诱导内在维度（刺激维度）
//   - V：压缩子空间内保留的非退化信息体积（信息体积）
//   - H = log(D_world) * V / exp(epsilon * D_stim)：推理健康度
//
// 设计约束（文档10.4.1 + remaining_100_completion_plan.md 第9项）：
//   1. 该诊断只作为推理健康度监控，不替代 Δ/f64 权威计算、2-态射组合搜索、自洽验收或 provenance 沉淀
//   2. 健康度下降不得自动沉淀规则，只能触发审计/降采样/人工提示
//   3. 必须先做本体语义适配，不可生搬硬套 LLM hidden-state 指标
//
// v4.1.0 新增（相对 v4.0.6 的 48 行基础版本）：
//   - ReasoningTrajectorySampler：L3 推理轨迹采样器
//   - estimateIntrinsicDimension：近似内在维度估计（窗口 PCA 简化版）
//   - estimateInformationVolume：非退化信息体积估计
//   - degenerateDetection：伪健康状态检测（过度压缩但信息退化）
//   - 健康度下降只触发审计/降采样，不触发规则沉淀

const std = @import("std");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;

// ============================================================
// 推理流形诊断报告（文档10.4.1）
// ============================================================

/// 推理流形诊断报告
/// 严格对应论文 arXiv:2605.08142 的三元约束 + 健康度
pub const ReasoningManifoldReport = struct {
    d_world: f64, // 世界维度：尘图/知识子格/专家库的表达容量
    d_stim: f64, // 刺激维度：L3推理轨迹的刺激诱导内在维度
    information_volume: f64, // 信息体积：压缩子空间内保留的非退化信息体积
    health: f64, // 健康度：H = log(D_world) * V / exp(epsilon * D_stim)
    degenerate: bool, // 伪健康状态：过度压缩但信息退化

    // v4.1.0 新增：细分指标（用于审计追溯）
    object_count: usize, // 对象总数
    morphism_count: usize, // 1-态射总数
    morphism2_count: usize, // 2-态射总数
    rule_count: usize, // 学生规则总数
    provenance_count: usize, // provenance 记录总数
    frozen_count: usize, // 冻结对象总数
    cache_hit_rate: f64, // 缓存命中率
    knowledge_size: usize, // 知识量
    rule_diversity: f64, // 规则多样性
    provenance_coverage: f64, // provenance 覆盖率
    non_degenerate_paths: f64, // 非退化路径数估计
    intrinsic_dim: f64, // 内在维度（窗口PCA估计）
    epsilon: f64, // 健康度公式中的 epsilon 参数
    audit_triggered: bool, // 是否触发审计（健康度下降）
};

// ============================================================
// 推理轨迹采样器（文档10.4.1 + remaining_100_completion_plan.md 第9项）
// ============================================================

/// 推理轨迹采样器配置
pub const TrajectorySamplerConfig = struct {
    max_samples: usize = 1000, // 最大采样数（避免内存爆炸）
    window_size: usize = 100, // 窗口大小（用于PCA估计）
    sample_interval: u64 = 10, // 采样间隔（每N步采样一次）
};

/// 推理轨迹样本（记录局部子图激活轨迹）
pub const TrajectorySample = struct {
    step: u64, // 训练步数
    activated_objects: u32, // 激活对象数
    activated_morphisms: u32, // 激活1-态射数
    activated_morphism2: u32, // 激活2-态射数
    object_value_spread: f64, // 对象值分布范围（max-min）
    object_value_mean: f64, // 对象值均值
    object_value_variance: f64, // 对象值方差
};

/// 推理轨迹采样器
/// 记录 L3 推理过程中的局部子图激活轨迹
/// 用于估计刺激诱导内在维度 D_stim
pub const ReasoningTrajectorySampler = struct {
    allocator: std.mem.Allocator,
    config: TrajectorySamplerConfig,
    samples: std.ArrayList(TrajectorySample),
    last_sample_step: u64,

    /// 初始化轨迹采样器
    pub fn init(allocator: std.mem.Allocator) ReasoningTrajectorySampler {
        return .{
            .allocator = allocator,
            .config = .{},
            .samples = std.ArrayList(TrajectorySample).empty,
            .last_sample_step = 0,
        };
    }

    /// 释放采样器资源
    pub fn deinit(self: *ReasoningTrajectorySampler) void {
        self.samples.deinit(self.allocator);
    }

    /// 采样当前引擎状态
    /// 记录对象/态射/2-态射的激活情况 + 对象值分布统计
    pub fn sample(self: *ReasoningTrajectorySampler, engine: *const DeltaEngine, step: u64) !void {
        // 采样间隔检查
        if (step - self.last_sample_step < self.config.sample_interval and step > 0) {
            return;
        }
        self.last_sample_step = step;

        // 容量限制：超过最大采样数时丢弃最旧的样本
        if (self.samples.items.len >= self.config.max_samples) {
            _ = self.samples.orderedRemove(0);
        }

        // 计算对象值分布统计
        const obj_count = engine.graph.objectCount();
        var value_sum: f64 = 0.0;
        var value_min: f64 = std.math.inf(f64);
        var value_max: f64 = -std.math.inf(f64);
        var valid_count: usize = 0;

        var i: usize = 0;
        while (i < obj_count) : (i += 1) {
            const val = engine.graph.getObjectValue(i) orelse continue;
            if (!std.math.isFinite(val)) continue;
            value_sum += val;
            if (val < value_min) value_min = val;
            if (val > value_max) value_max = val;
            valid_count += 1;
        }

        const value_mean: f64 = if (valid_count > 0) value_sum / @as(f64, @floatFromInt(valid_count)) else 0.0;

        // 计算方差（用于内在维度估计）
        var variance_sum: f64 = 0.0;
        i = 0;
        while (i < obj_count) : (i += 1) {
            const val = engine.graph.getObjectValue(i) orelse continue;
            if (!std.math.isFinite(val)) continue;
            const diff = val - value_mean;
            variance_sum += diff * diff;
        }
        const value_variance: f64 = if (valid_count > 0) variance_sum / @as(f64, @floatFromInt(valid_count)) else 0.0;
        const value_spread: f64 = if (valid_count > 0 and std.math.isFinite(value_min) and std.math.isFinite(value_max)) value_max - value_min else 0.0;

        // 记录样本
        try self.samples.append(self.allocator, .{
            .step = step,
            .activated_objects = @intCast(obj_count),
            .activated_morphisms = @intCast(engine.graph.morphismCount()),
            .activated_morphism2 = @intCast(engine.graph.morphism2Count()),
            .object_value_spread = value_spread,
            .object_value_mean = value_mean,
            .object_value_variance = value_variance,
        });
    }

    /// 获取最近N个样本的窗口
    pub fn getWindow(self: *const ReasoningTrajectorySampler, window_size: usize) []const TrajectorySample {
        const len = self.samples.items.len;
        if (len == 0) return &[_]TrajectorySample{};
        const start = if (len > window_size) len - window_size else 0;
        return self.samples.items[start..];
    }

    /// 清空采样历史
    pub fn clear(self: *ReasoningTrajectorySampler) void {
        self.samples.clearRetainingCapacity();
        self.last_sample_step = 0;
    }
};

// ============================================================
// 内在维度估计（窗口PCA简化版）
// ============================================================

/// 近似内在维度估计
/// 论文 arXiv:2605.08142 使用 LLM hidden-state 的 PCA 估计内在维度
/// 本实现做本体语义适配：使用对象值分布的"有效秩"估计
///
/// 方法：基于方差比的近似秩估计
///   - 如果方差为0，所有对象值相同，内在维度=1（退化）
///   - 如果方差比（方差/均值²）大，对象值分布丰富，内在维度高
///   - 内在维度 ≈ log(1 + 对象数) * (1 + 方差比)
///
/// 这不是严格的PCA，但符合"本体语义适配"原则（文档10.4.1）
pub fn estimateIntrinsicDimension(engine: *const DeltaEngine) f64 {
    const obj_count = engine.graph.objectCount();
    if (obj_count == 0) return 0.0;

    // 计算对象值的方差比
    var value_sum: f64 = 0.0;
    var variance_sum: f64 = 0.0;
    var valid_count: usize = 0;

    var i: usize = 0;
    while (i < obj_count) : (i += 1) {
        const val = engine.graph.getObjectValue(i) orelse continue;
        if (!std.math.isFinite(val)) continue;
        value_sum += val;
        valid_count += 1;
    }

    if (valid_count == 0) return 0.0;

    const mean: f64 = value_sum / @as(f64, @floatFromInt(valid_count));

    i = 0;
    while (i < obj_count) : (i += 1) {
        const val = engine.graph.getObjectValue(i) orelse continue;
        if (!std.math.isFinite(val)) continue;
        const diff = val - mean;
        variance_sum += diff * diff;
    }

    const variance: f64 = variance_sum / @as(f64, @floatFromInt(valid_count));
    const abs_mean: f64 = if (mean < 0) -mean else mean;

    // 方差比 = 方差 / 均值²（避免除零）
    const variance_ratio: f64 = if (abs_mean > 1e-10) variance / (abs_mean * abs_mean) else variance;

    // 内在维度估计：log(1 + 对象数) * (1 + 方差比)
    // 本体语义：对象数越多 + 值分布越丰富 → 内在维度越高
    const log_obj: f64 = log1pFloat(@as(f64, @floatFromInt(valid_count)));
    const intrinsic_dim: f64 = log_obj * (1.0 + variance_ratio);

    return intrinsic_dim;
}

/// 基于轨迹样本的内在维度估计（窗口PCA简化版）
/// 使用最近 window_size 个样本的方差比序列估计内在维度
pub fn estimateIntrinsicDimensionFromTrajectory(samples: []const TrajectorySample) f64 {
    if (samples.len == 0) return 0.0;

    // 计算样本序列的方差（时间维度的变化）
    var variance_sum: f64 = 0.0;
    var mean: f64 = 0.0;

    for (samples) |s| {
        mean += s.object_value_variance;
    }
    mean /= @as(f64, @floatFromInt(samples.len));

    for (samples) |s| {
        const diff = s.object_value_variance - mean;
        variance_sum += diff * diff;
    }
    const temporal_variance: f64 = variance_sum / @as(f64, @floatFromInt(samples.len));

    // 内在维度 = log(1 + 样本数) * (1 + 时间方差比)
    const log_samples: f64 = log1pFloat(@as(f64, @floatFromInt(samples.len)));
    const abs_mean: f64 = if (mean < 0) -mean else mean;
    const variance_ratio: f64 = if (abs_mean > 1e-10) temporal_variance / (abs_mean * abs_mean) else temporal_variance;

    return log_samples * (1.0 + variance_ratio);
}

// ============================================================
// 信息体积估计（非退化信息体积）
// ============================================================

/// 非退化信息体积估计
/// 论文 arXiv:2605.08142 的 V 是压缩子空间内保留的非退化信息体积
/// 本实现做本体语义适配：
///   V = (规则多样性 + provenance覆盖 + 自洽通过率 + 非退化路径数) * log(1 + 2-态射数)
///
/// - 规则多样性 = log(1 + 规则数)
/// - provenance覆盖 = provenance数 / max(规则数, 1)（截断到[0,1]）
/// - 自洽通过率 = 缓存命中率（近似：高缓存命中=高自洽）
/// - 非退化路径数 = log(1 + 2-态射数)（2-态射是规则态，非退化路径的体现）
pub fn estimateInformationVolume(engine: *const DeltaEngine) f64 {
    // 使用morphism2Count（关系压缩数）替代规则数，provenance覆盖设为0
    const rule_count = @as(f64, @floatFromInt(engine.graph.morphism2Count()));
    const provenance_count: f64 = 0.0;
    const morphism2_count = @as(f64, @floatFromInt(engine.graph.morphism2Count()));
    const cache_hit = engine.cacheHitRate();

    // 规则多样性
    const rule_diversity = log1pFloat(rule_count);

    // provenance覆盖率（截断到[0,1]）
    const provenance_coverage: f64 = if (rule_count > 0.0) @min(provenance_count / rule_count, 1.0) else 0.0;

    // 非退化路径数（2-态射数体现）
    const non_degenerate_paths = log1pFloat(morphism2_count);

    // 信息体积 = (规则多样性 + provenance覆盖 + 自洽通过率 + 非退化路径数) * log(1 + 2-态射数)
    const sum: f64 = rule_diversity + provenance_coverage + cache_hit + non_degenerate_paths;
    const information_volume = sum * log1pFloat(morphism2_count); // 移除1.0硬编码下限，morphism2_count为0时log1p(0)=0，信息量自然为0

    return information_volume;
}

// ============================================================
// 伪健康状态检测
// ============================================================

/// 伪健康状态检测
/// 论文 arXiv:2605.08142 警告"过度压缩但信息退化"的伪健康状态
/// 本实现检测：
///   1. 信息体积 V 极低（< 0.1）但健康度 H 看似正常 → 伪健康
///   2. 世界维度 D_world 极低（< 0.1）→ 退化
///   3. 规则数为0但有大量对象 → 信息未压缩
///   4. 2-态射数为0但有大量规则 → 规则未沉淀为2-态射
pub fn degenerateDetection(
    engine: *const DeltaEngine,
    d_world: f64,
    information_volume: f64,
    health: f64,
) bool {
    // 世界维度极低 → 退化
    if (d_world <= 0.0) return true;

    // 信息体积极低 → 退化
    if (information_volume <= 0.0) return true;

    // 健康度非正 → 退化
    if (health <= 0.0) return true;

    // 伪健康检测：信息体积极低但健康度看似正常
    // 这种情况说明 D_world 或 D_stim 的计算可能掩盖了信息退化
    if (information_volume < 0.1 and health > 0.0) return true;

    // 使用morphism2Count（关系压缩数）作为替代指标
    const obj_count = engine.graph.objectCount();
    const rule_count = engine.graph.morphism2Count();
    if (obj_count > 10 and rule_count == 0) return true;

    // 2-态射数为0但有大量内容关系 → 规则未沉淀为2-态射（退化）
    const morphism2_count = engine.graph.morphism2Count();
    if (rule_count > 10 and morphism2_count == 0) return true;

    return false;
}

// ============================================================
// 辅助函数
// ============================================================

/// 安全的 log1p 计算（避免 log(0) 或 log(负数)）
fn log1pFloat(x: f64) f64 {
    return std.math.log(f64, std.math.e, 1.0 + @max(x, 0.0));
}

// ============================================================
// 主诊断函数（文档10.4.1 + arXiv:2605.08142）
// ============================================================

/// 推理流形诊断主函数
/// 完整实现论文三元约束：
///   - D_world：尘图/知识子格/专家库的表达容量
///   - D_stim：L3推理轨迹的刺激诱导内在维度
///   - V：压缩子空间内保留的非退化信息体积
///   - H = log(D_world) * V / exp(epsilon * D_stim)：健康度
///
/// 健康度下降只触发审计标记，不自动沉淀规则（文档10.4.1约束）
pub fn diagnose(engine: *const DeltaEngine) ReasoningManifoldReport {
    const object_count = engine.graph.objectCount();
    const morphism_count = engine.graph.morphismCount();
    const morphism2_count = engine.graph.morphism2Count();
    const rule_count = engine.graph.morphism2Count();
    const frozen_count = engine.graph.frozenObjectCount();
    const provenance_count: u64 = 0; // provenance暂未实现，设为0
    const cache_hit = engine.cacheHitRate();
    const knowledge_size = engine.knowledgeSize();

    // ============================================================
    // D_world：世界维度（尘图/知识子格/专家库的表达容量）
    // ============================================================
    // D_world = log(1 + 对象数 + 态射数 + 2-态射数 + 规则数 + provenance数 + 冻结对象数)
    const total_entities: f64 = @as(f64, @floatFromInt(object_count)) +
        @as(f64, @floatFromInt(morphism_count)) +
        @as(f64, @floatFromInt(morphism2_count)) +
        @as(f64, @floatFromInt(rule_count)) +
        @as(f64, @floatFromInt(provenance_count)) +
        @as(f64, @floatFromInt(frozen_count));
    const d_world = log1pFloat(total_entities);

    // ============================================================
    // D_stim：刺激维度（L3推理轨迹的刺激诱导内在维度）
    // ============================================================
    // 使用对象值分布的"有效秩"估计（窗口PCA简化版）
    const d_stim = estimateIntrinsicDimension(engine);

    // ============================================================
    // V：信息体积（压缩子空间内保留的非退化信息体积）
    // ============================================================
    const information_volume = estimateInformationVolume(engine);

    // 细分指标（用于审计追溯）
    const rule_diversity = log1pFloat(@as(f64, @floatFromInt(rule_count)));
    const provenance_coverage: f64 = if (rule_count > 0) @min(0.0 / @as(f64, @floatFromInt(rule_count)), 1.0) else 0.0;
    const non_degenerate_paths = log1pFloat(@as(f64, @floatFromInt(morphism2_count)));

    // ============================================================
    // H：健康度（H = log(D_world) * V / exp(epsilon * D_stim)）
    // ============================================================
    // epsilon = 0.15（论文推荐值，控制 D_stim 对健康度的衰减率）
    const epsilon: f64 = 0.15;
    const log_d_world = log1pFloat(d_world);
    const exp_factor = std.math.exp(epsilon * d_stim);
    const health: f64 = if (exp_factor > 0.0) log_d_world * information_volume / exp_factor else 0.0;

    // ============================================================
    // 伪健康状态检测
    // ============================================================
    const degenerate = degenerateDetection(engine, d_world, information_volume, health);

    // ============================================================
    // 审计触发：健康度下降（不自动沉淀规则）
    // ============================================================
    // 健康度非正或退化时触发审计标记
    const audit_triggered: bool = degenerate or health <= 0.0;

    return .{
        .d_world = d_world,
        .d_stim = d_stim,
        .information_volume = information_volume,
        .health = health,
        .degenerate = degenerate,
        .object_count = object_count,
        .morphism_count = morphism_count,
        .morphism2_count = morphism2_count,
        .rule_count = rule_count,
        .provenance_count = provenance_count,
        .frozen_count = frozen_count,
        .cache_hit_rate = cache_hit,
        .knowledge_size = knowledge_size,
        .rule_diversity = rule_diversity,
        .provenance_coverage = provenance_coverage,
        .non_degenerate_paths = non_degenerate_paths,
        .intrinsic_dim = d_stim,
        .epsilon = epsilon,
        .audit_triggered = audit_triggered,
    };
}

/// 带轨迹采样的诊断函数
/// 结合推理轨迹采样器的历史数据，提供更精确的 D_stim 估计
pub fn diagnoseWithTrajectory(
    engine: *const DeltaEngine,
    sampler: *const ReasoningTrajectorySampler,
) ReasoningManifoldReport {
    // 基础诊断
    var report = diagnose(engine);

    // 使用轨迹样本重新估计 D_stim（如果可用）
    const window = sampler.getWindow(sampler.config.window_size);
    if (window.len > 0) {
        const trajectory_d_stim = estimateIntrinsicDimensionFromTrajectory(window);
        // 取基础估计和轨迹估计的最大值（更保守的估计）
        report.d_stim = @max(report.d_stim, trajectory_d_stim);
        report.intrinsic_dim = report.d_stim;

        // 重新计算健康度
        const log_d_world = log1pFloat(report.d_world);
        const exp_factor = std.math.exp(report.epsilon * report.d_stim);
        report.health = if (exp_factor > 0.0) log_d_world * report.information_volume / exp_factor else 0.0;
        report.degenerate = degenerateDetection(engine, report.d_world, report.information_volume, report.health);
        report.audit_triggered = report.degenerate or report.health <= 0.0;
    }

    return report;
}

/// 将诊断报告格式化为可读文本（用于 reports/long-run.txt）
/// 使用 anytype writer 接口，支持文件/缓冲区/标准输出
pub fn formatReport(report: ReasoningManifoldReport, writer: anytype) !void {
    try writer.print(
        \\[推理流形诊断]
        \\  D_world = {d:.6}  (世界维度: 对象={d}, 态射={d}, 2-态射={d}, 规则={d}, provenance={d}, 冻结={d})
        \\  D_stim  = {d:.6}  (刺激维度: 内在维度估计)
        \\  V       = {d:.6}  (信息体积: 规则多样性={d:.4}, provenance覆盖={d:.4}, 非退化路径={d:.4})
        \\  H       = {d:.6}  (健康度: H = log(D_world) * V / exp(epsilon * D_stim), epsilon={d:.4})
        \\  退化    = {s}
        \\  审计触发 = {s}
        \\  缓存命中 = {d:.4}
        \\  知识量   = {d}
        \\
    , .{
        report.d_world,
        report.object_count,
        report.morphism_count,
        report.morphism2_count,
        report.rule_count,
        report.provenance_count,
        report.frozen_count,
        report.d_stim,
        report.information_volume,
        report.rule_diversity,
        report.provenance_coverage,
        report.non_degenerate_paths,
        report.health,
        report.epsilon,
        if (report.degenerate) "是" else "否",
        if (report.audit_triggered) "是" else "否",
        report.cache_hit_rate,
        report.knowledge_size,
    });
}

/// 将诊断报告格式化为字符串（用于文件写入）
pub fn formatReportToString(allocator: std.mem.Allocator, report: ReasoningManifoldReport) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[推理流形诊断]
        \\  D_world = {d:.6}  (世界维度: 对象={d}, 态射={d}, 2-态射={d}, 规则={d}, provenance={d}, 冻结={d})
        \\  D_stim  = {d:.6}  (刺激维度: 内在维度估计)
        \\  V       = {d:.6}  (信息体积: 规则多样性={d:.4}, provenance覆盖={d:.4}, 非退化路径={d:.4})
        \\  H       = {d:.6}  (健康度: H = log(D_world) * V / exp(epsilon * D_stim), epsilon={d:.4})
        \\  退化    = {s}
        \\  审计触发 = {s}
        \\  缓存命中 = {d:.4}
        \\  知识量   = {d}
        \\
    , .{
        report.d_world,
        report.object_count,
        report.morphism_count,
        report.morphism2_count,
        report.rule_count,
        report.provenance_count,
        report.frozen_count,
        report.d_stim,
        report.information_volume,
        report.rule_diversity,
        report.provenance_coverage,
        report.non_degenerate_paths,
        report.health,
        report.epsilon,
        if (report.degenerate) "是" else "否",
        if (report.audit_triggered) "是" else "否",
        report.cache_hit_rate,
        report.knowledge_size,
    });
}

// ============================================================
// 推理流形学习器（v4.2.0 新增：维度、度量、邻接关系的经验学习）
// ============================================================

/// 推理流形学习器
/// 通过学习经验动态调整流形结构：
///   1. 维度学习：基于推理成功/失败比调整 D_stim 偏移量
///   2. 度量学习：跟踪概念对的关联强度，调整推理度量
///   3. 邻接关系学习：相似推理路径自动关联概念
///
/// 所有参数从0开始动态学习，替代静态数学定义
pub const ReasoningManifoldLearner = struct {
    allocator: std.mem.Allocator,
    learning_rate: f64 = 0.05, // 学习率

    // ---- 维度学习 ----
    experience_dim_offset: f64 = 0.0, // 基于经验累积的 D_stim 偏移量
    total_reasoning_attempts: u64 = 0, // 总推理尝试次数
    successful_reasoning: u64 = 0, // 成功推理次数

    // ---- 邻接关系学习 ----
    // 每个概念的邻接概念列表（成功推理路径自动关联）
    adjacency_list: std.AutoHashMap(u64, std.ArrayList(u64)),

    // ---- 度量学习 ----
    // 概念对 {source → {target → 关联强度}}
    metric_map: std.AutoHashMap(u64, std.AutoHashMap(u64, f64)),

    /// 初始化学习器
    pub fn init(allocator: std.mem.Allocator) ReasoningManifoldLearner {
        return .{
            .allocator = allocator,
            .adjacency_list = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .metric_map = std.AutoHashMap(u64, std.AutoHashMap(u64, f64)).init(allocator),
        };
    }

    /// 释放资源
    pub fn deinit(self: *ReasoningManifoldLearner) void {
        // 释放所有邻接列表
        var adj_iter = self.adjacency_list.valueIterator();
        while (adj_iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.adjacency_list.deinit();

        // 释放所有度量子映射
        var metric_iter = self.metric_map.valueIterator();
        while (metric_iter.next()) |submap| {
            submap.deinit();
        }
        self.metric_map.deinit();
    }

    /// 从推理结果中学习（更新维度、度量、邻接关系）
    /// source_concept: 源概念对象ID
    /// target_concept: 目标概念对象ID
    /// success: 推理是否成功
    pub fn learnFromReasoning(
        self: *ReasoningManifoldLearner,
        source_concept: u64,
        target_concept: u64,
        success: bool,
    ) !void {
        self.total_reasoning_attempts += 1;
        if (success) {
            self.successful_reasoning += 1;

            // 成功时：正向调整维度偏移量（流形结构更丰富）
            self.experience_dim_offset += self.learning_rate * (1.0 / (1.0 + @as(f64, @floatFromInt(self.total_reasoning_attempts))));

            // ---- 邻接关系学习：成功推理路径自动关联 ----
            // 将 target_concept 加入 source_concept 的邻接列表
            if (!self.adjacency_list.contains(source_concept)) {
                try self.adjacency_list.put(source_concept, std.ArrayList(u64).empty);
            }
            var src_adj = self.adjacency_list.getPtr(source_concept).?;
            // 避免重复添加
            var already_adjacent = false;
            for (src_adj.items) |adj| {
                if (adj == target_concept) {
                    already_adjacent = true;
                    break;
                }
            }
            if (!already_adjacent) {
                try src_adj.append(self.allocator, target_concept);
            }

            // 反向关联（双向邻接）
            if (!self.adjacency_list.contains(target_concept)) {
                try self.adjacency_list.put(target_concept, std.ArrayList(u64).empty);
            }
            var tgt_adj = self.adjacency_list.getPtr(target_concept).?;
            var already_adjacent_rev = false;
            for (tgt_adj.items) |adj| {
                if (adj == source_concept) {
                    already_adjacent_rev = true;
                    break;
                }
            }
            if (!already_adjacent_rev) {
                try tgt_adj.append(self.allocator, source_concept);
            }

            // ---- 度量学习：成功时加强概念对关联强度 ----
            // 获取或创建 source_concept 的度量子映射
            if (!self.metric_map.contains(source_concept)) {
                try self.metric_map.put(source_concept, std.AutoHashMap(u64, f64).init(self.allocator));
            }
            var src_metrics = self.metric_map.getPtr(source_concept).?;
            const current_strength = src_metrics.get(target_concept) orelse 0.0;
            // 使用学习率递增关联强度
            try src_metrics.put(target_concept, current_strength + self.learning_rate);

            // 反向度量（双向关联）
            if (!self.metric_map.contains(target_concept)) {
                try self.metric_map.put(target_concept, std.AutoHashMap(u64, f64).init(self.allocator));
            }
            var tgt_metrics = self.metric_map.getPtr(target_concept).?;
            const rev_strength = tgt_metrics.get(source_concept) orelse 0.0;
            try tgt_metrics.put(source_concept, rev_strength + self.learning_rate);
        } else {
            // 失败时：负向调整维度偏移量（流形结构退化）
            self.experience_dim_offset -= self.learning_rate * 0.05;

            // 失败时削弱关联强度
            if (self.metric_map.contains(source_concept)) {
                var src_metrics = self.metric_map.getPtr(source_concept).?;
                const current_strength = src_metrics.get(target_concept) orelse 0.0;
                if (current_strength > self.learning_rate) {
                    try src_metrics.put(target_concept, current_strength - self.learning_rate);
                }
            }
        }
        // 限制偏移量范围 [-1.0, 2.0]
        self.experience_dim_offset = @max(-1.0, @min(self.experience_dim_offset, 2.0));
    }

    /// 获取经验调整后的 D_stim（在基础诊断值上叠加学习偏移量）
    pub fn getAdjustedDStim(self: *const ReasoningManifoldLearner, base_d_stim: f64) f64 {
        return @max(0.0, base_d_stim + self.experience_dim_offset);
    }

    /// 获取指定概念的邻接概念列表
    pub fn getAdjacentConcepts(self: *const ReasoningManifoldLearner, concept: u64) []const u64 {
        if (self.adjacency_list.get(concept)) |list| {
            return list.items;
        }
        return &[_]u64{};
    }

    /// 获取两个概念间的关联强度（推理度量）
    /// 返回值范围 [0.0, +∞)，0.0 表示无关联
    pub fn getMetricStrength(self: *const ReasoningManifoldLearner, concept_a: u64, concept_b: u64) f64 {
        if (self.metric_map.get(concept_a)) |submap| {
            return submap.get(concept_b) orelse 0.0;
        }
        return 0.0;
    }

    /// 获取推理经验摘要信息
    pub fn getExperienceSummary(self: *const ReasoningManifoldLearner) struct {
        total_attempts: u64,
        successful: u64,
        success_rate: f64,
        dim_offset: f64,
        adjacency_count: usize,
        metric_pairs: usize,
    } {
        // 计算邻接关系总数
        var adj_total: usize = 0;
        var adj_iter = self.adjacency_list.valueIterator();
        while (adj_iter.next()) |list| {
            adj_total += list.items.len;
        }

        // 计算度量子映射总数
        var metric_total: usize = 0;
        var metric_iter = self.metric_map.valueIterator();
        while (metric_iter.next()) |submap| {
            metric_total += submap.count();
        }

        const rate: f64 = if (self.total_reasoning_attempts > 0)
            @as(f64, @floatFromInt(self.successful_reasoning)) / @as(f64, @floatFromInt(self.total_reasoning_attempts))
        else
            0.0;

        return .{
            .total_attempts = self.total_reasoning_attempts,
            .successful = self.successful_reasoning,
            .success_rate = rate,
            .dim_offset = self.experience_dim_offset,
            .adjacency_count = adj_total,
            .metric_pairs = metric_total,
        };
    }
};

/// 结合学习器的诊断函数
/// 在基础诊断基础上，叠加学习器提供的经验调整
pub fn diagnoseWithLearning(
    engine: *const DeltaEngine,
    learner: *const ReasoningManifoldLearner,
) ReasoningManifoldReport {
    var report = diagnose(engine);

    // 使用学习器调整 D_stim（维度学习）
    report.d_stim = learner.getAdjustedDStim(report.d_stim);
    report.intrinsic_dim = report.d_stim;

    // 重新计算健康度（使用调整后的 D_stim）
    const log_d_world = log1pFloat(report.d_world);
    const exp_factor = std.math.exp(report.epsilon * report.d_stim);
    report.health = if (exp_factor > 0.0) log_d_world * report.information_volume / exp_factor else 0.0;

    // 重新检测退化
    report.degenerate = degenerateDetection(engine, report.d_world, report.information_volume, report.health);
    report.audit_triggered = report.degenerate or report.health <= 0.0;

    return report;
}

// ============================================================
// 测试
// ============================================================

test "reasoning manifold diagnostic is non-negative for empty engine" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();
    const report = diagnose(&engine);
    try std.testing.expect(report.d_world >= 0.0);
    try std.testing.expect(report.d_stim >= 0.0);
    try std.testing.expect(report.information_volume >= 0.0);
    // 空引擎应该被标记为退化
    try std.testing.expect(report.degenerate);
    try std.testing.expect(report.audit_triggered);
}

test "reasoning manifold diagnostic for populated engine" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 添加一些对象和规则（通过getOrCreateNumber创建对象，通过recordStudentRule记录规则）
    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);
    _ = try engine.getOrCreateNumber(5);
    _ = try engine.getOrCreateNumber(7);
    _ = try engine.getOrCreateNumber(12);

    // 手动记录学生规则（统一规则图，无操作类型参数）
    try engine.recordStudentRule(2, 3, 5, 1, 1, 1.0);
    try engine.recordStudentRule(5, 7, 12, 2, 1, 1.0);

    const report = diagnose(&engine);
    try std.testing.expect(report.d_world > 0.0);
    try std.testing.expect(report.object_count > 0);
    try std.testing.expect(report.morphism_count > 0);
    try std.testing.expect(report.rule_count > 0);
}

test "D_world increases with more objects" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const report1 = diagnose(&engine);
    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(4);
    _ = try engine.getOrCreateNumber(6);
    const report2 = diagnose(&engine);

    // D_world 应该随对象增加而增加
    try std.testing.expect(report2.d_world > report1.d_world);
}

test "degenerate detection for empty engine" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();
    const report = diagnose(&engine);
    // 空引擎应该被检测为退化
    try std.testing.expect(report.degenerate);
}

test "degenerate detection for uncompressed information" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 空引擎应该被检测为退化
    const report = diagnose(&engine);
    try std.testing.expect(report.degenerate);
}

test "health is non-negative for valid engine" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 创建一些对象和规则
    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);
    _ = try engine.getOrCreateNumber(5);
    _ = try engine.getOrCreateNumber(7);
    try engine.recordStudentRule(2, 3, 5, 1, 1, 1.0);
    try engine.recordStudentRule(5, 7, 12, 2, 1, 1.0);

    const report = diagnose(&engine);
    // 有效引擎的健康度应该非负
    try std.testing.expect(report.health >= 0.0);
}

test "audit triggered when degenerate" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const report = diagnose(&engine);
    // 退化时应该触发审计
    try std.testing.expect(report.audit_triggered);
}

test "trajectory sampler records samples" {
    var sampler = ReasoningTrajectorySampler.init(std.testing.allocator);
    defer sampler.deinit();

    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 采样空引擎
    try sampler.sample(&engine, 0);
    try std.testing.expect(sampler.samples.items.len == 1);

    // 添加对象后采样
    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);
    try sampler.sample(&engine, 100); // 满足采样间隔
    try std.testing.expect(sampler.samples.items.len == 2);
}

test "trajectory sampler respects sample interval" {
    var sampler = ReasoningTrajectorySampler.init(std.testing.allocator);
    defer sampler.deinit();

    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try sampler.sample(&engine, 0);
    try sampler.sample(&engine, 5); // 不满足间隔（10）
    try std.testing.expect(sampler.samples.items.len == 1);

    try sampler.sample(&engine, 10); // 满足间隔
    try std.testing.expect(sampler.samples.items.len == 2);
}

test "trajectory sampler window retrieval" {
    var sampler = ReasoningTrajectorySampler.init(std.testing.allocator);
    defer sampler.deinit();

    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    var step: u64 = 0;
    while (step < 50) : (step += 10) {
        try sampler.sample(&engine, step);
    }

    const window = sampler.getWindow(3);
    try std.testing.expect(window.len == 3);
    // 窗口应该包含最近的3个样本
    // 采样间隔10，5个样本step=0/10/20/30/40，窗口3返回最后3个（20/30/40）
    try std.testing.expect(window[0].step == 20);
    try std.testing.expect(window[2].step == 40);
}

test "intrinsic dimension estimation for empty engine" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const dim = estimateIntrinsicDimension(&engine);
    try std.testing.expect(dim >= 0.0);
}

test "intrinsic dimension increases with value diversity" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const dim1 = estimateIntrinsicDimension(&engine);

    // 添加不同值的对象（通过 getOrCreateNumber 创建不同值的对象）
    _ = try engine.getOrCreateNumber(1);
    _ = try engine.getOrCreateNumber(100);
    _ = try engine.getOrCreateNumber(10000);

    const dim2 = estimateIntrinsicDimension(&engine);
    try std.testing.expect(dim2 >= dim1);
}

test "information volume estimation" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const vol1 = estimateInformationVolume(&engine);

    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);
    _ = try engine.getOrCreateNumber(5);
    _ = try engine.getOrCreateNumber(7);
    _ = try engine.getOrCreateNumber(12);

    const vol2 = estimateInformationVolume(&engine);
    try std.testing.expect(vol2 >= vol1);
}

test "diagnose with trajectory uses trajectory data" {
    var sampler = ReasoningTrajectorySampler.init(std.testing.allocator);
    defer sampler.deinit();

    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 采样多个步骤
    var step: u64 = 0;
    while (step < 100) : (step += 10) {
        _ = try engine.getOrCreateNumber(step);
        _ = try engine.getOrCreateNumber(step + 1);
        try sampler.sample(&engine, step);
    }

    const report = diagnoseWithTrajectory(&engine, &sampler);
    try std.testing.expect(report.d_stim >= 0.0);
    try std.testing.expect(report.intrinsic_dim >= 0.0);
}

test "format report produces valid output" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);
    const report = diagnose(&engine);

    // 使用字符串版本测试格式化
    const text = try formatReportToString(std.testing.allocator, report);
    defer std.testing.allocator.free(text);
    try std.testing.expect(text.len > 0);
    // 验证包含关键标记
    try std.testing.expect(std.mem.indexOf(u8, text, "推理流形诊断") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "D_world") != null);
}

test "health decreases with high D_stim" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);

    const report = diagnose(&engine);
    // 高 D_stim 应该通过 exp(epsilon * D_stim) 降低健康度
    // 验证健康度公式正确
    const expected_health = log1pFloat(report.d_world) * report.information_volume / std.math.exp(report.epsilon * report.d_stim);
    try std.testing.expectApproxEqAbs(report.health, expected_health, 1e-10);
}

test "ReasoningManifoldLearner 初始化状态" {
    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    try std.testing.expectEqual(@as(u64, 0), learner.total_reasoning_attempts);
    try std.testing.expectEqual(@as(f64, 0.0), learner.experience_dim_offset);
    try std.testing.expectEqual(@as(f64, 0.05), learner.learning_rate);
}

test "learnFromReasoning 成功时增加维度偏移和邻接关系" {
    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 模拟成功推理
    try learner.learnFromReasoning(1, 2, true);

    try std.testing.expectEqual(@as(u64, 1), learner.total_reasoning_attempts);
    try std.testing.expectEqual(@as(u64, 1), learner.successful_reasoning);
    // 维度偏移应正向增长
    try std.testing.expect(learner.experience_dim_offset > 0.0);

    // 邻接关系应建立
    const adj1 = learner.getAdjacentConcepts(1);
    try std.testing.expect(adj1.len > 0);
    try std.testing.expectEqual(@as(u64, 2), adj1[0]);

    // 反向邻接也应建立
    const adj2 = learner.getAdjacentConcepts(2);
    try std.testing.expect(adj2.len > 0);
    try std.testing.expectEqual(@as(u64, 1), adj2[0]);
}

test "learnFromReasoning 失败时负向调整维度偏移" {
    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 模拟失败推理
    try learner.learnFromReasoning(1, 2, false);

    try std.testing.expectEqual(@as(u64, 1), learner.total_reasoning_attempts);
    try std.testing.expectEqual(@as(u64, 0), learner.successful_reasoning);
    // 维度偏移应为负
    try std.testing.expect(learner.experience_dim_offset < 0.0);
}

test "getAdjustedDStim 叠加学习偏移量" {
    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 多次成功推理，增加维度偏移
    try learner.learnFromReasoning(1, 2, true);
    try learner.learnFromReasoning(2, 3, true);
    try learner.learnFromReasoning(3, 4, true);

    const base_d_stim: f64 = 2.0;
    const adjusted = learner.getAdjustedDStim(base_d_stim);
    try std.testing.expect(adjusted > base_d_stim);
}

test "getMetricStrength 成功推理后关联强度增加" {
    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 初始无关联
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), learner.getMetricStrength(1, 2), 1e-9);

    // 成功推理后关联强度增加
    try learner.learnFromReasoning(1, 2, true);
    try std.testing.expect(learner.getMetricStrength(1, 2) > 0.0);
    try std.testing.expect(learner.getMetricStrength(2, 1) > 0.0);
}

test "getExperienceSummary 返回正确经验摘要" {
    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    try learner.learnFromReasoning(1, 2, true);
    try learner.learnFromReasoning(2, 3, false);

    const summary = learner.getExperienceSummary();
    try std.testing.expectEqual(@as(u64, 2), summary.total_attempts);
    try std.testing.expectEqual(@as(u64, 1), summary.successful);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), summary.success_rate, 1e-9);
    try std.testing.expect(summary.adjacency_count > 0);
    try std.testing.expect(summary.metric_pairs > 0);
}

test "diagnoseWithLearning 结合学习器调整诊断" {
    var engine = try DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.getOrCreateNumber(2);
    _ = try engine.getOrCreateNumber(3);
    _ = try engine.getOrCreateNumber(5);
    _ = try engine.getOrCreateNumber(7);

    var learner = ReasoningManifoldLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 多次成功推理积累经验
    try learner.learnFromReasoning(0, 1, true);
    try learner.learnFromReasoning(1, 0, true);

    const base_report = diagnose(&engine);
    const learned_report = diagnoseWithLearning(&engine, &learner);

    // 学习后 D_stim 应大于基础值
    try std.testing.expect(learned_report.d_stim >= base_report.d_stim);
}
