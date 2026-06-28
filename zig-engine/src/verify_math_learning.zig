const std = @import("std");
const dc = @import("delta_consistency.zig");

pub fn verifyMathLearning() dc.ConsistencyReport {
    return dc.evaluateDeltaConsistency();
}

test "Delta algebra self-verification (no hardcoded answers)" {
    const r = verifyMathLearning();
    std.debug.print("\n", .{});
    std.debug.print("=== Delta Algebra Self-Verification ===\n", .{});
    std.debug.print("Method: Delta definition invariants (no external expected values)\n\n", .{});
    for (&r.invariants) |inv| {
        const s = if (inv.rate >= 0.99) "PASS" else "FAIL";
        std.debug.print("{s} | {s} | domain: {s} | rate: {d:.4} ({d}/{d})\n", .{s, inv.name, inv.domain, inv.rate, inv.passed, inv.total});
    }
    std.debug.print("\nOverall delta consistency: {d:.4} ", .{r.overall_score});
    if (r.overall_score >= 0.99) {
        std.debug.print("PASS\n", .{});
        std.debug.print("Conclusion: System delta algebra is self-consistent.\n", .{});
        std.debug.print("This is NOT 'learned correct answers'.\n", .{});
        std.debug.print("This IS 'algebraic structure convergence'.\n", .{});
    } else {
        std.debug.print("FAIL\n", .{});
    }
    try std.testing.expect(r.overall_score >= 0.99);
}
