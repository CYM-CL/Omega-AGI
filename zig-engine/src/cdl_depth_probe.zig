const std = @import("std");
const de = @import("delta_engine.zig").DeltaEngine;
const cdl = @import("cdl_expr.zig");

pub const CdlProbeConfig = struct { depth: usize, max_steps: u64, tolerance: f64, variant: usize };
pub const CdlProbeResult = struct { depth: usize, converged: bool, steps_used: u64, final_energy: f64, variant: usize };

pub fn runCdlProbe(cfg: CdlProbeConfig, engine: *de) !CdlProbeResult {
    const nid = try engine.createNodeWithCDL("probe", 0.5);
    var cur = try engine.cdl_pool.makeValueRef(nid);
    for (0..cfg.depth) |_| {
        const rf = try engine.cdl_pool.makeNodeRef(nid, cfg.variant % 2 == 0);
        cur = try engine.cdl_pool.makeDelta(rf, cur);
    }
    try engine.setNodeFExpr(nid, cur);
    var prv: f64 = 0.0;
    var steps: u64 = 0;
    while (steps < cfg.max_steps) : (steps += 1) {
        const val = engine.evalExprF(nid);
        if (@abs(val - prv) < cfg.tolerance) {
            return CdlProbeResult{.depth=cfg.depth,.converged=true,.steps_used=steps+1,.final_energy=val,.variant=cfg.variant};
        }
        prv = val;
        try engine.graph.setObjectValue(nid, val);
    }
    return CdlProbeResult{.depth=cfg.depth,.converged=false,.steps_used=steps,.final_energy=prv,.variant=cfg.variant};
}

pub fn runCdlVariantExperiment(d: usize, nv: usize, ms: u64, engine: *de) !struct { total: usize, converged: usize, rate: f64 } {
    var conv: usize = 0;
    for (0..nv) |v| {
        if ((try runCdlProbe(.{.depth=d,.max_steps=ms,.tolerance=1e-10,.variant=v}, engine)).converged) conv += 1;
    }
    return .{ .total = nv, .converged = conv, .rate = @as(f64, @floatFromInt(conv)) / @as(f64, @floatFromInt(nv)) };
}

pub fn runCdlTimeExperiment(d: usize, v: usize, sm: u64, lm: u64, engine: *de) !struct { d: usize, short: bool, long: bool, improved: bool } {
    const s = try runCdlProbe(.{.depth=d,.max_steps=sm,.tolerance=1e-10,.variant=v}, engine);
    const l = try runCdlProbe(.{.depth=d,.max_steps=lm,.tolerance=1e-10,.variant=v}, engine);
    return .{.d=d,.short=s.converged,.long=l.converged,.improved=(!s.converged and l.converged)};
}

pub fn runCdlGodelExperiment(ms: u64, rd: usize, rv: usize, engine: *de) !struct { converged: bool, matches: bool } {
    const gnid = try engine.createNodeWithCDL("godel", 0.0);
    const gref = try engine.cdl_pool.makeNodeRef(gnid, true);
    const gbase = try engine.cdl_pool.makeValueRef(gnid);
    const gexpr = try engine.cdl_pool.makeDelta(gref, gbase);
    try engine.setNodeFExpr(gnid, gexpr);
    var prv: f64 = -1.0;
    var steps: u64 = 0;
    while (steps < ms) : (steps += 1) {
        const val = engine.evalExprF(gnid);
        if (@abs(val - prv) < 1e-10) break;
        prv = val;
        try engine.graph.setObjectValue(gnid, val);
    }
    const godel_conv = steps >= ms;
    const ref = try runCdlProbe(.{.depth=rd,.max_steps=ms,.tolerance=1e-10,.variant=rv}, engine);
    return .{.converged=!godel_conv, .matches=(!godel_conv == ref.converged)};
}
