// Ω-落尘AGI 模拟退火接受准则 v4.0.10 - 从trainer.zig拆分
//
// 严格对应白皮书v2.0第7.4.5节条件4：Geman & Geman 1984对数退火
// 设计定义：
//   - 温度公式：T_n = c / log(n+1)，n从1开始
//   - 接受概率：p_n = min(1, exp(-ΔF / T_n))
//   - ΔF ≤ 0（自由能下降）：总是接受
//   - ΔF > 0（自由能上升）：以概率 exp(-ΔF/T) 接受
//
// 拆分依据：单一职责原则（文档要求单函数/模块职责唯一、体量严格受控）
// 原trainer.zig 2365行职责过重，本模块仅负责模拟退火逻辑
//
// 依赖关系：
//   - splitmix64.zig：可播种CSPRNG（文档要求全流程可复现，随机数使用可播种CSPRNG）

const std = @import("std");
const sm64 = @import("splitmix64.zig");

/// 模拟退火接受准则（文档7.4.5条件4）
///
/// 设计定义：
///   - c：退火常数（默认1.0）
///   - step：当前步数（从0开始，accept方法中先+1再计算温度）
///   - accepted_count/rejected_count：接受/拒绝次数统计
///   - rng：SplitMix64 CSPRNG实例（v4.0.8替换DefaultPrng）
///
/// 数学约束：
///   - T_n = c/log(n+1)，n≥1，所以log(n+1)≥log(2)>0，无除零问题
///   - 接受概率 p = exp(-ΔF/T) ∈ (0, 1]（当ΔF>0时）
///   - 收敛性定理v2.0：对数退火保证全局最优（Geman & Geman 1984）
///
/// 可复现性：
///   - 相同seed+相同ΔF序列生成相同接受/拒绝序列
///   - 跨语言一致：与Rust侧SplitMix64实现完全一致
pub const SimulatedAnnealing = struct {
    c: f64, // 退火常数
    step: u64, // 当前步数
    accepted_count: u64, // 接受次数
    rejected_count: u64, // 拒绝次数
    // v4.0.8：使用SplitMix64替代DefaultPrng（文档要求可播种CSPRNG，与Rust侧一致）
    rng: sm64.SplitMix64,
    /// 自适应调整速率（0.0-1.0）
    adaptation_rate: f64 = 0.01,
    /// 目标接受率（默认0.5，平衡探索与利用）
    target_acceptance_rate: f64 = 0.5,
    /// 是否启用自适应调整
    adaptive_enabled: bool = true,

    /// 初始化模拟退火
    /// 参数：
    ///   - c：退火常数（推荐1.0，会自适应调整）
    ///   - seed：随机数种子（保证可复现性）
    pub fn init(c: f64, seed: u64) SimulatedAnnealing {
        return .{
            .c = c,
            .step = 0,
            .accepted_count = 0,
            .rejected_count = 0,
            .rng = sm64.SplitMix64.init(seed),
        };
    }

    /// 计算当前温度 T_n = c/log(n+1)（Geman & Geman 1984对数退火）
    ///
    /// v4.0.5修复：公式偏差（原c/log(step+2)，应为c/log(step+1)）
    ///             文档7.4.5：T_n = c/log(n+1)，n从1开始
    ///             accept方法中step先+1再计算，所以step≥1
    ///             T = c/log(step+1)，step=1时T=c/log(2)（符合文档T_1=c/log(2)）
    ///
    /// 约束条件：
    ///   - step≥1（accept中先+1），所以log(step+1)≥log(2)>0，无除零问题
    ///   - 返回值随step单调递减趋于0（退火特性）
    pub fn temperature(self: *const SimulatedAnnealing) f64 {
        const n = @as(f64, @floatFromInt(self.step));
        // v4.0.5：使用log(n+1)而非log(n+2)，修正公式偏差
        // step≥1（accept中先+1），所以n+1≥2，log(n+1)≥log(2)>0，无除零问题
        return self.c / @log(n + 1.0);
    }

    /// 获取当前接受率
    pub fn acceptanceRate(self: *const SimulatedAnnealing) f64 {
        const total = self.accepted_count + self.rejected_count;
        if (total == 0) return 0.5; // 初始默认值
        return @as(f64, @floatFromInt(self.accepted_count)) / @as(f64, @floatFromInt(total));
    }

    /// 自适应调整退火常数c
    /// 原理：根据接受率调整c，使接受率维持在目标值附近
    ///   - 接受率 > 目标：温度太高，降低c
    ///   - 接受率 < 目标：温度太低，提高c
    pub fn adapt(self: *SimulatedAnnealing) void {
        if (!self.adaptive_enabled) return;
        if (self.step < 10) return; // 前10步不调整，积累足够样本

        const current_rate = self.acceptanceRate();
        const diff = self.target_acceptance_rate - current_rate;

        // 比例控制：c 与接受率正相关
        // 接受率低 → 提高c → 温度升高 → 更容易接受
        // 接受率高 → 降低c → 温度降低 → 更难接受
        const adjustment = 1.0 + self.adaptation_rate * diff * 10.0;
        self.c *= adjustment;

        // 限制c的范围，防止极端值
        if (self.c < 0.1) self.c = 0.1;
        if (self.c > 10.0) self.c = 10.0;
    }

    /// 判断是否接受更新（文档7.4.5条件4：接受概率 p_n = min(1, exp(-ΔF / T_n))）
    ///
    /// 设计定义：
    ///   - step先+1，保证step≥1，温度公式无除零问题
    ///   - ΔF ≤ 0（自由能下降）：总是接受，accepted_count+1
    ///   - ΔF > 0（自由能上升）：以概率 exp(-ΔF/T) 接受
    ///     - 接受：accepted_count+1
    ///     - 拒绝：rejected_count+1
    ///
    /// 约束条件：
    ///   - 随机数使用SplitMix64.nextFloat()（v4.0.8替换rng.random().float(f64)）
    ///   - 可复现性：相同seed+相同ΔF序列生成相同接受/拒绝序列
    pub fn accept(self: *SimulatedAnnealing, delta_f: f64) bool {
        self.step += 1;
        const temp = self.temperature();

        // ΔF ≤ 0（自由能下降）：总是接受
        if (delta_f <= 0.0) {
            self.accepted_count += 1;
            return true;
        }

        // ΔF > 0（自由能上升）：以概率 exp(-ΔF/T) 接受
        const accept_prob = @exp(-delta_f / temp);
        // v4.0.8：使用SplitMix64.nextFloat()替代rng.random().float(f64)
        const rand_val = self.rng.nextFloat();

        if (rand_val < accept_prob) {
            self.accepted_count += 1;
            return true;
        } else {
            self.rejected_count += 1;
            return false;
        }
    }
};

// ============================================================
// 单元测试（文档要求单元测试分支覆盖率≥95%，核心逻辑100%覆盖）
// ============================================================

test "SimulatedAnnealing 初始化" {
    const sa = SimulatedAnnealing.init(1.0, 42);

    try std.testing.expectEqual(@as(f64, 1.0), sa.c);
    try std.testing.expectEqual(@as(u64, 0), sa.step);
    try std.testing.expectEqual(@as(u64, 0), sa.accepted_count);
    try std.testing.expectEqual(@as(u64, 0), sa.rejected_count);
}

test "SimulatedAnnealing 自由能下降总是接受" {
    var sa = SimulatedAnnealing.init(1.0, 42);

    // ΔF ≤ 0 应总是接受
    try std.testing.expect(sa.accept(-1.0));
    try std.testing.expect(sa.accept(-0.5));
    try std.testing.expect(sa.accept(0.0)); // 边界：ΔF=0应接受
    try std.testing.expect(sa.accept(-100.0));

    try std.testing.expectEqual(@as(u64, 4), sa.accepted_count);
    try std.testing.expectEqual(@as(u64, 0), sa.rejected_count);
}

test "SimulatedAnnealing 温度公式 T_n = c/log(n+1)" {
    var sa = SimulatedAnnealing.init(2.0, 42);

    // step=0时（未调用accept），温度公式 T = 2/log(0+1) = 2/log(1) = 2/0 = +inf
    // 但实际accept中会先+1，所以这里测试调用accept后的温度
    sa.step = 1;
    // T_1 = c/log(1+1) = 2/log(2) ≈ 2/0.693 ≈ 2.885
    const t1 = sa.temperature();
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / @log(2.0)), t1, 1e-10);

    sa.step = 9;
    // T_9 = c/log(9+1) = 2/log(10) ≈ 2/2.303 ≈ 0.868
    const t9 = sa.temperature();
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / @log(10.0)), t9, 1e-10);
}

test "SimulatedAnnealing 温度单调递减" {
    var sa = SimulatedAnnealing.init(1.0, 42);

    var prev_temp: f64 = 1e18;
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        sa.step = i;
        const temp = sa.temperature();
        // 温度应单调递减（非严格）
        try std.testing.expect(temp <= prev_temp);
        prev_temp = temp;
    }
}

test "SimulatedAnnealing 自由能上升概率接受" {
    var sa = SimulatedAnnealing.init(1.0, 42);

    // ΔF > 0：以概率接受，结果取决于随机数
    // 多次调用后应有接受和拒绝两种情况
    var accepted_count: u64 = 0;
    var rejected_count: u64 = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (sa.accept(0.5)) {
            accepted_count += 1;
        } else {
            rejected_count += 1;
        }
    }

    // 应该有接受和拒绝两种情况（概率性，但100次中应该都有）
    try std.testing.expect(accepted_count > 0);
    try std.testing.expect(rejected_count > 0);
    try std.testing.expectEqual(@as(u64, 100), sa.accepted_count + sa.rejected_count);
}

test "SimulatedAnnealing 接受率计算" {
    var sa = SimulatedAnnealing.init(1.0, 42);

    // 无样本时返回0.0
    try std.testing.expectEqual(@as(f64, 0.0), sa.acceptanceRate());

    // 3次接受
    _ = sa.accept(-1.0);
    _ = sa.accept(-1.0);
    _ = sa.accept(-1.0);
    // 接受率应为1.0（全部接受）
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sa.acceptanceRate(), 1e-10);

    // 1次拒绝（ΔF很大，温度低时几乎必拒绝）
    sa.step = 1000; // 高step低温
    _ = sa.accept(1000.0);
    // 接受率 = 3/4 = 0.75
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), sa.acceptanceRate(), 1e-10);
}

test "SimulatedAnnealing 可复现性" {
    // 相同seed应生成相同接受/拒绝序列（文档要求全流程可复现）
    var sa1 = SimulatedAnnealing.init(1.0, 999);
    var sa2 = SimulatedAnnealing.init(1.0, 999);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const delta_f: f64 = 0.3;
        const r1 = sa1.accept(delta_f);
        const r2 = sa2.accept(delta_f);
        try std.testing.expectEqual(r1, r2);
    }

    try std.testing.expectEqual(sa1.accepted_count, sa2.accepted_count);
    try std.testing.expectEqual(sa1.rejected_count, sa2.rejected_count);
}

test "SimulatedAnnealing 不同seed生成不同序列" {
    var sa1 = SimulatedAnnealing.init(1.0, 1);
    var sa2 = SimulatedAnnealing.init(1.0, 2);

    var diff_count: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const r1 = sa1.accept(0.5);
        const r2 = sa2.accept(0.5);
        if (r1 != r2) diff_count += 1;
    }
    // 不同seed应生成不同序列（概率性，但100次中应该有差异）
    try std.testing.expect(diff_count > 0);
}
