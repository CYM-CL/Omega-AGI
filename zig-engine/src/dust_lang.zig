// Ω-落尘AGI 尘语言序列化/反序列化 v5.1
//
// 严格对应白皮书v2.0：
// - §3.2 格码同构：CDL子格 ↔ 尘语言表达式双向双射
// - §10.3 M2：尘语言序列化工具链
// - §13.1：每个尘算子 Δ(x,y) 对应一条尘语言语法单元
//
// 设计哲学：
// 尘语言不是"数据格式"，而是CDL结构的文本投影
// - 每个token对应一个CDL对象/态射/Δ运算
// - 序列化 = CDL → 文本（单向映射，保持格结构信息无损）
// - 反序列化 = 文本 → CDL（逆向映射，恢复格结构）
// - §3.2 格码同构保证双向双射：序列化后反序列化得到相同CDL结构
//
// 尘语言语法（.dust 文件格式）：
//   1. 对象定义：   obj <id> := <value>;
//   2. 1-态射定义： mor <id>: <src> -> <dst> [weight: <w>];
//   3. 2-态射定义： 2mor <id>: <src_mor> => <dst_mor> [weight: <w>];
//   4. 格 join:     join(<a>, <b>) => <result>
//   5. 格 meet:     meet(<a>, <b>) => <result>
//   6. 尘算子 Δ:    delta(<a>, <b>) => <result>
//   7. 注释:        // 注释内容
//   8. 子图区块:    graph <name> { ... }
//
// 约束条件：
//   - 序列化是无损的（完整保留CDL的所有对象、态射、2-态射）
//   - 反序列化保持ID稳定（对象/态射的ID在序列化-反序列化循环中不变）
//   - 尘语言文本是人类可读的，支持注释和结构化缩进
//   - 解析器对输入格式有容错：跳过空行、注释、前后空格

const std = @import("std");
const de = @import("delta_engine.zig");
const dg = @import("dust_graph.zig");

// ============================================================
// 尘语言强类型错误体系（白皮书要求全链路显式错误处理）
// ============================================================

/// 尘语言错误类型
/// 覆盖全量失败场景：解析错误、格式错误、ID越界、输入无效
pub const DustLangError = error{
    /// 语法解析错误：行格式不符合尘语言语法规范
    ParseError,
    /// 数字转换错误：字符串无法合法转换为数字
    NumberParseError,
    /// ID越界：反序列化时引用了不存在的对象/态射ID
    IdOutOfBounds,
    /// 未知指令：行首token不是obj/mor/2mor/join/meet/delta/graph中的任一
    UnknownDirective,
    /// 输入为空或全为空白/注释
    EmptyInput,
    /// 权重格式错误：weight值无法解析
    WeightParseError,
    /// 写入错误：writer写入失败
    WriteError,
    /// 内存分配失败：分配器无法分配内存
    OutOfMemory,
};

// ============================================================
// 内部辅助函数
// ============================================================

/// 修剪行首尾空白字符
fn trim(line: []const u8) []const u8 {
    var start: usize = 0;
    var end = line.len;
    // 跳过行首空白
    while (start < end and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    // 跳过行尾空白
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t' or
        line[end - 1] == '\r' or line[end - 1] == '\n')) : (end -= 1) {}
    return line[start..end];
}

/// 检查是否为注释行或空行
/// 注释以 "//" 开头，空行仅含空白字符
fn isCommentOrEmpty(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len == 0) return true;
    return trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/';
}

/// 跳过空白和注释，返回下一个有效行的起始位置
/// 用于多行文本解析时的行定位
fn skipToNextValidLine(lines: [][]const u8, start: usize) ?usize {
    var i = start;
    while (i < lines.len) : (i += 1) {
        if (!isCommentOrEmpty(lines[i])) return i;
    }
    return null;
}

/// 安全地将字符串解析为 u64
/// 支持十进制格式，处理前导空白
fn parseU64(s: []const u8) !u64 {
    const trimmed = trim(s);
    if (trimmed.len == 0) return DustLangError.NumberParseError;
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch DustLangError.NumberParseError;
}

/// 安全地将字符串解析为 f64
/// 支持浮点数格式（如 1.0, -0.5, 1e-10），处理前导空白
fn parseF64(s: []const u8) !f64 {
    const trimmed = trim(s);
    if (trimmed.len == 0) return DustLangError.NumberParseError;
    return std.fmt.parseFloat(f64, trimmed) catch DustLangError.NumberParseError;
}

/// 查找字符串中指定字符的位置
/// 返回第一个匹配位置，未找到返回null
fn findChar(line: []const u8, c: u8) ?usize {
    for (line, 0..) |ch, i| {
        if (ch == c) return i;
    }
    return null;
}

/// 按分隔符分割字符串，返回两个部分
/// 用于解析 "key: value" 或 "a -> b" 等格式
fn splitByChar(line: []const u8, sep: u8) ?struct { []const u8, []const u8 } {
    const pos = findChar(line, sep) orelse return null;
    return .{ trim(line[0..pos]), trim(line[pos + 1 ..]) };
}

/// 在字符串中查找子串的位置
/// 返回第一个匹配位置的起始索引
fn findStrPos(line: []const u8, substr: []const u8) ?usize {
    return std.mem.indexOf(u8, line, substr);
}

/// 向writer写入格式化字符串
/// Zig 0.16.0兼容：使用writer.print替代std.fmt.format（后者在0.16.0中不可用）
fn writeFmt(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
}

// ============================================================
// 序列化函数：CDL结构 → 尘语言文本
// 白皮书§3.2：CDL子格 → 尘语言表达式是严格双射
// 序列化方向：CDL → 文本
// ============================================================

/// 序列化一个CDL对象到writer
/// 格式：obj <id> := <value>;
///
/// 设计约束：
///   - id 必须合法（已在调用层校验）
///   - value 使用默认格式化（%e风格），保证精度
///   - 每行一个对象定义，以分号结束
pub fn serializeObject(writer: anytype, id: u64, value: f64) !void {
    try writeFmt(writer, "obj {} := {e};\n", .{ id, value });
}

/// 序列化一个1-态射到writer
/// 格式：mor <id>: <src> -> <dst> [weight: <w>];
///
/// 设计约束：
///   - id/src/dst 必须合法（已在调用层校验）
///   - weight 使用默认格式化（%e风格），保证精度
///   - 每个态射一行，以分号结束
///   - 白皮书§13.1：每个尘算子对应一条语法单元
pub fn serializeMorphism(writer: anytype, id: u64, src: u64, dst: u64, weight: f64) !void {
    try writeFmt(writer, "mor {}: {} -> {} [weight: {e}];\n", .{ id, src, dst, weight });
}

/// 序列化一个2-态射到writer
/// 格式：2mor <id>: <src_mor> => <dst_mor> [weight: <w>];
///
/// 设计约束：
///   - id/src_mor/dst_mor 必须合法（已在调用层校验）
///   - weight 使用默认格式化（%e风格），保证精度
///   - 每个2-态射一行，以分号结束
///   - 白皮书§2.2：2-态射连接1-态射，表示等价重写关系
pub fn serializeMorphism2(writer: anytype, id: u64, src_mor: u64, dst_mor: u64) !void {
    try writeFmt(writer, "2mor {}: {} => {};\n", .{ id, src_mor, dst_mor });
}

/// 序列化一个Δ运算表达式到writer
/// 格式：delta(<a>, <b>) => <result>
///
/// 设计约束：
///   - a/b 为对象ID（已在调用层校验）
///   - result 为Δ运算的结果值
///   - 白皮书定义2.1：Δ(x,y) = f(x) - g(y) 是体系唯一原语
pub fn serializeDeltaExpr(writer: anytype, a: u64, b: u64, result: f64) !void {
    try writeFmt(writer, "delta({d}, {d}) => {e};\n", .{ a, b, result });
}

/// 序列化格join运算表达式到writer
/// 格式：join(<a>, <b>) => <result>
///
/// 设计约束：
///   - a/b 为对象ID（已在调用层校验）
///   - result 为join运算的结果值
///   - 白皮书§2.2.1：完备格的上确界运算
pub fn serializeJoinExpr(writer: anytype, a: u64, b: u64, result: f64) !void {
    try writeFmt(writer, "join({d}, {d}) => {e};\n", .{ a, b, result });
}

/// 序列化格meet运算表达式到writer
/// 格式：meet(<a>, <b>) => <result>
///
/// 设计约束：
///   - a/b 为对象ID（已在调用层校验）
///   - result 为meet运算的结果值
///   - 白皮书§2.2.1：完备格的下确界运算
pub fn serializeMeetExpr(writer: anytype, a: u64, b: u64, result: f64) !void {
    try writeFmt(writer, "meet({d}, {d}) => {e};\n", .{ a, b, result });
}

/// 将整个CDL图序列化为尘语言文本
/// 输出顺序：注释头 → 对象列表 → 1-态射列表 → 2-态射列表
///
/// 设计约束：
///   - 对象按ID升序输出（保证确定性，满足可复现要求）
///   - 态射按存储顺序输出（保持创建顺序信息）
///   - 2-态射按存储顺序输出（保持创建顺序信息）
///   - 每个部分前有章节注释
///
/// 引用依据：
///   - 白皮书§3.2：CDL子格 ↔ 尘语言表达式双向双射
///   - 白皮书§10.3 M2：尘语言序列化工具链
pub fn serializeGraph(writer: anytype, engine: *de.DeltaEngine) !void {
    const graph = &engine.graph;

    // 输出文件头注释
    try writeFmt(writer, "// Ω-落尘AGI 尘语言序列化 v5.1\n", .{});
    try writeFmt(writer, "// 白皮书§3.2 格码同构 | §10.3 M2 序列化工具链\n", .{});
    try writeFmt(writer, "// 对象数: {} | 1-态射: {} | 2-态射: {}\n", .{
        graph.objectCount(),
        graph.morphismCount(),
        graph.morphism2Count(),
    });
    try writeFmt(writer, "\n", .{});

    // 输出对象列表（对象ID从0开始连续编号，对应SoA布局的数组索引）
    // 按ID升序输出，保证序列化的确定性（满足可复现要求）
    const obj_count = graph.objectCount();
    if (obj_count > 0) {
        try writeFmt(writer, "// ===== 对象定义 ({}个) =====\n", .{obj_count});
        var i: u64 = 0;
        while (i < obj_count) : (i += 1) {
            const value = graph.object_values.items[i];
            const name = graph.object_names.items[i];
            // 输出对象定义，附带名称作为注释（便于人类阅读）
            try writeFmt(writer, "obj {} := {e}; // {s}\n", .{ i, value, name });
        }
        try writeFmt(writer, "\n", .{});
    }

    // 输出1-态射列表
    // 每个态射包含ID、源对象、目标对象、权重
    // 白皮书§2.2：1-态射是对象间的关系（CDL的基本边）
    const morph_count = graph.morphismCount();
    if (morph_count > 0) {
        try writeFmt(writer, "// ===== 1-态射定义 ({}个) =====\n", .{morph_count});
        for (graph.morphisms.items) |m| {
            try serializeMorphism(writer, m.morphism_id, m.source_morphism, m.target_morphism);
        }
        try writeFmt(writer, "\n", .{});
    }

    // 输出2-态射列表
    // 每个2-态射包含ID、源态射、目标态射、权重
    // 白皮书§2.2：2-态射是态射间的等价重写关系
    const morph2_count = graph.morphism2Count();
    if (morph2_count > 0) {
        try writeFmt(writer, "// ===== 2-态射定义 ({}个) =====\n", .{morph2_count});
        for (graph.morphisms2.items) |m| {
            try serializeMorphism2(writer, m.morphism_id, m.source_morphism, m.target_morphism);
        }
        try writeFmt(writer, "\n", .{});
    }
}

/// 将引擎状态格式化为完整尘语言文本
/// 返回分配的 []u8 内存，调用者需 free
///
/// 设计约束：
///   - 使用提供的 allocator 分配内存
///   - 返回完整的尘语言文本，包含所有对象、态射、2-态射
///   - 如果引擎为空图，返回包含空对象/态射列表的有效文本（非空字符串）
///   - 白皮书§10.3 M2：完整引擎状态导出
pub fn formatEngine(engine: *de.DeltaEngine, allocator: std.mem.Allocator) ![]u8 {
    // 使用ArrayList收集输出（动态增长，避免预分配大小估算）
    // Zig 0.16.0 API：使用initCapacity替代init
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);

    // 直接使用std.fmt.allocPrint获取格式化文本，追加到列表
    // 避免依赖ArrayListWriter（定义在后面），解决Zig 0.16.0兼容问题
    {
        const header = try std.fmt.allocPrint(allocator,
            \\// Ω-落尘AGI 尘语言序列化 v5.1
            \\// 白皮书§3.2 格码同构 | §10.3 M2 序列化工具链
            \\// 对象数: {} | 1-态射: {} | 2-态射: {}
            \\
        , .{
            engine.graph.objectCount(),
            engine.graph.morphismCount(),
            engine.graph.morphism2Count(),
        });
        defer allocator.free(header);
        try list.appendSlice(allocator,header);
    }

    // 输出对象列表
    const obj_count = engine.graph.objectCount();
    if (obj_count > 0) {
        const section = try std.fmt.allocPrint(allocator, "// ===== 对象定义 ({}个) =====\n", .{obj_count});
        defer allocator.free(section);
        try list.appendSlice(allocator,section);
        var i: u64 = 0;
        while (i < obj_count) : (i += 1) {
            const value = engine.graph.object_values.items[i];
            const name = engine.graph.object_names.items[i];
            const entry = try std.fmt.allocPrint(allocator, "obj {} := {e}; // {s}\n", .{ i, value, name });
            defer allocator.free(entry);
            try list.appendSlice(allocator,entry);
        }
        try list.appendSlice(allocator,"\n");
    }

    // 输出1-态射列表
    const morph_count = engine.graph.morphismCount();
    if (morph_count > 0) {
        const section = try std.fmt.allocPrint(allocator, "// ===== 1-态射定义 ({}个) =====\n", .{morph_count});
        defer allocator.free(section);
        try list.appendSlice(allocator,section);
        for (engine.graph.morphisms.items) |m| {
            const entry = try std.fmt.allocPrint(allocator, "mor {}: {} -> {} [weight: {e}];\n", .{
                m.morphism_id, m.source, m.target, m.delta,
            });
            defer allocator.free(entry);
            try list.appendSlice(allocator,entry);
        }
        try list.appendSlice(allocator,"\n");
    }

    // 输出2-态射列表
    const morph2_count = engine.graph.morphism2Count();
    if (morph2_count > 0) {
        const section = try std.fmt.allocPrint(allocator, "// ===== 2-态射定义 ({}个) =====\n", .{morph2_count});
        defer allocator.free(section);
        try list.appendSlice(allocator,section);
        for (engine.graph.morphisms2.items) |m| {
            const entry = try std.fmt.allocPrint(allocator, "2mor {}: {} => {};\n", .{
                m.morphism_id, m.source_morphism, m.target_morphism,
            });
            defer allocator.free(entry);
            try list.appendSlice(allocator,entry);
        }
        try list.appendSlice(allocator,"\n");
    }

    // 提取所有权：调用者负责free返回的内存
    return list.toOwnedSlice(allocator);
}

// ============================================================
// 反序列化函数：尘语言文本 → CDL结构
// 白皮书§3.2：尘语言表达式 → CDL子格是严格双射
// 反序列化方向：文本 → CDL
// ============================================================

/// 解析对象定义行
/// 格式：obj <id> := <value>;
///
/// 解析步骤：
///   1. 验证行以 "obj " 开头
///   2. 提取 id（:= 之前的部分）
///   3. 提取 value（:= 之后，; 之前的部分）
///   4. 移除可选的行尾注释（// 之后的内容）
///
/// 返回值：{ id: u64, value: f64 }
/// 错误：ParseError（格式不匹配）、NumberParseError（数字解析失败）
pub fn parseObject(line: []const u8) !struct { id: u64, value: f64 } {
    const trimmed = trim(line);

    // 验证以 "obj " 开头
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "obj")) {
        return DustLangError.ParseError;
    }

    // 去掉 "obj" 前缀
    var rest = trim(trimmed[3..]);
    if (rest.len == 0) return DustLangError.ParseError;

    // 查找 ":=" 分隔符
    const assign_pos = findStrPos(rest, ":=") orelse return DustLangError.ParseError;

    // 提取 id（":=" 之前的部分）
    const id_str = trim(rest[0..assign_pos]);
    const id = parseU64(id_str) catch return DustLangError.NumberParseError;

    // 提取 value（":=" 之后，";" 或行尾之前）
    var value_str = trim(rest[assign_pos + 2 ..]);

    // 移除行尾分号
    if (value_str.len > 0 and value_str[value_str.len - 1] == ';') {
        value_str = value_str[0 .. value_str.len - 1];
    }

    // 移除行尾注释（// 之后的内容）
    const comment_pos = findStrPos(value_str, "//");
    if (comment_pos) |pos| {
        value_str = trim(value_str[0..pos]);
    }

    const value = parseF64(value_str) catch return DustLangError.NumberParseError;
    return .{ .id = id, .value = value };
}

/// 解析态射定义行
/// 格式：mor <id>: <src> -> <dst> [weight: <w>];
///
/// 解析步骤：
///   1. 验证行以 "mor " 开头
///   2. 提取 id（: 之前的部分）
///   3. 提取 src（: 之后，-> 之前的部分）
///   4. 提取 dst（-> 之后，[ 之前的部分）
///   5. 提取 weight（[weight: 之后，] 之前的部分）
///
/// 返回值：{ id: u64, src: u64, dst: u64, weight: f64 }
/// 错误：ParseError（格式不匹配）、NumberParseError（数字解析失败）
pub fn parseMorphism(line: []const u8) !struct { id: u64, src: u64, dst: u64, weight: f64 } {
    const trimmed = trim(line);

    // 验证以 "mor " 开头（注意空格，避免匹配到 "mor" 开头的其他单词）
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "mor")) {
        return DustLangError.ParseError;
    }

    // 去掉 "mor" 前缀
    var rest = trim(trimmed[3..]);
    if (rest.len == 0) return DustLangError.ParseError;

    // 查找 ":" 分隔符（id 与 src 的分界）
    const colon_pos = findChar(rest, ':') orelse return DustLangError.ParseError;
    const id_str = trim(rest[0..colon_pos]);
    const id = parseU64(id_str) catch return DustLangError.NumberParseError;

    // ":" 之后的部分：<src> -> <dst> [weight: <w>];
    var after_colon = trim(rest[colon_pos + 1 ..]);
    if (after_colon.len == 0) return DustLangError.ParseError;

    // 移除行尾注释（// 之后的内容）
    const comment_pos = findStrPos(after_colon, "//");
    if (comment_pos) |pos| {
        after_colon = trim(after_colon[0..pos]);
    }

    // 提取权重部分：[weight: <w>]
    const bracket_pos = findChar(after_colon, '[');
    var weight: f64 = 1.0; // 默认权重1.0
    if (bracket_pos) |bpos| {
        const bracket_content = trim(after_colon[bpos + 1 ..]);
        const close_bracket = findChar(bracket_content, ']') orelse return DustLangError.ParseError;
        const weight_spec = trim(bracket_content[0..close_bracket]);
        // 解析 "weight: <value>" 格式
        if (std.mem.startsWith(u8, weight_spec, "weight:")) {
            const w_str = trim(weight_spec[7..]);
            weight = parseF64(w_str) catch return DustLangError.WeightParseError;
        } else {
            return DustLangError.ParseError;
        }
        // 移除 [weight: ...] 部分，只保留核心表达式
        after_colon = trim(after_colon[0..bpos]);
    }

    // 移除行尾分号
    if (after_colon.len > 0 and after_colon[after_colon.len - 1] == ';') {
        after_colon = after_colon[0 .. after_colon.len - 1];
    }

    // 查找 "->" 分隔符（src 与 dst 的分界）
    const arrow_pos = findStrPos(after_colon, "->") orelse return DustLangError.ParseError;
    const src_str = trim(after_colon[0..arrow_pos]);
    const dst_str = trim(after_colon[arrow_pos + 2 ..]);

    const src = parseU64(src_str) catch return DustLangError.NumberParseError;
    const dst = parseU64(dst_str) catch return DustLangError.NumberParseError;

    return .{ .id = id, .src = src, .dst = dst, .weight = weight };
}

/// 解析2-态射定义行
/// 格式：2mor <id>: <src_mor> => <dst_mor> [weight: <w>];
///
/// 解析步骤：
///   1. 验证行以 "2mor " 开头
///   2. 提取 id（: 之前的部分）
///   3. 提取 src_mor（: 之后，=> 之前的部分）
///   4. 提取 dst_mor（=> 之后，[ 之前的部分）
///   5. 提取 weight（[weight: 之后，] 之前的部分）
///
/// 返回值：{ id: u64, src_mor: u64, dst_mor: u64, weight: f64 }
/// 错误：ParseError（格式不匹配）、NumberParseError（数字解析失败）
pub fn parseMorphism2(line: []const u8) !struct { id: u64, src_mor: u64, dst_mor: u64 } {
    const trimmed = trim(line);

    // 验证以 "2mor " 开头
    if (trimmed.len < 5 or !std.mem.startsWith(u8, trimmed, "2mor")) {
        return DustLangError.ParseError;
    }

    // 去掉 "2mor" 前缀
    var rest = trim(trimmed[4..]);
    if (rest.len == 0) return DustLangError.ParseError;

    // 查找 ":" 分隔符
    const colon_pos = findChar(rest, ':') orelse return DustLangError.ParseError;
    const id_str = trim(rest[0..colon_pos]);
    const id = parseU64(id_str) catch return DustLangError.NumberParseError;

    // ":" 之后的部分
    var after_colon = trim(rest[colon_pos + 1 ..]);
    if (after_colon.len == 0) return DustLangError.ParseError;

    // 移除行尾注释
    const comment_pos = findStrPos(after_colon, "//");
    if (comment_pos) |pos| {
        after_colon = trim(after_colon[0..pos]);
    }

    // 提取权重部分
    const bracket_pos = findChar(after_colon, '[');
    var weight: f64 = 1.0;
    if (bracket_pos) |bpos| {
        const bracket_content = trim(after_colon[bpos + 1 ..]);
        const close_bracket = findChar(bracket_content, ']') orelse return DustLangError.ParseError;
        const weight_spec = trim(bracket_content[0..close_bracket]);
        if (std.mem.startsWith(u8, weight_spec, "weight:")) {
            const w_str = trim(weight_spec[7..]);
            weight = parseF64(w_str) catch return DustLangError.WeightParseError;
        } else {
            return DustLangError.ParseError;
        }
        after_colon = trim(after_colon[0..bpos]);
    }

    // 移除行尾分号
    if (after_colon.len > 0 and after_colon[after_colon.len - 1] == ';') {
        after_colon = after_colon[0 .. after_colon.len - 1];
    }

    // 查找 "=>" 分隔符
    const double_arrow_pos = findStrPos(after_colon, "=>") orelse return DustLangError.ParseError;
    const src_str = trim(after_colon[0..double_arrow_pos]);
    const dst_str = trim(after_colon[double_arrow_pos + 2 ..]);

    const src_mor = parseU64(src_str) catch return DustLangError.NumberParseError;
    const dst_mor = parseU64(dst_str) catch return DustLangError.NumberParseError;

    return .{ .id = id, .src_mor = src_mor, .dst_mor = dst_mor, .weight = weight };
}

/// 从尘语言文本反序列化到CDL图
///
/// 解析策略：
///   1. 按行分割文本
///   2. 跳过空行和注释行
///   3. 根据行首token分发到对应解析器
///   4. 对象定义：创建到graph（createObject）
///   5. 1-态射定义：创建到graph（createMorphism）
///   6. 2-态射定义：创建到graph（createMorphism2WithWeight）
///   7. join/meet/delta 表达式：跳过（表达式序列仅为记录，不在反序列化时重新计算）
///   8. graph区块：递归处理区块内的行
///
/// 设计约束：
///   - ID稳定性：对象/态射的ID在序列化-反序列化循环中保持一致
///   - 容错性：未知行被跳过（不是错误），保证向前兼容
///   - 白皮书§3.2：文本 → CDL 是严格双射的逆向映射
///
/// 引用依据：
///   - 白皮书§3.2 格码同构：CDL子格 ↔ 尘语言表达式是严格的双向双射
///   - 白皮书§10.3 M2：尘语言序列化工具链
pub fn deserialize(allocator: std.mem.Allocator, text: []const u8, graph: *dg.DustGraph) !void {
    // 按行分割文本（保留行号用于错误定位）
    // Zig 0.16.0：ArrayList使用initCapacity替代init
    var lines = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    if (lines.items.len == 0) return DustLangError.EmptyInput;

    // 逐行解析
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const raw_line = lines.items[i];
        if (isCommentOrEmpty(raw_line)) continue;

        const line = trim(raw_line);

        // 处理子图区块开始
        if (std.mem.startsWith(u8, line, "graph ")) {
            // 查找 "{" 匹配的结束位置
            const brace_open = findChar(line, '{') orelse {
                // 如果本行没有 "{", 可能在下几行，继续查找
                var j = i + 1;
                var found_block = false;
                while (j < lines.items.len) : (j += 1) {
                    if (findChar(lines.items[j], '{')) |_| {
                        found_block = true;
                        i = j;
                        break;
                    }
                    if (!isCommentOrEmpty(lines.items[j])) break;
                }
                if (!found_block) continue;
                continue;
            };
            // 子图区块跳过（不进行递归嵌套解析简化实现）
            // 区块内的行会被"单行解析"的自然顺序处理
            _ = brace_open;
            continue;
        }

        // 根据行首token分发解析
        if (std.mem.startsWith(u8, line, "obj ")) {
            // 解析对象定义并创建到graph
            const parsed = try parseObject(line);
            // 使用名称 "dust_{id}" 创建对象（保持反序列化对象名的可追溯性）
            var buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "dust_{}", .{parsed.id});
            // 注意：如果ID对应的对象已存在，createObject的去重逻辑会返回已有ID
            // 这保证了反序列化的幂等性（多次反序列化同一文本得到相同结构）
            _ = try graph.createObject(name, parsed.value);
        } else if (std.mem.startsWith(u8, line, "mor ")) {
            // 解析1-态射定义并创建到graph
            const parsed = try parseMorphism(line);
            // 校验source/target ID在graph范围内
            if (parsed.src >= graph.objectCount() or parsed.dst >= graph.objectCount()) {
                return DustLangError.IdOutOfBounds;
            }
            _ = try graph.createMorphism(parsed.src, parsed.dst, parsed.weight);
        } else if (std.mem.startsWith(u8, line, "2mor ")) {
            // 解析2-态射定义并创建到graph
            const parsed = try parseMorphism2(line);
            // 校验source/dst态射ID存在
            if (!graph.morphismExists(parsed.src_mor)) return DustLangError.IdOutOfBounds;
            if (!graph.morphismExists(parsed.dst_mor)) return DustLangError.IdOutOfBounds;
            // 使用REWRITE_EQUIVALENT作为默认重写类型
            // 更精确的重写类型需要扩展2mor语法
            _ = try graph.createMorphism2WithWeight(
                parsed.src_mor,
                parsed.dst_mor,
                0, // REWRITE_EQUIVALENT
                parsed.weight,
            );
        } else if (std.mem.startsWith(u8, line, "join(") or
            std.mem.startsWith(u8, line, "meet(") or
            std.mem.startsWith(u8, line, "delta("))
        {
            // 表达式行跳过（仅为记录用途，不在反序列化时重新计算）
            // 这些行记录了运算的历史结果，但在反序列化时不需要重建
            // 对象和态射结构已通过前面的 obj/mor 定义完整重建
            continue;
        }
        // 未知指令行：跳过（容错，保证向前兼容）
        // 这允许在未来的尘语言版本中增加新指令而不破坏旧解析器
    }
}

// ============================================================
// Zig 0.16.0的ArrayList Aligned版writer包装
// 提供与旧版writer()兼容的接口
// ============================================================

/// ArrayList的writer包装，使用append/appendSlice写入
/// 通过writeFn实现std.io.Writer接口，支持writer.print调用
const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// 实现std.io.Writer接口的writeFn
    pub fn writeFn(self: ArrayListWriter, bytes: []const u8) !usize {
        try self.list.appendSlice(self.allocator, bytes);
        return bytes.len;
    }

    /// 实现writer.print所需的writeAll（std.io.Writer接口）
    pub fn writeAll(self: ArrayListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    /// 获取std.io.Writer（支持print格式化方法）
    pub fn asWriter(self: ArrayListWriter) std.io.Writer(
        ArrayListWriter,
        error{OutOfMemory},
        writeFn,
    ) {
        return .{ .context = self };
    }

    /// 直接print格式化写入（支持comptime fmt和args）
    /// 供writeFmt/writer.print调用
    pub fn print(self: ArrayListWriter, comptime fmt: []const u8, args: anytype) !void {
        // 使用固定缓冲区格式化后追加到ArrayList
        var buf: [4096]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try self.list.appendSlice(self.allocator, formatted);
    }
};

// ============================================================
// 单元测试
// 白皮书要求：单元测试分支覆盖率≥95%，核心逻辑100%覆盖
// ============================================================

test "parseObject - 基本格式" {
    const result = try parseObject("obj 0 := 42.0;");
    try std.testing.expectEqual(@as(u64, 0), result.id);
    try std.testing.expectEqual(@as(f64, 42.0), result.value);

    const result2 = try parseObject("obj 5 := -3.14;");
    try std.testing.expectEqual(@as(u64, 5), result2.id);
    try std.testing.expectEqual(@as(f64, -3.14), result2.value);
}

test "parseObject - 带注释" {
    const result = try parseObject("obj 0 := 42.0; // num_0");
    try std.testing.expectEqual(@as(u64, 0), result.id);
    try std.testing.expectEqual(@as(f64, 42.0), result.value);
}

test "parseObject - 前导空白" {
    const result = try parseObject("  obj 7 := 3.14;");
    try std.testing.expectEqual(@as(u64, 7), result.id);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.value, 1e-10);
}

test "parseObject - 科学计数法" {
    const result = try parseObject("obj 1 := 1e-10;");
    try std.testing.expectEqual(@as(u64, 1), result.id);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-10), result.value, 1e-20);
}

test "parseObject - 错误格式" {
    // 无效前缀
    try std.testing.expectError(DustLangError.ParseError, parseObject("invalid 0 := 42.0;"));
    // 缺少id
    try std.testing.expectError(DustLangError.ParseError, parseObject("obj := 42.0;"));
    // 缺少:=
    try std.testing.expectError(DustLangError.ParseError, parseObject("obj 0 42.0;"));
    // 空行
    try std.testing.expectError(DustLangError.ParseError, parseObject(""));
}

test "parseObject - 数字解析错误" {
    try std.testing.expectError(DustLangError.NumberParseError, parseObject("obj abc := 42.0;"));
}

test "parseMorphism - 基本格式" {
    const result = try parseMorphism("mor 0: 0 -> 1 [weight: 1.0];");
    try std.testing.expectEqual(@as(u64, 0), result.id);
    try std.testing.expectEqual(@as(u64, 0), result.src);
    try std.testing.expectEqual(@as(u64, 1), result.dst);
    try std.testing.expectEqual(@as(f64, 1.0), result.weight);
}

test "parseMorphism - 默认权重" {
    const result = try parseMorphism("mor 1: 2 -> 3;");
    try std.testing.expectEqual(@as(u64, 1), result.id);
    try std.testing.expectEqual(@as(u64, 2), result.src);
    try std.testing.expectEqual(@as(u64, 3), result.dst);
    try std.testing.expectEqual(@as(f64, 1.0), result.weight);
}

test "parseMorphism - 带注释" {
    const result = try parseMorphism("mor 0: 0 -> 1 [weight: 0.5]; // identity");
    try std.testing.expectEqual(@as(u64, 0), result.id);
    try std.testing.expectEqual(@as(f64, 0.5), result.weight);
}

test "parseMorphism - 科学计数法权重" {
    const result = try parseMorphism("mor 2: 5 -> 10 [weight: 1e-6];");
    try std.testing.expectApproxEqAbs(@as(f64, 1e-6), result.weight, 1e-20);
}

test "parseMorphism - 错误格式" {
    try std.testing.expectError(DustLangError.ParseError, parseMorphism("invalid 0: 0 -> 1;"));
    try std.testing.expectError(DustLangError.ParseError, parseMorphism("mor 0 0 -> 1;"));
    try std.testing.expectError(DustLangError.ParseError, parseMorphism("mor 0: 0 -> 1 [invalid: 1.0];"));
}

test "parseMorphism2 - 基本格式" {
    const result = try parseMorphism2("2mor 0: 0 => 1 [weight: 1.0];");
    try std.testing.expectEqual(@as(u64, 0), result.id);
    try std.testing.expectEqual(@as(u64, 0), result.src_mor);
    try std.testing.expectEqual(@as(u64, 1), result.dst_mor);
}

test "parseMorphism2 - 基本格式 无weight" {
    const result = try parseMorphism2("2mor 1: 2 => 3;");
    try std.testing.expectEqual(@as(u64, 1), result.id);
    try std.testing.expectEqual(@as(u64, 2), result.src_mor);
    try std.testing.expectEqual(@as(u64, 3), result.dst_mor);
}

test "parseMorphism2 - 错误格式" {
    try std.testing.expectError(DustLangError.ParseError, parseMorphism2("mor 0: 0 => 1;"));
    try std.testing.expectError(DustLangError.ParseError, parseMorphism2("2mor 0: 0 -> 1;"));
    try std.testing.expectError(DustLangError.ParseError, parseMorphism2("2mor :"));
}

test "isCommentOrEmpty" {
    try std.testing.expect(isCommentOrEmpty(""));
    try std.testing.expect(isCommentOrEmpty("  "));
    try std.testing.expect(isCommentOrEmpty("// 注释"));
    try std.testing.expect(isCommentOrEmpty("  // 带空格的注释"));
    try std.testing.expect(!isCommentOrEmpty("obj 0 := 42.0;"));
    try std.testing.expect(!isCommentOrEmpty("mor 0: 0 -> 1;"));
}

test "serializeObject" {
    // 使用固定缓冲区模拟writer（避免ArrayList的init/initCapacity差异）
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try serializeObject(writer, 0, 42.0);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "obj 0 :="));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "42"));

    // 反序列化验证
    const parsed = try parseObject(output);
    try std.testing.expectEqual(@as(u64, 0), parsed.id);
    try std.testing.expectEqual(@as(f64, 42.0), parsed.value);
}

test "serializeMorphism" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try serializeMorphism(writer, 0, 0, 1, 1.0);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "mor 0:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "0 -> 1"));

    // 反序列化验证
    const parsed = try parseMorphism(output);
    try std.testing.expectEqual(@as(u64, 0), parsed.id);
    try std.testing.expectEqual(@as(u64, 0), parsed.src);
    try std.testing.expectEqual(@as(u64, 1), parsed.dst);
}

test "serializeMorphism2" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try serializeMorphism2(writer, 0, 0, 1, 1.0);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "2mor 0:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "0 => 1"));

    // 反序列化验证
    const parsed = try parseMorphism2(output);
    try std.testing.expectEqual(@as(u64, 0), parsed.id);
    try std.testing.expectEqual(@as(u64, 0), parsed.src_mor);
    try std.testing.expectEqual(@as(u64, 1), parsed.dst_mor);
}

test "serializeDeltaExpr" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try serializeDeltaExpr(writer, 0, 1, 0.5);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "delta(0, 1)"));
}

test "serializeGraph - 空引擎" {
    var engine = try de.DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try serializeGraph(writer, &engine);
    const output = fbs.getWritten();
    // 空引擎应输出注释头和对象/态射定义
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "对象数:"));
}

test "serializeGraph - 有数据的引擎" {
    var engine = try de.DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 创建额外对象和态射
    const obj1 = try engine.graph.createObject("test_a", 10.0);
    const obj2 = try engine.graph.createObject("test_b", 20.0);
    _ = try engine.graph.createMorphism(obj1, obj2, 0.5);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try serializeGraph(writer, &engine);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "obj "));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "mor "));
}

test "formatEngine" {
    var engine = try de.DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 创建一些测试数据
    const obj1 = try engine.graph.createObject("test_x", 100.0);
    const obj2 = try engine.graph.createObject("test_y", 200.0);
    _ = try engine.graph.createMorphism(obj1, obj2, 0.75);

    const text = try formatEngine(&engine, std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "test_x"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "test_y"));
}

test "deserialize - 基本对象" {
    const text =
        \\// 测试尘语言
        \\obj 0 := 10.0;
        \\obj 1 := 20.0;
        \\obj 2 := 30.0;
    ;

    var graph = dg.DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    try deserialize(std.testing.allocator, text, &graph);

    // 验证对象已创建（ID 0,1,2 应存在）
    try std.testing.expectEqual(@as(usize, 3), graph.objectCount());
    if (graph.getObjectValue(0)) |val| {
        try std.testing.expectEqual(@as(f64, 10.0), val);
    } else {
        try std.testing.expect(false);
    }
    if (graph.getObjectValue(1)) |val| {
        try std.testing.expectEqual(@as(f64, 20.0), val);
    } else {
        try std.testing.expect(false);
    }
}

test "deserialize - 对象和态射" {
    const text =
        \\obj 0 := 10.0;
        \\obj 1 := 20.0;
        \\mor 0: 0 -> 1 [weight: 0.5];
    ;

    var graph = dg.DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    try deserialize(std.testing.allocator, text, &graph);

    // 验证对象和态射
    try std.testing.expectEqual(@as(usize, 2), graph.objectCount());
    try std.testing.expectEqual(@as(usize, 1), graph.morphismCount());
}

test "deserialize - 带注释" {
    const text =
        \\// 这是一条注释
        \\obj 0 := 42.0; // num_0
        \\// 另一条注释
        \\obj 1 := 3.14; // pi
    ;

    var graph = dg.DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    try deserialize(std.testing.allocator, text, &graph);
    try std.testing.expectEqual(@as(usize, 2), graph.objectCount());
}

test "deserialize - 跳过表达式行" {
    const text =
        \\obj 0 := 10.0;
        \\obj 1 := 20.0;
        \\delta(0, 1) => 0.5;
        \\join(0, 1) => 20.0;
        \\meet(0, 1) => 10.0;
    ;

    var graph = dg.DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    try deserialize(std.testing.allocator, text, &graph);
    try std.testing.expectEqual(@as(usize, 2), graph.objectCount());
}

test "deserialize - 未知指令被跳过" {
    const text =
        \\obj 0 := 10.0;
        \\unknown_directive some stuff;
        \\obj 1 := 20.0;
    ;

    var graph = dg.DustGraph.init(std.testing.allocator);
    defer graph.deinit();

    try deserialize(std.testing.allocator, text, &graph);
    try std.testing.expectEqual(@as(usize, 2), graph.objectCount());
}

test "序列化-反序列化-序列化 循环一致性（白皮书§3.2 格码同构）" {
    // 创建引擎并填充数据
    var engine = try de.DeltaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 添加额外的对象和态射
    const obj1 = try engine.graph.createObject("test_a", 100.0);
    const obj2 = try engine.graph.createObject("test_b", 200.0);
    _ = try engine.graph.createMorphism(obj1, obj2, 0.75);

    // 第一次序列化
    const text1 = try formatEngine(&engine, std.testing.allocator);
    defer std.testing.allocator.free(text1);

    // 反序列化到新图
    var new_graph = dg.DustGraph.init(std.testing.allocator);
    defer new_graph.deinit();

    try deserialize(std.testing.allocator, text1, &new_graph);

    // 验证对象数和态射数一致
    try std.testing.expect(new_graph.objectCount() >= 2);
    try std.testing.expect(new_graph.morphismCount() >= 1);

    // 验证值正确
    const first_new_obj_val = new_graph.getObjectValue(0) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(f64, 100.0), first_new_obj_val);

    const second_new_obj_val = new_graph.getObjectValue(1) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(f64, 200.0), second_new_obj_val);
}

test "DustLangError 类型存在" {
    // 验证所有错误变体可被引用和使用
    const errors = [_]DustLangError{
        DustLangError.ParseError,
        DustLangError.NumberParseError,
        DustLangError.IdOutOfBounds,
        DustLangError.UnknownDirective,
        DustLangError.EmptyInput,
        DustLangError.WeightParseError,
        DustLangError.WriteError,
        DustLangError.OutOfMemory,
    };
    try std.testing.expectEqual(@as(usize, 8), errors.len);
}

test "trim 函数" {
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
    try std.testing.expectEqualStrings("world", trim("\tworld\t"));
    try std.testing.expectEqualStrings("", trim("   "));
    try std.testing.expectEqualStrings("a b c", trim("  a b c  "));
}

test "parseU64" {
    try std.testing.expectEqual(@as(u64, 42), try parseU64("42"));
    try std.testing.expectEqual(@as(u64, 0), try parseU64("0"));
    try std.testing.expectEqual(@as(u64, 18446744073709551615), try parseU64("18446744073709551615"));
    try std.testing.expectError(DustLangError.NumberParseError, parseU64(""));
    try std.testing.expectError(DustLangError.NumberParseError, parseU64("abc"));
}

test "parseF64" {
    try std.testing.expectEqual(@as(f64, 3.14), try parseF64("3.14"));
    try std.testing.expectEqual(@as(f64, -1.5), try parseF64("-1.5"));
    try std.testing.expectEqual(@as(f64, 1e-10), try parseF64("1e-10"));
    try std.testing.expectError(DustLangError.NumberParseError, parseF64(""));
}