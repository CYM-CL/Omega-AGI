// Ω-落尘AGI 种子核FFI绑定 v5.0（清理版）
//
// v5.0变更（移除所有标量权重残留）：
// - 移除：delta() - 标量权重Δ运算（由CDL表达式引擎替代）
// - 移除：updateWeights() - 权重梯度下降（由拓扑演化替代）
// - 移除：selfReference() - 标量自指（由CDL表达式嵌套替代）
// - 移除：fixedPoint() - 标量不动点（由CDL表达式迭代替代）
// - 移除：freeEnergy() - 标量自由能计算（由内生自由能分量替代）
// - 移除：makeObject() / makeObjectWithWeights() - 标量对象构造
// - 保留：latticeJoin/Meet（格运算）、consistency/anchors（校验）
// - 保留：permission checker（安全管控）
// - 保留：FreeEnergyWeights（元自由能自适应）
// - 保留：Morphism/Morphism2/ID构造器
//
// ============================================================
// 迁移说明（标量权重 → CDL表达式引擎）
// ============================================================
// 本文件保留的 FFI 函数（latticeJoin/Meet、validateConsistency 等）均为
// 不依赖标量权重的纯数学运算或结构校验。所有依赖 f_weight/g_weight 标量的
// Δ 运算（delta、updateWeights、selfReference 等）已在 v5.0 中移除。
//
// 迁移路径：
//   1. 标量 Δ 运算 → cdl_expr.zig 的 ExprNode (NodeRef/Delta/Superpose)
//   2. 权重梯度下降 → delta_engine.zig 的传导即演化微自举
//   3. 标量自指 → CDL表达式嵌套（Δ(Δ(x,y), Δ(x,y))）
//   4. evalExprF/G 在 CDL表达式为 NULL 时回退到 graph.getObjectValue()
//
// 当前状态（v5.1）：
//   - Rust 种子核的 lib.rs 仍保留 f_weight/g_weight 字段和 delta_function()
//     供与旧版 FFI 合约的向后兼容。这些字段在新版 Zig 引擎中不被使用。
//   - Zig 引擎的 deltaExpr() 完全通过 CDL 表达式树计算 Δ。
//   - 本文件的保留函数不涉及标量权重，可安全使用。
// ============================================================

const std = @import("std");

// ============================================================
// C头文件导入
// ============================================================

pub const c = @cImport({
    @cInclude("seed_kernel.h");
});

// ============================================================
// 类型重新导出（Zig风格）
// ============================================================

pub const ObjectId = c.ObjectId;
pub const MorphismId = c.MorphismId;
pub const Morphism2Id = c.Morphism2Id;
pub const Object = c.Object;
pub const Morphism = c.Morphism;
pub const Morphism2 = c.Morphism2;
pub const RewriteType = c.RewriteType;
pub const Sign = c.Sign;
pub const ConsistencyReport = c.ConsistencyReport;
pub const ConvergenceStatus = c.ConvergenceStatus;
pub const FFIError = c.FFIError;

// 重写类型常量
// 直接引用C头文件中定义的枚举值，避免Zig版本兼容性问题
pub const REWRITE_EQUIVALENT: RewriteType = c.REWRITE_EQUIVALENT;
pub const REWRITE_OPTIMIZATION: RewriteType = c.REWRITE_OPTIMIZATION;
pub const REWRITE_ABSTRACTION: RewriteType = c.REWRITE_ABSTRACTION;
pub const REWRITE_INVERSE: RewriteType = c.REWRITE_INVERSE;
pub const REWRITE_TRANSITIVE: RewriteType = c.REWRITE_TRANSITIVE;
pub const REWRITE_CONTENT_TO_RULE: RewriteType = c.REWRITE_CONTENT_TO_RULE;
pub const REWRITE_RULE_TO_CONTENT: RewriteType = c.REWRITE_RULE_TO_CONTENT;

// FFI错误常量
pub const FFI_SUCCESS: i32 = 0;
pub const FFI_INVALID_INPUT: i32 = 1;
pub const FFI_CONSISTENCY_VIOLATION: i32 = 2;
pub const FFI_ANCHOR_VIOLATION: i32 = 3;

/// 安全级别检查（白皮书 §9.4.1：Seed ⊑ Sandbox ⊑ Main）
/// 替换旧的 PermissionChecker 权限校验器。新 API 无状态、无内存分配。
pub fn checkPermission(source_level: u8, target_level: u8) bool {
    return c.seed_check_permission(source_level, target_level);
}
pub const FFI_OUT_OF_MEMORY: i32 = 4;
pub const FFI_PERMISSION_DENIED: i32 = 5;

// Sign 枚举常量
// v4.0.16修复：Zig 0.16.0 @cImport不解析C枚举常量，Sign为c_uint类型，直接赋整数值
pub const SIGN_POSITIVE: Sign = 1;
pub const SIGN_ZERO: Sign = 0;
pub const SIGN_NEGATIVE: Sign = 2;

// ============================================================
// FFI函数包装（保留基础数学和校验功能）
// ============================================================

/// 种子核版本
pub fn version() u32 {
    return c.seed_kernel_version();
}

/// 格运算-上确界（join ∨）
/// 文档2.2.1：完备格要求任意子集有上确界
pub fn latticeJoin(a: f64, b: f64) f64 {
    return c.seed_lattice_join(a, b);
}

/// 格运算-下确界（meet ∧）
/// 文档2.2.1：完备格要求任意子集有下确界
pub fn latticeMeet(a: f64, b: f64) f64 {
    return c.seed_lattice_meet(a, b);
}

/// 全局自洽校验
/// v4.0.5修复：空输入返回consistency_rate=0.0
pub fn validateConsistency(
    objects: []const Object,
    morphisms: []const Morphism,
) ConsistencyReport {
    if (objects.len == 0 or morphisms.len == 0) {
        return .{
            .total_cycles = 0,
            .contradictions = 0,
            .consistency_rate = 0.0,
            .total_delta_sum = 0.0,
        };
    }
    return c.seed_validate_consistency(
        objects.ptr,
        objects.len,
        morphisms.ptr,
        morphisms.len,
    );
}

/// 三重分级自洽校验
pub const ConsistencyLevel = enum(u8) {
    L1_Realtime = 0,
    L2_Periodic = 1,
    L3_Full = 2,
};

/// 三重分级自洽校验
pub fn validateConsistencyLeveled(
    objects: []const Object,
    morphisms: []const Morphism,
    level: ConsistencyLevel,
    step_count: u64,
) ConsistencyReport {
    if (objects.len == 0 or morphisms.len == 0) {
        return .{
            .total_cycles = 0,
            .contradictions = 0,
            .consistency_rate = 0.0,
            .total_delta_sum = 0.0,
        };
    }
    return c.seed_validate_consistency_leveled(
        objects.ptr,
        objects.len,
        morphisms.ptr,
        morphisms.len,
        @intFromEnum(level),
        step_count,
    );
}

/// 三重锚定校验（公理锚+语义锚+结构锚）


// ============================================================
// 辅助构造函数（仅保留Morphism/Morphism2/ID构造——不含标量权重）
// ============================================================

/// 创建态射
pub fn makeMorphism(source: u64, target: u64, morphism_id: u64, delta: f64, security_level: u8) Morphism {
    return .{
        .source = source,
        .target = target,
        .morphism_id = morphism_id,
        .delta = delta,
        .security_level = security_level,
    };
}

/// 创建2-态射
pub fn makeMorphism2(
    morphism_id: u64,
    source_morphism: u64,
    target_morphism: u64,
    rewrite_type: RewriteType,
) Morphism2 {
    return .{
        .morphism_id = morphism_id,
        .source_morphism = source_morphism,
        .target_morphism = target_morphism,
        .rewrite_type = rewrite_type,
    };
}

/// 创建对象ID
pub fn makeObjectId(id: u64) ObjectId {
    return id;
}

/// 创建态射ID
pub fn makeMorphismId(id: u64) MorphismId {
    return id;
}

/// 创建2-态射ID
pub fn makeMorphism2Id(id: u64) Morphism2Id {
    return id;
}

// ============================================================
// 单元测试
// ============================================================

test "makeMorphism 基本构造" {
    const m = makeMorphism(10, 20, 1, 0.5, 2);
    try std.testing.expectEqual(@as(u64, 1), m.morphism_id);
    try std.testing.expectEqual(@as(u64, 10), m.source);
    try std.testing.expectEqual(@as(u64, 20), m.target);
    try std.testing.expectEqual(@as(f64, 0.5), m.delta);
}

test "makeMorphism 边界值：负权重" {
    const m = makeMorphism(0, 1, 1, -1.0, 2);
    try std.testing.expectEqual(@as(f64, -1.0), m.delta);
}

test "makeMorphism2 基本构造" {
    const m = makeMorphism2(1, 10, 20, REWRITE_EQUIVALENT);
    try std.testing.expectEqual(@as(u64, 1), m.morphism_id);
    try std.testing.expectEqual(@as(u64, 10), m.source_morphism);
    try std.testing.expectEqual(@as(u64, 20), m.target_morphism);
    try std.testing.expectEqual(REWRITE_EQUIVALENT, m.rewrite_type);
    // delta字段已从Morphism2结构体中移除
        try std.testing.expect(m.rewrite_type <= 6);
}

test "FFI错误常量可用性" {
    try std.testing.expectEqual(@as(i32, 0), FFI_SUCCESS);
    try std.testing.expectEqual(@as(i32, 1), FFI_INVALID_INPUT);
    try std.testing.expectEqual(@as(i32, 2), FFI_CONSISTENCY_VIOLATION);
    try std.testing.expectEqual(@as(i32, 3), FFI_ANCHOR_VIOLATION);
    try std.testing.expectEqual(@as(i32, 4), FFI_OUT_OF_MEMORY);
    try std.testing.expectEqual(@as(i32, 5), FFI_PERMISSION_DENIED);
}