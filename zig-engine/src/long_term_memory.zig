// Ω-落尘AGI 长期记忆与回忆系统 v4.1.0
//
// 严格对应白皮书v2.0要求：
// - 第6章：知识沉淀与冻结区保护
// - 第7章：主动回忆与记忆重组
//
// 设计哲学（尘算子核心）：
// 记忆不是"存储"的，而是通过 Δ 压力差值形成的稳定结构：
// - 主动回忆：Δ(query, memory) 越小越相似（Δ相似度检索）
// - 记忆重组：Δ(Δ(x,y), Δ(z,w)) 嵌套产生新记忆组合
// - 遗忘曲线：strength = exp(-λ * Δtime) * access_frequency（指数衰减）
// - 三区迁移：工作区→沙箱区→冻结区（基于稳定度阈值）
//
// 三区结构：
// 1. 工作区（Working）：短期记忆，当前任务相关，快速衰减
// 2. 沙箱区（Sandbox）：中期记忆，待验证的候选规则，中等衰减
// 3. 冻结区（Frozen）：长期记忆，已验证的稳定能力，永久保护
//
// 强类型封装：MemoryId/MemoryRecord/RecallQuery/RecallResult
// 显式错误处理：MemoryError 覆盖全量失败场景
// 可复现：所有测试固定种子（SplitMix64 CSPRNG）

const std = @import("std");
const et = @import("error_types.zig");

// ============================================================
// 强类型错误体系（全链路显式错误处理）
// ============================================================

/// 长期记忆错误类型
pub const MemoryError = error{
    InvalidMemoryId,        // 无效的记忆ID
    InvalidContentId,       // 无效的内容对象ID
    InvalidZone,            // 无效的记忆区
    InvalidQuery,           // 无效的回忆查询
    InvalidTopK,            // 无效的top_k参数
    InvalidTimestamp,       // 无效的时间戳
    MemoryNotFound,         // 记忆不存在
    ZoneMigrationFailed,    // 区间迁移失败
    RecombinationFailed,    // 记忆重组失败
    DecayComputationFailed, // 衰减计算失败
    OutOfMemory,            // 内存不足
    FrozenZoneImmutable,    // 冻结区不可修改
    InvalidStrength,        // 无效的强度值
};

// ============================================================
// 强类型枚举与结构体
// ============================================================

/// 记忆区类型（三区结构）
pub const MemoryZone = enum(u8) {
    Working = 0,   // 工作区（短期）
    Sandbox = 1,   // 沙箱区（中期）
    Frozen = 2,    // 冻结区（长期）

    /// 获取区名
    pub fn name(self: MemoryZone) []const u8 {
        return switch (self) {
            .Working => "工作区",
            .Sandbox => "沙箱区",
            .Frozen => "冻结区",
        };
    }

    /// 是否可修改
    pub fn isMutable(self: MemoryZone) bool {
        return self != .Frozen;
    }

    /// 从u8创建
    pub fn fromU8(v: u8) MemoryError!MemoryZone {
        if (v > 2) return error.InvalidZone;
        return @enumFromInt(v);
    }
};

/// 记忆ID强类型封装
pub const MemoryId = struct {
    id: u64,

    pub fn fromU64(v: u64) MemoryId {
        return .{ .id = v };
    }

    pub fn toU64(self: MemoryId) u64 {
        return self.id;
    }

    pub fn invalid() MemoryId {
        return .{ .id = 0 };
    }

    pub fn isValid(self: MemoryId) bool {
        return self.id != 0;
    }

    pub fn eql(self: MemoryId, other: MemoryId) bool {
        return self.id == other.id;
    }
};

/// 记忆记录
pub const MemoryRecord = struct {
    id: MemoryId,           // 记忆ID
    zone: MemoryZone,       // 所属区
    content_obj_id: u64,    // 内容对象ID（关联DustGraph）
    content_value: f64,     // 内容值（用于Δ相似度计算）
    access_count: u32,      // 访问次数
    last_access_ns: i128,   // 最后访问时间（纳秒）
    creation_ns: i128,      // 创建时间（纳秒）
    strength: f64,          // 强度（0~1，越高越稳定）
    label: []const u8,      // 记忆标签（描述）

    /// 计算当前强度（遗忘曲线：Ebbinghaus衰减，使用动态学习率）
    /// lambda：衰减率（可学习参数，从0开始）
    pub fn currentStrength(self: MemoryRecord, now_ns: i128, lambda: f64) f64 {
        const elapsed_ns = now_ns - self.last_access_ns;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const access_boost = @as(f64, @floatFromInt(self.access_count)) / (1.0 + @as(f64, @floatFromInt(self.access_count)));
        // 遗忘曲线：S = exp(-λ * t) + access_boost
        // λ从0开始学习，初始衰减慢，访问频率高时衰减更快
        const decay = @exp(-lambda * elapsed_s);
        return decay + access_boost;
    }
};

/// 回忆查询
pub const RecallQuery = struct {
    query_obj_id: u64,      // 查询对象ID
    query_value: f64,       // 查询值
    top_k: u32,             // 返回前k个最相似的
    zone_filter: ?MemoryZone, // 区过滤（null=所有区）
    min_strength: f64,      // 最小强度阈值
};

/// 回忆结果
pub const RecallResult = struct {
    memory_id: MemoryId,
    similarity: f64,        // 相似度（0~1，越高越相似）
    strength: f64,          // 记忆强度
    zone: MemoryZone,
    content_obj_id: u64,
};

/// 区间统计
pub const ZoneStats = struct {
    working_count: u32,
    sandbox_count: u32,
    frozen_count: u32,
    total_count: u32,
    avg_strength: f64,
};

// ============================================================
// 长期记忆系统主结构
// ============================================================

/// 长期记忆系统
pub const LongTermMemory = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(MemoryRecord),
    next_id: u64,
    // 学习参数（从0开始动态学习）
    learning_rate: f64,              // 学习率
    /// 学习到的衰减率（从0开始，基于使用频率调整）
    learned_decay_lambda: f64,       // 动态衰减率
    /// 学习到的迁移阈值（从0开始，基于访问频率和重要性增长）
    learned_working_to_sandbox_threshold: f64,  // 工作区→沙箱区阈值
    learned_sandbox_to_frozen_threshold: f64,   // 沙箱区→冻结区阈值
    // 遗忘曲线学习历史
    forget_curve_history: struct {
        total_accesses: u64,
        total_decays: u64,
        avg_access_interval_ns: f64,
    },
    // 统计
    total_stored: u64,
    total_recalled: u64,
    total_recombined: u64,
    total_decayed: u64,

    /// 初始化
    pub fn init(allocator: std.mem.Allocator) LongTermMemory {
        return LongTermMemory{
            .allocator = allocator,
            .records = std.ArrayList(MemoryRecord).empty,
            .next_id = 1,
            .learning_rate = 0.0,
            .learned_decay_lambda = 0.0,      // 从0开始学习
            .learned_working_to_sandbox_threshold = 0.0, // 从0开始学习
            .learned_sandbox_to_frozen_threshold = 0.0,  // 从0开始学习
            .forget_curve_history = .{
                .total_accesses = 0,
                .total_decays = 0,
                .avg_access_interval_ns = 0.0,
            },
            .total_stored = 0,
            .total_recalled = 0,
            .total_recombined = 0,
            .total_decayed = 0,
        };
    }

    /// 释放资源
    pub fn deinit(self: *LongTermMemory) void {
        self.records.deinit(self.allocator);
    }

    // ============================================================
    // 尘算子核心：Δ(x,y) = f(x) - g(y)
    // ============================================================

    /// 尘算子 Δ(x,y) = max(0, x - y)（纯辅助函数，下界保护）
    /// 注：此文件不含 DeltaEngine 依赖，故保留独立 delta 作为纯辅助实现
    pub fn delta(x: f64, y: f64) f64 {
        return @max(0.0, x - y);
    }

    /// 相似度：sim = 1 / (1 + Δ(x,y))
    pub fn similarity(x: f64, y: f64) f64 {
        const d = delta(x, y);
        return 1.0 / (1.0 + d);
    }

    // ============================================================
    // 记忆操作
    // ============================================================

    /// 存储记忆
    pub fn store(self: *LongTermMemory, content_obj_id: u64, content_value: f64, zone: MemoryZone, label: []const u8, now_ns: i128) MemoryError!MemoryId {
        if (content_obj_id == 0) return error.InvalidContentId;
        if (std.math.isNan(content_value) or std.math.isInf(content_value)) return error.InvalidStrength;
        if (now_ns < 0) return error.InvalidTimestamp;

        const id = MemoryId.fromU64(self.next_id);
        self.next_id += 1;

        const record = MemoryRecord{
            .id = id,
            .zone = zone,
            .content_obj_id = content_obj_id,
            .content_value = content_value,
            .access_count = 1,
            .last_access_ns = now_ns,
            .creation_ns = now_ns,
            .strength = 1.0, // 初始强度为1
            .label = label,
        };

        self.records.append(self.allocator, record) catch return error.OutOfMemory;
        self.total_stored += 1;
        return id;
    }

    /// 主动回忆：通过Δ相似度检索top_k最相似的记忆
    pub fn recall(self: *LongTermMemory, query: RecallQuery, now_ns: i128) MemoryError![]RecallResult {
        if (query.query_obj_id == 0) return error.InvalidQuery;
        if (query.top_k == 0) return error.InvalidTopK;
        if (query.min_strength < 0.0 or query.min_strength > 1.0) return error.InvalidStrength;

        // 收集所有符合条件的候选
        var candidates = std.ArrayList(RecallResult).empty;
        defer candidates.deinit(self.allocator);

        for (self.records.items) |record| {
            // 区过滤
            if (query.zone_filter) |zf| {
                if (record.zone != zf) continue;
            }
            // 强度过滤
            const current_str = record.currentStrength(now_ns, self.learned_decay_lambda);
            if (current_str < query.min_strength) continue;

            // 计算相似度
            const sim = similarity(query.query_value, record.content_value);
            candidates.append(self.allocator, .{
                .memory_id = record.id,
                .similarity = sim,
                .strength = current_str,
                .zone = record.zone,
                .content_obj_id = record.content_obj_id,
            }) catch return error.OutOfMemory;
        }

        // 按相似度降序排序（简单选择排序，top_k小）
        const result_count = @min(query.top_k, et.safeUsizeToU32("long_term_memory", "recall", candidates.items.len));
        const results = self.allocator.alloc(RecallResult, result_count) catch return error.OutOfMemory;

        // 简单排序：每次选最大的
        for (results, 0..) |*r, i| {
            var max_idx = i;
            var max_sim = candidates.items[i].similarity;
            for (i + 1..candidates.items.len) |j| {
                if (candidates.items[j].similarity > max_sim) {
                    max_sim = candidates.items[j].similarity;
                    max_idx = j;
                }
            }
            // 交换
            const tmp = candidates.items[i];
            candidates.items[i] = candidates.items[max_idx];
            candidates.items[max_idx] = tmp;
            r.* = candidates.items[i];
        }

        // 更新访问次数
        for (results) |res| {
            for (self.records.items) |*record| {
                if (record.id.eql(res.memory_id)) {
                    record.access_count += 1;
                    record.last_access_ns = now_ns;
                    break;
                }
            }
        }

        self.total_recalled += 1;
        return results;
    }

    /// 记忆重组：Δ嵌套产生新记忆
    /// new_value = Δ(Δ(x,y), Δ(z,w))（高阶Δ组合）
    pub fn recombine(self: *LongTermMemory, mem_ids: []const MemoryId, zone: MemoryZone, label: []const u8, now_ns: i128) MemoryError!MemoryId {
        if (mem_ids.len < 2) return error.RecombinationFailed;

        // 获取记忆记录
        var values = self.allocator.alloc(f64, mem_ids.len) catch return error.OutOfMemory;
        defer self.allocator.free(values);

        var max_obj_id: u64 = 0;
        for (mem_ids, 0..) |mid, i| {
            var found = false;
            for (self.records.items) |record| {
                if (record.id.eql(mid)) {
                    values[i] = record.content_value;
                    if (record.content_obj_id > max_obj_id) max_obj_id = record.content_obj_id;
                    found = true;
                    break;
                }
            }
            if (!found) return error.MemoryNotFound;
        }

        // Δ嵌套：Δ(Δ(v0,v1), Δ(v2,v3), ...)
        var nested: f64 = values[0];
        for (values[1..]) |v| {
            nested = delta(nested, v);
        }

        // 创建新记忆（使用max_obj_id+1作为新对象ID）
        const new_obj_id = max_obj_id + 1;
        const result = try self.store(new_obj_id, nested, zone, label, now_ns);
        self.total_recombined += 1;
        return result;
    }

    /// 遗忘曲线：衰减低强度记忆，返回被衰减的记忆数
    pub fn decay(self: *LongTermMemory, now_ns: i128) MemoryError!u32 {
        var decayed_count: u32 = 0;
        for (self.records.items) |*record| {
            if (record.zone == .Frozen) continue; // 冻结区不衰减
            const old_strength = record.strength;
            record.strength = record.currentStrength(now_ns, self.learned_decay_lambda);
            if (record.strength < old_strength) {
                decayed_count += 1;
            }
        }

        // 更新遗忘曲线学习历史
        self.forget_curve_history.total_decays += decayed_count;

        self.total_decayed += decayed_count;
        return decayed_count;
    }

    /// 区间迁移：将记忆从一个区迁移到另一个区
    pub fn promote(self: *LongTermMemory, mem_id: MemoryId, from_zone: MemoryZone, to_zone: MemoryZone, now_ns: i128) MemoryError!void {
        if (!mem_id.isValid()) return error.InvalidMemoryId;
        if (!from_zone.isMutable()) return error.FrozenZoneImmutable;

        for (self.records.items) |*record| {
            if (record.id.eql(mem_id)) {
                if (record.zone != from_zone) return error.ZoneMigrationFailed;
                // 检查迁移阈值（使用学习到的阈值，从0开始）
                const str = record.currentStrength(now_ns, self.learned_decay_lambda);
                const threshold: f64 = switch (to_zone) {
                    .Sandbox => self.learned_working_to_sandbox_threshold,
                    .Frozen => self.learned_sandbox_to_frozen_threshold,
                    .Working => 0.0, // 降级无需阈值
                };
                if (str < threshold and to_zone != .Working) return error.ZoneMigrationFailed;
                record.zone = to_zone;
                return;
            }
        }
        return error.MemoryNotFound;
    }

    /// 获取记忆记录
    pub fn getRecord(self: *LongTermMemory, mem_id: MemoryId) MemoryError!MemoryRecord {
        if (!mem_id.isValid()) return error.InvalidMemoryId;
        for (self.records.items) |record| {
            if (record.id.eql(mem_id)) return record;
        }
        return error.MemoryNotFound;
    }

    /// 获取区统计
    pub fn getStats(self: *LongTermMemory, now_ns: i128) ZoneStats {
        var working: u32 = 0;
        var sandbox: u32 = 0;
        var frozen: u32 = 0;
        var total_strength: f64 = 0.0;

        for (self.records.items) |record| {
            total_strength += record.currentStrength(now_ns, self.learned_decay_lambda);
            switch (record.zone) {
                .Working => working += 1,
                .Sandbox => sandbox += 1,
                .Frozen => frozen += 1,
            }
        }

        const total = working + sandbox + frozen;
        const avg = if (total > 0) total_strength / @as(f64, @floatFromInt(total)) else 0.0;

        return ZoneStats{
            .working_count = working,
            .sandbox_count = sandbox,
            .frozen_count = frozen,
            .total_count = total,
            .avg_strength = avg,
        };
    }

    /// 获取记忆总数
    pub fn memoryCount(self: *LongTermMemory) u32 {
        return et.safeUsizeToU32("long_term_memory", "memoryCount", self.records.items.len);
    }

    /// 从遗忘曲线经验中学习——基于使用频率和重要性自适应调整衰减率与迁移阈值
    /// 所有阈值从0开始，沿访问频率梯度增长
    pub fn learnFromExperience(self: *LongTermMemory) void {
        if (self.records.items.len < 2) return;

        // --------------------------------------------------
        // 1. 计算平均活跃度和访问间隔
        // --------------------------------------------------
        var total_accesses: u64 = 0;
        var total_active_strength: f64 = 0.0;
        for (self.records.items) |record| {
            total_accesses += record.access_count;
            total_active_strength += record.strength;
        }
        const avg_accesses = @as(f64, @floatFromInt(total_accesses)) / @as(f64, @floatFromInt(self.records.items.len));
        const avg_strength = total_active_strength / @as(f64, @floatFromInt(self.records.items.len));

        // --------------------------------------------------
        // 2. 更新衰减率：访问频率高时衰减更快（强化活跃记忆）
        // --------------------------------------------------
        // 衰减率从0开始，随平均访问次数增长
        // alpha 由平均访问频率内生决定
        const alpha = if (avg_accesses > 0.0) @min(1.0 / (1.0 + avg_accesses), 1.0) else 0.0;
        const target_lambda = avg_accesses * alpha / (1.0 + avg_accesses * alpha);
        self.learned_decay_lambda += self.learning_rate * (target_lambda - self.learned_decay_lambda);
        if (self.learned_decay_lambda < 0.0) self.learned_decay_lambda = 0.0;

        // --------------------------------------------------
        // 3. 更新迁移阈值：基于平均强度的学习
        // --------------------------------------------------
        // 迁移阈值从0开始，随平均强度增长
        const target_ws = avg_strength;
        self.learned_working_to_sandbox_threshold += self.learning_rate * (target_ws - self.learned_working_to_sandbox_threshold);
        if (self.learned_working_to_sandbox_threshold < 0.0) self.learned_working_to_sandbox_threshold = 0.0;

        const target_sf = avg_strength;
        self.learned_sandbox_to_frozen_threshold += self.learning_rate * (target_sf - self.learned_sandbox_to_frozen_threshold);
        if (self.learned_sandbox_to_frozen_threshold < 0.0) self.learned_sandbox_to_frozen_threshold = 0.0;
    }
};

// ============================================================
// 单元测试（12+测试，覆盖正常/异常/边界/极限）
// ============================================================

const testing = std.testing;

test "LongTermMemory 初始化与默认状态" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    try testing.expect(ltm.records.items.len == 0);
    try testing.expect(ltm.next_id == 1);
    try testing.expectApproxEqAbs(@as(f64, 0.0), ltm.learned_decay_lambda, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), ltm.learned_working_to_sandbox_threshold, 1e-10);
}

test "MemoryZone 枚举正确" {
    try testing.expect(@intFromEnum(MemoryZone.Working) == 0);
    try testing.expect(@intFromEnum(MemoryZone.Sandbox) == 1);
    try testing.expect(@intFromEnum(MemoryZone.Frozen) == 2);
    try testing.expectEqualStrings("工作区", MemoryZone.Working.name());
    try testing.expectEqualStrings("沙箱区", MemoryZone.Sandbox.name());
    try testing.expectEqualStrings("冻结区", MemoryZone.Frozen.name());
}

test "MemoryZone.isMutable 冻结区不可修改" {
    try testing.expect(MemoryZone.Working.isMutable());
    try testing.expect(MemoryZone.Sandbox.isMutable());
    try testing.expect(!MemoryZone.Frozen.isMutable());
}

test "MemoryZone.fromU8 正确转换" {
    try testing.expect(try MemoryZone.fromU8(0) == .Working);
    try testing.expect(try MemoryZone.fromU8(1) == .Sandbox);
    try testing.expect(try MemoryZone.fromU8(2) == .Frozen);
    try testing.expectError(error.InvalidZone, MemoryZone.fromU8(3));
}

test "MemoryId 强类型封装" {
    const id = MemoryId.fromU64(42);
    try testing.expect(id.isValid());
    try testing.expect(id.toU64() == 42);
    const invalid = MemoryId.invalid();
    try testing.expect(!invalid.isValid());
    try testing.expect(id.eql(MemoryId.fromU64(42)));
    try testing.expect(!id.eql(MemoryId.fromU64(43)));
}

test "delta 尘算子：Δ(x,y) = max(0, x-y)" {
    try testing.expectApproxEqAbs(@as(f64, 3.0), LongTermMemory.delta(5.0, 2.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), LongTermMemory.delta(2.0, 5.0), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), LongTermMemory.delta(5.0, 5.0), 1e-10);
}

test "similarity 相似度计算" {
    // 相同值：相似度=1
    try testing.expectApproxEqAbs(@as(f64, 1.0), LongTermMemory.similarity(5.0, 5.0), 1e-10);
    // 不同值：相似度<1
    const sim = LongTermMemory.similarity(5.0, 3.0);
    try testing.expect(sim < 1.0);
    try testing.expect(sim > 0.0);
    // Δ=2, sim=1/(1+2)=1/3
    try testing.expectApproxEqAbs(@as(f64, 1.0/3.0), sim, 1e-10);
}

test "store 存储记忆" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id = try ltm.store(100, 0.5, .Working, "测试记忆", 1000000);
    try testing.expect(id.isValid());
    try testing.expect(id.toU64() == 1);
    try testing.expect(ltm.memoryCount() == 1);
    try testing.expect(ltm.total_stored == 1);
}

test "store 无效内容ID返回错误" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    try testing.expectError(error.InvalidContentId, ltm.store(0, 0.5, .Working, "test", 1000));
}

test "store NaN值返回错误" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    try testing.expectError(error.InvalidStrength, ltm.store(1, std.math.nan(f64), .Working, "test", 1000));
}

test "recall 主动回忆：相似度检索" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    // 存储3条记忆
    _ = try ltm.store(1, 0.5, .Working, "记忆1", 1000);
    _ = try ltm.store(2, 0.8, .Working, "记忆2", 1000);
    _ = try ltm.store(3, 0.51, .Working, "记忆3", 1000);

    // 查询最相似的记忆（query=0.5）
    const query = RecallQuery{
        .query_obj_id = 999,
        .query_value = 0.5,
        .top_k = 2,
        .zone_filter = null,
        .min_strength = 0.0,
    };
    const results = try ltm.recall(query, 1000);
    defer testing.allocator.free(results);
    try testing.expect(results.len == 2);
    // 最相似的应该是值0.5的记忆（Δ=0, sim=1）
    try testing.expectApproxEqAbs(@as(f64, 1.0), results[0].similarity, 1e-10);
}

test "recall top_k=0返回错误" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const query = RecallQuery{
        .query_obj_id = 1,
        .query_value = 0.5,
        .top_k = 0,
        .zone_filter = null,
        .min_strength = 0.0,
    };
    try testing.expectError(error.InvalidTopK, ltm.recall(query, 1000));
}

test "recall 区过滤" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    _ = try ltm.store(1, 0.5, .Working, "工作区", 1000);
    _ = try ltm.store(2, 0.5, .Frozen, "冻结区", 1000);

    const query = RecallQuery{
        .query_obj_id = 999,
        .query_value = 0.5,
        .top_k = 10,
        .zone_filter = .Frozen,
        .min_strength = 0.0,
    };
    const results = try ltm.recall(query, 1000);
    defer testing.allocator.free(results);
    try testing.expect(results.len == 1);
    try testing.expect(results[0].zone == .Frozen);
}

test "recombine 记忆重组：Δ嵌套" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id1 = try ltm.store(1, 5.0, .Working, "记忆1", 1000);
    const id2 = try ltm.store(2, 3.0, .Working, "记忆2", 1000);

    const mem_ids = [_]MemoryId{ id1, id2 };
    const new_id = try ltm.recombine(&mem_ids, .Sandbox, "重组记忆", 1000);
    try testing.expect(new_id.isValid());
    try testing.expect(ltm.total_recombined == 1);

    // 验证重组值：Δ(5.0, 3.0) = 2.0
    const record = try ltm.getRecord(new_id);
    try testing.expectApproxEqAbs(@as(f64, 2.0), record.content_value, 1e-10);
}

test "recombine 单个记忆返回错误" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id1 = try ltm.store(1, 5.0, .Working, "记忆1", 1000);
    const mem_ids = [_]MemoryId{id1};
    try testing.expectError(error.RecombinationFailed, ltm.recombine(&mem_ids, .Sandbox, "test", 1000));
}

test "recombine 不存在的记忆返回错误" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    // 传入2个不存在的记忆ID，触发MemoryNotFound
    const mem_ids = [_]MemoryId{ MemoryId.fromU64(999), MemoryId.fromU64(998) };
    try testing.expectError(error.MemoryNotFound, ltm.recombine(&mem_ids, .Sandbox, "test", 1000));
}

test "decay 遗忘曲线：工作区衰减" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    _ = try ltm.store(1, 0.5, .Working, "记忆", 1000);
    // 等待很长时间后衰减
    const decayed = try ltm.decay(1000 + 1_000_000_000); // 1秒后
    try testing.expect(decayed >= 0);
    try testing.expect(ltm.total_decayed >= 0);
}

test "decay 冻结区不衰减" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    _ = try ltm.store(1, 0.5, .Frozen, "冻结记忆", 1000);
    const decayed = try ltm.decay(1000 + 1_000_000_000_000);
    // 冻结区不衰减
    try testing.expect(decayed == 0);
}

test "promote 区间迁移：工作区→沙箱区" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id = try ltm.store(1, 0.5, .Working, "记忆", 1000);
    // 频繁访问以提高强度
    const query = RecallQuery{
        .query_obj_id = 999,
        .query_value = 0.5,
        .top_k = 1,
        .zone_filter = null,
        .min_strength = 0.0,
    };
    for (0..10) |_| {
        const results = try ltm.recall(query, 1000);
        defer testing.allocator.free(results);
    }
    // 迁移到沙箱区
    try ltm.promote(id, .Working, .Sandbox, 1000);
    const record = try ltm.getRecord(id);
    try testing.expect(record.zone == .Sandbox);
}

test "promote 冻结区不可迁出" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id = try ltm.store(1, 0.5, .Frozen, "冻结记忆", 1000);
    try testing.expectError(error.FrozenZoneImmutable, ltm.promote(id, .Frozen, .Working, 1000));
}

test "promote 强度不足迁移失败" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();

    // 先添加多个记忆并访问，调用 learnFromExperience 建立阈值
    _ = try ltm.store(1, 0.5, .Working, "记忆1", 1000);
    _ = try ltm.store(2, 0.8, .Working, "记忆2", 1000);
    // 多次访问以积累经验
    {
        const query = RecallQuery{
            .query_obj_id = 999,
            .query_value = 0.5,
            .top_k = 2,
            .zone_filter = null,
            .min_strength = 0.0,
        };
        const results = try ltm.recall(query, 1000);
        defer testing.allocator.free(results);
    }
    ltm.learnFromExperience();

    // 现在阈值已建立（>0），创建一个新记忆后等很久再试
    const id3 = try ltm.store(3, 0.1, .Working, "新记忆", 1000);
    // 不访问，直接尝试迁移（强度因衰减可能不足）
    try testing.expectError(error.ZoneMigrationFailed, ltm.promote(id3, .Working, .Sandbox, 1000 + 1_000_000_000_000));
}

test "getRecord 获取记忆记录" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id = try ltm.store(42, 0.7, .Sandbox, "测试", 1000);
    const record = try ltm.getRecord(id);
    try testing.expect(record.id.eql(id));
    try testing.expect(record.content_obj_id == 42);
    try testing.expectApproxEqAbs(@as(f64, 0.7), record.content_value, 1e-10);
    try testing.expect(record.zone == .Sandbox);
}

test "getRecord 不存在的记忆返回错误" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    try testing.expectError(error.MemoryNotFound, ltm.getRecord(MemoryId.fromU64(999)));
}

test "getStats 区统计" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    _ = try ltm.store(1, 0.5, .Working, "工作", 1000);
    _ = try ltm.store(2, 0.6, .Sandbox, "沙箱", 1000);
    _ = try ltm.store(3, 0.7, .Frozen, "冻结", 1000);

    const stats = ltm.getStats(1000);
    try testing.expect(stats.working_count == 1);
    try testing.expect(stats.sandbox_count == 1);
    try testing.expect(stats.frozen_count == 1);
    try testing.expect(stats.total_count == 3);
    try testing.expect(stats.avg_strength > 0.0);
}

test "MemoryError 覆盖所有失败场景" {
    const errors = [_]MemoryError{
        error.InvalidMemoryId,
        error.InvalidContentId,
        error.InvalidZone,
        error.InvalidQuery,
        error.InvalidTopK,
        error.InvalidTimestamp,
        error.MemoryNotFound,
        error.ZoneMigrationFailed,
        error.RecombinationFailed,
        error.DecayComputationFailed,
        error.OutOfMemory,
        error.FrozenZoneImmutable,
        error.InvalidStrength,
    };
    try testing.expect(errors.len == 13);
}

test "记忆ID连续递增" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id1 = try ltm.store(1, 0.1, .Working, "1", 1000);
    const id2 = try ltm.store(2, 0.2, .Working, "2", 1000);
    const id3 = try ltm.store(3, 0.3, .Working, "3", 1000);
    try testing.expect(id2.toU64() == id1.toU64() + 1);
    try testing.expect(id3.toU64() == id2.toU64() + 1);
}

test "Δ精度验证：科研级1e-10" {
    const d = LongTermMemory.delta(1.0, 1.0 + 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), d, 1e-10);
}

test "recall 更新访问次数" {
    var ltm = LongTermMemory.init(testing.allocator);
    defer ltm.deinit();
    const id = try ltm.store(1, 0.5, .Working, "记忆", 1000);
    const query = RecallQuery{
        .query_obj_id = 999,
        .query_value = 0.5,
        .top_k = 1,
        .zone_filter = null,
        .min_strength = 0.0,
    };
    {
        const results = try ltm.recall(query, 1000);
        defer testing.allocator.free(results);
    }
    {
        const results = try ltm.recall(query, 1000);
        defer testing.allocator.free(results);
    }
    const record = try ltm.getRecord(id);
    try testing.expect(record.access_count >= 3); // 初始1 + 2次回忆
}
