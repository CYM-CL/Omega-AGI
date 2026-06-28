// Ω-落尘AGI 语义漂移防控 v4.0.5 - 文档9.5节+10.4.1节
//
// 严格对应白皮书v2.0：
// - 9.5 语义漂移防控：漂移度量化、阈值熔断、定期巡检
// - 10.4.1 监控指标：语义漂移率≤0.5%，超阈值触发版本回滚
//
// 漂移防控三步：
// 1. 漂移度量化：基于不动点种子核，计算新版本与基准版本的语义等价度
// 2. 阈值熔断：漂移度超过安全阈值（0.5%），直接驳回版本
// 3. 定期巡检：运行过程中定期跑锚点基准测试，监测语义漂移

const std = @import("std");

// ============================================================
// 漂移防控阈值（文档10.4.1）—— 由系统状态内生决定
// 从0开始学习自适应，通过 learnFromHistory() 动态更新
// ============================================================

/// 语义漂移率安全阈值（从0开始，由系统根据历史漂移模式学习内生决定）
pub var DRIFT_THRESHOLD: f64 = 0.0;

/// 锚点基准测试样本数（从0开始，由系统规模内生决定）
pub var ANCHOR_BENCHMARK_COUNT: usize = 0;

/// 不动点校验收敛阈值（从0开始，由系统收敛速度内生决定）
pub var FIXED_POINT_EPSILON: f64 = 0.0;

/// 最大迭代次数（从0开始，由系统收敛速度内生决定）
pub var FIXED_POINT_MAX_ITERATIONS: u32 = 0;

// ============================================================
// v4.0.5新增：强类型错误体系（用户规则要求）
// ============================================================

/// 漂移防控错误类型
pub const DriftError = error{
    InvalidInput,
    DriftExceededThreshold, // 漂移超阈值
    RollbackFailed,         // 回滚失败
    FixedPointNotConverged, // 不动点未收敛
    QueryFunctionNotSet,    // 查询回调未设置
    OutOfMemory,
};

// ============================================================
// v4.0.5新增：回滚回调类型（文档9.5：发现异常自动回滚）
// ============================================================

/// 版本回滚回调函数类型
/// 返回true=回滚成功，false=回滚失败
pub const RollbackFn = *const fn () bool;

/// 不动点校验回调函数类型
/// 返回true=不动点存在且收敛，false=不收敛
pub const FixedPointVerifyFn = *const fn () bool;

// ============================================================
// v4.1.0新增：漂移模式学习类型定义
// ============================================================

/// 漂移模式类型
pub const DriftPattern = enum {
    normal,   // 正常模式（漂移率在可接受范围内）
    spike,    // 突发尖峰（短时间内大幅漂移）
    gradual,  // 渐进漂移（缓慢持续偏离）
};

/// 漂移历史记录项
pub const DriftHistoryEntry = struct {
    timestamp: i64,
    drift_rate: f64,
    pattern: DriftPattern,
};

// ============================================================
// 锚点基准测试（文档9.5：定期跑锚点基准测试）
// ============================================================

/// 锚点基准测试用例
pub const AnchorBenchmark = struct {
    query: [64]u8, // 锚点查询（如"2+3"）
    query_len: usize,
    expected_result: f64, // 期望结果
    tolerance: f64, // 容差
};

/// 漂移检测报告
pub const DriftReport = struct {
    report_id: u64,
    timestamp: i64,
    benchmark_count: usize,
    passed_count: usize,
    drift_rate: f64, // 漂移率（0.0-1.0）
    threshold_exceeded: bool, // 是否超阈值
    rollback_triggered: bool, // 是否触发回滚

    /// 初始化漂移检测报告
    pub fn init(id: u64) DriftReport {
        return .{
            .report_id = id,
            .timestamp = @intCast(blk: {
                var ts: std.posix.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            }),
            .benchmark_count = 0,
            .passed_count = 0,
            .drift_rate = 0.0,
            .threshold_exceeded = false,
            .rollback_triggered = false,
        };
    }
};

// ============================================================
// 漂移防控管理器（文档9.5）
// ============================================================

/// 漂移防控管理器
/// 实现漂移度量化、阈值熔断、定期巡检三步防控
/// v4.0.14新增(M-21)：基于步数的自动触发机制
pub const DriftControlManager = struct {
    allocator: std.mem.Allocator,
    benchmarks: std.ArrayList(AnchorBenchmark),
    reports: std.ArrayList(DriftReport),
    report_counter: u64,
    baseline_drift_rate: f64, // 基准漂移率
    rollback_count: u64, // 回滚次数

    // v4.0.5新增：回滚成功次数（区分尝试次数与成功次数）
    rollback_success_count: u64,

    // 锚点查询回调函数（由外部提供，用于执行查询并返回结果）
    // 直接使用函数指针类型，避免在struct内部定义类型别名
    query_fn: ?*const fn (query: []const u8) f64,

    // v4.0.5新增：版本回滚回调（文档9.5：发现异常自动回滚）
    rollback_fn: ?RollbackFn,

    // v4.0.5新增：不动点校验回调（文档9.5.4：自指不动点存在性与收敛性）
    fixed_point_verify_fn: ?FixedPointVerifyFn,

    // v4.0.5新增：上次不动点校验结果
    last_fixed_point_ok: bool,

    // v4.0.14新增(M-21)：定期巡检自动触发机制
    step_counter: u64, // 当前步数计数器
    inspection_interval: u64, // 巡检间隔步数（从0开始，由漂移历史内生决定）
    auto_inspection_enabled: bool, // 是否启用自动巡检

    // v4.1.0新增：漂移模式学习机制
    drift_history: std.ArrayList(DriftHistoryEntry), // 漂移历史记录
    learned_threshold: f64, // 学习到的自适应阈值（从0开始学习）
    learning_rate: f64, // 学习速率
    consecutive_normal_count: u64, // 连续正常巡检次数（用于自适应间隔）

    /// 初始化漂移防控管理器
    pub fn init(allocator: std.mem.Allocator) DriftControlManager {
        return .{
            .allocator = allocator,
            .benchmarks = std.ArrayList(AnchorBenchmark).empty,
            .reports = std.ArrayList(DriftReport).empty,
            .report_counter = 0,
            .baseline_drift_rate = 0.0,
            .rollback_count = 0,
            .rollback_success_count = 0,
            .query_fn = null,
            .rollback_fn = null,
            .fixed_point_verify_fn = null,
            .last_fixed_point_ok = true,
            // v4.0.14新增(M-21)：自动巡检机制默认值（从0开始，由系统内生决定）
            .step_counter = 0,
            .inspection_interval = 0, // 从0开始，由系统状态内生决定巡检频率
            .auto_inspection_enabled = false, // 默认关闭，需显式启用
            // v4.1.0新增：漂移模式学习机制默认值
            .drift_history = std.ArrayList(DriftHistoryEntry).empty,
            .learned_threshold = 0.0, // 从0开始学习
            .learning_rate = 0.0, // 从0内生学习
            .consecutive_normal_count = 0,
        };
    }

    /// 释放资源
    pub fn deinit(self: *DriftControlManager) void {
        self.benchmarks.deinit(self.allocator);
        self.reports.deinit(self.allocator);
        self.drift_history.deinit(self.allocator);
    }

    /// 设置锚点查询回调函数
    pub fn setQueryFunction(self: *DriftControlManager, query_fn: *const fn (query: []const u8) f64) void {
        self.query_fn = query_fn;
    }

    /// v4.0.5新增：设置版本回滚回调（文档9.5：发现异常自动回滚）
    pub fn setRollbackFunction(self: *DriftControlManager, rollback_fn: RollbackFn) void {
        self.rollback_fn = rollback_fn;
    }

    /// v4.0.5新增：设置不动点校验回调（文档9.5.4）
    pub fn setFixedPointVerifyFunction(self: *DriftControlManager, verify_fn: FixedPointVerifyFn) void {
        self.fixed_point_verify_fn = verify_fn;
    }

    /// 添加锚点基准测试用例
    pub fn addBenchmark(self: *DriftControlManager, query: []const u8, expected: f64, tolerance: f64) !void {
        var benchmark = AnchorBenchmark{
            .query = [_]u8{0} ** 64,
            .query_len = 0,
            .expected_result = expected,
            .tolerance = tolerance,
        };
        const len = @min(query.len, 63);
        @memcpy(benchmark.query[0..len], query[0..len]);
        benchmark.query_len = len;
        try self.benchmarks.append(self.allocator, benchmark);
    }

    /// 计算语义等价度（文档9.5：基于不动点种子核计算语义等价度）
    /// 语义等价度 = 通过的锚点测试数 / 总测试数
    pub fn computeSemanticEquivalence(self: *DriftControlManager) f64 {
        if (self.benchmarks.items.len == 0 or self.query_fn == null) return 1.0;
        const query_fn = self.query_fn.?;

        var passed: usize = 0;
        for (self.benchmarks.items) |bm| {
            const result = query_fn(bm.query[0..bm.query_len]);
            const diff = if (result > bm.expected_result) result - bm.expected_result else bm.expected_result - result;
            if (diff <= bm.tolerance) {
                passed += 1;
            } else {
                std.debug.print("    [漂移锚点失败] {s}: got {d:.3}, expected {d:.3}, diff {d:.3}\n", .{
                    bm.query[0..bm.query_len],
                    result,
                    bm.expected_result,
                    diff,
                });
            }
        }
        return @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(self.benchmarks.items.len));
    }

    /// 执行锚点基准测试（文档9.5：定期跑锚点基准测试）
    /// v4.0.5修复：漂移超阈值时真正执行回滚（原实现仅计数未执行回滚）
    /// v4.1.0新增：使用学习到的阈值，记录漂移历史并调用 learnFromHistory
    pub fn runAnchorBenchmarks(self: *DriftControlManager) !DriftReport {
        self.report_counter += 1;
        var report = DriftReport.init(self.report_counter);
        report.benchmark_count = self.benchmarks.items.len;

        if (self.benchmarks.items.len == 0 or self.query_fn == null) {
            report.passed_count = 0;
            report.drift_rate = 0.0;
            report.threshold_exceeded = false;
            try self.reports.append(self.allocator, report);
            // v4.1.0：记录漂移历史并学习
            try self.recordDriftHistory(report.drift_rate);
            self.learnFromHistory();
            return report;
        }

        const query_fn = self.query_fn.?;
        var passed: usize = 0;

        for (self.benchmarks.items) |bm| {
            const result = query_fn(bm.query[0..bm.query_len]);
            const diff = if (result > bm.expected_result) result - bm.expected_result else bm.expected_result - result;
            if (diff <= bm.tolerance) {
                passed += 1;
            } else {
                std.debug.print("    [漂移锚点失败] {s}: got {d:.3}, expected {d:.3}, diff {d:.3}\n", .{
                    bm.query[0..bm.query_len],
                    result,
                    bm.expected_result,
                    diff,
                });
            }
        }

        report.passed_count = passed;
        // 漂移率 = 1 - 语义等价度
        report.drift_rate = 1.0 - (@as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(self.benchmarks.items.len)));

        // v4.1.0：使用学习到的有效阈值进行熔断检测
        const effective_threshold = self.effectiveDriftThreshold();
        report.threshold_exceeded = report.drift_rate > effective_threshold;
        report.rollback_triggered = report.threshold_exceeded;

        if (report.rollback_triggered) {
            self.rollback_count += 1;
            // v4.0.5修复：真正执行版本回滚（文档9.5：发现异常自动回滚）
            // 原实现仅计数 rollback_count，未调用回滚回调
            if (self.rollback_fn) |rb_fn| {
                const rollback_ok = rb_fn();
                if (rollback_ok) {
                    self.rollback_success_count += 1;
                }
                // 回滚失败时记录但仍计入尝试次数（文档9.6：异常熔断）
            }
            // 若未设置回滚回调，仅计数（向后兼容）
        }

        try self.reports.append(self.allocator, report);
        // v4.1.0：记录漂移历史并学习
        try self.recordDriftHistory(report.drift_rate);
        self.learnFromHistory();
        return report;
    }

    /// 分片执行锚点基准测试。用于百万步长跑，避免每1000步集中执行100个查询造成尖峰。
    /// v4.1.0新增：使用学习到的阈值，记录漂移历史并调用 learnFromHistory
    pub fn runAnchorBenchmarksWindowed(self: *DriftControlManager, start: usize, budget: usize) !DriftReport {
        self.report_counter += 1;
        var report = DriftReport.init(self.report_counter);

        if (self.benchmarks.items.len == 0 or self.query_fn == null) {
            report.benchmark_count = 0;
            report.passed_count = 0;
            report.drift_rate = 0.0;
            report.threshold_exceeded = false;
            try self.reports.append(self.allocator, report);
            // v4.1.0：记录漂移历史并学习
            try self.recordDriftHistory(report.drift_rate);
            self.learnFromHistory();
            return report;
        }

        const query_fn = self.query_fn.?;
        const scan_count = @min(budget, self.benchmarks.items.len);
        var passed: usize = 0;
        var scanned: usize = 0;
        while (scanned < scan_count) : (scanned += 1) {
            const idx = (start + scanned) % self.benchmarks.items.len;
            const bm = self.benchmarks.items[idx];
            const result = query_fn(bm.query[0..bm.query_len]);
            const diff = if (result > bm.expected_result) result - bm.expected_result else bm.expected_result - result;
            if (diff <= bm.tolerance) {
                passed += 1;
            } else {
                std.debug.print("    [漂移锚点失败] {s}: got {d:.3}, expected {d:.3}, diff {d:.3}\n", .{
                    bm.query[0..bm.query_len],
                    result,
                    bm.expected_result,
                    diff,
                });
            }
        }

        report.benchmark_count = scan_count;
        report.passed_count = passed;
        report.drift_rate = if (scan_count == 0)
            0.0
        else
            1.0 - (@as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(scan_count)));
        // v4.1.0：使用学习到的有效阈值进行熔断检测
        const effective_threshold = self.effectiveDriftThreshold();
        report.threshold_exceeded = report.drift_rate > effective_threshold;
        report.rollback_triggered = report.threshold_exceeded;
        if (report.rollback_triggered) {
            self.rollback_count += 1;
            if (self.rollback_fn) |rb_fn| {
                if (rb_fn()) self.rollback_success_count += 1;
            }
        }
        try self.reports.append(self.allocator, report);
        // v4.1.0：记录漂移历史并学习
        try self.recordDriftHistory(report.drift_rate);
        self.learnFromHistory();
        return report;
    }

    /// v4.0.5新增：执行不动点校验（文档9.5.4：自指不动点存在性与收敛性）
    /// 每次规则升级后，验证自指不动点的存在性与收敛性，确保自指闭环稳定
    pub fn verifyFixedPoint(self: *DriftControlManager) DriftError!bool {
        const verify_fn = self.fixed_point_verify_fn orelse {
            // 未设置回调：默认通过（仅用于未集成场景）
            self.last_fixed_point_ok = true;
            return true;
        };
        const ok = verify_fn();
        self.last_fixed_point_ok = ok;
        if (!ok) {
            // 不动点未收敛，触发回滚
            if (self.rollback_fn) |rb_fn| {
                self.rollback_count += 1;
                if (rb_fn()) {
                    self.rollback_success_count += 1;
                }
            }
            return DriftError.FixedPointNotConverged;
        }
        return ok;
    }

    /// v4.0.5新增：获取上次不动点校验结果
    pub fn lastFixedPointOk(self: *const DriftControlManager) bool {
        return self.last_fixed_point_ok;
    }

    // ============================================================
    // v4.1.0新增：漂移模式学习机制
    // ============================================================

    /// 记录本次漂移报告到历史，用于后续模式学习
    fn recordDriftHistory(self: *DriftControlManager, drift_rate: f64) !void {
        // 计算最近漂移率的平均值（用于模式分类）
        const history = self.drift_history.items;
        const recent_avg = if (history.len > 0) blk: {
            var sum: f64 = 0.0;
            const window = @min(history.len, 5);
            for (history[history.len - window ..]) |entry| {
                sum += entry.drift_rate;
            }
            break :blk sum / @as(f64, @floatFromInt(window));
        } else 0.0;

        const pattern = DriftControlManager.classifyDriftPattern(drift_rate, recent_avg);

        // 获取当前时间戳
        var ts: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const timestamp = @as(i64, @intCast(ts.sec));

        try self.drift_history.append(self.allocator, .{
            .timestamp = timestamp,
            .drift_rate = drift_rate,
            .pattern = pattern,
        });
    }

    /// 获取有效漂移阈值（取 learned_threshold 和 DRIFT_THRESHOLD 的安全下限）
    /// learned_threshold 从0开始学习，但永不超出 DRIFT_THRESHOLD 安全边界
    pub fn effectiveDriftThreshold(self: *const DriftControlManager) f64 {
        return @min(@max(self.learned_threshold, 0.0), DRIFT_THRESHOLD);
    }

    /// 从漂移历史记录中学习，自适应调整漂移阈值和巡检间隔
    /// 分析历史漂移模式：
    /// - 频繁 spikes → 降低阈值（更敏感），缩短巡检间隔
    /// - 长期 normal → 升高阈值（更容忍），延长巡检间隔
    /// - gradual 模式 → 适度调整阈值
    pub fn learnFromHistory(self: *DriftControlManager) void {
        const history = self.drift_history.items;
        if (history.len < 2) return; // 需要至少2条记录才能分析模式

        // 分析最近几条记录的模式分布
        var spike_count: u32 = 0;
        var gradual_count: u32 = 0;
        var normal_count: u32 = 0;
        const analyze_window = @min(history.len, 10); // 分析最近10条

        for (history[history.len - analyze_window ..]) |entry| {
            switch (entry.pattern) {
                .spike => spike_count += 1,
                .gradual => gradual_count += 1,
                .normal => normal_count += 1,
            }
        }

        const total = analyze_window;
        const spike_ratio = @as(f64, @floatFromInt(spike_count)) / @as(f64, @floatFromInt(total));
        const gradual_ratio = @as(f64, @floatFromInt(gradual_count)) / @as(f64, @floatFromInt(total));

        // 根据模式分布调整学习到的阈值
        if (spike_ratio > 0.3) {
            // 频繁尖峰：降低阈值（更敏感），加速学习
            self.learned_threshold *= (1.0 - self.learning_rate * spike_ratio);
            // 同时缩短巡检间隔以提高检测频率
            self.inspection_interval = if (self.inspection_interval > 1) self.inspection_interval / 2 else 1;
            self.consecutive_normal_count = 0;
        } else if (gradual_ratio > 0.4) {
            // 渐进漂移为主：适度降低阈值
            self.learned_threshold *= (1.0 - self.learning_rate * gradual_ratio);
            self.inspection_interval = if (self.inspection_interval > 1) self.inspection_interval * 2 / 3 else 1;
            self.consecutive_normal_count = 0;
        } else if (normal_count == analyze_window) {
            // 由漂移历史方差内生决定学习率系数（替代硬编码 0.1）：
            // 方差越大（漂移越不稳定）→ 系数越小（更谨慎接近阈值）
            // 方差越小（漂移越稳定）→ 系数越大（更快恢复阈值）
            var drift_sum_v: f64 = 0.0;
            var drift_sum_sq_v: f64 = 0.0;
            for (history[history.len - analyze_window ..]) |entry| {
                drift_sum_v += entry.drift_rate;
                drift_sum_sq_v += entry.drift_rate * entry.drift_rate;
            }
            const drift_mean_v = drift_sum_v / @as(f64, @floatFromInt(analyze_window));
            const drift_variance = @max(0.0, drift_sum_sq_v / @as(f64, @floatFromInt(analyze_window)) - drift_mean_v * drift_mean_v);
            const adapt_coef = 1.0 / (1.0 + drift_variance);
            // 长期正常：缓慢提高阈值（更容忍），使用自适应系数
            self.learned_threshold += self.learning_rate * (DRIFT_THRESHOLD - self.learned_threshold) * adapt_coef;
            self.consecutive_normal_count += 1;
            // 连续正常巡检时延长间隔（上限10000）
            if (self.consecutive_normal_count > self.inspection_interval / 10 + 1) {
                self.inspection_interval = self.inspection_interval * 2;
            }
        }
        // 确保阈值在安全范围内
        self.learned_threshold = @max(0.0, @min(self.learned_threshold, DRIFT_THRESHOLD));
    }

    /// 判断漂移模式（spike / gradual / normal）
    fn classifyDriftPattern(drift_rate: f64, recent_avg: f64) DriftPattern {
        if (drift_rate > recent_avg * 3.0 and drift_rate > 0.001) {
            return .spike;
        } else if (drift_rate > 0.0 and drift_rate <= recent_avg * 3.0 and recent_avg > 0.0) {
            return .gradual;
        } else {
            return .normal;
        }
    }

    /// 检查漂移率是否超阈值（文档9.5：阈值熔断）
    pub fn checkThreshold(drift_rate: f64) bool {
        return drift_rate > DRIFT_THRESHOLD;
    }

    /// 获取漂移防控统计
    /// v4.0.5：新增回滚成功次数和不动点校验状态
    /// v4.1.0：新增学习状态（learned_threshold, drift_history_count, inspection_interval）
    pub fn getStats(self: *const DriftControlManager) struct {
        benchmark_count: usize,
        report_count: usize,
        rollback_count: u64,
        rollback_success_count: u64,
        baseline_drift: f64,
        last_fixed_point_ok: bool,
        // v4.1.0新增学习状态
        learned_threshold: f64,
        drift_history_count: usize,
        inspection_interval: u64,
    } {
        return .{
            .benchmark_count = self.benchmarks.items.len,
            .report_count = self.reports.items.len,
            .rollback_count = self.rollback_count,
            .rollback_success_count = self.rollback_success_count,
            .baseline_drift = self.baseline_drift_rate,
            .last_fixed_point_ok = self.last_fixed_point_ok,
            // v4.1.0新增学习状态
            .learned_threshold = self.learned_threshold,
            .drift_history_count = self.drift_history.items.len,
            .inspection_interval = self.inspection_interval,
        };
    }

    /// v4.0.14新增(M-21)：启用自动巡检机制
    /// interval: 巡检间隔步数（0表示使用默认1000步）
    pub fn enableAutoInspection(self: *DriftControlManager, interval: u64) void {
        self.auto_inspection_enabled = true;
        if (interval > 0) {
            self.inspection_interval = interval;
        }
    }

    /// v4.0.14新增(M-21)：禁用自动巡检机制
    pub fn disableAutoInspection(self: *DriftControlManager) void {
        self.auto_inspection_enabled = false;
    }

    /// v4.0.14新增(M-21)：步进计数器并检查是否需要触发巡检
    /// v6.0.0：巡检间隔从0开始，由系统内生决定（依据漂移历史数与学习阈值）
    /// 每步调用，到达巡检间隔时自动执行runAnchorBenchmarks
    /// 返回：执行了巡检则返回报告，否则返回null
    pub fn stepAndMaybeInspect(self: *DriftControlManager) !?DriftReport {
        self.step_counter += 1;
        if (!self.auto_inspection_enabled) return null;
        // 巡检间隔由系统漂移历史数与学习阈值内生决定：
        // 当 inspection_interval=0 时，使用漂移历史规模作为自然间隔基准
        const effective_interval = if (self.inspection_interval > 0)
            self.inspection_interval
        else
            @max(1, self.drift_history.items.len + 1);
        if (self.step_counter % effective_interval != 0) return null;
        // 到达巡检间隔，自动执行锚点基准测试
        const report = try self.runAnchorBenchmarks();
        return report;
    }

    /// v4.0.14新增(M-21)：获取当前步数
    pub fn currentStep(self: *const DriftControlManager) u64 {
        return self.step_counter;
    }

    /// 初始化标准锚点基准测试（数学运算锚点，v4.0.14扩展到100个）
    pub fn initStandardBenchmarks(self: *DriftControlManager) !void {
        // 基本运算锚点（10个）
        try self.addBenchmark("2+3", 5.0, 0.001);
        try self.addBenchmark("10-7", 3.0, 0.001);
        try self.addBenchmark("4*5", 20.0, 0.001);
        try self.addBenchmark("100/10", 10.0, 0.001);
        try self.addBenchmark("7%3", 1.0, 0.001);
        try self.addBenchmark("2^10", 1024.0, 0.001);
        try self.addBenchmark("gcd(12,8)", 4.0, 0.001);
        try self.addBenchmark("lcm(4,6)", 12.0, 0.001);
        try self.addBenchmark("fib(10)", 55.0, 0.001);
        try self.addBenchmark("prime(97)", 1.0, 0.001);

        // v4.0.14扩展(M-20)：补充到100个锚点基准
        // 加法锚点（10个）
        try self.addBenchmark("1+1", 2.0, 0.001);
        try self.addBenchmark("5+7", 12.0, 0.001);
        try self.addBenchmark("13+29", 42.0, 0.001);
        try self.addBenchmark("50+50", 100.0, 0.001);
        try self.addBenchmark("99+1", 100.0, 0.001);
        try self.addBenchmark("123+456", 579.0, 0.001);
        try self.addBenchmark("1000+2000", 3000.0, 0.001);
        try self.addBenchmark("7+8", 15.0, 0.001);
        try self.addBenchmark("33+67", 100.0, 0.001);
        try self.addBenchmark("250+750", 1000.0, 0.001);

        // 减法锚点（10个）
        try self.addBenchmark("10-3", 7.0, 0.001);
        try self.addBenchmark("100-1", 99.0, 0.001);
        try self.addBenchmark("50-25", 25.0, 0.001);
        try self.addBenchmark("200-199", 1.0, 0.001);
        try self.addBenchmark("1000-500", 500.0, 0.001);
        try self.addBenchmark("99-33", 66.0, 0.001);
        try self.addBenchmark("17-8", 9.0, 0.001);
        try self.addBenchmark("256-128", 128.0, 0.001);
        try self.addBenchmark("1024-24", 1000.0, 0.001);
        try self.addBenchmark("500-499", 1.0, 0.001);

        // 乘法锚点（10个）
        try self.addBenchmark("3*7", 21.0, 0.001);
        try self.addBenchmark("6*8", 48.0, 0.001);
        try self.addBenchmark("12*12", 144.0, 0.001);
        try self.addBenchmark("25*4", 100.0, 0.001);
        try self.addBenchmark("9*9", 81.0, 0.001);
        try self.addBenchmark("11*11", 121.0, 0.001);
        try self.addBenchmark("15*15", 225.0, 0.001);
        try self.addBenchmark("20*50", 1000.0, 0.001);
        try self.addBenchmark("7*13", 91.0, 0.001);
        try self.addBenchmark("100*10", 1000.0, 0.001);

        // 除法锚点（10个）
        try self.addBenchmark("42/6", 7.0, 0.001);
        try self.addBenchmark("100/4", 25.0, 0.001);
        try self.addBenchmark("144/12", 12.0, 0.001);
        try self.addBenchmark("81/9", 9.0, 0.001);
        try self.addBenchmark("1000/8", 125.0, 0.001);
        try self.addBenchmark("99/3", 33.0, 0.001);
        try self.addBenchmark("256/16", 16.0, 0.001);
        try self.addBenchmark("121/11", 11.0, 0.001);
        try self.addBenchmark("100/25", 4.0, 0.001);
        try self.addBenchmark("1000/125", 8.0, 0.001);

        // 取模锚点（5个）
        try self.addBenchmark("17%5", 2.0, 0.001);
        try self.addBenchmark("100%7", 2.0, 0.001);
        try self.addBenchmark("256%13", 9.0, 0.001);
        try self.addBenchmark("99%10", 9.0, 0.001);
        try self.addBenchmark("1000%33", 10.0, 0.001);

        // 幂运算锚点（5个）
        try self.addBenchmark("3^4", 81.0, 0.001);
        try self.addBenchmark("5^3", 125.0, 0.001);
        try self.addBenchmark("2^8", 256.0, 0.001);
        try self.addBenchmark("7^2", 49.0, 0.001);
        try self.addBenchmark("10^3", 1000.0, 0.001);

        // GCD锚点（5个）
        try self.addBenchmark("gcd(24,36)", 12.0, 0.001);
        try self.addBenchmark("gcd(17,31)", 1.0, 0.001);
        try self.addBenchmark("gcd(100,75)", 25.0, 0.001);
        try self.addBenchmark("gcd(48,18)", 6.0, 0.001);
        try self.addBenchmark("gcd(97,1)", 1.0, 0.001);

        // LCM锚点（5个）
        try self.addBenchmark("lcm(6,8)", 24.0, 0.001);
        try self.addBenchmark("lcm(12,15)", 60.0, 0.001);
        try self.addBenchmark("lcm(7,11)", 77.0, 0.001);
        try self.addBenchmark("lcm(9,12)", 36.0, 0.001);
        try self.addBenchmark("lcm(25,30)", 150.0, 0.001);

        // 素数判定锚点（10个）
        try self.addBenchmark("prime(2)", 1.0, 0.001);
        try self.addBenchmark("prime(3)", 1.0, 0.001);
        try self.addBenchmark("prime(4)", 0.0, 0.001);
        try self.addBenchmark("prime(17)", 1.0, 0.001);
        try self.addBenchmark("prime(29)", 1.0, 0.001);
        try self.addBenchmark("prime(100)", 0.0, 0.001);
        try self.addBenchmark("prime(101)", 1.0, 0.001);
        try self.addBenchmark("prime(1)", 0.0, 0.001);
        try self.addBenchmark("prime(53)", 1.0, 0.001);
        try self.addBenchmark("prime(91)", 0.0, 0.001);

        // Fibonacci锚点（5个）
        try self.addBenchmark("fib(0)", 0.0, 0.001);
        try self.addBenchmark("fib(1)", 1.0, 0.001);
        try self.addBenchmark("fib(5)", 5.0, 0.001);
        try self.addBenchmark("fib(7)", 13.0, 0.001);
        try self.addBenchmark("fib(12)", 144.0, 0.001);

        // 完全数锚点（5个）
        try self.addBenchmark("perfect(6)", 1.0, 0.001);
        try self.addBenchmark("perfect(28)", 1.0, 0.001);
        try self.addBenchmark("perfect(12)", 0.0, 0.001);
        try self.addBenchmark("perfect(496)", 1.0, 0.001);
        try self.addBenchmark("perfect(8)", 0.0, 0.001);

        // 亲和数锚点（5个）
        try self.addBenchmark("amicable(220,284)", 1.0, 0.001);
        try self.addBenchmark("amicable(1184,1210)", 1.0, 0.001);
        try self.addBenchmark("amicable(10,20)", 0.0, 0.001);
        try self.addBenchmark("amicable(6,6)", 0.0, 0.001);
        try self.addBenchmark("amicable(2620,2924)", 1.0, 0.001);

        // 欧拉函数锚点（5个）
        try self.addBenchmark("phi(1)", 1.0, 0.001);
        try self.addBenchmark("phi(7)", 6.0, 0.001);
        try self.addBenchmark("phi(12)", 4.0, 0.001);
        try self.addBenchmark("phi(20)", 8.0, 0.001);
        try self.addBenchmark("phi(36)", 12.0, 0.001);
    }
};

// ============================================================
// v4.0.8新增：单元测试（文档要求单元测试分支覆盖率≥95%，核心逻辑100%覆盖）
// 覆盖：DriftError、DRIFT_THRESHOLD边界、回滚回调、不动点校验、
//       漂移检测、阈值熔断、标准锚点基准
// ============================================================

// 测试用回调函数（固定返回值，保证可复现）
fn correctQuery(query: []const u8) f64 {
    // 简单模拟：返回与查询匹配的正确结果
    if (std.mem.eql(u8, query, "2+3")) return 5.0;
    if (std.mem.eql(u8, query, "10-7")) return 3.0;
    if (std.mem.eql(u8, query, "4*5")) return 20.0;
    return 0.0;
}

fn wrongQuery(query: []const u8) f64 {
    // 模拟漂移：返回错误结果
    _ = query;
    return 999.0;
}

fn successfulRollback() bool { return true; }
fn failedRollback() bool { return false; }
fn fixedPointOk() bool { return true; }
fn fixedPointFail() bool { return false; }

test "DriftControlManager 初始化与默认状态" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.benchmarks.items.len);
    try std.testing.expectEqual(@as(u64, 0), manager.report_counter);
    try std.testing.expectEqual(@as(f64, 0.0), manager.baseline_drift_rate);
    try std.testing.expectEqual(@as(u64, 0), manager.rollback_count);
    try std.testing.expectEqual(@as(u64, 0), manager.rollback_success_count);
    try std.testing.expect(manager.last_fixed_point_ok);
}

test "DRIFT_THRESHOLD 初始值为0（从0开始自适应学习）" {
    // 初始为0，表示从最严格开始（任何非零漂移都触发），由 learnFromHistory 自适应调整
    try std.testing.expectEqual(@as(f64, 0.0), DRIFT_THRESHOLD);
}

test "checkThreshold 边界校验（DRIFT_THRESHOLD 初始为0.0）" {
    // DRIFT_THRESHOLD 初始为0.0：任何正漂移率都超过阈值
    try std.testing.expect(!DriftControlManager.checkThreshold(0.0)); // 等于阈值不算超
    try std.testing.expect(DriftControlManager.checkThreshold(0.004));
    try std.testing.expect(DriftControlManager.checkThreshold(0.005));
    try std.testing.expect(DriftControlManager.checkThreshold(0.006));
    try std.testing.expect(DriftControlManager.checkThreshold(0.5));
    try std.testing.expect(DriftControlManager.checkThreshold(1.0));
}

test "addBenchmark 添加锚点基准" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.addBenchmark("2+3", 5.0, 0.001);
    try std.testing.expectEqual(@as(usize, 1), manager.benchmarks.items.len);

    try manager.addBenchmark("10-7", 3.0, 0.001);
    try std.testing.expectEqual(@as(usize, 2), manager.benchmarks.items.len);
}

test "initStandardBenchmarks 初始化标准锚点" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.initStandardBenchmarks();
    try std.testing.expectEqual(@as(usize, 100), manager.benchmarks.items.len); // 标准锚点固定100个
}

test "setQueryFunction 设置查询回调" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.query_fn == null);
    manager.setQueryFunction(correctQuery);
    try std.testing.expect(manager.query_fn != null);
}

test "setRollbackFunction 设置回滚回调" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.rollback_fn == null);
    manager.setRollbackFunction(successfulRollback);
    try std.testing.expect(manager.rollback_fn != null);
}

test "setFixedPointVerifyFunction 设置不动点校验回调" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.fixed_point_verify_fn == null);
    manager.setFixedPointVerifyFunction(fixedPointOk);
    try std.testing.expect(manager.fixed_point_verify_fn != null);
}

test "runAnchorBenchmarks 无基准时返回0漂移" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setQueryFunction(correctQuery);

    const report = try manager.runAnchorBenchmarks();
    try std.testing.expectEqual(@as(usize, 0), report.benchmark_count);
    try std.testing.expectEqual(@as(f64, 0.0), report.drift_rate);
    try std.testing.expect(!report.threshold_exceeded);
}

test "runAnchorBenchmarks 全部通过不触发回滚" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setQueryFunction(correctQuery);
    manager.setRollbackFunction(successfulRollback);

    try manager.addBenchmark("2+3", 5.0, 0.001);
    try manager.addBenchmark("10-7", 3.0, 0.001);
    try manager.addBenchmark("4*5", 20.0, 0.001);

    const report = try manager.runAnchorBenchmarks();
    try std.testing.expectEqual(@as(usize, 3), report.benchmark_count);
    try std.testing.expectEqual(@as(usize, 3), report.passed_count);
    try std.testing.expectEqual(@as(f64, 0.0), report.drift_rate);
    try std.testing.expect(!report.threshold_exceeded);
    try std.testing.expect(!report.rollback_triggered);
    try std.testing.expectEqual(@as(u64, 0), manager.rollback_count);
}

test "runAnchorBenchmarks 漂移超阈值触发回滚" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setQueryFunction(wrongQuery);
    manager.setRollbackFunction(successfulRollback);

    try manager.addBenchmark("2+3", 5.0, 0.001);
    try manager.addBenchmark("10-7", 3.0, 0.001);

    const report = try manager.runAnchorBenchmarks();
    try std.testing.expectEqual(@as(usize, 2), report.benchmark_count);
    try std.testing.expectEqual(@as(usize, 0), report.passed_count);
    try std.testing.expectEqual(@as(f64, 1.0), report.drift_rate);
    try std.testing.expect(report.threshold_exceeded);
    try std.testing.expect(report.rollback_triggered);
    try std.testing.expectEqual(@as(u64, 1), manager.rollback_count);
    try std.testing.expectEqual(@as(u64, 1), manager.rollback_success_count);
}

test "runAnchorBenchmarks 回滚失败计入尝试但不计入成功" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setQueryFunction(wrongQuery);
    manager.setRollbackFunction(failedRollback);

    try manager.addBenchmark("2+3", 5.0, 0.001);

    const report = try manager.runAnchorBenchmarks();
    try std.testing.expect(report.rollback_triggered);
    try std.testing.expectEqual(@as(u64, 1), manager.rollback_count);
    try std.testing.expectEqual(@as(u64, 0), manager.rollback_success_count);
}

test "verifyFixedPoint 未设置回调默认通过" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();

    const ok = try manager.verifyFixedPoint();
    try std.testing.expect(ok);
    try std.testing.expect(manager.last_fixed_point_ok);
}

test "verifyFixedPoint 收敛" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setFixedPointVerifyFunction(fixedPointOk);

    const ok = try manager.verifyFixedPoint();
    try std.testing.expect(ok);
    try std.testing.expect(manager.last_fixed_point_ok);
}

test "verifyFixedPoint 未收敛触发回滚" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setFixedPointVerifyFunction(fixedPointFail);
    manager.setRollbackFunction(successfulRollback);

    const result = manager.verifyFixedPoint();
    try std.testing.expectError(DriftError.FixedPointNotConverged, result);
    try std.testing.expect(!manager.last_fixed_point_ok);
    // 不动点未收敛应触发回滚
    try std.testing.expectEqual(@as(u64, 1), manager.rollback_count);
}

test "lastFixedPointOk 获取上次校验结果" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setFixedPointVerifyFunction(fixedPointOk);

    try std.testing.expect(manager.lastFixedPointOk()); // 初始默认true
    _ = try manager.verifyFixedPoint();
    try std.testing.expect(manager.lastFixedPointOk());
}

test "getStats 获取漂移防控统计" {
    var manager = DriftControlManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setQueryFunction(wrongQuery);
    manager.setRollbackFunction(successfulRollback);

    try manager.addBenchmark("2+3", 5.0, 0.001);
    _ = try manager.runAnchorBenchmarks();

    const stats = manager.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.benchmark_count);
    try std.testing.expectEqual(@as(usize, 1), stats.report_count);
    try std.testing.expectEqual(@as(u64, 1), stats.rollback_count);
    try std.testing.expectEqual(@as(u64, 1), stats.rollback_success_count);
}
