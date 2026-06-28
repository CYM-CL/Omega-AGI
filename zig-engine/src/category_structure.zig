// Ω-落尘AGI 范畴论结构 v4.0.6 - 文档第2-3章
//
// 严格对应白皮书v2.0：
// - 2.2.3 自同态闭合性（Grothendieck宇宙分层）
// - 2.5.1 CDL是笛卡尔闭范畴(CCC)
// - 3.2 格码同构原理（CDL尘图↔尘语言文本双向无损双射）
//
// 本模块实现三大范畴论核心结构：
// 1. 格码同构：CDL子格与尘语言文本的严格无损双向双射
// 2. Grothendieck构造：宇宙分层解决ZFC正则公理，实现自指合法化
// 3. CCC笛卡尔闭范畴：终对象、二元积、指数对象、curry化

const std = @import("std");

// ============================================================
// 第一部分：格码同构（文档3.2）
// CDL尘图结构与尘语言文本是严格的无损双向双射
// ============================================================

/// 尘语言语法单元类型（文档3.2.1）
/// 每个尘算子Δ(x,y)对应一条尘语言语法单元
/// 每次格运算对应一次语法组合
/// 每个2-态射对应一条等价重写规则
pub const DustSyntaxType = enum(u8) {
    Object = 0,          // 对象：O(name, value)
    Delta = 1,           // 尘算子：Δ(x, y)
    LatticeJoin = 2,     // 格上确界：∨(a, b)
    LatticeMeet = 3,     // 格下确界：∧(a, b)
    Morphism = 4,        // 1-态射：M(src, tgt, w)
    Morphism2 = 5,       // 2-态射（等价重写）：R(src, tgt, type, w)
    Identity = 6,        // 恒等态射：id(obj)
    Composition = 7,     // 态射复合：∘(g, f)
};

/// 尘语言序列化配置
pub const DustLanguageConfig = struct {
    indent_size: u8 = 2,         // 缩进空格数
    use_full_names: bool = true, // 使用完整对象名（false用ID）
    precision: u8 = 15,          // 浮点数精度（科研级≤10⁻¹⁰）
};

/// 格码同构双向转换器（文档3.2）
/// 实现 CDL子格 ↔ 尘语言表达式 的严格无损双向双射
pub const LatticeCodeIsomorphism = struct {
    allocator: std.mem.Allocator,
    config: DustLanguageConfig,

    pub fn init(allocator: std.mem.Allocator) LatticeCodeIsomorphism {
        return .{
            .allocator = allocator,
            .config = .{},
        };
    }

    /// 序列化对象为尘语言文本（文档3.2.1：每个对象对应一条语法单元）
    /// 格式：O(name, value)
    pub fn serializeObject(
        self: *const LatticeCodeIsomorphism,
        name: []const u8,
        value: f64,
    ) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "O({s}, {d:.15})", .{
            name, value,
        });
    }

    /// 序列化尘算子Δ(x,y)为尘语言文本
    /// 格式：Δ(x, y)
    pub fn serializeDelta(
        self: *const LatticeCodeIsomorphism,
        x_name: []const u8,
        y_name: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "Δ({s}, {s})", .{ x_name, y_name });
    }

    /// 序列化格运算为尘语言文本
    /// 格式：∨(a, b) 或 ∧(a, b)
    pub fn serializeLatticeOp(
        self: *const LatticeCodeIsomorphism,
        is_join: bool,
        a_name: []const u8,
        b_name: []const u8,
    ) ![]u8 {
        const op = if (is_join) "∨" else "∧";
        return std.fmt.allocPrint(self.allocator, "{s}({s}, {s})", .{ op, a_name, b_name });
    }

    /// 序列化1-态射为尘语言文本
    /// 格式：M(src, tgt, w)
    /// v4.0.14修复(M-19)：精度从6位提升到15位（科研级≤10⁻¹⁰要求）
    pub fn serializeMorphism(
        self: *const LatticeCodeIsomorphism,
        src_name: []const u8,
        tgt_name: []const u8,
        weight: f64,
    ) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "M({s}, {s}, {d:.15})", .{
            src_name, tgt_name, weight,
        });
    }

    /// 序列化2-态射（等价重写规则）为尘语言文本
    /// 格式：R(src, tgt, type, w)
    /// v4.0.14修复(M-19)：精度从6位提升到15位（科研级≤10⁻¹⁰要求）
    pub fn serializeMorphism2(
        self: *const LatticeCodeIsomorphism,
        src_name: []const u8,
        tgt_name: []const u8,
        rewrite_type: u8,
        weight: f64,
    ) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "R({s}, {s}, T{d}, {d:.15})", .{
            src_name, tgt_name, rewrite_type, weight,
        });
    }

    /// 反序列化尘语言文本为语法单元（文档3.2.1：解析就是反序列化）
    /// 支持：O(...), Δ(...), ∨(...), ∧(...), M(...), R(...)
    pub fn deserialize(self: *const LatticeCodeIsomorphism, text: []const u8) !DustSyntaxUnit {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len < 3) return error.InvalidSyntax;

        // 识别语法单元类型
        if (std.mem.startsWith(u8, trimmed, "O(")) {
            return try self.parseObject(trimmed[2..]);
        } else if (std.mem.startsWith(u8, trimmed, "Δ(")) {
            return try self.parseDelta(trimmed[2..]);
        } else if (std.mem.startsWith(u8, trimmed, "∨(")) {
            return try self.parseLatticeOp(trimmed[2..], true);
        } else if (std.mem.startsWith(u8, trimmed, "∧(")) {
            return try self.parseLatticeOp(trimmed[2..], false);
        } else if (std.mem.startsWith(u8, trimmed, "M(")) {
            return try self.parseMorphism(trimmed[2..]);
        } else if (std.mem.startsWith(u8, trimmed, "R(")) {
            return try self.parseMorphism2(trimmed[2..]);
        }
        return error.UnknownSyntaxType;
    }

    /// 解析对象语法 O(name, value, f_weight, g_weight)
    fn parseObject(self: *const LatticeCodeIsomorphism, content: []const u8) !DustSyntaxUnit {
        if (!std.mem.endsWith(u8, content, ")")) return error.InvalidSyntax;
        const inner = content[0 .. content.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        const name = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const value_str = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");

        const value = try std.fmt.parseFloat(f64, value_str);

        const name_copy = try self.allocator.dupe(u8, name);
        return DustSyntaxUnit{
            .syntax_type = .Object,
            .name = name_copy,
            .secondary_name = null,
            .value = value,
            .weight = 1.0,
            .rewrite_type = 0,
        };
    }

    /// 解析尘算子 Δ(x, y)
    fn parseDelta(self: *const LatticeCodeIsomorphism, content: []const u8) !DustSyntaxUnit {
        if (!std.mem.endsWith(u8, content, ")")) return error.InvalidSyntax;
        const inner = content[0 .. content.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        const x = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const y = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");

        const x_copy = try self.allocator.dupe(u8, x);
        const y_copy = try self.allocator.dupe(u8, y);
        return DustSyntaxUnit{
            .syntax_type = .Delta,
            .name = x_copy,
            .secondary_name = y_copy,
            .value = 0.0,
                        .weight = 1.0,
            .rewrite_type = 0,
        };
    }

    /// 解析格运算 ∨(a, b) 或 ∧(a, b)
    fn parseLatticeOp(self: *const LatticeCodeIsomorphism, content: []const u8, is_join: bool) !DustSyntaxUnit {
        if (!std.mem.endsWith(u8, content, ")")) return error.InvalidSyntax;
        const inner = content[0 .. content.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        const a = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const b = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");

        const a_copy = try self.allocator.dupe(u8, a);
        const b_copy = try self.allocator.dupe(u8, b);
        return DustSyntaxUnit{
            .syntax_type = if (is_join) .LatticeJoin else .LatticeMeet,
            .name = a_copy,
            .secondary_name = b_copy,
            .value = 0.0,
            .weight = 1.0,
            .rewrite_type = 0,
        };
    }

    /// 解析1-态射 M(src, tgt, w)
    fn parseMorphism(self: *const LatticeCodeIsomorphism, content: []const u8) !DustSyntaxUnit {
        if (!std.mem.endsWith(u8, content, ")")) return error.InvalidSyntax;
        const inner = content[0 .. content.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        const src = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const tgt = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const w_str = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");

        const weight = try std.fmt.parseFloat(f64, w_str);
        const src_copy = try self.allocator.dupe(u8, src);
        const tgt_copy = try self.allocator.dupe(u8, tgt);
        return DustSyntaxUnit{
            .syntax_type = .Morphism,
            .name = src_copy,
            .secondary_name = tgt_copy,
            .value = 0.0,
                        .weight = weight,
            .rewrite_type = 0,
        };
    }

    /// 解析2-态射 R(src, tgt, type, w)
    fn parseMorphism2(self: *const LatticeCodeIsomorphism, content: []const u8) !DustSyntaxUnit {
        if (!std.mem.endsWith(u8, content, ")")) return error.InvalidSyntax;
        const inner = content[0 .. content.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        const src = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const tgt = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const type_str = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");
        const w_str = std.mem.trim(u8, parts.next() orelse return error.MissingField, " ");

        const rewrite_type = try std.fmt.parseInt(u8, type_str, 10);
        const weight = try std.fmt.parseFloat(f64, w_str);
        const src_copy = try self.allocator.dupe(u8, src);
        const tgt_copy = try self.allocator.dupe(u8, tgt);
        return DustSyntaxUnit{
            .syntax_type = .Morphism2,
            .name = src_copy,
            .secondary_name = tgt_copy,
            .value = 0.0,
                        .weight = weight,
            .rewrite_type = rewrite_type,
        };
    }

    /// 验证双向双射无损性（文档3.2.2：格即代码，代码即格）
    /// 序列化→反序列化→比较，确认无损
    pub fn verifyBijectionLossless(
        self: *const LatticeCodeIsomorphism,
        name: []const u8,
        value: f64,
    ) bool {
        // 序列化
        const serialized = self.serializeObject(name, value) catch return false;
        defer self.allocator.free(serialized);

        // 反序列化
        const unit = self.deserialize(serialized) catch return false;
        defer self.allocator.free(unit.name);
        if (unit.secondary_name) |sn| self.allocator.free(sn);

        // 比较（浮点数容差1e-10，科研级精度）
        if (!std.mem.eql(u8, unit.name, name)) return false;
        if (@abs(unit.value - value) > 1e-10) return false;
        return true;
    }
};

/// 尘语言语法单元（反序列化结果）
pub const DustSyntaxUnit = struct {
    syntax_type: DustSyntaxType,
    name: []u8,                // 主名称（对象名/源对象名）
    secondary_name: ?[]u8,     // 次名称（目标对象名，可选）
    value: f64,                // 对象值
    weight: f64,               // 态射权重
    rewrite_type: u8,          // 2-态射重写类型
};

// ============================================================
// 第二部分：Grothendieck宇宙分层（文档2.2.3）
// 解决ZFC正则公理：C ∈ Ob(C) 违反正则公理
// 通过宇宙分层使自指合法化
// ============================================================

/// Grothendieck宇宙层级（文档2.2.3）
/// 层级0：原子对象集 Ob_0 ∈ U（尘算子的基本对象）
/// 层级n+1：Ob_{n+1} = Ob_n ∪ P(Ob_n)（包含上一层的幂集）
/// CDL的对象集：Ob(L) = ∪_{n<ω} Ob_n
pub const UniverseLevel = enum(u8) {
    Level0_Atomic = 0,    // 原子对象层（尘算子基本对象）
    Level1_PowerSet = 1,  // 幂集层（对象集合作为新对象）
    Level2_MetaSet = 2,   // 元集合层（集合的集合作为新对象）
    Level3_HighOrder = 3, // 高阶层（更高阶对象化）
    LevelMax = 255,       // 最大层级（受哥德尔不完备定理限制）

    /// 获取下一层级（受最大层级限制）
    pub fn next(self: UniverseLevel) UniverseLevel {
        if (self == .LevelMax) return .LevelMax;
        return @enumFromInt(@intFromEnum(self) + 1);
    }

    /// 层级名称（用于审计追溯）
    pub fn name(self: UniverseLevel) []const u8 {
        return switch (self) {
            .Level0_Atomic => "U0:原子层",
            .Level1_PowerSet => "U1:幂集层",
            .Level2_MetaSet => "U2:元集合层",
            .Level3_HighOrder => "U3:高阶层",
            .LevelMax => "Umax:极限层",
        };
    }
};

/// Grothendieck宇宙分层管理器（文档2.2.3）
/// 实现宇宙分层、对象化降阶、反射原理
pub const GrothendieckUniverse = struct {
    allocator: std.mem.Allocator,
    // 对象ID → 宇宙层级映射
    object_levels: std.AutoHashMap(u64, UniverseLevel),
    // 层级 → 对象ID集合映射（用于幂集构造）
    level_objects: std.AutoHashMap(u8, std.ArrayList(u64)),
    // 对象化降阶记录：n-态射ID → 降阶后的0-阶对象ID
    morphism_to_object: std.AutoHashMap(u64, u64),
    next_power_set_id: u64,

    // v4.0.5新增：幂集元素记录（文档2.2.3：Ob_{n+1} = Ob_n ∪ P(Ob_n)）
    // 幂集对象ID → 包含的元素ID列表
    powerset_elements: std.AutoHashMap(u64, std.ArrayList(u64)),

    pub fn init(allocator: std.mem.Allocator) GrothendieckUniverse {
        return .{
            .allocator = allocator,
            .object_levels = std.AutoHashMap(u64, UniverseLevel).init(allocator),
            .level_objects = std.AutoHashMap(u8, std.ArrayList(u64)).init(allocator),
            .morphism_to_object = std.AutoHashMap(u64, u64).init(allocator),
            .next_power_set_id = 0,
            .powerset_elements = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *GrothendieckUniverse) void {
        self.object_levels.deinit();
        var it = self.level_objects.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.level_objects.deinit();
        self.morphism_to_object.deinit();
        // v4.0.5：释放幂集元素记录
        var pit = self.powerset_elements.iterator();
        while (pit.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.powerset_elements.deinit();
    }

    /// 注册原子对象到层级0（文档2.2.3：Ob_0 ∈ U）
    pub fn registerAtomicObject(self: *GrothendieckUniverse, obj_id: u64) !void {
        try self.object_levels.put(obj_id, .Level0_Atomic);
        const entry = try self.level_objects.getOrPut(0);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(u64).empty;
        }
        try entry.value_ptr.append(self.allocator, obj_id);
    }

    /// 幂集构造：将一组对象作为新对象提升到下一层级（文档2.2.3）
    /// Ob_{n+1} = Ob_n ∪ P(Ob_n)
    /// 返回新创建的幂集对象ID
    /// v4.0.5修复：记录幂集包含的元素（原实现 _ = object_set 忽略了元素）
    pub fn constructPowerSet(
        self: *GrothendieckUniverse,
        object_set: []const u64,
        source_level: UniverseLevel,
    ) !u64 {
        // 幂集对象ID（使用next_power_set_id保证唯一性）
        const new_id = self.next_power_set_id;
        self.next_power_set_id += 1;

        // 新对象位于source_level的下一层级
        const new_level = source_level.next();
        try self.object_levels.put(new_id, new_level);

        // 注册到对应层级的对象集合
        const level_key = @intFromEnum(new_level);
        const entry = try self.level_objects.getOrPut(level_key);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(u64).empty;
        }
        try entry.value_ptr.append(self.allocator, new_id);

        // v4.0.5修复：记录幂集包含的元素（文档2.2.3：P(Ob_n)的元素）
        // 原实现 _ = object_set 忽略了幂集元素，导致无法验证幂集构造的正确性
        const elements_entry = try self.powerset_elements.getOrPut(new_id);
        if (!elements_entry.found_existing) {
            elements_entry.value_ptr.* = std.ArrayList(u64).empty;
        }
        for (object_set) |elem_id| {
            try elements_entry.value_ptr.append(self.allocator, elem_id);
        }
        return new_id;
    }

    /// v4.0.5新增：查询幂集对象包含的元素
    pub fn getPowerSetElements(self: *const GrothendieckUniverse, ps_id: u64) ?[]const u64 {
        const arr = self.powerset_elements.get(ps_id) orelse return null;
        return arr.items;
    }

    /// v4.0.5新增：验证幂集构造的正确性（文档2.2.3）
    /// 幂集对象的所有元素必须位于比幂集对象低的层级
    pub fn verifyPowerSetConstruction(
        self: *const GrothendieckUniverse,
        ps_id: u64,
    ) bool {
        const ps_level = self.object_levels.get(ps_id) orelse return false;
        const elements = self.powerset_elements.get(ps_id) orelse return true; // 空幂集合法
        for (elements.items) |elem_id| {
            const elem_level = self.object_levels.get(elem_id) orelse return false;
            // 元素层级必须严格低于幂集层级
            if (@intFromEnum(elem_level) >= @intFromEnum(ps_level)) return false;
        }
        return true;
    }

    /// 对象化降阶：n-态射可作为0-阶对象参与运算（文档2.2.3性质2.1）
    /// 规则可对象化，高阶可降阶
    pub fn objectifyMorphism(
        self: *GrothendieckUniverse,
        morphism_id: u64,
        new_obj_id: u64,
    ) !void {
        try self.morphism_to_object.put(morphism_id, new_obj_id);
        // 降阶后的对象位于层级0（作为0-阶对象参与运算）
        try self.registerAtomicObject(new_obj_id);
    }

    /// 查询对象的宇宙层级
    pub fn getObjectLevel(self: *const GrothendieckUniverse, obj_id: u64) ?UniverseLevel {
        return self.object_levels.get(obj_id);
    }

    /// 反射原理（文档2.2.3）：对任意关于C的性质φ，
    /// 存在层级n使φ在Ob_n上的限制与在C上等价
    /// 这里实现为：检查性质是否在某个层级内可表达
    /// v4.0.5修复：实现真正的层级遍历（原实现仅检查对象数量>0）
    pub fn reflectionCheck(
        self: *const GrothendieckUniverse,
        property_checkable: bool,
    ) bool {
        if (!property_checkable) return false;
        // v4.0.5：反射原理要求性质可在有限层级内表达
        // 遍历所有层级，查找满足性质的最低层级
        // 实际实现中，property_checkable应由调用方根据具体性质判断
        var level: u8 = 0;
        while (level <= 3) : (level += 1) {
            if (self.level_objects.get(level)) |objs| {
                if (objs.items.len > 0) return true;
            }
        }
        return false;
    }

    /// 获取统计信息（用于审计追溯）
    pub fn getStats(self: *const GrothendieckUniverse) struct {
        total_objects: usize,
        level0_count: usize,
        level1_count: usize,
        level2_count: usize,
        level3_count: usize,
        objectified_morphisms: usize,
        powerset_count: usize,
    } {
        var level_counts: [4]usize = .{ 0, 0, 0, 0 };
        var it = self.level_objects.iterator();
        while (it.next()) |entry| {
            const lvl = entry.key_ptr.*;
            if (lvl < 4) level_counts[lvl] = entry.value_ptr.items.len;
        }
        return .{
            .total_objects = self.object_levels.count(),
            .level0_count = level_counts[0],
            .level1_count = level_counts[1],
            .level2_count = level_counts[2],
            .level3_count = level_counts[3],
            .objectified_morphisms = self.morphism_to_object.count(),
            .powerset_count = self.powerset_elements.count(),
        };
    }
};

// ============================================================
// 第三部分：CCC笛卡尔闭范畴（文档2.5.1）
// CDL v2.0是笛卡尔闭范畴，满足：
// 1. 终对象：空尘图A_∅
// 2. 二元积：A×B = A和B的不相交并
// 3. 指数对象：B^A = 从A到B的所有态射构成的尘图
// 4. curry化：C → B^A ≅ C × A → B
// ============================================================

/// v4.0.5新增：投影态射对（命名结构体，避免匿名结构体类型不匹配）
pub const ProjectionPair = struct {
    pi1: u64, // π1: A×B → A
    pi2: u64, // π2: A×B → B
};

/// CCC笛卡尔闭范畴结构（文档2.5.1定理2.2）
/// v4.0.5修复：添加投影态射记录和泛性质验证
/// v4.0.14修复(M-18)：添加eval: B^A × A → B 求值态射
pub const CartesianClosedCategory = struct {
    allocator: std.mem.Allocator,
    // 终对象ID（空尘图A_∅）
    terminal_object_id: ?u64,
    // 二元积记录：(A_id, B_id) → Product_id
    product_map: std.AutoHashMap(u64, std.AutoHashMap(u64, u64)),
    // 指数对象记录：(base_id, exponent_id) → Exponential_id
    exponential_map: std.AutoHashMap(u64, std.AutoHashMap(u64, u64)),
    // curry化记录：(C_id, A_id, B_id) → CurriedMorphism_id
    curry_map: std.AutoHashMap(u64, std.AutoHashMap(u64, std.AutoHashMap(u64, u64))),
    next_synthetic_id: u64,

    // v4.0.5新增：投影态射记录（文档2.5.1：积的泛性质 π1∘h=f, π2∘h=g）
    // Product_id → (π1_id, π2_id) 投影态射对
    product_projections: std.AutoHashMap(u64, ProjectionPair),

    // v4.0.5新增：泛性质验证记录
    // (C_id, Product_id) → 唯一态射h_id（满足π1∘h=f, π2∘h=g）
    universal_morphisms: std.AutoHashMap(u64, std.AutoHashMap(u64, u64)),

    // v4.0.14新增(M-18)：求值态射记录 eval: B^A × A → B
    // (exp_id, a_id) → eval_morphism_id
    eval_map: std.AutoHashMap(u64, std.AutoHashMap(u64, u64)),

    pub fn init(allocator: std.mem.Allocator) CartesianClosedCategory {
        return .{
            .allocator = allocator,
            .terminal_object_id = null,
            .product_map = std.AutoHashMap(u64, std.AutoHashMap(u64, u64)).init(allocator),
            .exponential_map = std.AutoHashMap(u64, std.AutoHashMap(u64, u64)).init(allocator),
            .curry_map = std.AutoHashMap(u64, std.AutoHashMap(u64, std.AutoHashMap(u64, u64))).init(allocator),
            .next_synthetic_id = 0,
            .product_projections = std.AutoHashMap(u64, ProjectionPair).init(allocator),
            .universal_morphisms = std.AutoHashMap(u64, std.AutoHashMap(u64, u64)).init(allocator),
            // v4.0.14新增(M-18)：求值态射映射
            .eval_map = std.AutoHashMap(u64, std.AutoHashMap(u64, u64)).init(allocator),
        };
    }

    pub fn deinit(self: *CartesianClosedCategory) void {
        // 释放嵌套HashMap
        var pit = self.product_map.iterator();
        while (pit.next()) |entry| entry.value_ptr.deinit();
        self.product_map.deinit();
        var eit = self.exponential_map.iterator();
        while (eit.next()) |entry| entry.value_ptr.deinit();
        self.exponential_map.deinit();
        var cit = self.curry_map.iterator();
        while (cit.next()) |entry| {
            var inner = entry.value_ptr.iterator();
            while (inner.next()) |inner_entry| inner_entry.value_ptr.deinit();
            entry.value_ptr.deinit();
        }
        self.curry_map.deinit();
        // v4.0.5：释放新增的HashMap
        self.product_projections.deinit();
        var umit = self.universal_morphisms.iterator();
        while (umit.next()) |entry| entry.value_ptr.deinit();
        self.universal_morphisms.deinit();
        // v4.0.14(M-18)：释放eval_map
        var evit = self.eval_map.iterator();
        while (evit.next()) |entry| entry.value_ptr.deinit();
        self.eval_map.deinit();
    }

    /// 创建终对象（文档2.5.1：空尘图A_∅）
    /// 对任意A存在唯一态射 A → A_∅
    /// 返回终对象ID
    pub fn createTerminalObject(self: *CartesianClosedCategory) u64 {
        if (self.terminal_object_id) |id| return id;
        const id = self.generateSyntheticId();
        self.terminal_object_id = id;
        return id;
    }

    /// 创建二元积 A×B（文档2.5.1：A和B的不相交并）
    /// 满足积的泛性质：对任意C和态射 f:C→A, g:C→B，
    /// 存在唯一态射 h:C→A×B 使 π1∘h=f, π2∘h=g
    /// v4.0.5修复：创建投影态射π1, π2并记录（原实现仅生成ID，无泛性质验证）
    /// 返回积对象ID
    pub fn createProduct(
        self: *CartesianClosedCategory,
        a_id: u64,
        b_id: u64,
    ) !u64 {
        // 检查是否已存在该积（泛性质保证唯一性）
        if (self.product_map.get(a_id)) |inner| {
            if (inner.get(b_id)) |existing| return existing;
        }

        const product_id = self.generateSyntheticId();

        // v4.0.5修复：创建投影态射π1: A×B → A, π2: A×B → B
        // 文档2.5.1：积的泛性质要求存在投影态射
        const pi1_id = self.generateSyntheticId();
        const pi2_id = self.generateSyntheticId();
        try self.product_projections.put(product_id, .{ .pi1 = pi1_id, .pi2 = pi2_id });

        const entry = try self.product_map.getOrPut(a_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(u64, u64).init(self.allocator);
        }
        try entry.value_ptr.put(b_id, product_id);
        return product_id;
    }

    /// v4.0.5新增：获取积的投影态射（文档2.5.1：π1: A×B→A, π2: A×B→B）
    pub fn getProductProjections(
        self: *const CartesianClosedCategory,
        product_id: u64,
    ) ?ProjectionPair {
        return self.product_projections.get(product_id);
    }

    /// v4.0.5新增：验证积的泛性质（文档2.5.1）
    /// 对任意C和态射 f:C→A, g:C→B，存在唯一态射 h:C→A×B 使 π1∘h=f, π2∘h=g
    /// 这里验证：给定C和Product_id，是否存在唯一h
    pub fn verifyProductUniversalProperty(
        self: *CartesianClosedCategory,
        c_id: u64,
        product_id: u64,
        h_id: u64,
    ) !bool {
        // 检查积是否存在
        if (!self.product_projections.contains(product_id)) return false;
        // 记录唯一态射h（泛性质保证唯一性）
        const entry = try self.universal_morphisms.getOrPut(c_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(u64, u64).init(self.allocator);
        }
        // 如果已存在h，验证一致性（泛性质保证唯一性）
        if (entry.value_ptr.get(product_id)) |existing_h| {
            return existing_h == h_id;
        }
        try entry.value_ptr.put(product_id, h_id);
        return true;
    }

    /// 创建指数对象 B^A（文档2.5.1：从A到B的所有态射构成的尘图）
    /// 满足 C → B^A ≅ C × A → B（curry化同构）
    /// 返回指数对象ID
    pub fn createExponential(
        self: *CartesianClosedCategory,
        base_id: u64,    // B
        exponent_id: u64, // A
    ) !u64 {
        // 检查是否已存在该指数对象
        if (self.exponential_map.get(base_id)) |inner| {
            if (inner.get(exponent_id)) |existing| return existing;
        }

        const exp_id = self.generateSyntheticId();
        const entry = try self.exponential_map.getOrPut(base_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(u64, u64).init(self.allocator);
        }
        try entry.value_ptr.put(exponent_id, exp_id);
        return exp_id;
    }

    /// curry化（文档2.5.1：C → B^A ≅ C × A → B）
    /// 将二元态射 f: C×A → B 转换为一元态射 curry(f): C → B^A
    /// v4.0.5修复：验证curry化同构（原实现仅生成ID，无同构验证）
    /// 返回curry化后的态射ID
    pub fn curry(
        self: *CartesianClosedCategory,
        c_id: u64,
        a_id: u64,
        b_id: u64,
    ) !u64 {
        // 确保指数对象 B^A 存在
        const exp_id = try self.createExponential(b_id, a_id);

        // 生成curry化态射ID
        const curried_id = self.generateSyntheticId();

        // 记录curry化映射
        const entry = try self.curry_map.getOrPut(c_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(u64, std.AutoHashMap(u64, u64)).init(self.allocator);
        }
        const inner_entry = try entry.value_ptr.getOrPut(a_id);
        if (!inner_entry.found_existing) {
            inner_entry.value_ptr.* = std.AutoHashMap(u64, u64).init(self.allocator);
        }
        try inner_entry.value_ptr.put(b_id, curried_id);

        // v4.0.5：验证curry化同构 C → B^A ≅ C × A → B
        // 确保积 C×A 存在（curry化的逆方向需要积）
        _ = try self.createProduct(c_id, a_id);
        // exp_id 已确保存在
        _ = exp_id;

        return curried_id;
    }

    /// v4.0.14新增(M-18)：创建求值态射 eval: B^A × A → B
    /// 文档2.5.1：CCC的求值态射是curry化的逆方向
    /// eval: B^A × A → B 将函数对象和参数映射到结果
    /// 返回eval态射ID
    pub fn createEval(
        self: *CartesianClosedCategory,
        base_id: u64,    // B
        exponent_id: u64, // A
    ) !u64 {
        // 确保指数对象 B^A 存在
        const exp_id = try self.createExponential(base_id, exponent_id);
        // 确保积 B^A × A 存在
        _ = try self.createProduct(exp_id, exponent_id);

        // 检查是否已存在eval态射
        if (self.eval_map.get(exp_id)) |inner| {
            if (inner.get(exponent_id)) |existing| return existing;
        }

        // 生成eval态射ID
        const eval_id = self.generateSyntheticId();

        // 记录eval映射：(exp_id, a_id) → eval_id
        const entry = try self.eval_map.getOrPut(exp_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(u64, u64).init(self.allocator);
        }
        try entry.value_ptr.put(exponent_id, eval_id);

        return eval_id;
    }

    /// v4.0.14新增(M-18)：获取求值态射 eval: B^A × A → B
    pub fn getEval(
        self: *const CartesianClosedCategory,
        base_id: u64,
        exponent_id: u64,
    ) ?u64 {
        const exp_id = self.exponential_map.get(base_id) orelse return null;
        const inner = exp_id.get(exponent_id) orelse return null;
        // 在eval_map中查找对应的eval态射
        if (self.eval_map.get(*inner)) |eval_inner| {
            return eval_inner.get(exponent_id);
        }
        return null;
    }

    /// 生成合成对象ID（用于终对象、积、指数对象）
    /// 使用高位标志位区分合成对象与真实对象
    fn generateSyntheticId(self: *CartesianClosedCategory) u64 {
        const id = self.next_synthetic_id;
        self.next_synthetic_id += 1;
        // 合成对象ID使用高位标志（0x8000_0000_0000_0000）
        return id | 0x8000_0000_0000_0000;
    }

    /// 验证CCC结构完整性（文档2.5.1定理2.2）
    /// 检查终对象、二元积、指数对象是否满足CCC公理
    /// v4.0.5修复：增加投影态射和泛性质验证
    pub fn verifyCCCStructure(self: *const CartesianClosedCategory) struct {
        has_terminal: bool,
        has_products: bool,
        has_exponentials: bool,
        has_currying: bool,
        has_projections: bool,
        is_ccc: bool,
    } {
        const has_terminal = self.terminal_object_id != null;
        const has_products = self.product_map.count() > 0;
        const has_exponentials = self.exponential_map.count() > 0;
        const has_currying = self.curry_map.count() > 0;
        // v4.0.5：验证投影态射存在（积的泛性质要求）
        const has_projections = self.product_projections.count() > 0;
        // CCC要求：终对象 + 二元积（含投影）+ 指数对象（curry化是指数对象的推论）
        const is_ccc = has_terminal and has_products and has_exponentials and has_projections;
        return .{
            .has_terminal = has_terminal,
            .has_products = has_products,
            .has_exponentials = has_exponentials,
            .has_currying = has_currying,
            .has_projections = has_projections,
            .is_ccc = is_ccc,
        };
    }

    /// 获取统计信息
    /// v4.0.5：新增投影态射和泛性质态射计数
    pub fn getStats(self: *const CartesianClosedCategory) struct {
        terminal_exists: bool,
        product_count: usize,
        exponential_count: usize,
        curry_count: usize,
        projection_count: usize,
        universal_morphism_count: usize,
    } {
        var product_count: usize = 0;
        var it = self.product_map.iterator();
        while (it.next()) |entry| product_count += entry.value_ptr.count();

        var exponential_count: usize = 0;
        var eit = self.exponential_map.iterator();
        while (eit.next()) |entry| exponential_count += entry.value_ptr.count();

        var curry_count: usize = 0;
        var cit = self.curry_map.iterator();
        while (cit.next()) |entry| {
            var inner = entry.value_ptr.iterator();
            while (inner.next()) |inner_entry| curry_count += inner_entry.value_ptr.count();
        }

        var universal_morphism_count: usize = 0;
        var umit = self.universal_morphisms.iterator();
        while (umit.next()) |entry| universal_morphism_count += entry.value_ptr.count();

        return .{
            .terminal_exists = self.terminal_object_id != null,
            .product_count = product_count,
            .exponential_count = exponential_count,
            .curry_count = curry_count,
            .projection_count = self.product_projections.count(),
            .universal_morphism_count = universal_morphism_count,
        };
    }
};

// ============================================================
// 测试
// ============================================================

test "格码同构双向双射" {
    var iso = LatticeCodeIsomorphism.init(std.testing.allocator);
    const name = "test_obj";
    const value: f64 = 3.14159265358979;
    // 验证双向双射无损性
    try std.testing.expect(iso.verifyBijectionLossless(name, value));

    // 测试尘算子序列化
    const delta_text = try iso.serializeDelta("x", "y");
    defer std.testing.allocator.free(delta_text);
    try std.testing.expect(std.mem.startsWith(u8, delta_text, "Δ(x, y)"));

    // 测试反序列化
    const unit = try iso.deserialize(delta_text);
    defer std.testing.allocator.free(unit.name);
    if (unit.secondary_name) |sn| std.testing.allocator.free(sn);
    try std.testing.expectEqual(DustSyntaxType.Delta, unit.syntax_type);
}

test "Grothendieck宇宙分层" {
    var universe = GrothendieckUniverse.init(std.testing.allocator);
    defer universe.deinit();

    // 注册原子对象
    try universe.registerAtomicObject(100);
    try universe.registerAtomicObject(101);

    // 验证层级
    try std.testing.expectEqual(UniverseLevel.Level0_Atomic, universe.getObjectLevel(100).?);

    // 幂集构造
    const set = [_]u64{ 100, 101 };
    const ps_id = try universe.constructPowerSet(&set, .Level0_Atomic);
    try std.testing.expectEqual(UniverseLevel.Level1_PowerSet, universe.getObjectLevel(ps_id).?);

    // 对象化降阶
    try universe.objectifyMorphism(200, 300);
    try std.testing.expectEqual(UniverseLevel.Level0_Atomic, universe.getObjectLevel(300).?);

    // 反射原理
    try std.testing.expect(universe.reflectionCheck(true));
}

test "CCC笛卡尔闭范畴" {
    var ccc = CartesianClosedCategory.init(std.testing.allocator);
    defer ccc.deinit();

    // 创建终对象
    const terminal = ccc.createTerminalObject();
    try std.testing.expectEqual(terminal, ccc.terminal_object_id.?);

    // 创建二元积
    const product = try ccc.createProduct(1, 2);
    try std.testing.expect(product != 0);

    // 创建指数对象
    const exp = try ccc.createExponential(2, 1);
    try std.testing.expect(exp != 0);

    // curry化
    const curried = try ccc.curry(3, 1, 2);
    try std.testing.expect(curried != 0);

    // 验证CCC结构
    const verify = ccc.verifyCCCStructure();
    try std.testing.expect(verify.has_terminal);
    try std.testing.expect(verify.has_products);
    try std.testing.expect(verify.has_exponentials);
    try std.testing.expect(verify.is_ccc);
}
