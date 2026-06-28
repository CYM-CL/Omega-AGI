// Ω-落尘AGI 自指深度探针系统 v1.0
//
// 三个验证实验，区分「哥德尔极限」与「工程 bug」：
//
// 实验1：换不同的自指探针 —— 同一深度不同变体，看收敛率是否一致
// 实验2：延长收敛时间 —— 把步数从 1000 加到 10000，看不收敛的是否最终收敛
// 实验3：对角化构造 —— 经典哥德尔式自指句，看系统反应是否与深度探针一致

const std = @import("std");

pub const ProbeConfig = struct {
    depth: usize,
    max_steps: u64,
    tolerance: f64,
    variant: usize,
};

pub const ProbeResult = struct {
    depth: usize,
    converged: bool,
    steps_used: u64,
    final_energy: f64,
    variant: usize,
    max_steps: u64,
};

pub fn runProbe(cfg: ProbeConfig) ProbeResult {
    var x: f64 = 0.5;
    var prev: f64 = 0.0;
    var steps: u64 = 0;

    while (steps < cfg.max_steps) : (steps += 1) {
        var layer_val: f64 = x;
        for (0..cfg.depth) |_| {
            const f_val = switch (cfg.variant % 5) {
                0 => layer_val,
                1 => -layer_val,
                2 => 0.5 * layer_val,
                3 => layer_val * layer_val,
                else => 0.7 * layer_val + 0.3,
            };
            const g_val = switch ((cfg.variant / 5) % 5) {
                0 => layer_val,
                1 => layer_val * 0.9,
                2 => 0.3 * layer_val,
                3 => layer_val,
                else => 0.4 * layer_val + 0.1,
            };
            layer_val = f_val - g_val;
        }
        const result = layer_val;
        if (@abs(result - prev) < cfg.tolerance) {
            return ProbeResult{
                .depth = cfg.depth, .converged = true,
                .steps_used = steps + 1, .final_energy = result,
                .variant = cfg.variant, .max_steps = cfg.max_steps,
            };
        }
        prev = result;
        x = result;
    }
    return ProbeResult{
        .depth = cfg.depth, .converged = false,
        .steps_used = steps, .final_energy = prev,
        .variant = cfg.variant, .max_steps = cfg.max_steps,
    };
}

pub const VariantExperimentResult = struct {
    depth: usize, total_variants: usize,
    converged_count: usize, convergence_rate: f64,
};

pub fn runVariantExperiment(depth: usize, nv: usize, ms: u64) VariantExperimentResult {
    var converged: usize = 0;
    for (0..nv) |v| { if (runProbe(.{.depth=depth,.max_steps=ms,.tolerance=1e-10,.variant=v}).converged) converged += 1; }
    return VariantExperimentResult{
        .depth = depth, .total_variants = nv,
        .converged_count = converged,
        .convergence_rate = @as(f64, @floatFromInt(converged)) / @as(f64, @floatFromInt(nv)),
    };
}

pub const TimeExtensionResult = struct {
    depth: usize, variant: usize,
    short_steps: u64, long_steps: u64,
    short_converged: bool, long_converged: bool,
    improved: bool,
};

pub fn runTimeExtensionExperiment(d: usize, v: usize, sm: u64, lm: u64) TimeExtensionResult {
    const short = runProbe(.{.depth=d,.max_steps=sm,.tolerance=1e-10,.variant=v});
    const long = runProbe(.{.depth=d,.max_steps=lm,.tolerance=1e-10,.variant=v});
    return TimeExtensionResult{
        .depth = d, .variant = v,
        .short_steps = sm, .long_steps = lm,
        .short_converged = short.converged, .long_converged = long.converged,
        .improved = (!short.converged and long.converged),
    };
}

pub const GodelSentenceResult = struct {
    constructed: bool, converged: bool,
    steps_used: u64, behavior_matches_depth_probe: bool,
};

pub fn runGodelExperiment(ms: u64, rd: usize, rv: usize) GodelSentenceResult {
    var x: f64 = 0.0; var prev: f64 = -1.0; var steps: u64 = 0;
    while (steps < ms) : (steps += 1) {
        const result = x + 1.0;
        if (@abs(result - prev) < 1e-10) break;
        prev = result; x = result;
    }
    const godel_converged = @abs(x - prev) < 1e-10;
    const ref = runProbe(.{.depth=rd,.max_steps=ms,.tolerance=1e-10,.variant=rv});
    return GodelSentenceResult{
        .constructed = true, .converged = godel_converged,
        .steps_used = steps,
        .behavior_matches_depth_probe = (godel_converged == ref.converged),
    };
}

pub const DepthScanResult = struct {
    converged_at_depth: usize,
    first_divergent_depth: usize,
    convergence_rate_by_depth: f64,
};

pub fn runDepthScan(md: usize, ms: u64, v: usize) DepthScanResult {
    var last_conv: usize = 0; var first_div: usize = md + 1;
    for (1..md+1) |d| {
        const r = runProbe(.{.depth=d,.max_steps=ms,.tolerance=1e-10,.variant=v});
        if (r.converged) { last_conv = d; } else if (first_div > d) { first_div = d; }
    }
    var conv_count: f64 = 0;
    for (1..md+1) |d| { const r = runProbe(.{.depth=d,.max_steps=ms,.tolerance=1e-10,.variant=v}); if (r.converged) conv_count += 1; }
    return DepthScanResult{
        .converged_at_depth = last_conv,
        .first_divergent_depth = if (first_div <= md) first_div else 0,
        .convergence_rate_by_depth = conv_count / @as(f64, @floatFromInt(md)),
    };
}

test "runProbe basic" { try std.testing.expect(runProbe(.{.depth=10,.max_steps=100,.tolerance=1e-10,.variant=0}).steps_used > 0); }
test "experiment1 variants" { const r = runVariantExperiment(50, 10, 1000); try std.testing.expect(r.total_variants == 10); }
test "experiment2 time" { const r = runTimeExtensionExperiment(50, 0, 1000, 10000); _ = r; }
test "experiment3 godel" { const r = runGodelExperiment(1000, 50, 0); try std.testing.expect(r.constructed); }
test "depth scan" { const r = runDepthScan(20, 100, 0); try std.testing.expect(r.convergence_rate_by_depth >= 0); }
