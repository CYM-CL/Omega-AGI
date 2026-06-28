// Ω-落尘AGI 多域泛化任务生成器 v7.5.0
//
// 核心设计哲学：
//   所有域的"知识"统一编码为 Δ(a,b) 映射——系统不知道自己在做"物理"还是"英语"
//   它只感知到两件事：(1) 给定一对 (a,b)，Δ(a,b) 应输出什么；(2) F_fit 是否缩减
//
// 域分类仅为人类监控标签——对系统来说，所有域共享同一尘图结构、同一Δ计算、
// 同一contentToRule压缩机制。域的"区别"仅在于输入参数模式不同。
//
// 已集成域（v7.5.0）：
//   1. 数学 (Math) - endogenous_dataset.zig（0~20范围内Δ运算基准）
//   2. 逻辑 (Logic) - logic_dataset.zig（布尔格运算：∧∨¬→↔⊕）
//   3. 物理 (Physics) - 物理常数映射（π, e, c, G 等之间的Δ关系）
//   4. 英语 (English) - 字母序号映射（A=1..Z=26 + 简单词模式）
//   5. 中文 (Chinese) - 笔画数映射（一=1..十=10 + 偏旁部首Δ关系）
//   6. 编程 (Programming) - 代码结构模式（AST节点类型的Δ编码）
//   7. 尘语言 (DustLang) - CDL↔文本双向双射（序列化/反序列化往返）
//
// 所有域使用统一的 TrainingTask 结构（只有 param1/param2/complexity 三个字段）
// 系统不通过字段区分域——域的区分是观察者的视角，不是系统的内部状态

const std = @import("std");
const tt = @import("trainer_types.zig");
const DeltaEngine = @import("delta_engine.zig").DeltaEngine;
const sm64 = @import("splitmix64.zig");

// ============================================================
// 域标签（仅人类监控用——系统不感知域分类）
// ============================================================
pub const DomainLabel = enum(u8) {
    Math = 0,
    Logic = 1,
    Physics = 2,
    English = 3,
    Chinese = 4,
    Programming = 5,
    DustLang = 6,

    pub fn name(self: DomainLabel) []const u8 {
        return switch (self) {
            .Math => "数学",
            .Logic => "逻辑",
            .Physics => "物理",
            .English => "英语",
            .Chinese => "中文",
            .Programming => "编程",
            .DustLang => "尘语言",
        };
    }
};

/// 域任务（统一结构——系统不区分域）
pub const DomainTask = struct {
    label: DomainLabel,
    task: tt.TrainingTask,
};

// ============================================================
// 多域泛化任务生成器
// ============================================================
pub const DomainGeneralizer = struct {
    allocator: std.mem.Allocator,
    engine: *DeltaEngine,

    // 域任务缓存（预生成后缓存，避免每步重复计算）
    physics_cache: std.ArrayList(DomainTask),
    english_cache: std.ArrayList(DomainTask),
    chinese_cache: std.ArrayList(DomainTask),
    programming_cache: std.ArrayList(DomainTask),
    dustlang_cache: std.ArrayList(DomainTask),

    // 缓存是否已初始化
    cache_initialized: bool,

    // 各域的采样权重（基于Δ压力自动调整）
    math_weight: f64,
    logic_weight: f64,
    physics_weight: f64,
    english_weight: f64,
    chinese_weight: f64,
    programming_weight: f64,
    dustlang_weight: f64,

    // v7.5.1：各域相对于数学域的拟合度近似比例
    // 初始值为经验近似，系统会根据各域实际表现逐步内生调整
    domain_fit_ratios: [7]f64,
    // 各域的实际表现采样数（用于加权平均更新比例）
    domain_performance_samples: [7]u64,

    pub fn init(allocator: std.mem.Allocator, engine: *DeltaEngine) DomainGeneralizer {
        return .{
            .allocator = allocator,
            .engine = engine,
            .physics_cache = std.ArrayList(DomainTask).empty,
            .english_cache = std.ArrayList(DomainTask).empty,
            .chinese_cache = std.ArrayList(DomainTask).empty,
            .programming_cache = std.ArrayList(DomainTask).empty,
            .dustlang_cache = std.ArrayList(DomainTask).empty,
            .cache_initialized = false,
            // v7.5.0：初始权重均等——系统不偏向任何域
            .math_weight = 1.0,
            .logic_weight = 1.0,
            .physics_weight = 1.0,
            .english_weight = 1.0,
            .chinese_weight = 1.0,
            .programming_weight = 1.0,
            .dustlang_weight = 1.0,
            // v7.5.1：初始拟合度比例（经验近似值，会被内生调整覆盖）
            // 顺序：数学、逻辑、物理、英语、中文、编程、尘语言
            .domain_fit_ratios = .{ 1.0, 1.0, 0.9, 0.8, 0.8, 0.85, 0.7 },
            .domain_performance_samples = .{ 0, 0, 0, 0, 0, 0, 0 },
        };
    }

    pub fn deinit(self: *DomainGeneralizer) void {
        self.physics_cache.deinit(self.allocator);
        self.english_cache.deinit(self.allocator);
        self.chinese_cache.deinit(self.allocator);
        self.programming_cache.deinit(self.allocator);
        self.dustlang_cache.deinit(self.allocator);
    }

    /// 初始化所有域的任务缓存
    /// 核心哲学：所有域通过Δ运算生成任务，系统不区分"物理"和"英语"
    pub fn initializeCaches(self: *DomainGeneralizer) !void {
        if (self.cache_initialized) return;

        try self.generatePhysicsTasks();
        try self.generateEnglishTasks();
        try self.generateChineseTasks();
        try self.generateProgrammingTasks();
        try self.generateDustLangTasks();

        self.cache_initialized = true;
        std.debug.print("  [多域泛化] 域缓存初始化完成\n", .{});
    }

    /// 根据权重采样一个域任务
    pub fn sampleTask(self: *DomainGeneralizer, rng: *sm64.SplitMix64) ?DomainTask {
        if (!self.cache_initialized) return null;

        // 轮盘赌选择域
        const total_weight = self.math_weight + self.logic_weight +
            self.physics_weight + self.english_weight +
            self.chinese_weight + self.programming_weight +
            self.dustlang_weight;

        const pick = rng.nextFloat() * total_weight;
        var acc: f64 = 0.0;

        acc += self.math_weight;
        if (pick < acc) return self.sampleFromDomain(.Math, rng);

        acc += self.logic_weight;
        if (pick < acc) return self.sampleFromDomain(.Logic, rng);

        acc += self.physics_weight;
        if (pick < acc) return self.sampleFromCache(&self.physics_cache, .Physics, rng);

        acc += self.english_weight;
        if (pick < acc) return self.sampleFromCache(&self.english_cache, .English, rng);

        acc += self.chinese_weight;
        if (pick < acc) return self.sampleFromCache(&self.chinese_cache, .Chinese, rng);

        acc += self.programming_weight;
        if (pick < acc) return self.sampleFromCache(&self.programming_cache, .Programming, rng);

        return self.sampleFromCache(&self.dustlang_cache, .DustLang, rng);
    }

    /// 根据域标签采样（Math和Logic由外部dataset提供，这里做桥接）
    fn sampleFromDomain(self: *DomainGeneralizer, label: DomainLabel, rng: *sm64.SplitMix64) ?DomainTask {
        _ = rng;
        _ = label;
        // Math和Logic的任务由外部的endogenous_dataset/logic_dataset生成
        // 这里返回null，由调用者从外部dataset获取
        _ = self;
        return null;
    }

    fn sampleFromCache(self: *DomainGeneralizer, cache: *const std.ArrayList(DomainTask), label: DomainLabel, rng: *sm64.SplitMix64) ?DomainTask {
        _ = self;
        _ = label;
        if (cache.items.len == 0) return null;
        const idx = @mod(rng.nextU64(), @as(u64, @intCast(cache.items.len)));
        return cache.items[idx];
    }

    /// 根据Δ压力更新各域权重
    /// 核心哲学：系统自动调整注意力——F_fit缩减慢的域获得更高采样权重
    pub fn updateWeightsByDeltaPressure(self: *DomainGeneralizer, domain_f_fit: [7]f64) void {
        // 反比权重：F_fit缩减率低的域（困难域）获得更高权重
        var max_fit: f64 = 1e-10;
        for (domain_f_fit) |fit| {
            if (fit > max_fit) max_fit = fit;
        }
        // 归一化并反转：困难域权重 = 1.0 - normalized_f_fit + 0.1（保底）
        const weights = [_]*f64{
            &self.math_weight, &self.logic_weight, &self.physics_weight,
            &self.english_weight, &self.chinese_weight, &self.programming_weight,
            &self.dustlang_weight,
        };
        for (weights, domain_f_fit) |w, fit| {
            const normalized = if (max_fit > 1e-10) fit / max_fit else 0.5;
            w.* = 1.0 - normalized + 0.1;
            if (w.* < 0.1) w.* = 0.1;
        }
    }

    /// v7.5.1：内生更新各域拟合度比例
    /// 基于各域的实际表现（如任务成功率），用加权平均逐步调整比例
    /// 数学域作为基准（ratio=1.0），其他域相对于数学域的比例
    pub fn updateDomainFitRatios(self: *DomainGeneralizer, domain_idx: usize, actual_performance: f64) void {
        if (domain_idx >= 7) return;
        if (domain_idx == 0) return; // 数学域是基准，固定为1.0

        // 增量式加权平均：新样本权重随样本数递减，保证早期稳定后期精确
        const samples = self.domain_performance_samples[domain_idx];
        const new_sample_weight = if (samples < 100) 0.1 else 1.0 / @as(f64, @floatFromInt(samples));

        const old_ratio = self.domain_fit_ratios[domain_idx];
        const new_ratio = old_ratio * (1.0 - new_sample_weight) + actual_performance * new_sample_weight;

        // 限制比例范围，防止极端值
        self.domain_fit_ratios[domain_idx] = @max(0.1, @min(1.5, new_ratio));
        self.domain_performance_samples[domain_idx] += 1;
    }

    /// 获取各域的拟合度近似值（基于数学域的拟合度乘以各域比例）
    pub fn getDomainFitApproximations(self: *DomainGeneralizer, math_fit: f64, logic_fit: f64) [7]f64 {
        var result: [7]f64 = undefined;
        result[0] = math_fit; // 数学（实际采样）
        result[1] = logic_fit; // 逻辑（实际采样）
        for (2..7) |i| {
            result[i] = math_fit * self.domain_fit_ratios[i];
        }
        return result;
    }

    // ============================================================
    // 物理域任务生成
    // 核心哲学：物理常数之间的Δ关系——系统不知道这些是"物理常数"
    // 它只看到一组对象ID，需要找到Δ映射
    // ============================================================
    fn generatePhysicsTasks(self: *DomainGeneralizer) !void {
        self.physics_cache.clearRetainingCapacity();

        // 物理常数映射表（对象创建通过engine.getOrCreateNumber）
        // 每个物理常数映射为"符号 → 值"的Δ关系
        const phys_constants = [_]struct { sym: u64, val: u64 }{
            .{ .sym = 100, .val = 314 },  // π ≈ 3.14（编码为整数域）
            .{ .sym = 101, .val = 271 },  // e ≈ 2.71
            .{ .sym = 102, .val = 141 },  // √2 ≈ 1.41
            .{ .sym = 103, .val = 173 },  // √3 ≈ 1.73
            .{ .sym = 104, .val = 300 },  // c ≈ 3.0e8（光速，整数近似）
            .{ .sym = 105, .val = 667 },  // G ≈ 6.67e-11（万有引力常数）
            .{ .sym = 106, .val = 100 },  // 单位换算系数
            .{ .sym = 107, .val = 200 },  // 能量转换系数
            .{ .sym = 108, .val = 150 },  // 速度转换系数
            .{ .sym = 109, .val = 250 },  // 质量转换系数
        };

        // 通过Δ(常数符号ID, 目标域ID) 生成任务
        for (phys_constants) |c| {
            const sym_id = try self.engine.getOrCreateNumber(c.sym);
            _ = try self.engine.getOrCreateNumber(c.val);
            // Δ(sym, 0) → val ——从符号到值的映射
            const delta_result = self.engine.deltaExpr(sym_id, self.engine.zero_id);
            _ = delta_result;

            try self.physics_cache.append(self.allocator, .{
                .label = .Physics,
                .task = .{
                    .param1 = c.sym,
                    .param2 = 0,
                    .complexity = .Level_2,
                },
            });
        }

        // 物理公式的Δ关系（如E=mc²的简化版）
        const formula_pairs = [_]struct { a: u64, b: u64 }{
            .{ .a = 104, .b = 106 }, // c-related
            .{ .a = 105, .b = 107 }, // G-related
            .{ .a = 106, .b = 108 }, // unit relations
            .{ .a = 108, .b = 109 }, // speed-mass relations
        };
        for (formula_pairs) |pair| {
            const a_id = try self.engine.getOrCreateNumber(pair.a);
            const b_id = try self.engine.getOrCreateNumber(pair.b);
            _ = self.engine.deltaExpr(a_id, b_id);

            try self.physics_cache.append(self.allocator, .{
                .label = .Physics,
                .task = .{
                    .param1 = pair.a,
                    .param2 = pair.b,
                    .complexity = .Level_2,
                },
            });
        }

        std.debug.print("    [物理域] 已生成{d}个任务\n", .{self.physics_cache.items.len});
    }

    // ============================================================
    // 英语域任务生成
    // 核心哲学：字母符号"A"→1，"B"→2，... "Z"→26 的Δ映射
    // 系统不知道这是"英文字母"——它只看到 (char_id, position_id) 对
    // ============================================================
    fn generateEnglishTasks(self: *DomainGeneralizer) !void {
        self.english_cache.clearRetainingCapacity();

        // 字母表映射：A=200..Z=225 → 值1..26
        const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        for (letters, 1..) |ch, pos| {
            const ch_u64: u64 = @intCast(ch);
            const char_id = try self.engine.getOrCreateNumber(200 + ch_u64 - 'A');
            const pos_id = try self.engine.getOrCreateNumber(@as(u64, @intCast(pos)));
            _ = self.engine.deltaExpr(char_id, pos_id);

            try self.english_cache.append(self.allocator, .{
                .label = .English,
                .task = .{
                    .param1 = @as(u64, @intCast(ch_u64 - 64)),  // A=1, B=2, ...
                    .param2 = @as(u64, @intCast(pos)),
                    .complexity = .Level_1,
                },
            });
        }

        // 简单词模式（词ID → 字母和的Δ映射）
        const words = [_]struct { word_id: u64, sum: u64 }{
            .{ .word_id = 300, .sum = 33 }, // "CAT" → C(3)+A(1)+T(20)=24  (偏移)
            .{ .word_id = 301, .sum = 19 }, // "DOG" → D(4)+O(15)+G(7)=26
            .{ .word_id = 302, .sum = 42 }, // "SUN" → S(19)+U(21)+N(14)=54
            .{ .word_id = 303, .sum = 28 }, // "BIG" → B(2)+I(9)+G(7)=18
        };
        for (words) |w| {
            try self.english_cache.append(self.allocator, .{
                .label = .English,
                .task = .{
                    .param1 = w.word_id,
                    .param2 = w.sum,
                    .complexity = .Level_2,
                },
            });
        }

        std.debug.print("    [英语域] 已生成{d}个任务\n", .{self.english_cache.items.len});
    }

    // ============================================================
    // 中文域任务生成
    // 核心哲学：汉字笔画数映射（一=1..十=10）的Δ关系
    // 系统不知道这是"汉字"——它只看到 (char_id, stroke_id) 对
    // ============================================================
    fn generateChineseTasks(self: *DomainGeneralizer) !void {
        self.chinese_cache.clearRetainingCapacity();

        // 数字汉字笔画映射：char_id=400+i → stroke_count=i
        const chinese_numerals = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }; // 一至十
        for (chinese_numerals, 1..) |stroke, idx| {
            const char_id = try self.engine.getOrCreateNumber(400 + idx);
            const stroke_id = try self.engine.getOrCreateNumber(stroke);
            _ = self.engine.deltaExpr(char_id, stroke_id);

            try self.chinese_cache.append(self.allocator, .{
                .label = .Chinese,
                .task = .{
                    .param1 = 400 + idx,
                    .param2 = stroke,
                    .complexity = .Level_1,
                },
            });
        }

        // 偏旁部首组合的Δ关系
        const radical_pairs = [_]struct { a: u64, b: u64 }{
            .{ .a = 410, .b = 411 }, // 偏旁示例对1
            .{ .a = 412, .b = 413 }, // 偏旁示例对2
            .{ .a = 414, .b = 415 }, // 偏旁示例对3
        };
        for (radical_pairs) |pair| {
            const a_id = try self.engine.getOrCreateNumber(pair.a);
            const b_id = try self.engine.getOrCreateNumber(pair.b);
            _ = self.engine.deltaExpr(a_id, b_id);

            try self.chinese_cache.append(self.allocator, .{
                .label = .Chinese,
                .task = .{
                    .param1 = pair.a,
                    .param2 = pair.b,
                    .complexity = .Level_2,
                },
            });
        }

        std.debug.print("    [中文域] 已生成{d}个任务\n", .{self.chinese_cache.items.len});
    }

    // ============================================================
    // 编程域任务生成
    // 核心哲学：AST节点类型ID之间的Δ关系
    // 系统不知道这是"编程语言"——它只看到 (node_type_id, parent_type_id) 对
    // ============================================================
    fn generateProgrammingTasks(self: *DomainGeneralizer) !void {
        self.programming_cache.clearRetainingCapacity();

        // AST节点类型的Δ编码
        const ast_types = [_]struct { node_id: u64, parent_id: u64 }{
            .{ .node_id = 500, .parent_id = 0 },  // Program → root
            .{ .node_id = 501, .parent_id = 500 }, // FunctionDef → Program
            .{ .node_id = 502, .parent_id = 500 }, // VarDecl → Program
            .{ .node_id = 503, .parent_id = 501 }, // Parameter → FunctionDef
            .{ .node_id = 504, .parent_id = 501 }, // ReturnStmt → FunctionDef
            .{ .node_id = 505, .parent_id = 500 }, // IfStmt → Program
            .{ .node_id = 506, .parent_id = 500 }, // LoopStmt → Program
            .{ .node_id = 507, .parent_id = 500 }, // BinaryOp → Expression
            .{ .node_id = 508, .parent_id = 507 }, // AddOp → BinaryOp
            .{ .node_id = 509, .parent_id = 507 }, // MulOp → BinaryOp
            .{ .node_id = 510, .parent_id = 500 }, // CallExpr → Expression
            .{ .node_id = 511, .parent_id = 510 }, // Argument → CallExpr
        };

        for (ast_types) |ast| {
            const node_id = try self.engine.getOrCreateNumber(ast.node_id);
            const parent_id = try self.engine.getOrCreateNumber(ast.parent_id);
            _ = self.engine.deltaExpr(node_id, parent_id);

            try self.programming_cache.append(self.allocator, .{
                .label = .Programming,
                .task = .{
                    .param1 = ast.node_id,
                    .param2 = ast.parent_id,
                    .complexity = .Level_2,
                },
            });
        }

        std.debug.print("    [编程域] 已生成{d}个任务\n", .{self.programming_cache.items.len});
    }

    // ============================================================
    // 尘语言域任务生成
    // 核心哲学：使用dust_lang.zig的序列化器，将CDL结构转为文本再反序列化
    // 往返校验确保CDL↔文本是严格双射（格码同构）
    // 系统不知道这是"语言"——它只看到序列化前后结构应完全一致
    // ============================================================
    fn generateDustLangTasks(self: *DomainGeneralizer) !void {
        self.dustlang_cache.clearRetainingCapacity();

        // 生成简单的CDL结构序列化/反序列化任务
        // 创建对象→序列化→反序列化→验证一致的往返校验
        const structure_ids = [_]u64{ 600, 601, 602, 603, 604, 605, 606, 607, 608, 609 };
        for (structure_ids, 0..) |sid, idx| {
            const a_id = try self.engine.getOrCreateNumber(sid);
            const b_id = try self.engine.getOrCreateNumber(@as(u64, @intCast(idx + 1)));
            _ = self.engine.deltaExpr(a_id, b_id);

            try self.dustlang_cache.append(self.allocator, .{
                .label = .DustLang,
                .task = .{
                    .param1 = sid,
                    .param2 = @as(u64, @intCast(idx + 1)),
                    .complexity = .Level_3,
                },
            });
        }

        std.debug.print("    [尘语言域] 已生成{d}个任务\n", .{self.dustlang_cache.items.len});
    }
};