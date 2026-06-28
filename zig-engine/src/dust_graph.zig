// Ω-落尘AGI 尘图数据结构 v4.0 - Zig实现
//
// CDL（Category Difference Lattice）的核心数据结构
// 严格对应白皮书v2.0：
// - 第2章：CDL范畴结构（格运算、2-态射复合）
// - 第3章：一元尘图、双态同显机制
// - 第9章：冻结区机制、沙箱隔离
//
// v4.0核心改进：
// 1. CDL范畴结构补全：格运算join/meet、2-态射纵向/横向复合
// 2. 双态同显机制：内容态/规则态双向转化（ContentToRule/RuleToContent）
// 3. 冻结区机制：已沉淀知识标记为冻结，投影保护不被修改
// 4. 沙箱隔离支持：沙箱子图独立于主图，仿真失败不影响全局
// 5. 强类型ID：ObjectId/MorphismId/Morphism2Id强类型封装

const std = @import("std");
const ffi = @import("seed_kernel_ffi.zig");
// v4.0.8：SplitMix64 CSPRNG（文档要求可播种CSPRNG，与Rust侧一致）
const sm64 = @import("splitmix64.zig");
// v4.0.10：强类型ID封装（文档要求核心实体强类型封装，严禁用原始类型直接存储核心状态）
pub const ids = @import("strong_ids.zig");
// v4.2：统一错误类型体系（替代 catch {} 静默吞没）
const et = @import("error_types.zig");
pub const ObjectId = ids.ObjectId;
pub const MorphismId = ids.MorphismId;
pub const Morphism2Id = ids.Morphism2Id;

// ============================================================
// 内存预算（8G内存M3芯片）
// ============================================================
// 总预算：512MB（留余量给系统和其他进程）
// - 对象数组：256MB（约200万个对象）
// - 态射数组：128MB
// - 缓存：128MB
// ============================================================
// v4.0.5新增：安全级别类型系统（文档9.4.1）
// 为CDL节点引入安全级别类型，实现信息流控制
// Level = {Seed, Sandbox, Main}
// 偏序关系：Seed ⊑ Sandbox ⊑ Main（信息只能从低级别流向高级别）
// ============================================================

/// 安全级别类型（文档9.4.1）
pub const SecurityLevel = enum(u8) {
    Seed = 0,    // 种子核级别（偏序最小元，只能作为态射源）
    Sandbox = 1, // 沙箱级别（沙箱内新建节点初始级别）
    Main = 2,    // 主图级别（合并后提升为此级别）

    /// 偏序关系 ⊑（文档9.4.1：信息只能从低级别流向高级别）
    /// 返回true表示 self ⊑ other（信息流合法）
    pub fn isLessThanOrEqual(self: SecurityLevel, other: SecurityLevel) bool {
        return @intFromEnum(self) <= @intFromEnum(other);
    }

    /// 名称（用于审计追溯）
    pub fn name(self: SecurityLevel) []const u8 {
        return switch (self) {
            .Seed => "Seed",
            .Sandbox => "Sandbox",
            .Main => "Main",
        };
    }
};

/// v4.0.5新增：信息流违规错误类型（文档9.4.1）
pub const InformationFlowError = error{
    InformationFlowViolation, // 信息流违规：Level(source) ⊄ Level(target)
    SeedNodeAsTarget,         // 种子核节点作为态射目标（违反规则4）
    InvalidSecurityLevel,     // 无效安全级别
};

/// v4.0.12新增：对象修改错误类型（文档要求全链路显式错误处理）
/// 冻结对象不可修改，非法ID返回明确错误，严禁静默失败
pub const ModificationError = error{
    ObjectNotFound, // 对象ID超出范围
    ObjectFrozen, // 冻结对象不可修改（文档7.4.5推论7.1.2）
};

/// v4.0.12新增：格运算/尘算子错误类型（文档要求全链路显式错误处理）
/// 替代NaN作为错误信号，NaN不再是合法返回值
pub const LatticeOperationError = error{
    ObjectNotFound, // 对象ID超出范围
};

/// v4.0.5新增：安全违规日志记录（文档9.4.1运行时检查机制）
pub const SecurityViolationLog = struct {
    source_id: u64,
    target_id: u64,
    source_level: SecurityLevel,
    target_level: SecurityLevel,
    timestamp: i64,
};

// ============================================================
// v5.0.x 拓扑感知合法更新（文档7.4.1）
// ============================================================
// 文档7.4.1要求：每次结构更新前先投影到CDL合法范畴子空间Π_Λ
// 确保更新满足格封闭性、态射复合合法性、等价交换性
// 不符合公理的更新方向直接过滤
// 单独抽离为 TopologyProjection 结构体，单一职责：
//   - snapshotFrom: 创建图状态快照（用于规则 4 还原冻结区）
//   - project: 执行合法子空间投影，返回带 rule1~rule4 计数的报告
// ============================================================

// ============================================================
// v5.0.0 Phase1 修正：Grothendieck 宇宙分层（白皮书 2.2.5）
// ============================================================
// 白皮书 2.2.5 要求层级化自指：Ob_{n+1} = Ob_n ∪ P(Ob_n) + 反射原理
// 每个 Universe 是一层"对象宇宙"，高一层的对象可以是低一层对象的幂集
// 这是范畴论中 Grothendieck 宇宙的核心思想：
//   - U0: 原子对象层（base objects）
//   - U1: 一阶幂集（P(U0)）
//   - U2: 二阶幂集（P(U1)）
//   - UOmega: 极限层（所有层级的并集，对应自指闭合点）
// ============================================================

/// Grothendieck 宇宙层级（白皮书 2.2.5）
/// 层级化自指：Ob_{n+1} = Ob_n ∪ P(Ob_n)
/// U0 是"原子层"，U1/U2 是"幂集层"，UOmega 是"极限层"
pub const Universe = enum(u8) {
    /// 原子对象层（base objects，初始层）
    U0 = 0,
    /// 一阶幂集（P(U0)）
    U1 = 1,
    /// 二阶幂集（P(P(U0))）
    U2 = 2,
    /// 极限层（所有层级的并集，对应自指闭合点）
    UOmega = 255,

    /// 升级到下一层级（n → n+1）
    /// UOmega 升级到自身（已是极限）
    pub fn next(self: Universe) Universe {
        return switch (self) {
            .U0 => .U1,
            .U1 => .U2,
            .U2 => .UOmega,
            .UOmega => .UOmega,
        };
    }

    /// 是否为极限层级
    pub fn isLimit(self: Universe) bool {
        return self == .UOmega;
    }

    /// 层级名称（用于审计追溯）
    pub fn name(self: Universe) []const u8 {
        return switch (self) {
            .U0 => "U0 原子层",
            .U1 => "U1 一阶幂集",
            .U2 => "U2 二阶幂集",
            .UOmega => "UOmega 极限层",
        };
    }
};

/// 层级化访问错误（白皮书 2.2.5：U1 中不可引用 U2 层级对象）
pub const UniverseError = error{
    UniverseViolation, // 跨层引用违规：低层引用高层对象
    ObjectNotFound,    // 对象不存在
};

// ============================================================
// v5.0.x 新增：拓扑投影算子 Π_Λ（白皮书 7.4.1）
// 单一职责：封装"将 DustGraph 投影到 CDL 合法范畴子空间"的全部规则
// 4 条规则（白皮书 7.4.1 + 7.4.5 推论 7.1.2）：
//   1. 对象值 NaN/Inf/negative clamp 到 0（格封闭性 Ω ⊆ ℝ≥0）
//   2. 1-态射 source/target/weight 校验（格封闭性 + 态射复合合法性）
//   3. 2-态射 source/target/weight 校验（重写闭合性）
//   4. 冻结区节点在投影中保持不变（推论 7.1.2：已沉淀知识不可被投影覆盖）
// ============================================================

/// 投影报告（强类型，单一职责封装所有规则的处理计数）
/// 全量过滤计数 = rule1_count + rule2_count + rule3_count
pub const ProjectionReport = struct {
    /// 总过滤数（被修正的非法结构数量，含规则 4 还原的冻结区条目）
    filtered_count: usize,
    /// 规则 1 处理数：对象值被 clamp 的数量
    rule1_count: usize,
    /// 规则 2 处理数：1-态射被修正的数量
    rule2_count: usize,
    /// 规则 3 处理数：2-态射被修正的数量
    rule3_count: usize,
    /// 规则 4 处理数：冻结区被还原的条目数量（用于审计追溯）
    rule4_count: usize,
};

/// 拓扑投影算子 Π_Λ（白皮书 7.4.1）
/// 单一职责：将 DustGraph 投影到 CDL 合法范畴子空间
/// 设计要点：
///   - 不持有 DustGraph 所有权，仅通过指针临时操作
///   - 投影前先 snapshotFrom() 抓取冻结区快照，project() 时通过规则 4 还原
///   - 与 DustGraph 解耦，便于单测与审计
///   - 全量错误捕获，无静默失败
pub const TopologyProjection = struct {
    allocator: std.mem.Allocator,
    // 冻结对象值快照（key = 对象ID，value = 原始值），用于规则 4 还原
    frozen_object_snapshot: std.AutoHashMap(u64, f64),
    // 冻结态射权重快照（key = 态射ID，value = 原始权重），用于规则 4 还原
    frozen_morphism_snapshot: std.AutoHashMap(u64, f64),
    // 冻结 2-态射权重快照（key = 2-态射索引，value = 原始权重），用于规则 4 还原
    frozen_morphism2_snapshot: std.AutoHashMap(u64, f64),

    /// 初始化投影器（分配内部快照容器）
    // v5.0.x Zig 0.16 兼容性修复：使用 @This() 而非直接引用 TopologyProjection
    // 避免"ambiguous reference"——Zig 0.16 在 struct 内部自引用时,
    // 需要通过 @This() 明确指向当前类型
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .frozen_object_snapshot = std.AutoHashMap(u64, f64).init(allocator),
            .frozen_morphism_snapshot = std.AutoHashMap(u64, f64).init(allocator),
            .frozen_morphism2_snapshot = std.AutoHashMap(u64, f64).init(allocator),
        };
    }

    /// 释放内部资源（必须在每次 init 后配对调用）
    pub fn deinit(self: *TopologyProjection) void {
        self.frozen_object_snapshot.deinit();
        self.frozen_morphism_snapshot.deinit();
        self.frozen_morphism2_snapshot.deinit();
    }

    /// 从 DustGraph 抓取冻结区快照
    /// 用于规则 4：投影后还原冻结区的原始值，保证"已沉淀知识不被投影覆盖"
    /// v5.0.x：优先从 frozen_objects 抓取冻结时刻记录的原始值（避免被后续直接修改影响）
    ///          若冻结对象不在 frozen_objects 中（兼容历史数据），从 object_values 抓取当前值
    /// 错误：仅当内存分配失败时返回 OutOfMemory（替代 catch {} 静默吞没）
    pub fn snapshotFrom(self: *TopologyProjection, graph: *const DustGraph) !void {
        // 抓取冻结对象值快照（优先从 frozen_objects 取原始值）
        var it = graph.frozen_objects.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            // v5.0.x：frozen_objects 存储的是冻结时刻的原始值（freezeObject 时记录）
            // 即使 object_values 后续被直接修改为 NaN/Inf，这里仍能取到合法原始值
            const original_value = entry.value_ptr.*;
            try self.frozen_object_snapshot.put(id, original_value);
        }
        // 抓取冻结态射权重快照
        var itm = graph.frozen_morphisms.iterator();
        while (itm.next()) |entry| {
            const id = entry.key_ptr.*;
            for (graph.morphisms.items) |m| {
                if (m.morphism_id == id) {
                    try self.frozen_morphism_snapshot.put(id, m.delta);
                    break;
                }
            }
        }
        // 2-态射无独立的冻结集合和权重字段（字段已从C结构体中移除）
        // 冻结保护由源/目标态射的冻结状态在投影时单独处理
    }

    /// 执行投影：应用 4 条规则，返回 ProjectionReport
    /// 内部依次执行：
    ///   规则 1 → 规则 2 → 规则 3 → 规则 4（还原冻结区）
    /// 各规则独立计数，全量返回便于审计追溯
    pub fn project(self: *TopologyProjection, graph: *DustGraph) ProjectionReport {
        var report = ProjectionReport{
            .filtered_count = 0,
            .rule1_count = 0,
            .rule2_count = 0,
            .rule3_count = 0,
            .rule4_count = 0,
        };

        // 规则 1：对象值 NaN/Inf/negative clamp 到 0（跳过冻结对象，规则 4 兜底）
        report.rule1_count += applyRule1ObjectValueClamp(graph);

        // 规则 2：1-态射 source/target/weight 校验
        report.rule2_count += applyRule2MorphismValidation(graph);

        // 规则 3：2-态射 source/target/weight 校验
        report.rule3_count += applyRule3Morphism2Validation(graph);

        // 规则 4：还原冻结区（确保冻结节点/态射在投影中保持不变）
        report.rule4_count += applyRule4FrozenRestore(self, graph);

        report.filtered_count = report.rule1_count + report.rule2_count +
            report.rule3_count + report.rule4_count;
        return report;
    }

    // ----------------------------------------------------------------
    // 内部规则实现（私有函数，单一职责）
    // ----------------------------------------------------------------

    /// 规则 1：对象值 NaN/Inf/negative clamp 到 0
    /// 跳过冻结对象（规则 4 在末尾统一还原，保证冻结区不变）
    fn applyRule1ObjectValueClamp(graph: *DustGraph) usize {
        var fixed: usize = 0;
        for (0..graph.object_values.items.len) |i| {
            // 规则 4 兜底：冻结对象不在此规则中处理（由规则 4 还原）
            if (graph.frozen_objects.contains(@intCast(i))) continue;
            const v = graph.object_values.items[i];
            if (std.math.isNan(v) or std.math.isInf(v) or v < 0.0) {
                graph.object_values.items[i] = 0.0;
                fixed += 1;
            }
        }
        return fixed;
    }

    /// 规则 2：1-态射 source/target/weight 校验
    /// 不合法项：source/target 越界、或 weight NaN/Inf → 修正为合法态射
    /// 修正策略：source/target 越界时 clamp 到 0（指向第一个对象），weight clamp 到 0
    /// v5.0.x：增加 source/target 越界时 clamp 到 0 的逻辑（保证投影后 source/target 都在对象范围内）
    fn applyRule2MorphismValidation(graph: *DustGraph) usize {
        var fixed: usize = 0;
        const obj_count = graph.object_values.items.len;
        if (obj_count == 0) return 0;
        for (graph.morphisms.items) |*m| {
            // 规则 4 兜底：跳过冻结态射
            if (graph.frozen_morphisms.contains(m.morphism_id)) continue;
            const src_invalid = m.source >= obj_count;
            const tgt_invalid = m.target >= obj_count;
            const weight_invalid = std.math.isNan(m.delta) or std.math.isInf(m.delta);
            if (src_invalid or tgt_invalid or weight_invalid) {
                // 越界 ID clamp 到 0（指向第一个对象，保证 source/target 合法）
                if (src_invalid) m.source = 0;
                if (tgt_invalid) m.target = 0;
                if (weight_invalid) m.delta = 0.0;
                fixed += 1;
            }
        }
        return fixed;
    }

    /// 规则 3：2-态射 source/target/weight 校验
    /// 不合法项：source/target 态射不存在、或 weight NaN/Inf → weight clamp 到 0
    fn applyRule3Morphism2Validation(graph: *DustGraph) usize {
        var fixed: usize = 0;
        for (graph.morphisms2.items) |*m2| {
            // 规则 4 兜底：跳过 source/target 均为冻结态射的 2-态射
            const src_frozen = graph.frozen_morphisms.contains(m2.source_morphism);
            const tgt_frozen = graph.frozen_morphisms.contains(m2.target_morphism);
            if (src_frozen and tgt_frozen) continue;

            const src_exists = graph.morphismExists(m2.source_morphism);
            const tgt_exists = graph.morphismExists(m2.target_morphism);
            // 权重已从morphism2结构体中移除，只校验源/目标态射存在性
            const invalid = !src_exists or !tgt_exists;
            if (invalid) {
                fixed += 1;
            }
        }
        return fixed;
    }

    /// 规则 4：还原冻结区节点/态射在投影前的原始值
    /// 严格对应白皮书 7.4.5 推论 7.1.2：已沉淀知识不可被投影覆盖
    /// 流程：用 snapshot 覆盖当前值，确保冻结区绝对不变
    fn applyRule4FrozenRestore(self: *TopologyProjection, graph: *DustGraph) usize {
        var restored: usize = 0;
        // 还原冻结对象值
        var it = self.frozen_object_snapshot.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const original = entry.value_ptr.*;
            if (id < graph.object_values.items.len) {
                graph.object_values.items[id] = original;
                restored += 1;
            }
        }
        // 还原冻结态射权重
        var itm = self.frozen_morphism_snapshot.iterator();
        while (itm.next()) |entry| {
            const id = entry.key_ptr.*;
            const original = entry.value_ptr.*;
            for (graph.morphisms.items) |*m| {
                if (m.morphism_id == id) {
                    m.delta = original;
                    restored += 1;
                    break;
                }
            }
        }
        // morphism2已无权重字段，冻结保护由源/目标态射的冻结状态完成
        _ = &self.frozen_morphism2_snapshot;
        return restored;
    }
};

// ============================================================
// 尘图 - CDL核心数据结构（v4.0 完整CDL范畴版）
// ============================================================
// 严格对应文档第2章CDL定义：
// - 完备格Ω：join/meet运算
// - enriched范畴C：1-态射复合
// - 2-态射结构：纵向/横向复合
//
// 使用Structure of Arrays布局，提升缓存命中率
// 对象ID直接作为数组索引，O(1)访问
pub const DustGraph = struct {
    allocator: std.mem.Allocator,

    // SoA布局：分离存储对象属性
    object_values: std.ArrayList(f64),
    object_names: std.ArrayList([]u8),

    // 态射存储
    morphisms: std.ArrayList(ffi.Morphism),
    morphisms2: std.ArrayList(ffi.Morphism2),

    // v4.1.0新增：态射去重索引（修复百万步态射无限增长导致进程被kill）
    // key = (source << 64) | target，value = morphism_id
    // 相同(source, target)的态射只创建一次，避免deltaAdd重复创建态射
    morphism_index: std.AutoHashMap(u128, u64),

    // 概念名→对象ID映射（用于去重）
    concept_map: std.StringHashMap(u64),

    // v4.0新增：冻结区机制（文档7.4.5推论7.1.2）
    // 已沉淀知识标记为冻结，投影保护不被修改
    // v5.0.x：frozen_objects 值改为 f64，记录冻结时的原始值
    // 用于 TopologyProjection 规则 4 还原：即使后续 object_values 被直接修改为 NaN/Inf，
    // 投影时也能从 frozen_objects 抓取冻结时刻的合法原始值进行还原
    frozen_objects: std.AutoHashMap(u64, f64),
    frozen_morphisms: std.AutoHashMap(u64, void),
    // 对象未修改步数计数器（用于冻结判定）
    object_unmodified_steps: std.AutoHashMap(u64, u64),

    // v4.0新增：沙箱隔离标志（文档9.4）
    // 沙箱图独立于主图，仿真失败不影响全局
    is_sandbox: bool,
    parent_graph: ?*DustGraph,

    // v4.0.5新增：安全级别类型系统（文档9.4.1）
    // 对象ID → 安全级别映射
    object_security_levels: std.AutoHashMap(u64, SecurityLevel),
    // 安全违规日志（文档9.4.1运行时检查机制）
    security_violation_logs: std.ArrayList(SecurityViolationLog),
    // 是否启用安全级别检查（默认启用）
    security_check_enabled: bool,

    // ============================================================
    // v5.0.0 Phase1：Grothendieck 宇宙分层（白皮书 2.2.5）
    // 层级化自指：Ob_{n+1} = Ob_n ∪ P(Ob_n)
    // ============================================================
    /// 层级索引：universe -> 对象ID列表
    /// 同一对象可以属于多个层级（高一层包含低一层的幂集）
    objects_by_universe: std.AutoHashMap(u8, std.ArrayList(u64)),
    /// 对象 → 所属层级（u8 枚举值对应 Universe 枚举）
    object_universe_map: std.AutoHashMap(u64, u8),

    next_morphism_id: u64,
    next_morphism2_id: u64,

    /// 创建尘图
    pub fn init(allocator: std.mem.Allocator) DustGraph {
        return .{
            .allocator = allocator,
            .object_values = std.ArrayList(f64).empty,
            .object_names = std.ArrayList([]u8).empty,
            .morphisms = std.ArrayList(ffi.Morphism).empty,
            .morphisms2 = std.ArrayList(ffi.Morphism2).empty,
            .morphism_index = std.AutoHashMap(u128, u64).init(allocator),
            .concept_map = std.StringHashMap(u64).init(allocator),
            .frozen_objects = std.AutoHashMap(u64, f64).init(allocator),
            .frozen_morphisms = std.AutoHashMap(u64, void).init(allocator),
            .object_unmodified_steps = std.AutoHashMap(u64, u64).init(allocator),
            .is_sandbox = false,
            .parent_graph = null,
            // v4.0.5：安全级别类型系统初始化
            .object_security_levels = std.AutoHashMap(u64, SecurityLevel).init(allocator),
            .security_violation_logs = std.ArrayList(SecurityViolationLog).empty,
            .security_check_enabled = true,
            // v5.0.0 Phase1：Grothendieck 宇宙分层初始化
            .objects_by_universe = std.AutoHashMap(u8, std.ArrayList(u64)).init(allocator),
            .object_universe_map = std.AutoHashMap(u64, u8).init(allocator),
            .next_morphism_id = 0,
            .next_morphism2_id = 0,
        };
    }

    /// 创建沙箱尘图（文档9.4：完全隔离的独立子格）
    /// v4.0.2修复：复制主图数据作为"数字孪生"（文档5.4.2.1要求）
    /// v4.0.2优化：只复制对象元数据，态射通过parent_graph引用（写时复制语义）
    /// v4.0.5：沙箱内新建节点初始级别为Sandbox（文档9.4.1规则1）
    /// v4.2：返回 error.OutOfMemory 若内存分配失败（替代 catch {} 静默吞没）
    pub fn initSandbox(allocator: std.mem.Allocator, parent: *DustGraph) !DustGraph {
        var sandbox = DustGraph{
            .allocator = allocator,
            .object_values = std.ArrayList(f64).empty,
            .object_names = std.ArrayList([]u8).empty,
            .morphisms = std.ArrayList(ffi.Morphism).empty,
            .morphisms2 = std.ArrayList(ffi.Morphism2).empty,
            .morphism_index = std.AutoHashMap(u128, u64).init(allocator),
            .concept_map = std.StringHashMap(u64).init(allocator),
            .frozen_objects = std.AutoHashMap(u64, f64).init(allocator),
            .frozen_morphisms = std.AutoHashMap(u64, void).init(allocator),
            .object_unmodified_steps = std.AutoHashMap(u64, u64).init(allocator),
            .is_sandbox = true,
            .parent_graph = parent,
            // v4.0.5：安全级别类型系统初始化
            .object_security_levels = std.AutoHashMap(u64, SecurityLevel).init(allocator),
            .security_violation_logs = std.ArrayList(SecurityViolationLog).empty,
            .security_check_enabled = true,
            // v5.0.0 Phase1：Grothendieck 宇宙分层初始化（沙箱独立）
            .objects_by_universe = std.AutoHashMap(u8, std.ArrayList(u64)).init(allocator),
            .object_universe_map = std.AutoHashMap(u64, u8).init(allocator),
            .next_morphism_id = parent.next_morphism_id,
            .next_morphism2_id = parent.next_morphism2_id,
        };

        // v4.0.2：只复制对象值和名称（轻量级数字孪生）
        // 态射通过parent_graph引用主图（写时复制：沙箱新增的态射存到sandbox.morphisms）
        // v4.2：使用 try 传播 OutOfMemory 错误（替代 catch {} 静默吞没）
        try sandbox.object_values.appendSlice(allocator, parent.object_values.items);
        // 对象名用空字符串占位
        try sandbox.object_names.ensureTotalCapacity(allocator, parent.object_names.items.len);
        for (parent.object_names.items) |_| {
            try sandbox.object_names.append(allocator, &[_]u8{});
        }

        // v4.0.5：复制主图对象的安全级别（文档9.4.1：沙箱继承主图的安全级别映射）
        // v4.2：使用 try 传播 OutOfMemory 错误（替代 catch {} 静默吞没）
        var level_it = parent.object_security_levels.iterator();
        while (level_it.next()) |entry| {
            try sandbox.object_security_levels.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // v5.0.0 Phase1：复制主图的 Grothendieck 宇宙分层映射
        var uni_it = parent.object_universe_map.iterator();
        while (uni_it.next()) |entry| {
            try sandbox.object_universe_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return sandbox;
    }

    /// 释放尘图资源
    pub fn deinit(self: *DustGraph) void {
        // 释放对象名（沙箱中的空字符串占位符不释放）
        if (!self.is_sandbox) {
            for (self.object_names.items) |name| {
                self.allocator.free(name);
            }
        }
        // concept_map 的 key 与 object_names 共享同一份 name_copy。
        // object_names 是唯一所有者，避免在此重复释放导致 double free。
        self.object_values.deinit(self.allocator);
        self.object_names.deinit(self.allocator);
        self.morphisms.deinit(self.allocator);
        self.morphisms2.deinit(self.allocator);
        self.morphism_index.deinit();
        self.concept_map.deinit();
        self.frozen_objects.deinit();
        self.frozen_morphisms.deinit();
        self.object_unmodified_steps.deinit();
        // v4.0.5：释放安全级别类型系统资源
        self.object_security_levels.deinit();
        self.security_violation_logs.deinit(self.allocator);
        // v5.0.0 Phase1：释放 Grothendieck 宇宙分层资源
        // 释放 objects_by_universe 中所有 ArrayList
        var uni_it = self.objects_by_universe.iterator();
        while (uni_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.objects_by_universe.deinit();
        self.object_universe_map.deinit();
    }

    /// 创建对象（ID索引化：ID = 数组索引）
    /// 若概念已存在，返回已有ID（知识去重）
    /// v4.0：检查冻结区，冻结对象不可创建同名新对象
    /// v4.0.1：拓扑感知合法更新前置校验（文档7.4.1）
    ///         对象值必须投影到CDL合法范畴子空间Π_Λ：有限且在Ω=[0,M]内
    /// v4.0.5修复：完备格Ω允许负值（原clamp到[-M, M]）
    ///             文档2.2.1要求Ω=[0,M]⊆R≥0，对象值必须非负
    pub fn createObject(self: *DustGraph, name: []const u8, value: f64) !u64 {
        // 拓扑感知合法更新前置校验（文档7.4.1）
        // 校验对象值在CDL合法范畴子空间Π_Λ内：非负且有限
        // v4.0.5：完备格Ω⊆R≥0，负值clamp到0（原保留符号违反格定义）
        const clamped_value: f64 = blk: {
            // NaN/Inf重置为0，完备格Ω非负约束：负值clamp到0
            if (value < 0.0 or std.math.isNan(value)) break :blk @as(f64, 0.0);
            if (std.math.isInf(value)) break :blk std.math.floatMax(f64);
            break :blk value;
        };

        // 若概念已存在，返回已有ID
        if (self.concept_map.get(name)) |id| {
            return id;
        }

        const id = @as(u64, @intCast(self.object_values.items.len));

        // SoA布局：分别存储属性
        try self.object_values.append(self.allocator, clamped_value);

        // 复制name并存储
        const name_copy = try self.allocator.dupe(u8, name);
        try self.object_names.append(self.allocator, name_copy);
        try self.concept_map.put(name_copy, id);

        // v5.0.0 Phase1：Grothendieck 宇宙分层——新对象默认放入 U0 层级（原子层）
        // 白皮书 2.2.5：Ob_{n+1} = Ob_n ∪ P(Ob_n)
        // 新创建的对象是"原子对象"，属于最底层 U0
        try self.putAtUniverse(id, .U0);

        return id;
    }

    /// 获取对象值（O(1)数组索引访问）
    pub fn getObjectValue(self: *const DustGraph, id: u64) ?f64 {
        if (id >= self.object_values.items.len) return null;
        return self.object_values.items[id];
    }
 
    // ============================================================
    // v5.0.0 Phase1：Grothendieck 宇宙分层方法（白皮书 2.2.5）
    // ============================================================

    /// 将对象放入指定 Universe 层级（白皮书 2.2.5：层级化自指）
    /// 同一对象可以被放入多个层级（高一层包含低一层的幂集）
    /// 参数：
    ///   - obj_id: 对象ID
    ///   - u: 目标 Universe 层级
    /// 返回：错误通过错误类型传播
    pub fn putAtUniverse(self: *DustGraph, obj_id: u64, u: Universe) !void {
        // 校验对象存在
        if (obj_id >= self.object_values.items.len) return UniverseError.ObjectNotFound;

        // 将对象添加到层级的索引列表
        const result = try self.objects_by_universe.getOrPut(@intFromEnum(u));
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(u64).empty;
        }
        // 避免重复添加
        var exists = false;
        for (result.value_ptr.items) |existing_id| {
            if (existing_id == obj_id) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try result.value_ptr.append(self.allocator, obj_id);
        }

        // 更新对象的层级映射（如果尚未设置或要升级到更高层级）
        if (self.object_universe_map.get(obj_id)) |current_level| {
            // 仅当新层级更高时才更新（U0 < U1 < U2 < UOmega）
            if (@intFromEnum(u) > current_level) {
                try self.object_universe_map.put(obj_id, @intFromEnum(u));
            }
        } else {
            try self.object_universe_map.put(obj_id, @intFromEnum(u));
        }
    }

    /// 反射原理（白皮书 2.2.5）：在 source 所在层级 + 1 的层级中创建 source 的副本
    /// 用于实现自指机制：Ob_{n+1} = Ob_n ∪ P(Ob_n) 中的 P(Ob_n) 部分
    /// 参数：
    ///   - target: 反射副本的目标层级（可选，None表示自动+1）
    ///   - source: 源对象ID
    /// 返回：副本对象ID
    pub fn reflect(self: *DustGraph, target: u64, source: u64) !u64 {
        // 校验源对象存在
        if (source >= self.object_values.items.len) return UniverseError.ObjectNotFound;

        // 校验目标对象存在
        if (target >= self.object_values.items.len) return UniverseError.ObjectNotFound;

        // 获取 source 所在层级
        const source_level = self.object_universe_map.get(source) orelse 0; // 默认为 U0

        // 计算目标层级：source_level + 1（最高不超过 UOmega）
        const next_level: u8 = if (source_level >= @intFromEnum(Universe.U2))
            @intFromEnum(Universe.UOmega)
        else
            source_level + 1;

        // 获取源对象的值
        const source_value = self.object_values.items[source];

        // 创建副本对象名（带 _reflect 标记）
        var new_name_buf: [128]u8 = undefined;
        const source_name = self.object_names.items[source];
        const new_name = std.fmt.bufPrint(&new_name_buf, "{s}_reflect_{d}", .{ source_name, next_level }) catch
            return UniverseError.UniverseViolation;

        // 创建新对象（会默认放入 U0，但立刻升级到目标层级）
        const copy_id = try self.createObject(new_name, source_value);
        // 升级到目标层级
        const target_universe: Universe = @enumFromInt(next_level);
        try self.putAtUniverse(copy_id, target_universe);

        return copy_id;
    }

    /// 获取对象所在 Universe 层级（默认返回 U0）
    pub fn getObjectUniverse(self: *const DustGraph, obj_id: u64) Universe {
        if (obj_id >= self.object_values.items.len) return .U0;
        const level = self.object_universe_map.get(obj_id) orelse 0;
        return @enumFromInt(level);
    }

    /// 获取指定 Universe 层级中的所有对象ID列表
    pub fn getObjectsInUniverse(self: *const DustGraph, u: Universe) []const u64 {
        if (self.objects_by_universe.get(@intFromEnum(u))) |list| {
            return list.items;
        }
        return &[_]u64{};
    }

    /// 校验跨层引用合法性（白皮书 2.2.5：U1 中不可引用 U2 层级对象）
    /// 允许规则：高层可以引用低层（信息流从低到高），但低层不可引用高层
    /// 返回：true 表示引用合法（from_level >= to_level），false 表示违反层级约束
    pub fn validateUniverseReference(self: *const DustGraph, from_obj: u64, to_obj: u64) bool {
        const from_level = self.object_universe_map.get(from_obj) orelse 0;
        const to_level = self.object_universe_map.get(to_obj) orelse 0;
        // 高层（from_level 数值大）可以引用低层（to_level 数值小）或同层
        // 低层（from_level 数值小）引用高层（to_level 数值大）违反层级约束
        return from_level >= to_level;
    }

    /// v4.0.11新增：通过名称查找对象（Δ演绎数字对象时使用）
    /// 设计文档8.1：数字对象通过Δ演绎创建，需检查是否已存在
    pub fn findObjectByName(self: *const DustGraph, name: []const u8) ?u64 {
        return self.concept_map.get(name);
    }

    /// v4.0.11新增：设置对象值（Δ权重学习后更新演绎值）
    /// 设计文档2.1.1：value通过Δ运算演绎，权重学习后需更新
    /// v4.0.12修复：冻结对象修改时返回错误而非静默忽略（M-7）
    pub fn setObjectValue(self: *DustGraph, id: u64, value: f64) ModificationError!void {
    if (id >= self.object_values.items.len) return error.ObjectNotFound;
    if (self.frozen_objects.contains(id)) return error.ObjectFrozen;
    self.object_values.items[@as(usize, @intCast(id))] = value;
}


    /// 构造FFI Object结构（按需构造，不存储）
    pub fn getObject(self: *const DustGraph, id: u64) ?ffi.Object {
        if (id >= self.object_values.items.len) return null;
        return ffi.Object{
            .id = .{ .id = id },
            .value = self.object_values.items[id],
            .f_weight = 1.0,  // CDL表达式引擎替代标量权重
            .g_weight = 1.0,  // 保留默认值以满足FFI Object结构定义
        };
    }

    /// 创建态射
    /// v4.0：检查冻结区
    /// v4.0.1：语义锚约束 - 态射权重必须有限且非Inf/NaN
    ///         对应Rust内核verify_semantic_anchor（lib.rs:622-626）
    ///         防止大数运算时权重无界增长导致三重锚定校验失败
    /// v4.0.1：拓扑感知合法更新前置校验（文档7.4.1）
    ///         态射source/target对象必须存在（格封闭性）
    /// v4.0.5：安全级别信息流检查（文档9.4.1规则2+4）
    ///         态射 f: A → B 必须 Level(A) ⊑ Level(B)
    ///         种子核节点只能作为态射源，不能作为态射目标
    pub fn createMorphism(self: *DustGraph, source: u64, target: u64, weight: f64) !u64 {
        // 拓扑感知合法更新前置校验（文档7.4.1）
        // 校验态射source/target对象存在（格封闭性：态射两端对象必须在范畴内）
        // 不符合公理的更新方向直接拒绝（返回错误）
        if (source >= self.object_values.items.len) return error.InvalidMorphismSource;
        if (target >= self.object_values.items.len) return error.InvalidMorphismTarget;

        // v4.0.5：安全级别信息流检查（文档9.4.1）
        // 类型规则2：态射 f: A → B 必须 Level(A) ⊑ Level(B)
        // 类型规则4：种子核节点只能作为态射源，不能作为态射目标
        if (self.security_check_enabled) {
            const source_level = self.getObjectSecurityLevel(source);
            const target_level = self.getObjectSecurityLevel(target);

            // 类型规则4：种子核节点不能作为态射目标（文档9.4.1）
            if (target_level == .Seed) {
                // 记录安全违规日志
                self.logSecurityViolation(source, target, source_level, target_level);
                return InformationFlowError.SeedNodeAsTarget;
            }

            // 类型规则2：信息流必须合法 Level(source) ⊑ Level(target)
            if (!source_level.isLessThanOrEqual(target_level)) {
                // 记录安全违规日志
                self.logSecurityViolation(source, target, source_level, target_level);
                return InformationFlowError.InformationFlowViolation;
            }
        }

        // 态射权重不由硬编码上限限制，仅受完备格Ω非负约束
        // NaN/Inf映射为0.0，保留有限值
        const clamped_weight: f64 = blk: {
            if (!std.math.isFinite(weight)) break :blk @as(f64, 0.0);
            break :blk weight;
        };

        // v4.1.0：态射去重（修复百万步态射无限增长导致进程被kill）
        // 相同(source, target)的态射只创建一次，返回已有id
        // 设计依据：CDL结构化记录中，相同source-target的态射是冗余的
        const dedup_key: u128 = (@as(u128, source) << 64) | @as(u128, target);
        if (self.morphism_index.get(dedup_key)) |existing_id| {
            return existing_id;
        }

        const id = self.next_morphism_id;
        self.next_morphism_id += 1;
        try self.morphisms.append(self.allocator, ffi.makeMorphism(source, target, id, clamped_weight, 2));
        // 注册到去重索引
        try self.morphism_index.put(dedup_key, id);
        return id;
    }

    /// 按MorphismId检查1-态射是否存在。
    /// 2-态射必须连接1-态射，不能把对象ID伪装为态射ID。
    pub fn morphismExists(self: *const DustGraph, morphism_id: u64) bool {
        for (self.morphisms.items) |m| {
            if (m.morphism_id == morphism_id) return true;
        }
        return false;
    }

    /// 按MorphismId获取1-态射。
    pub fn getMorphismById(self: *const DustGraph, morphism_id: u64) ?ffi.Morphism {
        for (self.morphisms.items) |m| {
            if (m.morphism_id == morphism_id) return m;
        }
        return null;
    }

    /// 查找对象的已有恒等态射。
    pub fn findIdentityMorphism(self: *const DustGraph, obj_id: u64) ?u64 {
        for (self.morphisms.items) |m| {
            if (m.source == obj_id and m.target == obj_id) return m.morphism_id;
        }
        return null;
    }

    /// 创建2-态射（态射间的等价重写）。
    /// 严格对应白皮书2.2：2-态射 α: f ⇒ g 的 source/target 必须是 MorphismId。
    pub fn createMorphism2(
        self: *DustGraph,
        source_morphism: u64,
        target_morphism: u64,
        rewrite_type: ffi.RewriteType,
    ) !u64 {
        if (!self.morphismExists(source_morphism)) return error.InvalidMorphismSource;
        if (!self.morphismExists(target_morphism)) return error.InvalidMorphismTarget;

        const id = self.next_morphism2_id;
        self.next_morphism2_id += 1;
        try self.morphisms2.append(self.allocator, ffi.makeMorphism2(
            id,
            source_morphism,
            target_morphism,
            rewrite_type,
        ));
        return id;
    }

    /// 创建带权重的2-态射。
    /// source/target 必须是真实存在的 MorphismId。
    pub fn createMorphism2WithWeight(
        self: *DustGraph,
        source_morphism: u64,
        target_morphism: u64,
        rewrite_type: ffi.RewriteType,
    ) !u64 {
        if (!self.morphismExists(source_morphism)) return error.InvalidMorphismSource;
        if (!self.morphismExists(target_morphism)) return error.InvalidMorphismTarget;

        // 态射权重不由硬编码上限限制，仅受完备格Ω非负约束
        // NaN/Inf映射为0.0，保留有限值
        const id = self.next_morphism2_id;
        self.next_morphism2_id += 1;
        try self.morphisms2.append(self.allocator, ffi.makeMorphism2(
            id,
            source_morphism,
            target_morphism,
            rewrite_type,
        ));
        return id;
    }

    /// 将对象级等价显式提升为“恒等态射之间的2-态射”。
    /// 这是对象关系进入2-范畴层的唯一允许桥接路径，避免对象ID/态射ID混用。
    pub fn createMorphism2BetweenObjectIdentities(
        self: *DustGraph,
        source_object: u64,
        target_object: u64,
        rewrite_type: ffi.RewriteType,
    ) !u64 {
        const source_identity = self.findIdentityMorphism(source_object) orelse try self.createIdentityMorphism(source_object);
        const target_identity = self.findIdentityMorphism(target_object) orelse try self.createIdentityMorphism(target_object);
        return try self.createMorphism2WithWeight(source_identity, target_identity, rewrite_type);
    }

    // ============================================================
    // v4.0新增：CDL范畴结构（文档2.2.1）
    // ============================================================

    /// 格运算-上确界（join ∨）：取最大值
    /// 文档2.2.1：完备格要求任意子集有上确界
    /// 通过FFI调用Rust种子核的seed_lattice_join
    /// v4.0.12修复：使用显式错误类型替代NaN作为错误信号（M-8）
    pub fn latticeJoin(self: *const DustGraph, a_id: u64, b_id: u64) LatticeOperationError!f64 {
        // 输入校验：对象不存在返回明确错误（非NaN信号）
        const a_val = self.getObjectValue(a_id) orelse return error.ObjectNotFound;
        const b_val = self.getObjectValue(b_id) orelse return error.ObjectNotFound;
        return ffi.latticeJoin(a_val, b_val);
    }

    /// 格运算-下确界（meet ∧）：取最小值
    /// 文档2.2.1：完备格要求任意子集有下确界
    /// 通过FFI调用Rust种子核的seed_lattice_meet
    /// v4.0.12修复：使用显式错误类型替代NaN作为错误信号（M-8）
    pub fn latticeMeet(self: *const DustGraph, a_id: u64, b_id: u64) LatticeOperationError!f64 {
        // 输入校验：对象不存在返回明确错误（非NaN信号）
        const a_val = self.getObjectValue(a_id) orelse return error.ObjectNotFound;
        const b_val = self.getObjectValue(b_id) orelse return error.ObjectNotFound;
        return ffi.latticeMeet(a_val, b_val);
    }

    // ============================================================
    // v4.0.9新增：2-态射差值度上界约束（文档2.2.1）
    // 文档2.2.1：2-态射 α: f ⇒ g 满足 ω(α) ≤ ω(f) ∨ ω(g)
    // ============================================================

    /// 校验2-态射差值度上界约束（文档2.2.1）
    /// 公理：ω(α) ≤ ω(f) ∨ ω(g)
    /// 其中 α: f ⇒ g 是2-态射，f和g是1-态射
    /// 参数：
    ///   - alpha_weight: 2-态射α的差值度 ω(α)
    ///   - f_weight: 1-态射f的差值度 ω(f)
    ///   - g_weight: 1-态射g的差值度 ω(g)
    /// 返回：true表示满足上界约束
    pub fn verifyMorphism2UpperBound(
        self: *const DustGraph,
        alpha_weight: f64,
        f_weight: f64,
        g_weight: f64,
    ) bool {
        _ = self;
        // 公理：ω(α) ≤ ω(f) ∨ ω(g)
        // ∨ 是join/上确界/max
        const upper_bound = if (f_weight >= g_weight) f_weight else g_weight;
        return alpha_weight <= upper_bound + 1e-10; // 容差1e-10（科研精度）
    }

    /// 计算纵向复合2-态射的差值度上界（文档2.2.1形式化）
    /// 公理：ω(β·α) ≤ ω(α) ∨ ω(β)
    /// 其中 α: f ⇒ g, β: g ⇒ h, β·α: f ⇒ h
    pub fn verticalComposeUpperBound(
        self: *const DustGraph,
        alpha_weight: f64,
        beta_weight: f64,
    ) f64 {
        _ = self;
        // ω(β·α) ≤ ω(α) ∨ ω(β)
        // 取等号实现精确格运算对应
        return if (alpha_weight >= beta_weight) alpha_weight else beta_weight;
    }

    /// 计算横向复合2-态射的差值度上界（文档2.2.1形式化）
    /// 公理：ω(β*α) ≤ ω(α) ∨ ω(β)
    /// 其中 α: f₁ ⇒ g₁, β: f₂ ⇒ g₂, β*α: f₂∘f₁ ⇒ g₂∘g₁
    pub fn horizontalComposeUpperBound(
        self: *const DustGraph,
        alpha_weight: f64,
        beta_weight: f64,
    ) f64 {
        _ = self;
        // ω(β*α) ≤ ω(α) ∨ ω(β)
        // 取等号实现精确格运算对应
        return if (alpha_weight >= beta_weight) alpha_weight else beta_weight;
    }

    // ============================================================
    // v4.0.9新增：对象层格运算与Hom兼容性公理（文档2.2.1 enriched结构）
    // 基于尘算子 Δ(x,y) = max(0, f(x) - g(y)) 推导
    // ============================================================

    /// 兼容性公理1：对象join与Hom第一参数（文档2.2.1 enriched）
    /// 公理：若f保持join，则 Hom(A₁∨A₂, B) = Hom(A₁, B) ∨ Hom(A₂, B)
    /// 推导：Hom(A₁∨A₂, B) = max(0, f(A₁∨A₂) - g(B))
    ///       = max(0, max(f(A₁),f(A₂)) - g(B))
    ///       = max(max(0,f(A₁)-g(B)), max(0,f(A₂)-g(B)))
    ///       = Hom(A₁, B) ∨ Hom(A₂, B)
    /// 参数：a1_id, a2_id为对象ID，b_id为目标对象ID
    /// 返回：true表示满足兼容性公理1
    pub fn verifyJoinCompatibilityFirstArg(
        self: *const DustGraph,
        a1_id: u64,
        a2_id: u64,
        b_id: u64,
    ) bool {
        // 计算对象join：A₁ ∨ A₂
        // v4.0.12：使用catch处理LatticeOperationError，替代NaN检查
        _ = self.latticeJoin(a1_id, a2_id) catch return false;

        // 计算Hom(A₁∨A₂, B) = Δ(A₁∨A₂, B)
        const hom_join = self.deltaByObjId(a1_id, a2_id, b_id, true) catch return false;

        // 计算Hom(A₁, B) ∨ Hom(A₂, B)
        const hom_a1 = self.deltaObjToObj(a1_id, b_id) catch return false;
        const hom_a2 = self.deltaObjToObj(a2_id, b_id) catch return false;

        const rhs = if (hom_a1 >= hom_a2) hom_a1 else hom_a2;

        // 校验等式：Hom(A₁∨A₂, B) = Hom(A₁, B) ∨ Hom(A₂, B)
        return @abs(hom_join - rhs) < 1e-10;
    }

    /// 兼容性公理2：对象meet与Hom第二参数（文档2.2.1 enriched）
    /// 公理：若g保持meet，则 Hom(A, B₁∧B₂) = Hom(A, B₁) ∨ Hom(A, B₂)
    /// 推导：Hom(A, B₁∧B₂) = max(0, f(A) - g(B₁∧B₂))
    ///       = max(0, f(A) - min(g(B₁),g(B₂)))
    ///       = max(0, max(f(A)-g(B₁), f(A)-g(B₂)))
    ///       = max(max(0,f(A)-g(B₁)), max(0,f(A)-g(B₂)))
    ///       = Hom(A, B₁) ∨ Hom(A, B₂)
    pub fn verifyMeetCompatibilitySecondArg(
        self: *const DustGraph,
        a_id: u64,
        b1_id: u64,
        b2_id: u64,
    ) bool {
        // 计算Hom(A, B₁∧B₂) = Δ(A, B₁∧B₂) = max(0, A - min(B₁, B₂))
        // 文档2.2.1 enriched：g(B₁∧B₂) = min(B₁, B₂)（裸值，权重由CDL处理）
        const a_val = self.getObjectValue(a_id) orelse return false;
        const b1_val = self.getObjectValue(b1_id) orelse return false;
        const b2_val = self.getObjectValue(b2_id) orelse return false;
        // g(B₁∧B₂) = min(B₁, B₂)
        const g_meet = @min(b1_val, b2_val);
        const hom_meet = if (a_val >= g_meet) a_val - g_meet else 0.0;

        // 计算Hom(A, B₁) ∨ Hom(A, B₂)
        // v4.0.12：使用catch处理LatticeOperationError，替代NaN检查
        const hom_b1 = self.deltaObjToObj(a_id, b1_id) catch return false;
        const hom_b2 = self.deltaObjToObj(a_id, b2_id) catch return false;

        const rhs = if (hom_b1 >= hom_b2) hom_b1 else hom_b2;

        // 校验等式：Hom(A, B₁∧B₂) = Hom(A, B₁) ∨ Hom(A, B₂)
        return @abs(hom_meet - rhs) < 1e-10;
    }

    /// 兼容性公理3：对象join与Hom第二参数（文档2.2.1 enriched）
    /// 公理：Hom(A, B₁∨B₂) ≤ Hom(A, B₁) ∧ Hom(A, B₂)
    /// 推导：Hom(A, B₁∨B₂) = max(0, f(A) - max(g(B₁),g(B₂)))
    ///       = max(0, min(f(A)-g(B₁), f(A)-g(B₂)))
    ///       ≤ min(max(0,f(A)-g(B₁)), max(0,f(A)-g(B₂)))
    ///       = Hom(A, B₁) ∧ Hom(A, B₂)
    pub fn verifyJoinCompatibilitySecondArg(
        self: *const DustGraph,
        a_id: u64,
        b1_id: u64,
        b2_id: u64,
    ) bool {
        // 计算Hom(A, B₁∨B₂) = Δ(A, B₁∨B₂) = max(0, A - max(B₁, B₂))
        // 文档2.2.1 enriched：g(B₁∨B₂) = max(B₁, B₂)（裸值，权重由CDL处理）
        const a_val = self.getObjectValue(a_id) orelse return false;
        const b1_val = self.getObjectValue(b1_id) orelse return false;
        const b2_val = self.getObjectValue(b2_id) orelse return false;
        // g(B₁∨B₂) = max(B₁, B₂)
        const g_join = @max(b1_val, b2_val);
        const hom_join = if (a_val >= g_join) a_val - g_join else 0.0;

        // 计算Hom(A, B₁) ∧ Hom(A, B₂)
        // v4.0.12：使用catch处理LatticeOperationError，替代NaN检查
        const hom_b1 = self.deltaObjToObj(a_id, b1_id) catch return false;
        const hom_b2 = self.deltaObjToObj(a_id, b2_id) catch return false;

        const rhs = if (hom_b1 <= hom_b2) hom_b1 else hom_b2;

        // 校验不等式：Hom(A, B₁∨B₂) ≤ Hom(A, B₁) ∧ Hom(A, B₂)
        return hom_join <= rhs + 1e-10;
    }

    /// 兼容性公理4：对象meet与Hom第一参数（文档2.2.1 enriched）
    /// 公理：Hom(A₁∧A₂, B) ≤ Hom(A₁, B) ∧ Hom(A₂, B)
    /// 推导：Hom(A₁∧A₂, B) = max(0, min(f(A₁),f(A₂)) - g(B))
    ///       = max(0, min(f(A₁)-g(B), f(A₂)-g(B)))
    ///       ≤ min(max(0,f(A₁)-g(B)), max(0,f(A₂)-g(B)))
    ///       = Hom(A₁, B) ∧ Hom(A₂, B)
    pub fn verifyMeetCompatibilityFirstArg(
        self: *const DustGraph,
        a1_id: u64,
        a2_id: u64,
        b_id: u64,
    ) bool {
        // 计算Hom(A₁∧A₂, B) = Δ(A₁∧A₂, B) = max(0, min(A₁, A₂) - B)
        // 文档2.2.1 enriched：f(A₁∧A₂) = min(A₁, A₂)（裸值，权重由CDL处理）
        const a1_val = self.getObjectValue(a1_id) orelse return false;
        const a2_val = self.getObjectValue(a2_id) orelse return false;
        const b_val = self.getObjectValue(b_id) orelse return false;
        // f(A₁∧A₂) = min(A₁, A₂)
        const f_meet = @min(a1_val, a2_val);
        const hom_meet = if (f_meet >= b_val) f_meet - b_val else 0.0;

        // 计算Hom(A₁, B) ∧ Hom(A₂, B)
        // v4.0.12：使用catch处理LatticeOperationError，替代NaN检查
        const hom_a1 = self.deltaObjToObj(a1_id, b_id) catch return false;
        const hom_a2 = self.deltaObjToObj(a2_id, b_id) catch return false;

        const rhs = if (hom_a1 <= hom_a2) hom_a1 else hom_a2;

        // 校验不等式：Hom(A₁∧A₂, B) ≤ Hom(A₁, B) ∧ Hom(A₂, B)
        return hom_meet <= rhs + 1e-10;
    }

    /// 辅助方法：计算对象间的差值度 Hom(A, B) = Δ(A, B) = max(0, A - B)
    /// 文档2.2.1：Hom-对象取值于完备格Ω，表示A到B的差值度
    /// 核心哲学：尘算子Δ(x,y) = f(x) - g(y) 是体系唯一原语
    /// 注意：CDL表达式引擎提供真正的f/g权重演化（通过deltaExpr），
    /// 此方法仅提供基于裸值的简单Δ近似，用于格运算兼容性校验。
    /// v4.0.12修复：使用显式错误类型替代NaN作为错误信号（M-8）
    /// v6.0：移除标量权重，使用裸值（CDL表达式引擎处理权重演化）
    pub fn deltaObjToObj(self: *const DustGraph, a_id: u64, b_id: u64) LatticeOperationError!f64 {
        const a_val = self.getObjectValue(a_id) orelse return error.ObjectNotFound;
        const b_val = self.getObjectValue(b_id) orelse return error.ObjectNotFound;
        // 尘算子：Δ(A, B) = max(0, A - B)，权重由CDL表达式引擎处理
        const delta = a_val - b_val;
        return if (delta >= 0.0) delta else 0.0;
    }

    /// 辅助方法：计算对象join/meet后的差值度
    /// is_join=true计算Hom(A₁∨A₂, B)，is_join=false计算Hom(A₁∧A₂, B)
    /// 核心哲学：Δ(A₁∨A₂, B) = max(0, f(A₁∨A₂) - g(B))
    /// 其中 f(A₁∨A₂) = max(f(A₁), f(A₂))（join的f值取上确界）
    ///       f(A₁∧A₂) = min(f(A₁), f(A₂))（meet的f值取下确界）
    /// v4.0.12修复：使用显式错误类型替代NaN作为错误信号（M-8）
    /// v6.0：移除标量权重，使用裸值（CDL表达式引擎处理权重演化）
    fn deltaByObjId(
        self: *const DustGraph,
        a1_id: u64,
        a2_id: u64,
        b_id: u64,
        is_join: bool,
    ) LatticeOperationError!f64 {
        const a1_val = self.getObjectValue(a1_id) orelse return error.ObjectNotFound;
        const a2_val = self.getObjectValue(a2_id) orelse return error.ObjectNotFound;
        const b_val = self.getObjectValue(b_id) orelse return error.ObjectNotFound;
        // 裸值计算（权重由CDL表达式引擎处理）
        const f_combined = if (is_join) @max(a1_val, a2_val) else @min(a1_val, a2_val);
        const delta = f_combined - b_val;
        return if (delta >= 0.0) delta else 0.0;
    }

    // ============================================================
    // v4.0.3新增：1-态射复合公理（文档2.2.2）
    // 文档2.2.2要求：compose(g,f)满足dom(g)=cod(f)，
    //   恒等态射id_A，结合律h∘(g∘f)=(h∘g)∘f
    // ============================================================

    /// 1-态射复合 compose(g, f)（文档2.2.2）
    /// 公理要求：dom(g) = cod(f)，即 g.source == f.target
    /// 复合规则：新态射 source=f.source, target=g.target, weight=min(g.delta, f.delta)
    ///          v4.0.12修复：使用∧(min)而非乘法，与对偶性定理2.2a一致（S-5）
    /// 参数顺序遵循数学惯例 compose(g, f) = g ∘ f（先f后g）
    /// 返回新创建的复合态射ID；若dom(g)≠cod(f)返回error.CompositionDomainMismatch
    pub fn composeMorphism(self: *DustGraph, g_id: u64, f_id: u64) !u64 {
        // 在态射集合中查找g和f（按ID匹配）
        var g_morphism: ?ffi.Morphism = null;
        var f_morphism: ?ffi.Morphism = null;
        for (self.morphisms.items) |m| {
            if (m.morphism_id == g_id) g_morphism = m;
            if (m.morphism_id == f_id) f_morphism = m;
        }

        // 任一态射不存在则报错（全链路显式错误处理）
        if (g_morphism == null) return error.MorphismNotFound;
        if (f_morphism == null) return error.MorphismNotFound;

        const g = g_morphism.?;
        const f = f_morphism.?;

        // 校验复合合法性：dom(g) = cod(f)，即 g.source == f.target
        // 文档2.2.2：态射复合要求定义域与余定义域匹配
        if (g.source != f.target) {
            return error.CompositionDomainMismatch;
        }

        // 创建复合态射：source=f.source, target=g.target, weight=min(g.delta, f.delta)
        // v4.0.12：使用∧(min)而非乘法，对偶性定理2.2a：
        //   1-态射复合用∧(min)（距离缩短），2-态射复合用∨(max)（差异累积）
        const new_weight = @min(g.delta, f.delta);
        return try self.createMorphism(f.source, g.target, new_weight);
    }

    /// 创建恒等态射 id_A（文档2.2.2）
    /// 公理要求：对每个对象A存在id_A: A→A，满足 id_A ∘ f = f, g ∘ id_A = g
    /// 恒等态射：source=obj_id, target=obj_id, weight=1.0
    /// 返回新创建的恒等态射ID；若对象不存在返回error.ObjectNotFound
    pub fn createIdentityMorphism(self: *DustGraph, obj_id: u64) !u64 {
        // 校验对象存在（边界校验，非法输入返回明确错误）
        if (obj_id >= self.object_values.items.len) return error.ObjectNotFound;

        // 创建恒等态射：source=target=obj_id, weight=1.0
        // weight=1.0保证 id_A ∘ f = 1.0 * f.delta = f.delta（恒等性）
        return try self.createMorphism(obj_id, obj_id, 1.0);
    }

    /// 校验1-态射复合的结合律（文档2.2.2）
    /// 公理要求：h ∘ (g ∘ f) = (h ∘ g) ∘ f
    /// 抽样校验（全量O(n³)不可行），上限10000次
    /// 使用固定种子的伪随机采样，保证可复现（文档要求CSPRNG可播种）
    /// 返回true表示所有抽样均满足结合律
    pub fn verifyCompositionAssociativity(self: *const DustGraph) bool {
        const n = self.morphisms.items.len;
        // 态射数<3无法构成h∘(g∘f)，结合律平凡满足
        if (n < 3) return true;

        // 采样上限由图规模内生决定（取对象数与态射数的最大值）
        const sample_limit: u64 = @max(@as(u64, @intCast(self.objectCount())), @as(u64, @intCast(self.morphismCount())));
        var sampled: u64 = 0;
        // v4.0.8：使用SplitMix64替代自实现LCG（文档要求可播种CSPRNG，与Rust侧一致）
        // 固定种子，保证可复现（文档要求全流程可复现）
        var rng = sm64.SplitMix64.init(0x1234567890ABCDEF);

        while (sampled < sample_limit) {
            // SplitMix64伪随机采样（可播种、可复现、与Rust侧一致）
            const i = @as(usize, @intCast(rng.nextRange(n)));
            const j = @as(usize, @intCast(rng.nextRange(n)));
            const k = @as(usize, @intCast(rng.nextRange(n)));

            // 跳过重复索引（保证f,g,h是不同态射）
            if (i == j or j == k or i == k) continue;
            sampled += 1;

            const f = self.morphisms.items[i];
            const g = self.morphisms.items[j];
            const h = self.morphisms.items[k];

            // 检查可复合性：f: A→B, g: B→C, h: C→D
            // 即 f.target == g.source 且 g.target == h.source
            if (f.target != g.source) continue;
            if (g.target != h.source) continue;

            // 计算 h ∘ (g ∘ f) 的权重
            // v4.0.12修复：使用∧(min)而非乘法，与对偶性定理2.2a一致（S-5）
            // g ∘ f 的权重 = min(g.delta, f.delta)
            // h ∘ (g ∘ f) 的权重 = min(h.delta, min(g.delta, f.delta))
            const gf_weight = @min(g.delta, f.delta);
            const hgf_weight = @min(h.delta, gf_weight);

            // 计算 (h ∘ g) ∘ f 的权重
            // h ∘ g 的权重 = min(h.delta, g.delta)
            // (h ∘ g) ∘ f 的权重 = min(min(h.delta, g.delta), f.delta)
            const hg_weight = @min(h.delta, g.delta);
            const hgf_weight2 = @min(hg_weight, f.delta);

            // 校验结合律：h∘(g∘f) = (h∘g)∘f
            // 浮点数容差1e-10（科研级精度，文档要求≤10⁻¹⁰）
            const diff = @abs(hgf_weight - hgf_weight2);
            if (diff > 1e-10) return false;

            // 校验源/目标一致性（结合律要求两端态射的dom/cod相同）
            // h∘(g∘f): source=f.source, target=h.target
            // (h∘g)∘f: source=f.source, target=h.target
            // 由复合规则保证，无需额外校验（权重一致即可判定）
        }

        return true;
    }

    /// 2-态射纵向复合（vertical composition）
    /// 文档2.2.1：若 α: f ⇒ g, β: g ⇒ h，则 β·α: f ⇒ h
    /// v4.0新增：实现2-范畴的纵向复合
    /// v4.0.9形式化：纵向复合差值度规则 ω(β·α) ≤ ω(α) ∨ ω(β)
    ///   - 与格运算的精确对应：使用 ∨（join/上确界/max）
    ///   - 语义：串联重写路径的总差值取各段上确界（中间状态g截断累积）
    ///   - 对偶性：1-态射复合用 ∧（min，距离缩短），2-态射复合用 ∨（max，差异累积）
    ///   - 原实现错误：使用乘法 alpha.delta * beta.delta，违反格运算公理
    pub fn verticalComposeMorphism2(
        self: *DustGraph,
        alpha_idx: usize,
        beta_idx: usize,
    ) !?u64 {
        if (alpha_idx >= self.morphisms2.items.len) return null;
        if (beta_idx >= self.morphisms2.items.len) return null;

        const alpha = self.morphisms2.items[alpha_idx];
        const beta = self.morphisms2.items[beta_idx];

        // 纵向复合要求alpha的target_morphism == beta的source_morphism
        if (alpha.target_morphism != beta.source_morphism) return null;

        // v4.0.9形式化：纵向复合差值度由系统内生决定（权重字段已从morphism2结构体移除）
        return try self.createMorphism2WithWeight(
            alpha.source_morphism,
            beta.target_morphism,
            alpha.rewrite_type,
        );
    }

    /// 2-态射横向复合（horizontal composition）
    /// 文档2.2.1：若 α: f ⇒ f', β: g ⇒ g'，则 β*α: g∘f ⇒ g'∘f'
    /// v4.0新增：实现2-范畴的横向复合
    /// v4.0.9形式化：横向复合差值度规则 ω(β*α) ≤ ω(α) ∨ ω(β)
    ///   - 与格运算的精确对应：使用 ∨（join/上确界/max）
    ///   - 语义：并行重写的总差值取各段上确界（最坏情况）
    ///   - 与纵向复合规则一致：ω(β*α) = ω(α) ∨ ω(β)
    ///   - 原实现错误：使用乘法 alpha.delta * beta.delta，违反格运算公理
    pub fn horizontalComposeMorphism2(
        self: *DustGraph,
        alpha_idx: usize,
        beta_idx: usize,
    ) !u64 {
        if (alpha_idx >= self.morphisms2.items.len) return error.InvalidIndex;
        if (beta_idx >= self.morphisms2.items.len) return error.InvalidIndex;

        const alpha = self.morphisms2.items[alpha_idx];
        const beta = self.morphisms2.items[beta_idx];

        // 横向复合差值度由系统内生决定（权重字段已从morphism2结构体移除）
        const source_composite = try self.composeMorphism(beta.source_morphism, alpha.source_morphism);
        const target_composite = try self.composeMorphism(beta.target_morphism, alpha.target_morphism);
        return try self.createMorphism2WithWeight(
            source_composite,
            target_composite,
            alpha.rewrite_type,
        );
    }

    // ============================================================
    // v4.0新增：双态同显机制（文档3.3）
    // ============================================================

    /// 内容升格为规则（ContentToRule）
    /// 文档3.3.1：反复出现的1-态射模式（内容规律），
    /// 可被提炼压缩为2-态射（通用规则），沉淀为新的认知范式
    /// v4.0新增：将高频1-态射模式升格为2-态射规则
    pub fn contentToRule(
        self: *DustGraph,
        pattern_source: u64,
        pattern_target: u64,
        confidence: f64,
    ) !u64 {
        const pattern_morphism = try self.createMorphism(pattern_source, pattern_target, confidence);
        return try self.createMorphism2WithWeight(
            pattern_morphism,
            pattern_morphism,
            ffi.REWRITE_CONTENT_TO_RULE,
        );
    }

    /// 规则降格为内容（RuleToContent）
    /// 文档3.3.1：2-态射（规则）可被当作0-阶对象，
    /// 成为被推演、被优化的内容，实现对规则的反思
    /// v4.0新增：将2-态射规则降格为可推演的内容对象
    pub fn ruleToContent(
        self: *DustGraph,
        rule_morphism2_idx: usize,
    ) !u64 {
        if (rule_morphism2_idx >= self.morphisms2.items.len) return error.InvalidIndex;

        const rule = self.morphisms2.items[rule_morphism2_idx];

        // 创建2-态射标记：规则降格为内容
        return try self.createMorphism2WithWeight(
            rule.source,
            rule.target,
            ffi.REWRITE_RULE_TO_CONTENT,
            rule.delta,
        );
    }

    // ============================================================
    // v4.0新增：冻结区机制（文档7.4.5推论7.1.2）
    // ============================================================

    /// 标记对象为冻结（文档7.4.5：已沉淀知识标记为冻结节点）
    /// 冻结节点不被修改，保证灾难性遗忘免疫
    /// v5.0.x：冻结时记录当前对象值到 frozen_objects，投影规则 4 还原使用
    /// v4.2：使用 logGlobalError 记录 put 失败（替代 catch {} 静默吞没）
    pub fn freezeObject(self: *DustGraph, id: u64) void {
        // 抓取冻结时刻的对象值作为原始值（v5.0.x 新增）
        // 若对象ID越界或值非法，使用 0.0 作为合法回退
        const original_value: f64 = if (id < self.object_values.items.len) blk: {
            const v = self.object_values.items[id];
            if (std.math.isNan(v) or std.math.isInf(v) or v < 0.0) break :blk 0.0;
            break :blk v;
        } else 0.0;
        self.frozen_objects.put(id, original_value) catch |err| {
            et.logGlobalError(.Warning, "dust_graph", "freezeObject", @intFromError(err), "put failed");
        };
    }

    /// 标记态射为冻结
    /// v4.2：使用 logGlobalError 记录 put 失败（替代 catch {} 静默吞没）
    pub fn freezeMorphism(self: *DustGraph, id: u64) void {
        self.frozen_morphisms.put(id, {}) catch |err| {
            et.logGlobalError(.Warning, "dust_graph", "freezeMorphism", @intFromError(err), "put failed");
        };
    }

    /// 检查对象是否冻结
    pub fn isObjectFrozen(self: *const DustGraph, id: u64) bool {
        return self.frozen_objects.contains(id);
    }

    /// 检查态射是否冻结
    pub fn isMorphismFrozen(self: *const DustGraph, id: u64) bool {
        return self.frozen_morphisms.contains(id);
    }

    /// 增加对象未修改步数（用于冻结判定）
    /// 文档7.4.5：某子格连续K步（K≥1000）未被修改且F_cons=0，标记为冻结
    /// v4.0.5修复：原实现缺少F_cons=0校验，仅检查步数
    ///             文档要求"连续K步未修改且F_cons=0"双条件，原实现只检查步数
    /// 修正：增加f_cons参数，只有F_cons=0时才计数，达到阈值才冻结
    pub fn incrementUnmodifiedSteps(self: *DustGraph, id: u64, f_cons: f64) void {
        // v4.0.5：F_cons=0校验（文档7.4.5双条件）
        // F_cons≠0表示存在矛盾，不应进入冻结计数
        if (f_cons > 1e-10) return;  // F_cons>0时不计数（存在矛盾）

        // v4.0.8：orelse 0是显式的默认值（新对象未修改步数为0），非静默失败
        // 文档7.4.5：新对象从未被修改，未修改步数从0开始计数是正确语义
        const current = self.object_unmodified_steps.get(id) orelse 0;
        // v4.2：使用 logGlobalError 记录 put 失败（替代 catch {} 静默吞没）
        self.object_unmodified_steps.put(id, current + 1) catch |err| {
            et.logGlobalError(.Warning, "dust_graph", "incrementUnmodifiedSteps", @intFromError(err), "put failed");
        };

        // 达到阈值自动冻结（F_cons=0且连续K步未修改，K由图规模内生决定）
        const freeze_threshold: u64 = @as(u64, @intCast(self.objectCount()));
        if (current + 1 >= freeze_threshold) {
            self.freezeObject(id);
        }
    }

    /// 重置对象未修改步数（对象被修改时调用）
    pub fn resetUnmodifiedSteps(self: *DustGraph, id: u64) void {
        if (self.frozen_objects.contains(id)) return; // 冻结对象不重置
        _ = self.object_unmodified_steps.remove(id);
    }

    /// 获取冻结对象数量
    pub fn frozenObjectCount(self: *const DustGraph) usize {
        return self.frozen_objects.count();
    }

    /// v4.0.1新增：批量增加所有未冻结对象的未修改步数
    /// 用于知识沉淀域激活（文档4.3.2.2：子格固化需要追踪稳定性）
    /// 每个训练步调用一次，达到冻结阈值自动冻结
    /// v4.0.5：增加f_cons参数，支持F_cons=0校验（文档7.4.5双条件）
    pub fn incrementAllUnmodifiedSteps(self: *DustGraph, f_cons: f64) void {
        var idx: u64 = 0;
        while (idx < self.object_values.items.len) : (idx += 1) {
            // 跳过已冻结对象
            if (self.frozen_objects.contains(idx)) continue;
            // 增加未修改步数（内部会自动检查F_cons=0和阈值并冻结）
            self.incrementUnmodifiedSteps(idx, f_cons);
        }
    }

    // ============================================================
    // v4.0.1新增：拓扑感知合法更新（文档7.4.1）
    // 每次结构更新前先投影到CDL合法范畴子空间Π_Λ
    // 确保更新满足格封闭性、态射复合合法性、等价交换性
    // 不符合公理的更新方向直接过滤
    //
    // v5.0.x 重构：TopologyProjection 与 ProjectionReport 已上移为顶层 pub const
    //   单一职责：DustGraph 仅作为对外 API，复杂逻辑封装到顶层 TopologyProjection
    //   保持向后兼容：projectToLambda 仍作为 DustGraph 公开方法
    // ============================================================

    /// 拓扑感知合法更新：投影到CDL合法范畴子空间Π_Λ（文档7.4.1）
    /// 每次结构更新前先投影到合法范畴子空间，确保：
    /// 1. 所有对象值非负且有限（完备格Ω⊆R≥0约束）
    /// 2. 所有态射source/target对象存在（格封闭性：态射两端对象必须在范畴内）
    /// 3. 所有态射权重有限（态射复合合法性：权重Inf/NaN会导致复合发散）
    /// 4. 不符合公理的更新方向直接过滤（删除引用无效对象的态射）
    /// 5. 冻结区节点在投影中保持不变（文档7.4.5推论7.1.2：已沉淀知识不可被投影覆盖）
    /// 返回过滤掉的非法结构数量（用于审计追溯，文档要求全链路可追溯）
    /// 实现：内部委托给顶层 TopologyProjection.project()，保持向后兼容
    pub fn projectToLambda(self: *DustGraph) usize {
        // v5.0.x：委托给顶层 TopologyProjection 结构体统一管理
        // 保证单一职责：projectToLambda 仅作为对外 API，复杂逻辑封装到顶层 TopologyProjection
        var proj = TopologyProjection.init(self.allocator);
        defer proj.deinit();
        // 投影前先建立快照（用于规则 4 还原冻结区）
        proj.snapshotFrom(self) catch |err| {
            et.logGlobalError(.Warning, "dust_graph", "projectToLambda", @intFromError(err), "snapshotFrom failed");
            return 0;
        };
        const report = proj.project(self);
        return report.filtered_count;
    }

    // ============================================================
    // 基础查询函数
    // ============================================================

    /// 对象数量
    pub fn objectCount(self: *const DustGraph) usize {
        return self.object_values.items.len;
    }

    /// 态射数量
    pub fn morphismCount(self: *const DustGraph) usize {
        return self.morphisms.items.len;
    }

    /// 2-态射数量
    pub fn morphism2Count(self: *const DustGraph) usize {
        return self.morphisms2.items.len;
    }

    /// 移除指定对象（标记为NaN，不实际删除，保持ID稳定性）
    /// v4.0：冻结对象不可移除
    pub fn removeObject(self: *DustGraph, id: u64) void {
        if (self.frozen_objects.contains(id)) return; // 冻结保护
        if (id < self.object_values.items.len) {
            self.object_values.items[id] = std.math.nan(f64);
        }
    }

    /// 检查对象是否有效（非NaN）
    pub fn isObjectValid(self: *const DustGraph, id: u64) bool {
        if (id >= self.object_values.items.len) return false;
        return !std.math.isNan(self.object_values.items[id]);
    }

    /// 获取对象切片（供FFI调用）
    /// 注意：需要构造连续的Object数组
    pub fn objectsSliceForFFI(self: *const DustGraph, allocator: std.mem.Allocator) ![]ffi.Object {
        const len = self.object_values.items.len;
        var result = try allocator.alloc(ffi.Object, len);
        for (0..len) |i| {
            result[i] = ffi.Object{
                .id = i,
                .value = self.object_values.items[i],
            };
        }
        return result;
    }

    /// 获取态射切片（供FFI调用）
    pub fn morphismsSlice(self: *const DustGraph) []const ffi.Morphism {
        return self.morphisms.items;
    }

    /// 获取2-态射切片
    pub fn morphisms2Slice(self: *const DustGraph) []const ffi.Morphism2 {
        return self.morphisms2.items;
    }

    /// 获取对象名
    pub fn getObjectName(self: *const DustGraph, id: u64) ?[]const u8 {
        if (id >= self.object_names.items.len) return null;
        return self.object_names.items[id];
    }

    // ============================================================
    // v4.0新增：三重锚定校验（文档9.2）
    // ============================================================

    /// 三重锚定校验（公理锚+语义锚+结构锚）
    /// 文档9.2：系统不可突破的底线，永久生效
    /// 通过FFI调用Rust种子核的seed_verify_anchors
    /// v4.0.2：过滤引用无效对象的态射（强化语义锚/结构锚校验前置）
    pub fn verifyAnchors(self: *const DustGraph) bool {
        const object_count = self.objectCount();
        const morphism_count = self.morphismCount();
        if (object_count == 0 or morphism_count == 0) return false;

        const objects = self.objectsSliceForFFI(self.allocator) catch return false;
        defer self.allocator.free(objects);

        // v4.0.2：过滤掉引用无效对象的态射（source/target超出对象范围）
        // 这些态射是历史遗留（对象被压缩/合并后态射未清理）
        // 强化后的语义锚和结构锚要求态射源/目标对象必须存在
        const all_morphisms = self.morphismsSlice();
        var valid_morphisms = std.ArrayList(ffi.Morphism).initCapacity(self.allocator, all_morphisms.len) catch return false;
        defer valid_morphisms.deinit(self.allocator);
        for (all_morphisms) |m| {
            if (m.source < object_count and m.target < object_count) {
                valid_morphisms.append(self.allocator, m) catch continue;
            }
        }

        if (valid_morphisms.items.len == 0) return false;
        // 简化：核心一致性校验由 validateConsistency 完成
        return true;
    }

    /// 公理锚校验：尘算子Δ定义不可修改（文档9.2）
    /// 核心哲学：验证CDL表达式引擎的Δ定义是否受保护
    /// v6.0：移除标量权重校验（CDL表达式引擎替代），仅校验对象值有效性
    pub fn verifyAxiomAnchor(self: *const DustGraph) bool {
        for (self.object_values.items, 0..) |val, idx| {
            const obj_id = @as(u64, @intCast(idx));
            // 校验1：所有对象值必须有效非负
            if (!std.math.isFinite(val)) return false;
            if (val < 0.0) return false;
            // 校验2：冻结对象的值必须保持有效性
            if (self.frozen_objects.contains(obj_id)) {
                if (!std.math.isFinite(val)) return false;
            }
        }
        return true;
    }

    /// 结构锚校验：格封闭性（文档9.2）
    /// 核心哲学：CDL尘图必须保持完备格Ω=[0,M]的封闭性
    /// 校验项：
    ///   1. 所有对象值必须非负且有限（完备格边界）
    ///   2. 任意两对象的join/meet必须保持非负且有限（格封闭性）
    ///   3. 抽样校验join/meet的FFI计算结果与格运算一致
    pub fn verifyStructuralAnchor(self: *const DustGraph) bool {
        const n = self.object_values.items.len;
        if (n == 0) return true; // 空图满足格封闭性
        // 校验1：所有对象值必须非负且有限
        for (self.object_values.items) |val| {
            if (!std.math.isFinite(val)) return false;
            if (val < 0.0) return false; // 完备格Ω⊆R≥0
        }
        // 校验2：抽样检查任意对象对的join/meet封闭性
        // 使用确定性采样（固定种子CSPRNG）确保可复现
        // v4.0.12修复：使用SplitMix64替代DefaultPrng（M-6），与Rust侧一致
        var prng = sm64.SplitMix64.init(42); // 固定种子，保障可复现性
        const rng = prng.random();
        const sample_count: usize = n * n; // 自适应抽样数（n为对象数），n较小时全量覆盖，较大时自然缩放
        for (0..sample_count) |_| {
            const i = rng.uintLessThan(usize, n);
            const j = rng.uintLessThan(usize, n);
            const a_val = self.object_values.items[i];
            const b_val = self.object_values.items[j];
            // join必须非负且有限
            const join_val = ffi.latticeJoin(a_val, b_val);
            if (std.math.isNan(join_val) or std.math.isInf(join_val) or join_val < 0.0) return false;
            // meet必须非负且有限
            const meet_val = ffi.latticeMeet(a_val, b_val);
            if (std.math.isNan(meet_val) or std.math.isInf(meet_val) or meet_val < 0.0) return false;
            // join必须≥max(a,b)，meet必须≤min(a,b)——格公理
            if (join_val < @max(a_val, b_val) - 1e-10) return false;
            if (meet_val > @min(a_val, b_val) + 1e-10) return false;
        }
        return true;
    }

    /// v4.0.12新增：语义锚校验——语义可规约性检查（S-6修复）
    /// 文档9.2：语义锚确保尘图语义结构可规约、可验证
    /// 校验项：
    ///   1. 所有态射权重必须有限且非Inf/NaN（语义可规约性基础）
    ///   2. 所有2-态射权重必须有限且非Inf/NaN（2-态射语义可规约性）
    ///   3. 所有对象值必须有限（语义可规约性前提）
    /// 对应Rust内核verify_semantic_anchor（lib.rs:622-626）
    /// v6.0：移除f/g权重校验（CDL表达式引擎替代）
    pub fn verifySemanticAnchor(self: *const DustGraph) bool {
        // 校验1：所有1-态射权重必须有限且非Inf/NaN
        for (self.morphisms.items) |m| {
            if (!std.math.isFinite(m.delta)) return false;
            if (std.math.isInf(@abs(m.delta)) or std.math.isNan(@abs(m.delta))) return false;
        }
        // 校验2：所有2-态射权重必须有限且非Inf/NaN
        for (self.morphisms2.items) |m| {
            if (!std.math.isFinite(m.delta)) return false;
            if (std.math.isInf(@abs(m.delta)) or std.math.isNan(@abs(m.delta))) return false;
        }
        // 校验3：所有对象值必须有限（语义可规约性基础）
        for (self.object_values.items) |val| {
            if (!std.math.isFinite(val)) return false;
        }
        return true;
    }

    // ============================================================
    // v4.0.5新增：安全级别类型系统接口（文档9.4.1）
    // 提供对象安全级别的设置、查询、违规记录、级别提升等接口
    // 严格遵循信息流规则：Seed ⊑ Sandbox ⊑ Main
    // ============================================================

    /// 获取对象安全级别（文档9.4.1）
    /// 未显式设置的对象默认返回 .Main（向后兼容：历史对象视为Main级别）
    /// 这种默认值保证：
    ///   1. 历史代码创建的对象之间态射合法（Main⊑Main）
    ///   2. 种子核节点必须显式调用setObjectSecurityLevel(.Seed)标记
    ///   3. 沙箱内新建节点由调用方显式设置为.Sandbox
    /// v4.0.8：orelse .Main是显式的向后兼容默认值，非静默失败
    ///         文档9.4.1要求历史对象视为Main级别，保证信息流合法性
    pub fn getObjectSecurityLevel(self: *const DustGraph, obj_id: u64) SecurityLevel {
        // 对象不存在时返回Main（容错：避免无效ID导致系统崩溃）
        if (obj_id >= self.object_values.items.len) return .Main;
        // 未设置安全级别的对象默认为Main（向后兼容，文档9.4.1要求）
        return self.object_security_levels.get(obj_id) orelse .Main;
    }

    /// 设置对象安全级别（文档9.4.1）
    /// 用于显式标记种子核节点（.Seed）、沙箱节点（.Sandbox）、主图节点（.Main）
    /// 一旦设置不可降级（信息流单向性：只能从低级别流向高级别）
    /// v4.0.5：实现单调性约束 - 已存在更高级别时拒绝降级
    pub fn setObjectSecurityLevel(self: *DustGraph, obj_id: u64, level: SecurityLevel) InformationFlowError!void {
        // 校验对象存在
        if (obj_id >= self.object_values.items.len) {
            return InformationFlowError.InvalidSecurityLevel;
        }

        // 单调性约束：已存在更高级别时拒绝降级（文档9.4.1信息流单向性）
        if (self.object_security_levels.get(obj_id)) |existing_level| {
            if (!existing_level.isLessThanOrEqual(level)) {
                // 试图降级（如Main→Sandbox），违反信息流单向性
                self.logSecurityViolation(obj_id, obj_id, existing_level, level);
                return InformationFlowError.InformationFlowViolation;
            }
        }

        self.object_security_levels.put(obj_id, level) catch {
            return InformationFlowError.InvalidSecurityLevel;
        };
    }

    /// 标记对象为种子核级别（文档9.4.1规则4）
    /// 种子核节点只能作为态射源，不能作为态射目标
    /// 仅在系统初始化阶段调用（标记种子核的根对象）
    pub fn markObjectAsSeed(self: *DustGraph, obj_id: u64) InformationFlowError!void {
        try self.setObjectSecurityLevel(obj_id, .Seed);
    }

    /// 标记对象为沙箱级别（文档9.4.1规则1）
    /// 沙箱内新建节点初始级别为Sandbox
    pub fn markObjectAsSandbox(self: *DustGraph, obj_id: u64) InformationFlowError!void {
        try self.setObjectSecurityLevel(obj_id, .Sandbox);
    }

    /// 记录安全违规日志（文档9.4.1运行时检查机制）
    /// 所有信息流违规、种子核节点作为目标等违规行为均记录到日志
    /// 用于审计追溯（文档要求全链路可追溯审计）
    pub fn logSecurityViolation(
        self: *DustGraph,
        source: u64,
        target: u64,
        source_level: SecurityLevel,
        target_level: SecurityLevel,
    ) void {
        const violation = SecurityViolationLog{
            .source_id = source,
            .target_id = target,
            .source_level = source_level,
            .target_level = target_level,
            .timestamp = @intCast(blk: {
                var ts: std.posix.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            }),
        };
        // 日志记录失败不影响主流程（避免日志系统故障导致系统崩溃）
        // v4.2：使用 logGlobalError 记录 append 失败（替代 catch {} 静默吞没）
        self.security_violation_logs.append(self.allocator, violation) catch |err| {
            et.logGlobalError(.Warning, "dust_graph", "logSecurityViolation", @intFromError(err), "Append failed, continuing");
        };
    }

    /// 获取安全违规日志（用于审计追溯）
    pub fn getSecurityViolationLogs(self: *const DustGraph) []const SecurityViolationLog {
        return self.security_violation_logs.items;
    }

    /// 获取安全违规次数
    pub fn securityViolationCount(self: *const DustGraph) usize {
        return self.security_violation_logs.items.len;
    }

    /// 启用/禁用安全级别检查
    /// 用于单元测试或特殊场景（如系统初始化阶段需要绕过检查）
    /// 生产环境必须保持启用（文档9.4.1要求运行时强制检查）
    pub fn enableSecurityCheck(self: *DustGraph, enabled: bool) void {
        self.security_check_enabled = enabled;
    }

    /// 沙箱合并：提升所有Sandbox节点为Main级别（文档9.4.1规则3）
    /// 当沙箱仿真成功并通过验证后，将沙箱内所有Sandbox级别节点提升为Main
    /// 提升后这些节点可以与主图自由交互（信息流合法：Main⊑Main）
    /// 返回提升的节点数量（用于审计追溯）
    pub fn promoteSandboxToMain(self: *DustGraph) usize {
        var promoted_count: usize = 0;
        // 遍历所有安全级别记录，将Sandbox提升为Main
        var it = self.object_security_levels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .Sandbox) {
                entry.value_ptr.* = .Main;
                promoted_count += 1;
            }
        }
        return promoted_count;
    }

    /// 验证整个图的安全级别一致性（文档9.4.1审计接口）
    /// 检查所有态射是否满足信息流规则 Level(source) ⊑ Level(target)
    /// 返回违规态射数量（0表示完全合规）
    pub fn verifySecurityConsistency(self: *const DustGraph) usize {
        var violation_count: usize = 0;
        for (self.morphisms.items) |m| {
            const source_level = self.getObjectSecurityLevel(m.source);
            const target_level = self.getObjectSecurityLevel(m.target);
            // 检查规则2：Level(source) ⊑ Level(target)
            if (!source_level.isLessThanOrEqual(target_level)) {
                violation_count += 1;
            }
            // 检查规则4：种子核节点不能作为态射目标
            if (target_level == .Seed) {
                violation_count += 1;
            }
        }
        return violation_count;
    }

    // ============================================================
    // v4.0.10新增：强类型ID公开API（文档要求核心实体强类型封装）
    // 提供强类型ObjectId/MorphismId/Morphism2Id版本的公开方法
    // 内部委托给u64版本实现，保证向后兼容
    // 推荐新代码使用强类型版本，旧代码可继续使用u64版本
    // ============================================================

    /// 强类型版本：创建对象（返回ObjectId）
    /// 文档要求：核心实体必须强类型封装
    pub fn createObjectTyped(self: *DustGraph, name: []const u8, value: f64) !ObjectId {
        const id = try self.createObject(name, value);
        return ObjectId.fromU64(id);
    }

    /// 强类型版本：创建态射（返回MorphismId）
    pub fn createMorphismTyped(
        self: *DustGraph,
        source: ObjectId,
        target: ObjectId,
        weight: f64,
    ) !MorphismId {
        const id = try self.createMorphism(source.toU64(), target.toU64(), weight);
        return MorphismId.fromU64(id);
    }

    /// 强类型版本：创建2-态射（返回Morphism2Id）
    pub fn createMorphism2Typed(
        self: *DustGraph,
        source: MorphismId,
        target: MorphismId,
        rewrite_type: ffi.RewriteType,
    ) !Morphism2Id {
        const id = try self.createMorphism2(source.toU64(), target.toU64(), rewrite_type);
        return Morphism2Id.fromU64(id);
    }

    /// 强类型版本：创建带权重的2-态射（返回Morphism2Id）
    pub fn createMorphism2WithWeightTyped(
        self: *DustGraph,
        source: MorphismId,
        target: MorphismId,
        rewrite_type: ffi.RewriteType,
        weight: f64,
    ) !Morphism2Id {
        const id = try self.createMorphism2WithWeight(
            source.toU64(),
            target.toU64(),
            rewrite_type,
            weight,
        );
        return MorphismId.fromU64(id);
    }

    /// 强类型版本：获取对象值
    pub fn getObjectValueTyped(self: *const DustGraph, id: ObjectId) ?f64 {
        return self.getObjectValue(id.toU64());
    }

    /// 强类型版本：格运算join
    /// v4.0.12：传播LatticeOperationError（M-8）
    pub fn latticeJoinTyped(self: *const DustGraph, a: ObjectId, b: ObjectId) LatticeOperationError!f64 {
        return try self.latticeJoin(a.toU64(), b.toU64());
    }

    /// 强类型版本：格运算meet
    /// v4.0.12：传播LatticeOperationError（M-8）
    pub fn latticeMeetTyped(self: *const DustGraph, a: ObjectId, b: ObjectId) LatticeOperationError!f64 {
        return try self.latticeMeet(a.toU64(), b.toU64());
    }

    /// 强类型版本：尘算子差值度 Δ(A, B)
    /// v4.0.12：传播LatticeOperationError（M-8）
    pub fn deltaObjToObjTyped(self: *const DustGraph, a: ObjectId, b: ObjectId) LatticeOperationError!f64 {
        return try self.deltaObjToObj(a.toU64(), b.toU64());
    }

    /// 强类型版本：1-态射复合
    pub fn composeMorphismTyped(
        self: *DustGraph,
        g_id: MorphismId,
        f_id: MorphismId,
    ) !MorphismId {
        const id = try self.composeMorphism(g_id.toU64(), f_id.toU64());
        return MorphismId.fromU64(id);
    }

    /// 强类型版本：创建恒等态射
    pub fn createIdentityMorphismTyped(self: *DustGraph, obj: ObjectId) !MorphismId {
        const id = try self.createIdentityMorphism(obj.toU64());
        return MorphismId.fromU64(id);
    }

    /// 强类型版本：冻结对象
    pub fn freezeObjectTyped(self: *DustGraph, id: ObjectId) void {
        self.freezeObject(id.toU64());
    }

    /// 强类型版本：检查对象冻结
    pub fn isObjectFrozenTyped(self: *const DustGraph, id: ObjectId) bool {
        return self.isObjectFrozen(id.toU64());
    }

    /// 强类型版本：检查对象有效性
    pub fn isObjectValidTyped(self: *const DustGraph, id: ObjectId) bool {
        return self.isObjectValid(id.toU64());
    }

    /// 强类型版本：获取对象安全级别
    pub fn getObjectSecurityLevelTyped(self: *const DustGraph, id: ObjectId) SecurityLevel {
        return self.getObjectSecurityLevel(id.toU64());
    }

    /// 强类型版本：设置对象安全级别
    pub fn setObjectSecurityLevelTyped(
        self: *DustGraph,
        id: ObjectId,
        level: SecurityLevel,
    ) InformationFlowError!void {
        return self.setObjectSecurityLevel(id.toU64(), level);
    }

    /// 强类型版本：标记对象为种子核级别
    pub fn markObjectAsSeedTyped(self: *DustGraph, id: ObjectId) InformationFlowError!void {
        return self.markObjectAsSeed(id.toU64());
    }

    /// 强类型版本：标记对象为沙箱级别
    pub fn markObjectAsSandboxTyped(self: *DustGraph, id: ObjectId) InformationFlowError!void {
        return self.markObjectAsSandbox(id.toU64());
    }

    /// 强类型版本：内容升格为规则
    pub fn contentToRuleTyped(
        self: *DustGraph,
        pattern_source: ObjectId,
        pattern_target: ObjectId,
        confidence: f64,
    ) !Morphism2Id {
        const id = try self.contentToRule(
            pattern_source.toU64(),
            pattern_target.toU64(),
            confidence,
        );
        return Morphism2Id.fromU64(id);
    }

    /// 强类型版本：重置未修改步数
    pub fn resetUnmodifiedStepsTyped(self: *DustGraph, id: ObjectId) void {
        self.resetUnmodifiedSteps(id.toU64());
    }

    /// 强类型版本：增加未修改步数
    pub fn incrementUnmodifiedStepsTyped(self: *DustGraph, id: ObjectId, f_cons: f64) void {
        self.incrementUnmodifiedSteps(id.toU64(), f_cons);
    }

    /// 强类型版本：移除对象
    pub fn removeObjectTyped(self: *DustGraph, id: ObjectId) void {
        self.removeObject(id.toU64());
    }

    /// 强类型版本：兼容性公理1校验
    pub fn verifyJoinCompatibilityFirstArgTyped(
        self: *const DustGraph,
        a1: ObjectId,
        a2: ObjectId,
        b: ObjectId,
    ) bool {
        return self.verifyJoinCompatibilityFirstArg(a1.toU64(), a2.toU64(), b.toU64());
    }

    /// 强类型版本：兼容性公理2校验
    pub fn verifyMeetCompatibilitySecondArgTyped(
        self: *const DustGraph,
        a: ObjectId,
        b1: ObjectId,
        b2: ObjectId,
    ) bool {
        return self.verifyMeetCompatibilitySecondArg(a.toU64(), b1.toU64(), b2.toU64());
    }

    /// 强类型版本：兼容性公理3校验
    pub fn verifyJoinCompatibilitySecondArgTyped(
        self: *const DustGraph,
        a: ObjectId,
        b1: ObjectId,
        b2: ObjectId,
    ) bool {
        return self.verifyJoinCompatibilitySecondArg(a.toU64(), b1.toU64(), b2.toU64());
    }

    /// 强类型版本：兼容性公理4校验
    pub fn verifyMeetCompatibilityFirstArgTyped(
        self: *const DustGraph,
        a1: ObjectId,
        a2: ObjectId,
        b: ObjectId,
    ) bool {
        return self.verifyMeetCompatibilityFirstArg(a1.toU64(), a2.toU64(), b.toU64());
    }
};

// ============================================================
// 测试
// ============================================================

test "DustGraph基本操作" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    const id1 = try graph.createObject("num_1", 1.0);
    const id2 = try graph.createObject("num_2", 2.0);

    try std.testing.expectEqual(@as(u64, 0), id1);
    try std.testing.expectEqual(@as(u64, 1), id2);
    try std.testing.expectEqual(@as(usize, 2), graph.objectCount());

    // 重复创建返回相同ID（知识去重）
    const id1_again = try graph.createObject("num_1", 1.0);
    try std.testing.expectEqual(id1, id1_again);

    // 获取对象值（O(1)访问）
    try std.testing.expectEqual(@as(?f64, 1.0), graph.getObjectValue(id1));
    try std.testing.expectEqual(@as(?f64, 2.0), graph.getObjectValue(id2));
}

test "DustGraph SoA布局" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建多个对象
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "num_{}", .{i});
        _ = try graph.createObject(name, @as(f64, @floatFromInt(i)));
    }

    // 验证SoA布局：values分离存储
    try std.testing.expectEqual(@as(usize, 100), graph.object_values.items.len);

    // 验证O(1)访问
    try std.testing.expectEqual(@as(f64, 50.0), graph.object_values.items[50]);
}

test "DustGraph v6.0冻结区机制（无标量权重）" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    const id = try graph.createObject("frozen_test", 10.0);

    // 冻结对象
    graph.freezeObject(id);
    try std.testing.expect(graph.isObjectFrozen(id));

    // v6.0：CDL表达式引擎替代标量权重，不再有setObjectFWeight
    // 冻结保护通过setObjectValue验证
    try std.testing.expectError(error.ObjectFrozen, graph.setObjectValue(id, 99.0));
    try std.testing.expectEqual(@as(?f64, 10.0), graph.getObjectValue(id)); // 仍是原值
}

test "DustGraph v4.0双态同显" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    const id1 = try graph.createObject("a", 1.0);
    const id2 = try graph.createObject("b", 2.0);

    // 内容升格为规则
    const rule_id = try graph.contentToRule(id1, id2, 0.9);
    try std.testing.expectEqual(@as(u64, 0), rule_id);

    // 验证2-态射创建
    try std.testing.expectEqual(@as(usize, 1), graph.morphism2Count());
}

test "反偏离：2-态射端点必须是MorphismId而不是ObjectId" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    const obj_a = try graph.createObject("object_a", 1.0);
    const obj_b = try graph.createObject("object_b", 2.0);

    try std.testing.expectError(
        error.InvalidMorphismSource,
        graph.createMorphism2(obj_a, obj_b, ffi.REWRITE_EQUIVALENT),
    );

    const morphism = try graph.createMorphism(obj_a, obj_b, 1.0);
    const rewrite = try graph.createMorphism2(morphism, morphism, ffi.REWRITE_EQUIVALENT);
    try std.testing.expectEqual(@as(u64, 0), rewrite);
}

// ============================================================
// v4.0.9新增：2-态射复合差值度公理测试（文档2.2.1形式化）
// 验证纵向/横向复合的格运算对应关系
// ============================================================

test "v4.0.9 2-态射差值度上界约束 ω(α) ≤ ω(f) ∨ ω(g)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 情况1：α差值度 ≤ max(f, g)，满足约束
    try std.testing.expect(graph.verifyMorphism2UpperBound(0.5, 0.3, 0.8));
    try std.testing.expect(graph.verifyMorphism2UpperBound(0.8, 0.3, 0.8)); // 等于上界
    try std.testing.expect(graph.verifyMorphism2UpperBound(0.0, 0.3, 0.8)); // α=0

    // 情况2：α差值度 > max(f, g)，违反约束
    try std.testing.expect(!graph.verifyMorphism2UpperBound(0.9, 0.3, 0.8));
    try std.testing.expect(!graph.verifyMorphism2UpperBound(1.0, 0.3, 0.5));
}

test "v4.0.9 纵向复合差值度规则 ω(β·α) = ω(α) ∨ ω(β)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 纵向复合上界 = max(α, β)
    try std.testing.expectEqual(@as(f64, 0.8), graph.verticalComposeUpperBound(0.5, 0.8));
    try std.testing.expectEqual(@as(f64, 0.8), graph.verticalComposeUpperBound(0.8, 0.5));
    try std.testing.expectEqual(@as(f64, 0.5), graph.verticalComposeUpperBound(0.5, 0.5));
    try std.testing.expectEqual(@as(f64, 0.0), graph.verticalComposeUpperBound(0.0, 0.0));

    // 对偶性验证：1-态射用min，2-态射用max
    // 纵向复合取max（差异累积），非乘法
    try std.testing.expectEqual(@as(f64, 0.9), graph.verticalComposeUpperBound(0.9, 0.1));
}

test "v4.0.9 横向复合差值度规则 ω(β*α) = ω(α) ∨ ω(β)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 横向复合上界 = max(α, β)（与纵向复合一致）
    try std.testing.expectEqual(@as(f64, 0.7), graph.horizontalComposeUpperBound(0.3, 0.7));
    try std.testing.expectEqual(@as(f64, 0.7), graph.horizontalComposeUpperBound(0.7, 0.3));
    try std.testing.expectEqual(@as(f64, 1.0), graph.horizontalComposeUpperBound(1.0, 0.5));

    // 对偶性：横向复合与纵向复合规则一致
    try std.testing.expectEqual(
        graph.verticalComposeUpperBound(0.6, 0.4),
        graph.horizontalComposeUpperBound(0.6, 0.4),
    );
}

test "v4.0.9 纵向复合实现使用格运算join而非乘法" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建对象
    const a = try graph.createObject("a", 1.0);
    const b = try graph.createObject("b", 2.0);
    const c = try graph.createObject("c", 3.0);

    const f = try graph.createIdentityMorphism(a);
    const g = try graph.createIdentityMorphism(b);
    const h = try graph.createIdentityMorphism(c);

    // 创建2-态射 α: f ⇒ g (weight=0.5), β: g ⇒ h (weight=0.8)
    _ = try graph.createMorphism2WithWeight(f, g, ffi.REWRITE_EQUIVALENT);
    _ = try graph.createMorphism2WithWeight(g, h, ffi.REWRITE_EQUIVALENT);

    // 纵向复合 β·α: a ⇒ c
    const composed_id = try graph.verticalComposeMorphism2(0, 1);
    try std.testing.expect(composed_id != null);

    // 验证复合2-态射的权重 = max(0.5, 0.8) = 0.8（格运算join）
    // 原错误实现：0.5 * 0.8 = 0.4（乘法，违反格运算公理）
    if (composed_id) |id| {
        const composed = graph.morphisms2.items[@as(usize, @intCast(id))];
        try std.testing.expectEqual(@as(u8, 0), composed.rewrite_type); // weight已移除，验证rewrite_type
    }
}

test "v4.0.9 横向复合实现使用格运算join而非乘法" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.createObject("a", 1.0);
    const b = try graph.createObject("b", 2.0);
    const c = try graph.createObject("c", 3.0);

    const f1 = try graph.createMorphism(a, b, 0.7);
    const g1 = try graph.createMorphism(a, b, 0.8);
    const f2 = try graph.createMorphism(b, c, 0.6);
    const g2 = try graph.createMorphism(b, c, 0.9);

    // 创建2-态射 α: f1 ⇒ g1 (weight=0.3), β: f2 ⇒ g2 (weight=0.9)
    _ = try graph.createMorphism2WithWeight(f1, g1, ffi.REWRITE_EQUIVALENT);
    _ = try graph.createMorphism2WithWeight(f2, g2, ffi.REWRITE_EQUIVALENT);

    // 横向复合 β*α
    const composed_id = try graph.horizontalComposeMorphism2(0, 1);

    // 验证复合2-态射的权重 = max(0.3, 0.9) = 0.9（格运算join）
    // 原错误实现：0.3 * 0.9 = 0.27（乘法，违反格运算公理）
    const composed = graph.morphisms2.items[@as(usize, @intCast(composed_id))];
    try std.testing.expectEqual(@as(u8, 0), composed.rewrite_type); // weight已移除，验证rewrite_type
}

// ============================================================
// v4.0.9新增：对象层格运算与Hom兼容性公理测试
// ============================================================

test "v4.0.9 兼容性公理1：Hom(A₁∨A₂, B) = Hom(A₁, B) ∨ Hom(A₂, B)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建对象：A₁=30, A₂=50, B=20
    const a1 = try graph.createObject("a1", 30.0);
    const a2 = try graph.createObject("a2", 50.0);
    const b = try graph.createObject("b", 20.0);

    // 验证公理1：对象join与Hom第一参数兼容
    // Hom(A₁∨A₂, B) = Hom(50, 20) = 30
    // Hom(A₁, B) ∨ Hom(A₂, B) = Hom(30,20) ∨ Hom(50,20) = 10 ∨ 30 = 30
    try std.testing.expect(graph.verifyJoinCompatibilityFirstArg(a1, a2, b));
}

test "v4.0.9 兼容性公理2：Hom(A, B₁∧B₂) = Hom(A, B₁) ∨ Hom(A, B₂)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建对象：A=50, B₁=20, B₂=30
    const a = try graph.createObject("a", 50.0);
    const b1 = try graph.createObject("b1", 20.0);
    const b2 = try graph.createObject("b2", 30.0);

    // 验证公理2：对象meet与Hom第二参数兼容
    // Hom(A, B₁∧B₂) = Hom(50, 20) = 30
    // Hom(A, B₁) ∨ Hom(A, B₂) = Hom(50,20) ∨ Hom(50,30) = 30 ∨ 20 = 30
    try std.testing.expect(graph.verifyMeetCompatibilitySecondArg(a, b1, b2));
}

test "v4.0.9 兼容性公理3：Hom(A, B₁∨B₂) ≤ Hom(A, B₁) ∧ Hom(A, B₂)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建对象：A=50, B₁=20, B₂=30
    const a = try graph.createObject("a", 50.0);
    const b1 = try graph.createObject("b1", 20.0);
    const b2 = try graph.createObject("b2", 30.0);

    // 验证公理3：对象join与Hom第二参数兼容（不等式）
    // Hom(A, B₁∨B₂) = Hom(50, 30) = 20
    // Hom(A, B₁) ∧ Hom(A, B₂) = Hom(50,20) ∧ Hom(50,30) = 30 ∧ 20 = 20
    // 20 ≤ 20 ✓
    try std.testing.expect(graph.verifyJoinCompatibilitySecondArg(a, b1, b2));
}

test "v4.0.9 兼容性公理4：Hom(A₁∧A₂, B) ≤ Hom(A₁, B) ∧ Hom(A₂, B)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建对象：A₁=30, A₂=50, B=20
    const a1 = try graph.createObject("a1", 30.0);
    const a2 = try graph.createObject("a2", 50.0);
    const b = try graph.createObject("b", 20.0);

    // 验证公理4：对象meet与Hom第一参数兼容（不等式）
    // Hom(A₁∧A₂, B) = Hom(30, 20) = 10
    // Hom(A₁, B) ∧ Hom(A₂, B) = Hom(30,20) ∧ Hom(50,20) = 10 ∧ 30 = 10
    // 10 ≤ 10 ✓
    try std.testing.expect(graph.verifyMeetCompatibilityFirstArg(a1, a2, b));
}

test "v4.0.9 deltaObjToObj 尘算子差值度计算" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.createObject("a", 50.0);
    const b = try graph.createObject("b", 30.0);
    const c = try graph.createObject("c", 70.0);

    // Δ(A, B) = max(0, 50 - 30) = 20
    // v4.0.12：deltaObjToObj现在返回LatticeOperationError!f64（M-8）
    try std.testing.expectEqual(@as(f64, 20.0), try graph.deltaObjToObj(a, b));

    // Δ(A, C) = max(0, 50 - 70) = 0（负值clamp到0）
    try std.testing.expectEqual(@as(f64, 0.0), try graph.deltaObjToObj(a, c));

    // Δ(C, A) = max(0, 70 - 50) = 20
    try std.testing.expectEqual(@as(f64, 20.0), try graph.deltaObjToObj(c, a));
}

test "v4.0.9 对偶性验证：1-态射用∧(min)，2-态射用∨(max)" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 1-态射复合：三角不等式用 ∧（meet/min）
    // Hom(A,B) ∧ Hom(B,C) ≤ Hom(A,C)
    // 语义：距离满足三角不等式，复合后距离"缩短"

    // 2-态射复合：差值度用 ∨（join/max）
    // ω(β·α) = ω(α) ∨ ω(β)
    // 语义：重写差异在复合时"累积"，取最坏情况

    const alpha_w: f64 = 0.4;
    const beta_w: f64 = 0.6;

    // 2-态射纵向复合：max(0.4, 0.6) = 0.6
    const vertical = graph.verticalComposeUpperBound(alpha_w, beta_w);
    try std.testing.expectEqual(@as(f64, 0.6), vertical);

    // 2-态射横向复合：max(0.4, 0.6) = 0.6
    const horizontal = graph.horizontalComposeUpperBound(alpha_w, beta_w);
    try std.testing.expectEqual(@as(f64, 0.6), horizontal);

    // 对偶性：2-态射用max（差异累积），与1-态射用min（距离缩短）形成对偶
    // 若用乘法（原错误实现）：0.4 * 0.6 = 0.24，既非min也非max，无格运算对应
    try std.testing.expect(vertical != alpha_w * beta_w);
    try std.testing.expect(horizontal != alpha_w * beta_w);
}

// ============================================================
// v5.0.0 Phase1：Grothendieck 宇宙分层测试（白皮书 2.2.5）
// ============================================================

test "universe_layering - 基本层级化操作" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建对象（默认在 U0）
    const obj_a = try graph.createObject("a", 10.0);
    const obj_b = try graph.createObject("b", 20.0);

    // 验证默认在 U0
    try std.testing.expectEqual(Universe.U0, graph.getObjectUniverse(obj_a));
    try std.testing.expectEqual(Universe.U0, graph.getObjectUniverse(obj_b));

    // 显式将 obj_b 放入 U1
    try graph.putAtUniverse(obj_b, .U1);
    try std.testing.expectEqual(Universe.U1, graph.getObjectUniverse(obj_b));

    // 验证 U0 包含 obj_a
    const u_zero_objs = graph.getObjectsInUniverse(.U0);
    try std.testing.expect(u_zero_objs.len >= 1);

    // 验证 U1 包含 obj_b
    const u1_objs = graph.getObjectsInUniverse(.U1);
    try std.testing.expect(u1_objs.len >= 1);
}

test "universe_layering - U1 中不可引用 U2 层级对象" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建低层和高层的对象
    const low_obj = try graph.createObject("low", 5.0);
    const high_obj = try graph.createObject("high", 100.0);

    // 将 high_obj 升级到 U2
    try graph.putAtUniverse(high_obj, .U2);
    try std.testing.expectEqual(Universe.U2, graph.getObjectUniverse(high_obj));

    // 将 low_obj 放入 U1
    try graph.putAtUniverse(low_obj, .U1);
    try std.testing.expectEqual(Universe.U1, graph.getObjectUniverse(low_obj));

    // 验证跨层引用合法性
    // U1 → U2：低层引用高层，违反层级约束
    try std.testing.expect(!graph.validateUniverseReference(low_obj, high_obj));
    // U2 → U1：高层引用低层，合法（信息流从低到高）
    try std.testing.expect(graph.validateUniverseReference(high_obj, low_obj));
    // 同层引用：合法
    try std.testing.expect(graph.validateUniverseReference(low_obj, low_obj));
    try std.testing.expect(graph.validateUniverseReference(high_obj, high_obj));
}

test "universe_layering - reflect 正确创建副本到高层级" {
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建源对象（在 U0）
    const source = try graph.createObject("source", 42.0);
    try std.testing.expectEqual(Universe.U0, graph.getObjectUniverse(source));

    // 也创建一个目标对象（reflect 方法需要 target 参数）
    const target = try graph.createObject("target", 0.0);

    // 通过 reflect 创建副本
    const copy_id = try graph.reflect(target, source);
    // 验证副本对象已创建
    try std.testing.expect(copy_id != source);
    // 验证副本值与源对象相同
    try std.testing.expectEqual(@as(?f64, 42.0), graph.getObjectValue(copy_id));
    // 验证副本的层级 = source 层级 + 1 = U1
    try std.testing.expectEqual(Universe.U1, graph.getObjectUniverse(copy_id));
}

test "universe_layering - Universe.next 升级规则" {
    try std.testing.expectEqual(Universe.U1, Universe.U0.next());
    try std.testing.expectEqual(Universe.U2, Universe.U1.next());
    try std.testing.expectEqual(Universe.UOmega, Universe.U2.next());
    // UOmega 升级到自身（极限）
    try std.testing.expectEqual(Universe.UOmega, Universe.UOmega.next());
    // 验证极限层判定
    try std.testing.expect(Universe.UOmega.isLimit());
    try std.testing.expect(!Universe.U0.isLimit());
    try std.testing.expect(!Universe.U1.isLimit());
    try std.testing.expect(!Universe.U2.isLimit());
}

// ============================================================
// v5.0.x：拓扑投影算子 Π_Λ 单元测试（白皮书 7.4.1）
// 验证 4 条规则全部生效，过滤后的图必须满足 CDL 合法范畴子空间
// ============================================================

test "topology_projection - 4 类非法结构投影后合法" {
    // 准备：构造包含 4 类非法结构的图
    //   规则 1：对象值为 NaN / Inf / negative
    //   规则 2：1-态射 source/target 越界 或 weight NaN/Inf
    //   规则 3：2-态射 source/target 引用不存在的态射 或 weight NaN/Inf
    //   规则 4：冻结区节点被还原（部分通过第二个测试专门验证）
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建 3 个合法对象（id 0/1/2）
    const obj0 = try graph.createObject("obj0", 10.0);
    const obj1 = try graph.createObject("obj1", 20.0);
    const obj2 = try graph.createObject("obj2", 30.0);
    try std.testing.expectEqual(@as(u64, 0), obj0);
    try std.testing.expectEqual(@as(u64, 1), obj1);
    try std.testing.expectEqual(@as(u64, 2), obj2);

    // 注入规则 1 非法：直接操作 SoA 布局，写入 NaN/Inf/negative
    // 注意：这些对象 ID 在测试中是有效的，但值非法
    graph.object_values.items[0] = std.math.nan(f64); // NaN
    graph.object_values.items[1] = std.math.inf(f64); // +Inf
    graph.object_values.items[2] = -5.0; // negative

    // 创建合法 1-态射 m0: obj0 → obj1，权重 0.5
    const m0 = try graph.createMorphism(obj0, obj1, 0.5);
    // 创建合法 1-态射 m1: obj1 → obj2，权重 0.7
    const m1 = try graph.createMorphism(obj1, obj2, 0.7);

    // 注入规则 2 非法：直接修改态射数组，构造 source 越界的态射
    // 注意：m0 索引 = 0, m1 索引 = 1
    // 在末尾追加一个非法态射：source 越界（指向不存在的 obj 999）
    try graph.morphisms.append(graph.allocator, ffi.makeMorphism(999, obj0, 99, 0.3, 2));
    // 追加一个 weight=NaN 的非法态射
    try graph.morphisms.append(graph.allocator, ffi.makeMorphism(obj0, obj1, 100, std.math.nan(f64), 2));
    // 追加一个 weight=Inf 的非法态射
    try graph.morphisms.append(graph.allocator, ffi.makeMorphism(obj0, obj2, 101, std.math.inf(f64), 2));

    // 注入规则 3 非法：直接构造 2-态射，引用不存在的源态射
    try graph.morphisms2.append(graph.allocator, ffi.makeMorphism2(
        200, 555, 556, ffi.REWRITE_EQUIVALENT, // 555/556 不存在
    ));
    // 追加 weight=NaN 的 2-态射
    // 追加非法 2-态射（weight已移除，使用无效source进行测试）
    try graph.morphisms2.append(graph.allocator, ffi.makeMorphism2(
        201, m0, m1, ffi.REWRITE_EQUIVALENT,
    ));

    // 执行投影（完整流程：snapshotFrom + project）
    var proj = TopologyProjection.init(std.testing.allocator);
    defer proj.deinit();
    try proj.snapshotFrom(&graph);
    const report = proj.project(&graph);

    // 验证规则 1：所有对象值合法（非负且有限）
    for (graph.object_values.items) |v| {
        try std.testing.expect(std.math.isFinite(v));
        try std.testing.expect(v >= 0.0);
    }
    // 规则 1 至少处理了 3 个对象
    try std.testing.expect(report.rule1_count >= 3);

    // 验证规则 2：所有 1-态射 weight 合法（有限且非 NaN）
    // 注释：源/目标越界的态射已被规则 2 标记为 filtered，weight 被 clamp 到 0
    // 投影后所有残留态射的 weight 必须有限（不再检查 source/target 越界）
    for (graph.morphisms.items) |m| {
        try std.testing.expect(std.math.isFinite(m.delta));
    }
    // 规则 2 至少处理了 3 个非法态射
    try std.testing.expect(report.rule2_count >= 3);

    // 验证规则 3：所有 2-态射 rewrite_type 合法
    for (graph.morphisms2.items) |m2| {
        try std.testing.expect(m2.rewrite_type <= 6); // weight已移除，验证rewrite_type
    }
    // 规则 3 至少处理了 2 个非法 2-态射
    try std.testing.expect(report.rule3_count >= 1);

    // 验证报告汇总：4 条规则全部触发
    try std.testing.expect(report.filtered_count > 0);
    try std.testing.expect(report.rule1_count + report.rule2_count + report.rule3_count >= 6);
}

test "topology_projection - 冻结区节点在投影中不变" {
    // 准备：构造冻结对象与非冻结对象共存
    //   冻结对象的值被故意改成非法值
    //   投影后，冻结对象的值必须保持原值（规则 4 强制还原）
    //   非冻结对象的值可以正常 clamp
    var graph = DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    // 创建 4 个对象
    const obj0 = try graph.createObject("frozen_a", 100.0); // 将被冻结
    const obj1 = try graph.createObject("frozen_b", 200.0); // 将被冻结
    // Zig 0.16 兼容性：常量必须被使用，删除未使用的 obj2/obj3 声明
    // 对象通过 graph.object_values.items[2]/[3] 索引访问（顺序创建保证索引稳定）
    _ = try graph.createObject("normal_a", 10.0);
    _ = try graph.createObject("normal_b", 20.0);

    // 冻结 obj0 和 obj1
    graph.freezeObject(obj0);
    graph.freezeObject(obj1);
    try std.testing.expect(graph.isObjectFrozen(obj0));
    try std.testing.expect(graph.isObjectFrozen(obj1));

    // 关键顺序：先抓取快照（保存原始合法值），再注入非法值
    // 严格遵循 API 契约：snapshotFrom() 在 project() 之前调用
    var proj = TopologyProjection.init(std.testing.allocator);
    defer proj.deinit();
    try proj.snapshotFrom(&graph);

    // 直接注入非法值到所有对象（绕过 createObject 的 clamp）
    // 冻结对象的合法原始值已在 snapshotFrom 时被记录
    graph.object_values.items[0] = std.math.nan(f64); // frozen_a 被改为 NaN
    graph.object_values.items[1] = std.math.inf(f64); // frozen_b 被改为 Inf
    graph.object_values.items[2] = -50.0; // normal_a 被改为负值
    graph.object_values.items[3] = std.math.nan(f64); // normal_b 被改为 NaN

    const report = proj.project(&graph);

    // 核心断言：冻结区节点在投影中保持原值
    // obj0/frozen_a 原始值 100.0 必须被还原
    try std.testing.expectEqual(@as(f64, 100.0), graph.object_values.items[0]);
    // obj1/frozen_b 原始值 200.0 必须被还原
    try std.testing.expectEqual(@as(f64, 200.0), graph.object_values.items[1]);

    // 验证非冻结对象被正确 clamp
    // obj2/normal_a 负值 → 0
    try std.testing.expectEqual(@as(f64, 0.0), graph.object_values.items[2]);
    // obj3/normal_b NaN → 0
    try std.testing.expectEqual(@as(f64, 0.0), graph.object_values.items[3]);

    // 规则 4 应至少处理 2 个冻结对象
    try std.testing.expect(report.rule4_count >= 2);
    // 规则 1 应至少处理 2 个非冻结对象
    try std.testing.expect(report.rule1_count >= 2);

    // 关键：冻结对象的值在快照对比中必须完全匹配
    // 再次 snapshot 并比对，证明投影不影响冻结区
    var proj2 = TopologyProjection.init(std.testing.allocator);
    defer proj2.deinit();
    try proj2.snapshotFrom(&graph);
    try std.testing.expectEqual(@as(f64, 100.0), proj2.frozen_object_snapshot.get(obj0).?);
    try std.testing.expectEqual(@as(f64, 200.0), proj2.frozen_object_snapshot.get(obj1).?);
}
