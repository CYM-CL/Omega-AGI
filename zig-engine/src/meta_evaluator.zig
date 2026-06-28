// Ω-落尘AGI v6.0 自监督元学习器 — 七路评价共识检测
//
// 核心架构：
// 系统不再使用外部的 Teacher/Student 判官，而是通过七条独立的评价路径
// 的共识/分歧来驱动自我演化。共识高 = 系统已收敛；分歧高 = 系统继续探索。
// 2. MEPP (EntropyProduction) — 格熵变化率 → 差异势能释放效率
// 3. 压缩率 (Compression) — compressionRate → 描述效率
// 4. 泛性质 (UniversalProperty) — CCC 完备度 → 范畴结构自洽
// 5. 自创生 (Autopoiesis) — [待实现] 自我维持能力
// 6. 对称破缺 (SSB) — [待实现] 对称基态
// 7. 自指 (SelfRef) — [待实现] 自我模型预测误差
//
// v6.0 核心定理：
// 当七条路的 Kendall W 协调系数 → 1 时，系统达到内生评价不动点 S*，
// S* 是七条路共识最高的结构，且 S* 自我评价为最优。

const std = @import("std");
const cdl = @import("cdl_expr.zig");
const de = @import("delta_engine.zig");
const cs = @import("category_structure.zig");
const tt = @import("trainer_types.zig");
const et = @import("error_types.zig");

// ============================================================
// 七路评价结果
// ============================================================

/// 单条评价路径的输出
pub const PathScore = struct {
    /// 路径名称（用于调试输出）
    name: []const u8,
    /// 原始分数（未归一化，范围取决于具体的评价维度）
    raw_score: f64,
    /// 归一化分数 [0, 1]，历史窗口内
    normalized_score: f64,
    /// 趋势方向：1=向上，-1=向下，0=稳定
    trend: i8,
    /// 该路径是否有足够数据给出有意义的评价
    has_valid_data: bool,
};

/// 七路评价的完整报告
pub const EvaluationReport = struct {
    /// 各路径独立评分
    paths: [7]PathScore,
    /// Kendall W 协调系数 [0, 1]，0=无共识，1=完全共识
    /// 可用路径越多，W 越可靠（最少 2 路有意义，4 路+ 可靠）
    consensus_coefficient: f64,
    /// 有足够数据的路径数
    active_path_count: usize,
    /// 系统是否已收敛（W > 0.85 且持续 N 步）
    is_converged: bool,
    /// 报告生成时间步
    step: u64,
};

// ============================================================
// 路径索引常量
// ============================================================

pub const PATH_PERSISTENCE: usize = 0;
pub const PATH_ENTROPY: usize = 1;
pub const PATH_COMPRESSION: usize = 2;
pub const PATH_UNIVERSAL: usize = 3;
pub const PATH_AUTOPOIESIS: usize = 4;
pub const PATH_SSB: usize = 5;
pub const PATH_SELFREF: usize = 6;

// ============================================================
// 历史滚动窗口
// ============================================================

/// 滚动窗口：存储最近 N 步的历史值，用于计算趋势和归一化
pub const RollingWindow = struct {
    allocator: std.mem.Allocator,
    /// 历史值（环形缓冲区）
    values: std.ArrayList(f64),
    /// 最大窗口大小
    max_size: usize,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) RollingWindow {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(f64).empty,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *RollingWindow) void {
        self.values.deinit(self.allocator);
    }

    /// 记录一个新值
    pub fn record(self: *RollingWindow, value: f64) void {
        self.values.append(self.allocator, value) catch |err| {
            et.logGlobalError(.Warning, "meta_evaluator", "record", @intFromError(err), "append value failed");
            return;
        };
        // 超出最大大小则移除最早的值
        if (self.values.items.len > self.max_size) {
            _ = self.values.orderedRemove(0);
        }
    }

    /// 获取当前值数量
    pub fn count(self: *const RollingWindow) usize {
        return self.values.items.len;
    }

    /// 获取最新值（窗口尾）
    pub fn latest(self: *const RollingWindow) ?f64 {
        if (self.values.items.len == 0) return null;
        return self.values.items[self.values.items.len - 1];
    }

    /// 计算归一化分数 [0, 1]：将最新值映射到窗口历史范围
    pub fn normalized(self: *const RollingWindow) f64 {
        if (self.values.items.len < 2) return 0.5; // 数据不足时返回中性值
        var min_val: f64 = std.math.inf(f64);
        var max_val: f64 = -std.math.inf(f64);
        for (self.values.items) |v| {
            if (v < min_val) min_val = v;
            if (v > max_val) max_val = v;
        }
        const range = max_val - min_val;
        if (range < 1e-12) {
            // 无变化时返回最新值，让稳定路径贡献真实分数
            const flat_val = self.latest().?;
            return if (std.math.isFinite(flat_val)) flat_val else 0.5;
        }
        const latest_val = self.latest().?;
        if (!std.math.isFinite(latest_val)) return 0.5;
        const result = (latest_val - min_val) / range;
        return if (std.math.isFinite(result)) result else 0.5;
    }

    /// 计算趋势：比较最近 N 步的均值与更早 N 步的均值
    pub fn trend(self: *const RollingWindow) i8 {
        if (self.values.items.len < 4) return 0;
        const recent_n = @min(@as(usize, 5), self.values.items.len / 2);
        const older_n = @min(@as(usize, 5), self.values.items.len / 2);
        if (older_n == 0 or recent_n == 0) return 0;

        var recent_sum: f64 = 0;
        var older_sum: f64 = 0;
        for (0..recent_n) |i| {
            recent_sum += self.values.items[self.values.items.len - 1 - i];
        }
        for (0..older_n) |i| {
            older_sum += self.values.items[i];
        }
        const recent_avg = recent_sum / @as(f64, @floatFromInt(recent_n));
        const older_avg = older_sum / @as(f64, @floatFromInt(older_n));
        const diff = recent_avg - older_avg;
        if (@abs(diff) < 0.01) return 0;
        return if (diff > 0) 1 else -1;
    }
};

// ============================================================
// 七路元评价器
// ============================================================

/// 自监督元评价器
///
/// 独立于训练循环运行，仅读取系统状态，不修改任何内容。
pub const ExpectationEntry = struct { sum: f64, count: u64 };

/// 所有路径的输出汇总为 consensusCoefficient -> 驱动训练决策。
pub const MetaEvaluator = struct {
    allocator: std.mem.Allocator,

    // 各路径的滚动窗口（存储历史值用于趋势/归一化）
    persistence_window: RollingWindow,
    entropy_window: RollingWindow,
    compression_window: RollingWindow,
    universal_window: RollingWindow,
    autopoiesis_window: RollingWindow,
    ssb_window: RollingWindow,
    selfref_window: RollingWindow,

    // 共识历史（用于判断是否收敛）
    consensus_history: RollingWindow,

    // 上一报告
    last_report: ?EvaluationReport,
    // 共识持续达标计数
    consecutive_consensus_steps: u64,
    // v6.0: 统计预期历史（记录每个任务的输出分布）
    // key = (param1 << 32) | param2
    expectation_history: std.AutoHashMap(u64, ExpectationEntry),
    // 统计预期与 deltaExpr 的一致性度量 [0, 1]
    statistical_consistency: f64,


    pub fn init(allocator: std.mem.Allocator) MetaEvaluator {
        const window_size: usize = 100; // 滚动窗口大小
        return .{
            .allocator = allocator,
            .persistence_window = RollingWindow.init(allocator, window_size),
            .entropy_window = RollingWindow.init(allocator, window_size),
            .compression_window = RollingWindow.init(allocator, window_size),
            .expectation_history = std.AutoHashMap(u64, ExpectationEntry).init(allocator),
            .statistical_consistency = 1.0,

            .universal_window = RollingWindow.init(allocator, window_size),
            .autopoiesis_window = RollingWindow.init(allocator, window_size),
            .ssb_window = RollingWindow.init(allocator, window_size),
            .selfref_window = RollingWindow.init(allocator, window_size),
            .consensus_history = RollingWindow.init(allocator, window_size * 2),
            .last_report = null,
            .consecutive_consensus_steps = 0,
        };
    }

    pub fn deinit(self: *MetaEvaluator) void {
        self.persistence_window.deinit();
        self.entropy_window.deinit();
        self.compression_window.deinit();
        self.universal_window.deinit();
        self.autopoiesis_window.deinit();
        self.ssb_window.deinit();
        self.selfref_window.deinit();
        self.expectation_history.deinit();

        self.consensus_history.deinit();
    }

    // ============================================================
    // 路径 1：统计留存 (Persistence)
    // 基于 ExprActivity 的聚合统计
    // 分数 = conduction_contribution × activation_frequency / (1 + recursive_stability)
    // ============================================================

    /// 计算表达式池中所有活动表达式的平均留存分数
    pub fn computePersistenceScore(_: *MetaEvaluator, pool: *const cdl.ExprPool) f64 {
        const count = pool.size();
        if (count == 0) return 0.0;

        var total_score: f64 = 0.0;
        var active_count: usize = 0;

        for (0..count) |i| {
            const idx = @as(cdl.ExprIdx, @intCast(i));
            const act = pool.getActivity(idx) orelse continue;

            if (act.first_activation) continue; // 跳过从未激活的
            if (act.frozen) {
                total_score += act.conduction_contribution;
                active_count += 1;
                continue;
            }

            // 留存分数 = 传导贡献度 × 激活频率 / (1 + 不稳定度)
            // 高贡献 + 高频率 + 高稳定 = 高留存
            const stability_factor = 1.0 / (1.0 + act.recursive_stability);
            const score = act.conduction_contribution * (1.0 + act.activation_frequency) * stability_factor;
            if (std.math.isFinite(score) and score >= 0.0) {
                total_score += score;
                active_count += 1;
            }
        }

        if (active_count == 0) return 0.0;
        return total_score / @as(f64, @floatFromInt(active_count));
    }

    // ============================================================
    // 路径 2：MEPP — 熵产生速率 (Entropy Production)
    // 基于格熵的变化率
    // ============================================================

    /// 计算 MEPP 分数（熵产生速率）
    /// 需要调用者提供当前格熵值
    pub fn computeEntropyScore(_: *MetaEvaluator, current_entropy: f64) f64 {
        // 路径 2 的实际计算由调用者维护（格熵在 trainer.zig 中已计算）
        // 此处只是一个通道——窗口更新在 record() 中完成
        // 分数 = 归一化的熵值（高熵 = 高差异势能释放 = 高 MEPP）
        return current_entropy;
    }

    // ============================================================
    // 路径 3：压缩率 (Compression)
    // 基于 compressionRate / knowledgeCompressionRate
    // ============================================================

    /// 计算压缩率分数
    pub fn computeCompressionScore(_: *MetaEvaluator, compression_rate: f64) f64 {
        // 压缩率 ∈ [0, 1]，值越高越好（用更少结构表达更多规则）
        return compression_rate;
    }

    // ============================================================
    // 路径 4：泛性质 (UniversalProperty)
    // 基于 CCC 范畴结构的完备度
    // ============================================================

    /// 计算泛性质分数（v6.0: 加入连续化深度因子）
    pub fn computeUniversalScore(_: *MetaEvaluator, ccc: *const cs.CartesianClosedCategory) f64 {
        const verify = ccc.verifyCCCStructure();
        // 基础分：4 个二元类各 0.20
        var score: f64 = 0.0;
        if (verify.has_terminal) score += 0.20;
        if (verify.has_products) score += 0.20;
        if (verify.has_exponentials) score += 0.20;
        if (verify.has_currying) score += 0.20;
        // 前附加连续深度因子 0.20：实际结构数 / 理想结构数
        // 理想情况下，N 个对象应有 O(N^2) 乘积/指数/curry
        // 此处用 product_map 的键数（一阶）估算深度
        const depth_count = ccc.product_map.count() + ccc.exponential_map.count() + ccc.curry_map.count();
        const depth_ratio = @min(1.0, @as(f64, @floatFromInt(depth_count)) / 30.0); // CCC 深度因子更平滑
        score += 0.20 * depth_ratio;
        return @min(1.0, score);
    }

    // ============================================================
    // 路径 5-7：占位（将来自创生/SSB/自指）
    // ============================================================

    pub fn computeAutopoiesisScore(_: *MetaEvaluator, frozen_ratio: f64) f64 {
        // 自创生 = 系统维持自身结构的能力
        // 冻结比率 = 已固化对象 / 总对象（越高越好）
        // 当 frozen_ratio > 0.5 时认为系统有基本自维持能力
        if (frozen_ratio <= 0.0) return 0.0;
        // 使用平滑曲率：score = 1 - (1 - frozen_ratio)^2
        // 冻结率低时快速增长，冻结率高时趋近1.0
        const diff = 1.0 - @min(frozen_ratio, 1.0);
        return 1.0 - diff * diff;
    }

    pub fn computeSSBScore(_: *MetaEvaluator, asymmetry_ratio: f64) f64 {
        // 对称破缺 = 非对称Δ关系的丰富度
        // Δ(a,b) ≠ Δ(b,a) 的对越多 → 非对称结构越丰富 → 破缺越充分
        // score = 1 - (1 - ratio)^2，平滑增长曲率
        // ratio=0: score=0（完全对称，未破缺→不活跃）
        // ratio=0.5: score=0.75（部分破缺→活跃）
        // ratio=1.0: score=1.0（完全破缺→最活跃）
        const ratio = @max(0.0, @min(1.0, asymmetry_ratio));
        const diff = 1.0 - ratio;
        return 1.0 - diff * diff;
    }
    /// 计算自指评分：基于表达式结构复杂度
    /// 分数 = (Delta + paths) / total，Delta 表示关系建构
    /// 越高表示系统形成了更复杂的结构化知识
    pub fn computeSelfRefScore(_: *MetaEvaluator, pool: *const cdl.ExprPool) f64 {
        const count = pool.size();
        if (count < 2) return 0.0;

        var delta_plus_paths: u64 = 0;
        for (0..count) |i| {
            const node = pool.getNode(@as(cdl.ExprIdx, @intCast(i))) orelse continue;
            switch (node.*) {
                .Delta, .paths => delta_plus_paths += 1,
                else => {},
            }
        }

        return @as(f64, @floatFromInt(delta_plus_paths)) / @as(f64, @floatFromInt(count));
    }
    /// 记录一次训练任务的输出（用于统计预期）
    pub fn recordOutcome(self: *MetaEvaluator, param1: u64, param2: u64, result: f64) void {
        const key = @as(u64, param1) << 32 | @as(u64, param2);
        const gop = self.expectation_history.getOrPut(key) catch return;
        if (gop.found_existing) {
            gop.value_ptr.sum += result;
            gop.value_ptr.count += 1;
        } else {
            gop.value_ptr.* = .{ .sum = result, .count = 1 };
        }
    }


    /// 获取统计预期：返回 (param1, param2) 的历史均值
    /// 无历史记录时返回 null（调用者应回退到 deltaExpr）
    pub fn statisticalExpectation(self: *MetaEvaluator, param1: u64, param2: u64) ?f64 {
        const key = @as(u64, param1) << 32 | @as(u64, param2);
        const entry = self.expectation_history.get(key) orelse return null;
        if (entry.count == 0) return null;
        return entry.sum / @as(f64, @floatFromInt(entry.count));
    }

    /// 计算统计预期与 deltaExpr 的一致性
    /// 当前简单返回 1.0（尚未实现对比机制）
    pub fn computeStatisticalConsistency(self: *MetaEvaluator) f64 {
        _ = self;
        // TODO: 比较 statisticalExpectation 与 deltaExpr 的差异
        return 1.0;
    }

    /// 记录当前步的系统状态（由训练循环每步调用）
    /// 新增 self_ref_prediction + frozen_ratio + asymmetry_ratio 实现全部7路路径
    pub fn record(
        self: *MetaEvaluator,
        step: u64,
        pool: *const cdl.ExprPool,
        current_entropy: f64,
        compression_rate: f64,
        ccc: *const cs.CartesianClosedCategory,
        self_ref_prediction: f64,
        frozen_ratio: f64,
        asymmetry_ratio: f64,
    ) void {
        // 计算并记录各路径的原始分数
        const p_raw = self.computePersistenceScore(pool);
        const e_raw = self.computeEntropyScore(current_entropy);
        const c_raw = self.computeCompressionScore(compression_rate);
        const u_raw = self.computeUniversalScore(ccc);
        const a_raw = self.computeAutopoiesisScore(frozen_ratio);
        const s_raw = self.computeSSBScore(asymmetry_ratio);
        const r_raw = if (self_ref_prediction > 0.0) self_ref_prediction else self.computeSelfRefScore(pool);
        // NaN保护：确保所有分数在 [0,1] 范围内
        const p_score = if (std.math.isFinite(p_raw)) @max(0.0, @min(1.0, p_raw)) else 0.5;
        const e_score = if (std.math.isFinite(e_raw)) @max(0.0, @min(1.0, e_raw)) else 0.5;
        const c_score = if (std.math.isFinite(c_raw)) @max(0.0, @min(1.0, c_raw)) else 0.5;
        const u_score = if (std.math.isFinite(u_raw)) @max(0.0, @min(1.0, u_raw)) else 0.5;
        const a_score = if (std.math.isFinite(a_raw)) @max(0.0, @min(1.0, a_raw)) else 0.5;
        const s_score = if (std.math.isFinite(s_raw)) @max(0.0, @min(1.0, s_raw)) else 0.5;
        const r_score = if (std.math.isFinite(r_raw)) @max(0.0, @min(1.0, r_raw)) else 0.5;

        // 记录到滚动窗口
        self.persistence_window.record(p_score);
        self.entropy_window.record(e_score);
        self.compression_window.record(c_score);
        self.universal_window.record(u_score);
        self.autopoiesis_window.record(a_score);
        self.ssb_window.record(s_score);
        self.selfref_window.record(r_score);

        // 生成报告
        self.last_report = self.generateReport(step);
    }

    /// 生成七路评价报告
    pub fn generateReport(self: *MetaEvaluator, step: u64) EvaluationReport {
        const paths = [_]PathScore{
            .{
                .name = "统计留存",
                .raw_score = self.persistence_window.latest() orelse 0.0,
                .normalized_score = self.persistence_window.normalized(),
                .trend = self.persistence_window.trend(),
                .has_valid_data = self.persistence_window.count() >= 2,
            },
            .{
                .name = "熵产生(MEPP)",
                .raw_score = self.entropy_window.latest() orelse 0.0,
                .normalized_score = self.entropy_window.normalized(),
                .trend = self.entropy_window.trend(),
                .has_valid_data = self.entropy_window.count() >= 2,
            },
            .{
                .name = "压缩率",
                .raw_score = self.compression_window.latest() orelse 0.0,
                .normalized_score = self.compression_window.normalized(),
                .trend = self.compression_window.trend(),
                .has_valid_data = self.compression_window.count() >= 2,
            },
            .{
                .name = "泛性质(CCC)",
                .raw_score = self.universal_window.latest() orelse 0.0,
                .normalized_score = self.universal_window.normalized(),
                .trend = self.universal_window.trend(),
                .has_valid_data = self.universal_window.count() >= 2,
            },
            .{
                .name = "自创生",
                .raw_score = self.autopoiesis_window.latest() orelse 0.0,
                .normalized_score = self.autopoiesis_window.normalized(),
                .trend = self.autopoiesis_window.trend(),
                .has_valid_data = self.autopoiesis_window.count() >= 2 and self.autopoiesis_window.latest().? > 0.0,
            },
            .{
                .name = "对称破缺(SSB)",
                .raw_score = self.ssb_window.latest() orelse 0.0,
                .normalized_score = self.ssb_window.normalized(),
                .trend = self.ssb_window.trend(),
                .has_valid_data = self.ssb_window.count() >= 2 and self.ssb_window.latest().? > 0.0,
            },
            .{
                .name = "自指(SelfRef)",
                .raw_score = self.selfref_window.latest() orelse 0.0,
                .normalized_score = self.selfref_window.normalized(),
                .trend = self.selfref_window.trend(),
                .has_valid_data = self.selfref_window.count() >= 2 and self.selfref_window.latest().? > 0.0,
            },
        };

        // ---- 计算 Kendall W 协调系数 ----
        // 使用各路径的归一化分数作为排序依据
        // W = 12 * Σ(R_i - avg_R)^2 / (k² * (n³ - n))
        // 简化版本：用各路径 normalized_score 作为排序值，
        // 计算 paired tau-b 相关性，取均值

        var active_count: usize = 0;
        var sum_scores: f64 = 0.0;
        var sum_sq_scores: f64 = 0.0;
        for (&paths) |p| {
            if (p.has_valid_data) {
                active_count += 1;
                sum_scores += p.normalized_score;
                sum_sq_scores += p.normalized_score * p.normalized_score;
            }
        }

        const w: f64 = if (active_count >= 2) blk: {
            const n = @as(f64, @floatFromInt(active_count));
            // NaN保护：检查输入的合法性
            if (!std.math.isFinite(sum_scores) or !std.math.isFinite(sum_sq_scores)) break :blk 0.5;
            const variance = if (active_count > 1)
                (sum_sq_scores - sum_scores * sum_scores / n) / (n - 1.0)
            else
                0.0;
            if (!std.math.isFinite(variance)) break :blk 0.5;
            const max_var: f64 = 0.25;
            const w_raw = 1.0 - variance / max_var;
            const clamped = @max(0.0, @min(1.0, w_raw));
            break :blk if (std.math.isFinite(clamped)) clamped else 0.5;
        } else 0.0;

        // 共识历史
        self.consensus_history.record(w);

        // 收敛判断：W > 0.85
        const is_converged = w > 0.85 and self.consecutive_consensus_steps >= 5;
        if (w > 0.85) {
            self.consecutive_consensus_steps += 1;
        } else {
            self.consecutive_consensus_steps = 0;
        }

        return .{
            .paths = paths,
            .consensus_coefficient = w,
            .active_path_count = active_count,
            .is_converged = is_converged,
            .step = step,
        };
    }

    /// 获取上次报告
    pub fn getLastReport(self: *const MetaEvaluator) ?EvaluationReport {
        return self.last_report;
    }

    /// 获取近期平均共识系数
    pub fn averageRecentConsensus(self: *const MetaEvaluator) f64 {
        if (self.consensus_history.count() == 0) return 0.0;
        var sum: f64 = 0.0;
        for (self.consensus_history.values.items) |v| {
            sum += v;
        }

        return sum / @as(f64, @floatFromInt(self.consensus_history.count()));
    }

};

// ============================================================
// 测试
// ============================================================

test "MetaEvaluator 初始化" {
    var evaluator = MetaEvaluator.init(std.testing.allocator);
    defer evaluator.deinit();
    try std.testing.expect(evaluator.getLastReport() == null);
    try std.testing.expectEqual(@as(f64, 0.0), evaluator.averageRecentConsensus());
}

test "RollingWindow 滚动记录" {
    var window = RollingWindow.init(std.testing.allocator, 5);
    defer window.deinit();

    try std.testing.expectEqual(@as(?f64, null), window.latest());

    window.record(1.0);
    try std.testing.expectEqual(@as(f64, 1.0), window.latest().?);

    window.record(2.0);
    window.record(3.0);
    window.record(4.0);
    window.record(5.0);
    try std.testing.expectEqual(@as(usize, 5), window.count());

    // 超出窗口大小时应该移除最早的值
    window.record(6.0);
    try std.testing.expectEqual(@as(usize, 5), window.count());
    try std.testing.expectEqual(@as(f64, 6.0), window.latest().?);
}
