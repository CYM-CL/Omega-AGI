const std = @import("std");
const builtin = @import("builtin");

extern fn vDSP_svesqD(values: [*]const f64, stride: isize, result: *f64, count: usize) void;

pub const DeltaBatchBackend = enum {
    scalar,
    simd_neon,
    accelerate_vdsp,
    metal_unavailable_for_f64,
};

pub fn sumSquaresAccelerate(values: []const f64) ?f64 {
    if (builtin.os.tag != .macos) return null;
    if (values.len == 0) return 0.0;

    var result: f64 = 0.0;
    vDSP_svesqD(values.ptr, 1, &result, values.len);
    return result;
}

pub fn metalFrameworkAvailable() bool {
    if (builtin.os.tag != .macos) return false;
    var lib = std.DynLib.open("/System/Library/Frameworks/Metal.framework/Metal") catch return false;
    defer lib.close();
    return true;
}

pub fn metalSupportsF64DeltaBatch() bool {
    // Apple GPU Metal kernels are optimized around f16/f32. The core Δ free-energy
    // path is f64 and must preserve the same numerical semantics as the CPU path.
    // Keep Metal as an availability-checked backend, but do not route f64 Δ² there.
    return false;
}

pub fn preferredDeltaBatchBackend() DeltaBatchBackend {
    if (sumSquaresAccelerate(&.{ 1.0, 2.0 })) |_| {
        return .accelerate_vdsp;
    }
    if (metalFrameworkAvailable() and metalSupportsF64DeltaBatch()) {
        return .metal_unavailable_for_f64;
    }
    return .simd_neon;
}

test "hardware acceleration backend availability is explicit" {
    const backend = preferredDeltaBatchBackend();
    try std.testing.expect(backend == .accelerate_vdsp or backend == .simd_neon or backend == .metal_unavailable_for_f64);
}

test "Accelerate sumSquares matches scalar when available" {
    const values = [_]f64{ 1.0, 2.0, 3.0 };
    if (sumSquaresAccelerate(&values)) |sum| {
        try std.testing.expectApproxEqAbs(@as(f64, 14.0), sum, 1e-9);
    }
}
