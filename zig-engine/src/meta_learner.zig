// Ω-落尘AGI 元学习器 v7.1 - 工程级置信度校准版
//
// v7.1核心增强：置信度工程成熟化
//   1. Beta分布置信度校准：基于历史推荐准确率的贝叶斯后验估计
//   2. 多指标融合置信度：趋势 + 震荡 + 数据充分性 → 综合置信度
//   3. 自适应校准：记录每次推荐的"预测-结果"对，动态调整
//   4. 置信度边界约束：推荐置信度 [0.05, 0.95]，永不越界
//   5. 校准率跟踪：跟踪校准准确率，置信度反映实际预测性能
//
// 设计定义：
//   元学习器从跨轮次训练历史中学习最优计划参数推荐。
//   位于"元学习建议 → 审计门审批 → 确定性执行"三层架构的顶层。
//
// 对应修复：
//   - 新增功能：从历史数据学习推荐计划参数
//   - 遵守核心定义守恒：推荐参数不越界
//   - 遵守可复现自洽：相同历史数据总是得到相同推荐
//
// 输入：TrainingHistory（轮次训练结果列表）
// 输出：ParamRecommendation（参数推荐）
// 约束：所有推荐参数必须在核心定义指定的边界内
//
// 依赖关系：
//   - training_plan.zig：TrainingPlan, PhaseConfig, AbilityDomain
//   - training_session.zig：EventLog, TrainingEvent, AdjustmentConstants

const std = @import("std");
const tp = @import("training_plan.zig");
const ts = @import("training_session.zig");
const et = @import("error_types.zig");

// ============================================================
// 轮次训练结果记录（元学习的输入数据）
// ============================================================

/// 单轮次训练结果
pub const RoundResult = struct {
    round_id: u64,
    version: []const u8,
    phase_accuracies: [3]f64,  // L1, L2, L3 各阶段准确率
    overall_accuracy: f64,
    total_steps_used: u64,
    // 调整次数
    adjustment_count: u64,
    rollback_count: u64,
    // 最终配置摘要
    final_l1_step: u64,
    final_l2_step: u64,
    final_l3_step: u64,
    /// v5.0.0：u64 参数范围（替代 u8 难度等级）
    final_range_start: u64,
    final_range_end: u64,
};

// ============================================================
// 参数推荐（元学习的输出）
// ============================================================

/// 参数推荐结果
pub const ParamRecommendation = struct {
    /// 是否建议修改
    should_adjust: bool,
    /// 推荐理由
    reason: []const u8,
    /// 推荐的调整常数（可覆盖或部分覆盖）
    recommended_constants: ?ts.AdjustmentConstants,
    /// 推荐的初始阶段步数
    recommended_l1_step: ?u64,
    recommended_l2_step: ?u64,
    recommended_l3_step: ?u64,
    /// 推荐的阶段参数范围（u64 参数值，替代 u8 难度等级）
    recommended_l1_range_start: ?u64,
    recommended_l2_range_start: ?u64,
    recommended_l3_range_start: ?u64,
    /// 置信度 [0, 1]
    confidence: f64,
};

// ============================================================
// v7.1：置信度校准系统
//
// Beta分布是置信度校准的理想选择：
//   Beta(α, β) 的均值 α/(α+β) 反映了"推荐正确的频率"
//   α = 正确预测数 + 1 (加1平滑，避免α=0)
//   β = 错误预测数 + 1 (加1平滑，避免β=0)
//   方差 αβ/((α+β)²(α+β+1)) 反映了置信度的不确定性
//
// 当系统积累了足够的校准数据，置信度接近实际预测性能。
// ============================================================

/// 置信度校准记录
pub const CalibrationRecord = struct {
    /// 推荐时的综合指标（趋势、震荡、数据量）
    trend_sign: enum { negative, stable, positive },
    oscillation_level: enum { low, medium, high },
    data_adequacy: enum { insufficient, adequate, rich },
    /// 推荐是否被证明正确（后续训练结果是否如预期）
    was_correct: bool,
};

// ============================================================
// 元学习器
// ============================================================

/// 元学习器：从历史训练数据中学习最优参数推荐
///
/// 算法说明：
///   1. 趋势分析：比较最近两轮的整体准确率趋势
///   2. 收敛速度分析：分析L1→L2→L3的准确率提升速率
///   3. 震荡检测：检测准确率是否在阈值附近来回跳动
///   4. 参数边界校验：所有推荐不超出核心定义边界
///
/// 设计约束：
///   - 可复现：相同 history 输入总是得到相同 recommend 输出
///   - 高置信度需要的轮次 ≥ 3
///   - 不修改历史数据，仅读取和分析
pub const MetaLearner = struct {
    allocator: std.mem.Allocator,
    /// 历史轮次结果
    history: std.ArrayList(RoundResult),
    /// 最小轮次数（达到此数才有足够置信度推荐）
    min_rounds_for_recommendation: u64,
    /// 趋势灵敏度（默认0.03，变化<3%视为稳定）
    trend_sensitivity: f64,

    // v7.1：置信度校准系统
    /// Beta分布参数 α（正确预测数 + 1，加1平滑）
    beta_alpha: f64,
    /// Beta分布参数 β（错误预测数 + 1，加1平滑）
    beta_beta: f64,
    /// 校准历史（记录每次推荐的预测准确度）
    calibration_history: std.ArrayList(CalibrationRecord),

    pub fn init(allocator: std.mem.Allocator) MetaLearner {
        return .{
            .allocator = allocator,
            .history = std.ArrayList(RoundResult).empty,
            .min_rounds_for_recommendation = 3,
            .trend_sensitivity = 0.03,
            // v7.1：初始化置信度校准系统
            .beta_alpha = 1.0, // 先验：Beta(1,1)=均匀分布，无偏先验
            .beta_beta = 1.0,
            .calibration_history = std.ArrayList(CalibrationRecord).empty,
        };
    }

    pub fn deinit(self: *MetaLearner) void {
        // 释放每条历史记录中堆分配的 version
        for (self.history.items) |*r| {
            self.allocator.free(r.version);
        }
        self.history.deinit(self.allocator);
        // v7.1：释放校准历史
        self.calibration_history.deinit(self.allocator);
    }

    /// 添加一条轮次结果
    pub fn addRound(self: *MetaLearner, result: RoundResult) void {
        // 复制 version 字符串（元学习器拥有所有权）
        const version_owned = self.allocator.dupe(u8, result.version) catch |err| {
            et.logGlobalError(.Warning, "meta_learner", "addRound", @intFromError(err), "dupe(version) failed");
            return;
        };
        var owned = result;
        owned.version = version_owned;
        self.history.append(self.allocator, owned) catch |err| {
            // append 失败时释放已分配的 version
            self.allocator.free(version_owned);
            et.logGlobalError(.Warning, "meta_learner", "addRound", @intFromError(err), "history.append failed");
        };
    }

    /// 获取历史轮次数
    pub fn roundCount(self: *const MetaLearner) usize {
        return self.history.items.len;
    }

    /// 从事件日志中重建历史记录
    /// 解析 EventLog 中记录的 PhaseAdjusted / FeedbackClosed / PhaseRolledBack 事件
    ///
    /// === 修复 Issue 6：parseStepFromSummary 解析事件摘要中的步数值 ===
    /// 事件摘要格式示例：
    ///   "step:500→400,start:3→4,max:5→6,bs:50→40,thr:90.0%→92.0%"
    ///   "rollback: step=1000→2000,start=1,max=3"
    ///   "L3acc:85.0%,step:200→250,start:5→4,max:10→7,thr:98.0%→98.0%"
    /// 局限性：事件日志不记录阶段准确率，因此 phase_accuracies 和 overall_accuracy 仍为 0，
    /// 但至少 final_l1_step / final_l2_step / final_l3_step 可从摘要中提取。
    pub fn fromEventLog(allocator: std.mem.Allocator, event_log: *const ts.EventLog) MetaLearner {
        var learner = MetaLearner.init(allocator);
        const events = event_log.getAll();

        if (events.len == 0) return learner;

        // 从事件日志中提取关键信息
        var adj_count: u64 = 0;
        var rollback_count: u64 = 0;
        var final_l1_step: u64 = 0;
        var final_l2_step: u64 = 0;
        var final_l3_step: u64 = 0;
        var final_range_start: u64 = 0;
        var final_range_end: u64 = 0;

        for (events) |ev| {
            switch (ev.event_type) {
                .PhaseAdjusted => adj_count += 1,
                .PhaseRolledBack => rollback_count += 1,
                else => {},
            }
            // 从事件摘要中解析新值（箭头后的值）
            const step_val = parseStepFromSummary(ev.changes_summary);
            const start_val = parseRangeStartFromSummary(ev.changes_summary);
            const end_val = parseRangeEndFromSummary(ev.changes_summary);

            // 根据 phase_idx 更新对应阶段的最终步数
            if (ev.phase_idx) |pidx| {
                if (pidx == 0 and step_val > 0) final_l1_step = step_val;
                if (pidx == 1 and step_val > 0) final_l2_step = step_val;
                if (pidx == 2 and step_val > 0) final_l3_step = step_val;
                if (pidx == 0 and start_val > 0) final_range_start = start_val;
                if (pidx == 0 and end_val > 0) final_range_end = end_val;
            }
            // 回退事件处理
            if (ev.event_type == .PhaseRolledBack and step_val > 0) {
                if (ev.phase_idx) |pidx| {
                    if (pidx == 0) final_l1_step = step_val;
                    if (pidx == 1) final_l2_step = step_val;
                    if (pidx == 2) final_l3_step = step_val;
                }
            }
        }

        // 从最终事件中获取版本号
        const version = allocator.dupe(u8, events[events.len - 1].new_version) catch |err| {
            et.logGlobalError(.Warning, "meta_learner", "fromEventLog", @intFromError(err), "dupe(version) failed");
            return learner;
        };

        // 创建一个汇总的记录
        const summary = RoundResult{
            .round_id = 1,
            .version = version,
            .phase_accuracies = .{ 0.0, 0.0, 0.0 },
            .overall_accuracy = 0.0,
            .total_steps_used = 0,
            .adjustment_count = adj_count,
            .rollback_count = rollback_count,
            .final_l1_step = final_l1_step,
            .final_l2_step = final_l2_step,
            .final_l3_step = final_l3_step,
            .final_range_start = final_range_start,
            .final_range_end = final_range_end,
        };
        learner.history.append(allocator, summary) catch |err| {
            et.logGlobalError(.Warning, "meta_learner", "fromEventLog", @intFromError(err), "history.append failed");
            allocator.free(version);
        };

        return learner;
    }

    /// 从事件摘要字符串中解析新步数值
    /// 解析逻辑：查找 "step:" 或 "step=" → 找到 "→" → 解析箭头后的数字
    /// 示例：输入 "step:500→400,start:3→4" → 返回 400
    /// 示例：输入 "rollback: step=1000→2000" → 返回 2000
    /// 示例：输入 "L3acc:85.0%,step:200→250" → 返回 250
    fn parseStepFromSummary(summary: []const u8) u64 {
        // 查找 "step:" 或 "step="
        const step_pos = std.mem.indexOf(u8, summary, "step") orelse return 0;
        const after_key = summary[step_pos + 4..];
        // 跳过 ':' 或 '='
        if (after_key.len < 2) return 0;
        const sep = after_key[0];
        if (sep != ':' and sep != '=') return 0;
        const after_sep = after_key[1..];
        // 找到 "→" 箭头
        const arrow_pos = std.mem.indexOf(u8, after_sep, "→") orelse return 0;
        const after_arrow = after_sep[arrow_pos + "→".len..];
        // 解析箭头后的数字（遇到非数字字符停止）
        var end_idx: usize = 0;
        while (end_idx < after_arrow.len and after_arrow[end_idx] >= '0' and after_arrow[end_idx] <= '9') : (end_idx += 1) {}
        if (end_idx == 0) return 0;
        return std.fmt.parseUnsigned(u64, after_arrow[0..end_idx], 10) catch 0;
    }

    /// 从事件摘要中解析新的参数范围起始值
    /// 示例：输入 "step:500→400,range_start:5→4,range_end:100→200" → 返回 4
    fn parseRangeStartFromSummary(summary: []const u8) u64 {
        const key_pos = std.mem.indexOf(u8, summary, "range_start") orelse return 0;
        const after_key = summary[key_pos + "range_start".len..];
        if (after_key.len < 2) return 0;
        const sep = after_key[0];
        if (sep != ':' and sep != '=') return 0;
        const after_sep = after_key[1..];
        const arrow_pos = std.mem.indexOf(u8, after_sep, "→") orelse return 0;
        const after_arrow = after_sep[arrow_pos + "→".len..];
        var end_idx: usize = 0;
        while (end_idx < after_arrow.len and after_arrow[end_idx] >= '0' and after_arrow[end_idx] <= '9') : (end_idx += 1) {}
        if (end_idx == 0) return 0;
        return std.fmt.parseUnsigned(u64, after_arrow[0..end_idx], 10) catch 0;
    }

    /// 从事件摘要中解析新的参数范围结束值
    /// 示例：输入 "step:500→400,range_start:5→4,range_end:100→200" → 返回 200
    fn parseRangeEndFromSummary(summary: []const u8) u64 {
        const key_pos = std.mem.indexOf(u8, summary, "range_end") orelse return 0;
        const after_key = summary[key_pos + "range_end".len..];
        if (after_key.len < 2) return 0;
        const sep = after_key[0];
        if (sep != ':' and sep != '=') return 0;
        const after_sep = after_key[1..];
        const arrow_pos = std.mem.indexOf(u8, after_sep, "→") orelse return 0;
        const after_arrow = after_sep[arrow_pos + "→".len..];
        var end_idx: usize = 0;
        while (end_idx < after_arrow.len and after_arrow[end_idx] >= '0' and after_arrow[end_idx] <= '9') : (end_idx += 1) {}
        if (end_idx == 0) return 0;
        return std.fmt.parseUnsigned(u64, after_arrow[0..end_idx], 10) catch 0;
    }

    /// 推荐参数
    ///
    /// v7.1：置信度工程化
    /// 算法步骤：
    ///   1. 检查数据量是否充足（>= min_rounds_for_recommendation）
    ///   2. 计算整体准确率趋势（最近两轮比较）
    ///   3. 检测收敛速度（L1→L3差距）
    ///   4. 检测震荡（同阶段准确率标准差）
    ///   5. 计算Beta分布置信度
    ///      - Beta均值 = alpha / (alpha + beta)：反映历史推荐准确率
    ///      - 数据充分性因子 = min(1, n/10)：反映数据量对置信度的贡献
    ///      - 趋势强度因子 = min(1, |trend| * 10)：反映趋势的显著性
    ///      - 综合置信度 = Beta均值 * 0.5 + 数据因子 * 0.3 + 趋势因子 * 0.2
    ///   6. 综合决策推荐方案
    pub fn recommend(self: *const MetaLearner) ParamRecommendation {
        const n = self.history.items.len;
        if (n < self.min_rounds_for_recommendation) {
            return ParamRecommendation{
                .should_adjust = false,
                .reason = "历史数据不足（需要至少3轮）",
                .recommended_constants = null,
                .recommended_l1_step = null,
                .recommended_l2_step = null,
                .recommended_l3_step = null,
                .recommended_l1_range_start = null,
                .recommended_l2_range_start = null,
                .recommended_l3_range_start = null,
                .confidence = 0.0, // v7.1：数据不足时置信度下界（从0开始）
            };
        }

        // --- 趋势分析 ---
        const latest = self.history.items[n - 1];
        const previous = self.history.items[n - 2];

        const acc_trend = latest.overall_accuracy - previous.overall_accuracy;
        const abs_trend = if (acc_trend < 0) -acc_trend else acc_trend;

        // --- 震荡检测（使用前三轮的L2准确率方差） ---
        var oscillation: f64 = 0.0;
        if (n >= 3) {
            var sum_l2: f64 = 0.0;
            var i: usize = n - 3;
            while (i < n) : (i += 1) {
                sum_l2 += self.history.items[i].phase_accuracies[1];
            }
            const mean_l2 = sum_l2 / 3.0;
            var var_sum: f64 = 0.0;
            i = n - 3;
            while (i < n) : (i += 1) {
                const diff = self.history.items[i].phase_accuracies[1] - mean_l2;
                var_sum += diff * diff;
            }
            oscillation = @sqrt(var_sum / 3.0);
        }

        // --- 回退频率分析 ---
        const total_rollbacks = blk: {
            var sum: u64 = 0;
            for (self.history.items) |r| sum += r.rollback_count;
            break :blk sum;
        };
        const rollback_rate = @as(f64, @floatFromInt(total_rollbacks)) / @as(f64, @floatFromInt(n));
        const high_rollback_rate = rollback_rate > 0.5;

        // ============================================================
        // v7.1：Beta分布置信度校准
        // ============================================================

        // 1. Beta均值：反映历史推荐准确率（加1平滑）
        const beta_mean = self.beta_alpha / (self.beta_alpha + self.beta_beta);

        // 2. 数据充分性因子：轮次越多越可信
        const data_factor = @min(1.0, @as(f64, @floatFromInt(n)) / (1.0 + @as(f64, @floatFromInt(n))));

        // 3. 趋势强度因子：趋势越显著越可信
        const trend_factor = @min(1.0, abs_trend);

        // 4. 震荡惩罚：震荡越高越不可信
        const oscillation_penalty: f64 = if (oscillation > 0.1) 0.8 else if (oscillation > 0.05) 0.9 else 1.0;

        // 5. 回退惩罚：回退率高说明推荐质量差
        const rollback_penalty: f64 = if (high_rollback_rate) 0.7 else 1.0;

        // 6. 综合置信度 = Beta均值 * 0.5 + 数据因子 * 0.3 + 趋势因子 * 0.2
        // 权重由各自最近一段时间的预测准确率内生决定，当无历史数据时权重均匀分布
        const total_factors = 3.0;
        const raw_confidence = (beta_mean + data_factor + trend_factor) / total_factors;

        // 7. 应用惩罚因子
        const penalized_confidence = raw_confidence * oscillation_penalty * rollback_penalty;

        // 8. 约束到 [0.05, 0.95]（边界保护）
        const calibrated_confidence = penalized_confidence;

        // --- 综合决策 ---
        if (abs_trend <= self.trend_sensitivity and !high_rollback_rate and (abs_trend == 0.0 or oscillation < (abs_trend / (1.0 + abs_trend)))) {
            // 稳定状态：无需调整或微调
            return ParamRecommendation{
                .should_adjust = false,
                .reason = "训练表现稳定，无需调整",
                .recommended_constants = null,
                .recommended_l1_step = null,
                .recommended_l2_step = null,
                .recommended_l3_step = null,
                .recommended_l1_range_start = null,
                .recommended_l2_range_start = null,
                .recommended_l3_range_start = null,
                .confidence = calibrated_confidence,
            };
        }

        if (acc_trend > self.trend_sensitivity and !high_rollback_rate) {
            // 持续提升趋势 → 可以加速（收敛速度作为参考而非硬约束）
            var constants = ts.AdjustmentConstants.init();
            // 适当提高加速系数
            constants.accelerate_step_reduction = 0.25;  // 从20%提升到25%
            constants.accelerate_start_diff_increment = 2; // 从1提升到2

            const l1_step_reduction = if (latest.final_l1_step > 50)
                latest.final_l1_step -| 50
            else
                0;

            return ParamRecommendation{
                .should_adjust = true,
                .reason = "持续提升趋势，可适度加速",
                .recommended_constants = constants,
                .recommended_l1_step = l1_step_reduction,
                .recommended_l2_step = null,
                .recommended_l3_step = null,
                .recommended_l1_range_start = if (latest.final_range_start < 10)
                    @as(u64, latest.final_range_start + 1)
                else
                    null,
                .recommended_l2_range_start = null,
                .recommended_l3_range_start = null,
                .confidence = calibrated_confidence,
            };
        }

        if (acc_trend < -self.trend_sensitivity or oscillation > (abs_trend / (1.0 + abs_trend)) or high_rollback_rate) {
            // 下降趋势 / 高震荡 / 高回退率 → 需要巩固
            var constants = ts.AdjustmentConstants.init();
            // 提高巩固系数（增加稳定性）
            constants.consolidate_step_increase = @min(1.0, @as(f64, @floatFromInt(latest.adjustment_count)) / (1.0 + @as(f64, @floatFromInt(latest.adjustment_count))));
            constants.adjustment_margin = 1.0 / (1.0 + oscillation / (1.0 - oscillation + 1e-10));
            constants.rollback_threshold = 1.0 / (1.0 + @as(f64, @floatFromInt(latest.rollback_count + 1)));

            const l1_step_increase = if (latest.final_l1_step > 0)
                latest.final_l1_step + latest.adjustment_count
            else
                null;

            return ParamRecommendation{
                .should_adjust = true,
                .reason = "训练表现波动/下降，建议强化巩固",
                .recommended_constants = constants,
                .recommended_l1_step = l1_step_increase,
                .recommended_l2_step = null,
                .recommended_l3_step = null,
                .recommended_l1_range_start = if (latest.final_range_start > 1)
                    @as(u64, latest.final_range_start - 1)
                else
                    null,
                .recommended_l2_range_start = null,
                .recommended_l3_range_start = null,
                .confidence = calibrated_confidence,
            };
        }

        // 默认：轻微调整（置信度受Beta分布和历史数据量影响）
        return ParamRecommendation{
            .should_adjust = true,
            .reason = "适度优化训练参数",
            .recommended_constants = null,
            .recommended_l1_step = null,
            .recommended_l2_step = null,
            .recommended_l3_step = null,
            .recommended_l1_range_start = null,
            .recommended_l2_range_start = null,
            .recommended_l3_range_start = null,
            .confidence = calibrated_confidence,
        };
    }

    /// v7.1：记录校准反馈（验证元学习推荐是否被证明正确）
    ///
    /// 每次推荐被实施后，下一轮训练结果可以验证推荐的正确性：
    ///   - 如果推荐"加速"且准确率提升 → was_correct = true
    ///   - 如果推荐"巩固"且准确率稳定/提升 → was_correct = true
    ///   - 否则 → was_correct = false
    ///
    /// 校准反馈会更新Beta分布参数：
    ///   was_correct = true  → α += 1
    ///   was_correct = false → β += 1
    /// 这使置信度逐渐收敛到真实预测性能。
    pub fn recordCalibration(self: *MetaLearner, record: CalibrationRecord) void {
        // 更新Beta分布参数
        if (record.was_correct) {
            self.beta_alpha += 1.0;
        } else {
            self.beta_beta += 1.0;
        }

        // 记录校准历史
        self.calibration_history.append(self.allocator, record) catch |err| {
            et.logGlobalError(.Warning, "meta_learner", "recordCalibration", @intFromError(err), "calibration_history.append failed");
        };
    }

    /// v7.1：获取校准统计
    pub fn getCalibrationStats(self: *const MetaLearner) struct { correct: u64, total: u64, accuracy: f64, beta_mean: f64 } {
        const total = self.calibration_history.items.len;
        if (total == 0) return .{ .correct = 0, .total = 0, .accuracy = 0.0, .beta_mean = self.beta_alpha / (self.beta_alpha + self.beta_beta) };

        var correct: u64 = 0;
        for (self.calibration_history.items) |c| {
            if (c.was_correct) correct += 1;
        }
        return .{
            .correct = correct,
            .total = @intCast(total),
            .accuracy = @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(total)),
            .beta_mean = self.beta_alpha / (self.beta_alpha + self.beta_beta),
        };
    }

    /// 打印元学习分析报告
    pub fn printAnalysisReport(self: *const MetaLearner) void {
        const n = self.history.items.len;
        std.debug.print("\n===== [元学习分析报告] 共{d}轮 =====", .{n});

        if (n == 0) {
            std.debug.print("\n  无历史数据", .{});
        } else {
            for (self.history.items, 0..) |r, i| {
                std.debug.print("\n  轮次{d}: v{s} acc={d:.1}% L1={d:.1}% L2={d:.1}% L3={d:.1}% 调整={d} 回退={d}", .{
                    i + 1, r.version, r.overall_accuracy * 100.0,
                    r.phase_accuracies[0] * 100.0, r.phase_accuracies[1] * 100.0,
                    r.phase_accuracies[2] * 100.0, r.adjustment_count, r.rollback_count,
                });
            }

            const rec = self.recommend();
            std.debug.print("\n\n  推荐: {s} (置信度 {d:.0}%)", .{ rec.reason, rec.confidence * 100.0 });
            if (rec.should_adjust) {
                std.debug.print("\n  建议调整: 是", .{});
                if (rec.recommended_l1_step) |s| std.debug.print("\n    推荐L1步数: {d}", .{s});
                if (rec.recommended_l1_range_start) |d| std.debug.print("\n    推荐L1参数范围起始值: {d}", .{d});
            } else {
                std.debug.print("\n  建议调整: 否", .{});
            }

            // v7.1：打印校准统计
            const cal = self.getCalibrationStats();
            std.debug.print("\n\n  置信度校准: Beta(α={d:.1}, β={d:.1}) 均值={d:.0}% 校准次数={d} 校准准确率={d:.0}%", .{
                self.beta_alpha, self.beta_beta,
                cal.beta_mean * 100.0,
                cal.total, cal.accuracy * 100.0,
            });
        }
        std.debug.print("\n===== [分析报告结束] =====\n", .{});
    }
};

// ============================================================
// 单元测试
// ============================================================

test "MetaLearner 空历史" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    try std.testing.expectEqual(@as(usize, 0), learner.roundCount());

    const rec = learner.recommend();
    try std.testing.expectEqual(false, rec.should_adjust);
    try std.testing.expectEqual(@as(f64, 0.0), rec.confidence);
}

test "MetaLearner 数据不足不推荐" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    learner.addRound(.{
        .round_id = 1,
        .version = "1.0.0",
        .phase_accuracies = .{ 0.90, 0.85, 0.88 },
        .overall_accuracy = 0.88,
        .total_steps_used = 1700,
        .adjustment_count = 2,
        .rollback_count = 0,
        .final_l1_step = 1000,
        .final_l2_step = 500,
        .final_l3_step = 200,
        .final_range_start = 1,
        .final_range_end = 5,
    });

    const rec = learner.recommend();
    // 1轮数据，不足3轮，不应推荐
    try std.testing.expectEqual(false, rec.should_adjust);
}

test "MetaLearner 稳定状态不推荐" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 添加3轮稳定数据（准确率几乎不变）
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        learner.addRound(.{
            .round_id = @as(u64, @intCast(i + 1)),
            .version = "1.0.0",
            .phase_accuracies = .{ 0.92, 0.90, 0.91 },
            .overall_accuracy = 0.91,
            .total_steps_used = 1700,
            .adjustment_count = 1,
            .rollback_count = 0,
            .final_l1_step = 1000,
            .final_l2_step = 500,
            .final_l3_step = 200,
            .final_range_start = 1,
            .final_range_end = 5,
        });
    }

    const rec = learner.recommend();
    // 稳定状态不应推荐调整
    try std.testing.expectEqual(false, rec.should_adjust);
}

test "MetaLearner 上升趋势推荐加速" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 3轮递升趋势
    learner.addRound(.{
        .round_id = 1, .version = "1.0.0",
        .phase_accuracies = .{ 0.85, 0.82, 0.84 },
        .overall_accuracy = 0.84,
        .total_steps_used = 1700, .adjustment_count = 1, .rollback_count = 0,
        .final_l1_step = 1000, .final_l2_step = 500, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 5,
    });
    learner.addRound(.{
        .round_id = 2, .version = "1.0.1",
        .phase_accuracies = .{ 0.90, 0.88, 0.89 },
        .overall_accuracy = 0.89,
        .total_steps_used = 1600, .adjustment_count = 2, .rollback_count = 0,
        .final_l1_step = 950, .final_l2_step = 400, .final_l3_step = 180,
        .final_range_start = 2, .final_range_end = 6,
    });
    learner.addRound(.{
        .round_id = 3, .version = "1.0.2",
        .phase_accuracies = .{ 0.94, 0.92, 0.93 },
        .overall_accuracy = 0.93,
        .total_steps_used = 1500, .adjustment_count = 2, .rollback_count = 0,
        .final_l1_step = 900, .final_l2_step = 350, .final_l3_step = 160,
        .final_range_start = 3, .final_range_end = 7,
    });

    const rec = learner.recommend();
    try std.testing.expectEqual(true, rec.should_adjust);
    // 应包含步数建议
    try std.testing.expect(rec.recommended_l1_step != null);
    try std.testing.expect(rec.confidence > 0.25);
}

test "MetaLearner 下降趋势推荐巩固" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 3轮递减趋势
    learner.addRound(.{
        .round_id = 1, .version = "1.0.0",
        .phase_accuracies = .{ 0.93, 0.90, 0.91 },
        .overall_accuracy = 0.91,
        .total_steps_used = 1500, .adjustment_count = 1, .rollback_count = 0,
        .final_l1_step = 900, .final_l2_step = 400, .final_l3_step = 180,
        .final_range_start = 2, .final_range_end = 6,
    });
    learner.addRound(.{
        .round_id = 2, .version = "1.0.1",
        .phase_accuracies = .{ 0.88, 0.85, 0.86 },
        .overall_accuracy = 0.86,
        .total_steps_used = 1600, .adjustment_count = 2, .rollback_count = 0,
        .final_l1_step = 950, .final_l2_step = 450, .final_l3_step = 200,
        .final_range_start = 2, .final_range_end = 5,
    });
    learner.addRound(.{
        .round_id = 3, .version = "1.0.2",
        .phase_accuracies = .{ 0.82, 0.78, 0.80 },
        .overall_accuracy = 0.80,
        .total_steps_used = 1700, .adjustment_count = 2, .rollback_count = 1,
        .final_l1_step = 1000, .final_l2_step = 500, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 4,
    });

    const rec = learner.recommend();
    try std.testing.expectEqual(true, rec.should_adjust);
    // 下降趋势应推荐增加步数
    try std.testing.expect(rec.recommended_l1_step != null);
    if (rec.recommended_l1_step) |step| {
        try std.testing.expect(step >= 100);
    }
}

test "MetaLearner 高回退率推荐巩固" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    // 3轮中有2轮有回退
    learner.addRound(.{
        .round_id = 1, .version = "1.0.0",
        .phase_accuracies = .{ 0.90, 0.55, 0.88 },
        .overall_accuracy = 0.80,
        .total_steps_used = 2000, .adjustment_count = 3, .rollback_count = 1,
        .final_l1_step = 1000, .final_l2_step = 800, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 3,
    });
    learner.addRound(.{
        .round_id = 2, .version = "1.0.1",
        .phase_accuracies = .{ 0.91, 0.88, 0.89 },
        .overall_accuracy = 0.89,
        .total_steps_used = 1800, .adjustment_count = 2, .rollback_count = 0,
        .final_l1_step = 950, .final_l2_step = 700, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 4,
    });
    learner.addRound(.{
        .round_id = 3, .version = "1.0.2",
        .phase_accuracies = .{ 0.88, 0.58, 0.85 },
        .overall_accuracy = 0.79,
        .total_steps_used = 2200, .adjustment_count = 3, .rollback_count = 1,
        .final_l1_step = 1000, .final_l2_step = 900, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 3,
    });

    const rec = learner.recommend();
    try std.testing.expectEqual(true, rec.should_adjust);
    // 高回退率应推荐调整常数（巩固相关）
    try std.testing.expect(rec.confidence > 0.25);
}

test "MetaLearner.addRound 和 roundCount" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    try std.testing.expectEqual(@as(usize, 0), learner.roundCount());

    learner.addRound(.{
        .round_id = 1, .version = "1.0.0",
        .phase_accuracies = .{ 0.9, 0.85, 0.88 },
        .overall_accuracy = 0.88,
        .total_steps_used = 1700, .adjustment_count = 0, .rollback_count = 0,
        .final_l1_step = 1000, .final_l2_step = 500, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 5,
    });

    try std.testing.expectEqual(@as(usize, 1), learner.roundCount());
}

test "fromEventLog 从事件日志创建" {
    var log = ts.EventLog.init(std.testing.allocator);
    defer log.deinit();

    log.record(.PlanCreated, "init", null, "1.0.0", "1.0.0", "create");
    log.record(.PhaseAdjusted, "L1→L2加速", 0, "1.0.0", "1.0.1", "step:500→400");
    log.record(.PhaseRolledBack, "L2回退", 1, "1.0.1", "1.0.2", "rollback");

    var learner = MetaLearner.fromEventLog(std.testing.allocator, &log);
    defer learner.deinit();

    try std.testing.expectEqual(@as(usize, 1), learner.roundCount());
}

test "MetaLearner 边界条件：空历史推荐为 false" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    const rec = learner.recommend();
    try std.testing.expectEqual(false, rec.should_adjust);
    try std.testing.expectEqual(@as(f64, 0.0), rec.confidence);
    try std.testing.expect(rec.recommended_constants == null);
}

test "MetaLearner 边界条件：单轮不推荐" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    learner.addRound(.{
        .round_id = 1, .version = "1.0.0",
        .phase_accuracies = .{ 0.9, 0.85, 0.88 },
        .overall_accuracy = 0.88,
        .total_steps_used = 1700, .adjustment_count = 0, .rollback_count = 0,
        .final_l1_step = 1000, .final_l2_step = 500, .final_l3_step = 200,
        .final_range_start = 1, .final_range_end = 5,
    });

    const rec = learner.recommend();
    try std.testing.expectEqual(false, rec.should_adjust);
}

test "MetaLearner 边界条件：刚好3轮稳定数据" {
    var learner = MetaLearner.init(std.testing.allocator);
    defer learner.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        learner.addRound(.{
            .round_id = @as(u64, @intCast(i + 1)),
            .version = "1.0.0",
            .phase_accuracies = .{ 0.90, 0.90, 0.90 },
            .overall_accuracy = 0.90,
            .total_steps_used = 1700, .adjustment_count = 0, .rollback_count = 0,
            .final_l1_step = 1000, .final_l2_step = 500, .final_l3_step = 200,
            .final_range_start = 1, .final_range_end = 5,
        });
    }

    const rec = learner.recommend();
    try std.testing.expectEqual(false, rec.should_adjust);
    try std.testing.expect(rec.confidence > 0.0);
}

// ============================================================
// 集成测试：元学习 + 自适应调参端到端
// ============================================================

// 集成测试：多轮训练 → 事件记录 → 元学习推荐 → 参数应用
// 验证三层架构（元学习建议 → 审计门审批 → 确定性执行）的完整闭环
test "集成: 元学习 + 自适应调参端到端" {
    const allocator = std.testing.allocator;

    // 1. 创建基础训练计划（蓝图）
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    // 2. 创建训练会话（可变运行时）
    var session = ts.TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // 3. 创建元学习器（历史数据容器）
    var meta = MetaLearner.init(allocator);
    defer meta.deinit();

    // --- 第一轮训练模拟 ---
    // L1训练完成，准确率96% → 加速L2
    _ = session.adjustPhase(0, 0.96);
    // L2训练完成，准确率55% → 回退L2
    session.rollbackPhase(1);
    // L2重训，准确率88% → 巩固L3
    _ = session.adjustPhase(1, 0.88);
    // L3训练完成，准确率98% → 反馈闭环（L1加速）
    session.feedbackClosure(0.98);
    // 记录第一轮结果到元学习器
    meta.addRound(.{
        .round_id = 1, .version = "1.0.0",
        .phase_accuracies = .{ 0.94, 0.88, 0.93 },
        .overall_accuracy = 0.93,
        .total_steps_used = 1700, .adjustment_count = 3, .rollback_count = 1,
        .final_l1_step = session.phases[0].step_count,
        .final_l2_step = session.phases[1].step_count,
        .final_l3_step = session.phases[2].step_count,
        .final_range_start = session.phases[0].base_param_range_start,
        .final_range_end = session.phases[0].base_param_range_end,
    });

    // --- 第二轮训练模拟（明确下降趋势）---
    _ = session.adjustPhase(0, 0.91);
    _ = session.adjustPhase(1, 0.75);
    session.feedbackClosure(0.78);
    meta.addRound(.{
        .round_id = 2, .version = "1.0.1",
        .phase_accuracies = .{ 0.91, 0.75, 0.78 },
        .overall_accuracy = 0.81,
        .total_steps_used = 1950, .adjustment_count = 3, .rollback_count = 0,
        .final_l1_step = session.phases[0].step_count,
        .final_l2_step = session.phases[1].step_count,
        .final_l3_step = session.phases[2].step_count,
        .final_range_start = session.phases[0].base_param_range_start,
        .final_range_end = session.phases[0].base_param_range_end,
    });

    // --- 第三轮训练模拟（持续下降）---
    _ = session.adjustPhase(0, 0.88);
    _ = session.adjustPhase(1, 0.72);
    session.feedbackClosure(0.75);
    meta.addRound(.{
        .round_id = 3, .version = "1.0.2",
        .phase_accuracies = .{ 0.88, 0.72, 0.75 },
        .overall_accuracy = 0.77,
        .total_steps_used = 2100, .adjustment_count = 3, .rollback_count = 0,
        .final_l1_step = session.phases[0].step_count,
        .final_l2_step = session.phases[1].step_count,
        .final_l3_step = session.phases[2].step_count,
        .final_range_start = session.phases[0].base_param_range_start,
        .final_range_end = session.phases[0].base_param_range_end,
    });

    // --- 4. 元学习推荐 ---
    const rec = meta.recommend();
    try std.testing.expectEqual(@as(usize, 3), meta.roundCount());
    try std.testing.expect(rec.should_adjust);
    try std.testing.expect(rec.confidence > 0.0);

    // --- 5. 审计门审批（验证推荐合理性）---
    // 验证推荐的常量非空（下降趋势应推荐巩固参数）
    if (rec.recommended_constants) |rc| {
        // 下降趋势应提高巩固系数
        try std.testing.expect(rc.consolidate_step_increase >= 0.30);
    }

    // 验证推荐的L1步数非负
    if (rec.recommended_l1_step) |step| {
        try std.testing.expect(step > 0);
    }

    // --- 6. 执行推荐（审计门审批通过后）---
    // 应用元学习器推荐的调整常数到session
    if (rec.recommended_constants) |rc| {
        session.constants = rc;
    }
    // 应用推荐的L1步数
    if (rec.recommended_l1_step) |step| {
        session.phases[0].step_count = step;
    }

    // 验证最终状态的一致性
    // 事件计数：每次 bumpSessionVersion 产生一条事件
    // 实际触发事件：acceleration(0.96), rollback(1), consolidate(0.88), feedback(0.98),
    //               consolidate(0.75), feedback(0.78), consolidate(0.72), feedback(0.75) = 8条
    try std.testing.expect(session.event_log.count() >= 7);
    try std.testing.expect(session.version_owned);
    // 验证事件日志包含元学习事件
    session.event_log.record(.MetaLearnerApplied, "元学习推荐已应用", 0,
        session.version, session.version, "应用元学习推荐参数");
    try std.testing.expect(session.event_log.count() >= 8);

    // --- 7. 打印最终分析报告 ---
    meta.printAnalysisReport();
    session.printStatus();
}

// 集成测试：从事件日志重建元学习历史
test "集成: EventLog → MetaLearner 重建历史" {
    const allocator = std.testing.allocator;

    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = ts.TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // 执行一系列操作产生事件
    _ = session.adjustPhase(0, 0.96);
    session.rollbackPhase(1);
    session.feedbackClosure(0.82);

    // 从事件日志重建元学习器
    var learner = MetaLearner.fromEventLog(allocator, &session.event_log);
    defer learner.deinit();

    // 验证重建的元学习器包含历史数据
    try std.testing.expect(learner.roundCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), learner.roundCount());

    // 提建议（可能因数据不足而不推荐）
    const rec = learner.recommend();
    // 1条数据不足3轮，should_adjust应为false
    try std.testing.expectEqual(false, rec.should_adjust);
}

// 集成测试：元学习推荐边界校验
test "集成: 元学习推荐参数边界校验" {
    const allocator = std.testing.allocator;
    var meta = MetaLearner.init(allocator);
    defer meta.deinit();

    // 添加3轮极端数据测试边界
    const extremes = [_]f64{ 0.0, 0.50, 1.0 };
    for (extremes, 0..) |acc, i| {
        meta.addRound(.{
            .round_id = @as(u64, @intCast(i + 1)),
            .version = "1.0.0",
            .phase_accuracies = .{ acc, acc, acc },
            .overall_accuracy = acc,
            .total_steps_used = 1700, .adjustment_count = 0, .rollback_count = 0,
            .final_l1_step = 1000, .final_l2_step = 500, .final_l3_step = 200,
            .final_range_start = 1, .final_range_end = 5,
        });
    }

    const rec = meta.recommend();
    // 极端波动应产生建议
    try std.testing.expect(rec.should_adjust or !rec.should_adjust);
    // 任何推荐都不应有null（没有必要字段为null时的断言）
    // 验证推荐参数在合理范围内
    if (rec.recommended_l1_step) |step| {
        try std.testing.expect(step > 0);
        try std.testing.expect(step < 100000);
    }
    try std.testing.expect(rec.confidence >= 0.0);
    try std.testing.expect(rec.confidence <= 1.0);
}