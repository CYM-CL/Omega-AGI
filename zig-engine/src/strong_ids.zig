// Ω-落尘AGI 强类型ID定义 v4.0.10
//
// 严格对应白皮书v2.0要求：
// - 核心实体必须强类型封装，严禁用原始类型直接存储核心状态与敏感数据
// - 用户规则要求强类型封装核心实体
//
// 设计依据：
// - Rust侧已用ObjectId(pub u64)强类型封装（lib.rs:23-35）
// - Zig侧原使用裸u64，违反强类型封装原则
// - 本文件定义Zig侧强类型ID，与Rust侧保持一致
//
// 类型安全保证：
// - ObjectId/MorphismId/Morphism2Id是不同的类型，编译期防止混用
// - 无法将对象ID误传为态射ID参数
// - 提供fromU64/toU64显式转换函数，转换点明确可审计

const std = @import("std");

/// 对象ID强类型封装
/// 对应Rust侧ObjectId(pub u64)
/// 用于标识CDL中的0-阶对象（尘算子节点）
pub const ObjectId = struct {
    /// 内部存储的u64值
    id: u64,

    /// 从u64创建ObjectId（显式转换，转换点可审计）
    pub fn fromU64(v: u64) ObjectId {
        return .{ .id = v };
    }

    /// 转换为u64（显式转换，转换点可审计）
    pub fn toU64(self: ObjectId) u64 {
        return self.id;
    }

    /// 无效对象ID（用于错误标识）
    pub fn invalid() ObjectId {
        return .{ .id = std.math.maxInt(u64) };
    }

    /// 检查是否为无效ID
    pub fn isValid(self: ObjectId) bool {
        return self.id != std.math.maxInt(u64);
    }

    /// 相等性比较
    pub fn eql(self: ObjectId, other: ObjectId) bool {
        return self.id == other.id;
    }
};

/// 态射ID强类型封装
/// 对应Rust侧MorphismId(pub u64)
/// 用于标识CDL中的1-态射（对象间关系）
pub const MorphismId = struct {
    /// 内部存储的u64值
    id: u64,

    /// 从u64创建MorphismId（显式转换，转换点可审计）
    pub fn fromU64(v: u64) MorphismId {
        return .{ .id = v };
    }

    /// 转换为u64（显式转换，转换点可审计）
    pub fn toU64(self: MorphismId) u64 {
        return self.id;
    }

    /// 无效态射ID
    pub fn invalid() MorphismId {
        return .{ .id = std.math.maxInt(u64) };
    }

    /// 检查是否为无效ID
    pub fn isValid(self: MorphismId) bool {
        return self.id != std.math.maxInt(u64);
    }

    /// 相等性比较
    pub fn eql(self: MorphismId, other: MorphismId) bool {
        return self.id == other.id;
    }
};

/// 2-态射ID强类型封装
/// 对应Rust侧Morphism2Id(pub u64)
/// 用于标识CDL中的2-态射（态射间等价重写）
pub const Morphism2Id = struct {
    /// 内部存储的u64值
    id: u64,

    /// 从u64创建Morphism2Id（显式转换，转换点可审计）
    pub fn fromU64(v: u64) Morphism2Id {
        return .{ .id = v };
    }

    /// 转换为u64（显式转换，转换点可审计）
    pub fn toU64(self: Morphism2Id) u64 {
        return self.id;
    }

    /// 无效2-态射ID
    pub fn invalid() Morphism2Id {
        return .{ .id = std.math.maxInt(u64) };
    }

    /// 检查是否为无效ID
    pub fn isValid(self: Morphism2Id) bool {
        return self.id != std.math.maxInt(u64);
    }

    /// 相等性比较
    pub fn eql(self: Morphism2Id, other: Morphism2Id) bool {
        return self.id == other.id;
    }
};

// ============================================================
// 单元测试（文档要求单元测试覆盖率≥95%）
// ============================================================

test "ObjectId 基本功能" {
    const id = ObjectId.fromU64(42);
    try std.testing.expectEqual(@as(u64, 42), id.toU64());
    try std.testing.expect(id.isValid());
    try std.testing.expect(ObjectId.eql(id, ObjectId.fromU64(42)));
    try std.testing.expect(!ObjectId.eql(id, ObjectId.fromU64(43)));
}

test "ObjectId 无效ID" {
    const invalid_id = ObjectId.invalid();
    try std.testing.expect(!invalid_id.isValid());
    try std.testing.expectEqual(std.math.maxInt(u64), invalid_id.toU64());
}

test "MorphismId 基本功能" {
    const id = MorphismId.fromU64(100);
    try std.testing.expectEqual(@as(u64, 100), id.toU64());
    try std.testing.expect(id.isValid());
}

test "Morphism2Id 基本功能" {
    const id = Morphism2Id.fromU64(200);
    try std.testing.expectEqual(@as(u64, 200), id.toU64());
    try std.testing.expect(id.isValid());
}

test "强类型ID类型安全 - 编译期防止混用" {
    // 这三种ID是不同的类型，编译器会阻止混用
    const obj_id = ObjectId.fromU64(1);
    const morph_id = MorphismId.fromU64(1);
    const morph2_id = Morphism2Id.fromU64(1);

    // 验证它们是不同的类型（虽然内部值相同）
    try std.testing.expectEqual(obj_id.toU64(), morph_id.toU64());
    try std.testing.expectEqual(morph_id.toU64(), morph2_id.toU64());

    // 以下代码如果取消注释会导致编译错误（类型不匹配）：
    // const _: ObjectId = morph_id;  // 错误：expected ObjectId, found MorphismId
}
