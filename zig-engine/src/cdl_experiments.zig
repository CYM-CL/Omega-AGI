const std = @import("std");
const de = @import("delta_engine.zig").DeltaEngine;
const cdp = @import("cdl_depth_probe.zig");

test "all cdl experiments" {
    var engine = try de.init(std.testing.allocator);
    defer engine.deinit();

    std.debug.print("\n=== CDL深度谱系扫描 (depth=1..15, variant=0, max_steps=1000) ===\n", .{});
    var converged: usize = 0;
    for (1..16) |d| {
        const r = try cdp.runCdlProbe(.{.depth=d, .max_steps=1000, .tolerance=1e-10, .variant=0}, &engine);
        if (r.converged) { converged += 1; std.debug.print("深度{d:2}: 收敛({d}步)\n", .{d, r.steps_used}); }
        else { std.debug.print("深度{d:2}: ✗不收敛\n", .{d}); }
    }
    const rate = @as(f64, @floatFromInt(converged)) / 15.0;
    std.debug.print("收敛率: {d:.3} ({d}/15)\n", .{rate, converged});

    std.debug.print("\n=== 实验1: 变体替换 (depth=5, 10 variants) ===\n", .{});
    const e1 = try cdp.runCdlVariantExperiment(5, 10, 1000, &engine);
    std.debug.print("收敛率: {d:.2} ({d}/{d})\n", .{e1.rate, e1.converged, e1.total});

    std.debug.print("\n=== 实验2: 延长时间 (depth=5, variant=0) ===\n", .{});
    const e2 = try cdp.runCdlTimeExperiment(5, 0, 1000, 10000, &engine);
    std.debug.print("1000步: {}, 10000步: {}, 改善: {}\n", .{e2.short, e2.long, e2.improved});

    std.debug.print("\n=== 实验3: 对角化构造（哥德尔句）===\n", .{});
    const e3 = try cdp.runCdlGodelExperiment(1000, 5, 0, &engine);
    std.debug.print("哥德尔句收敛: {}, 深度探针行为匹配: {}\n", .{e3.converged, e3.matches});

    std.debug.print("\n=== 综合结论 ===\n", .{});
    if (!e2.short and !e2.long and !e3.converged) {
        std.debug.print("指向可能性A: 真·哥德尔极限\n", .{});
    } else if (!e3.converged and e3.matches) {
        std.debug.print("指向可能性B混合: 慢收敛 + 哥德尔句一致\n", .{});
    } else {
        std.debug.print("数据不足，需要更大深度扫描\n", .{});
    }
}
