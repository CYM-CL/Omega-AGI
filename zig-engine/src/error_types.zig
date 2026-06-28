// Ω-落尘AGI 统一错误类型体系 v4.2
//
// 严格对应白皮书要求：
// - "全链路显式错误处理，定义专属强类型错误体系，覆盖全量失败场景"
// - "严禁静默失败、裸用强制解包/异常终止"
// - "全量输入边界校验，非法输入返回明确错误"
//
// 本文件提供全项目统一的错误类型定义，所有模块使用此错误类型体系。
// 替代原来散落在各模块的 catch {} 静默吞没和 catch unreachable 强制解包。

const std = @import("std");

// ============================================================
// 一级错误分类（按领域划分）
// ============================================================

/// 记忆系统错误
pub const MemoryError = error{
    OutOfMemory,           // 内存分配失败（如ArrayList扩容失败）
    UseAfterFree,          // 使用已释放的内存
    DoubleFree,            // 重复释放
    BufferOverflow,        // 缓冲区溢出（如格式化写入超过缓冲区大小）
    InvalidPointer,        // 无效指针操作
};

/// 初始化错误
pub const InitError = error{
    ModuleNotInitialized,  // 模块尚未初始化即被使用
    AlreadyInitialized,    // 模块重复初始化
    InitFailed,            // 初始化过程失败
    DependencyMissing,     // 依赖模块缺失
};

/// 输入校验错误
pub const ValidationError = error{
    InvalidInput,          // 非法输入
    OutOfBounds,           // 超出范围
    ValueTooLarge,         // 值过大
    ValueTooSmall,         // 值过小
    NaNOrInf,              // 值为NaN或Infinity
    NegativeNotAllowed,    // 不允许负值
    DivisionByZero,        // 除零错误
    ObjectNotFound,        // 对象不存在
    MorphismNotFound,      // 态射不存在
    TooManyItems,          // 超出容量上限
};

/// 缓存操作错误
pub const CacheError = error{
    CacheInsertFailed,     // 缓存插入失败
    CacheLookupFailed,     // 缓存查找失败
    CacheFull,             // 缓存已满
    StaleEntry,            // 缓存项已过期
};

/// 训练过程错误
pub const TrainingError = error{
    PhaseMismatch,         // 训练阶段不匹配
    TaskGenerationFailed,  // 任务生成失败
    ScoreComputationFailed,// 评分计算失败
    BootstrapFailed,       // 自举过程失败
    FrozenZoneViolation,   // 违反冻结区规则
    L3TransitionFailed,    // L3跃迁失败
};

/// 安全错误
pub const SecurityError = error{
    PermissionDenied,      // 权限不足（文档9.3）
    L3NotApproved,         // L3操作未获人工批准（文档9.7）
    AnchorViolation,       // 违反锚定规则（文档9.2）
    ShutdownActive,        // 系统已关停（文档9.7）
    EvolutionPaused,       // 演化已暂停（文档9.7）
    SecurityLevelViolation,// 安全级别违规（文档9.4.1）
    FrozenObjectModification,// 试图修改冻结对象（文档7.4.5）
};

/// 持久化/IO错误
pub const PersistenceError = error{
    SerializationFailed,   // 序列化失败
    DeserializationFailed, // 反序列化失败
    FileNotFound,          // 文件未找到
    FileWriteError,        // 文件写入错误
    FileReadError,         // 文件读取错误
    InvalidCheckpoint,     // 检查点无效
    VersionMismatch,       // 版本不匹配
};

// ============================================================
// 二级错误：全局错误联合体（所有模块通用）
// ============================================================

/// 全局通用错误类型（覆盖全量失败场景）
pub const GlobalError = error{
    // 内存相关
    OutOfMemory,
    // 输入校验
    InvalidInput,
    OutOfBounds,
    DivisionByZero,
    ObjectNotFound,
    // 初始化
    ModuleNotInitialized,
    InitFailed,
    // 安全
    PermissionDenied,
    FrozenObjectModification,
    // 持久化
    SerializationFailed,
    DeserializationFailed,
    // 通用
    NotSupported,
    OperationFailed,
    // 缓存
    CacheInsertFailed,
};

// ============================================================
// 错误处理辅助函数（替代 catch {} 静默吞没）
// ============================================================

/// 错误日志级别
pub const ErrorLevel = enum(u8) {
    Debug = 0,      // 调试信息，不影响流程
    Info = 1,       // 普通信息，记录但不影响
    Warning = 2,    // 警告，可能影响后续操作
    Error = 3,      // 错误，影响当前操作但系统可继续运行
    Critical = 4,   // 严重错误，可能影响系统稳定性
    Fatal = 5,      // 致命错误，系统无法继续运行
};

/// 错误记录（用于审计全链路可追溯）
pub const ErrorRecord = struct {
    level: ErrorLevel,
    module: []const u8,      // 错误来源模块名
    operation: []const u8,   // 出错操作名
    code: usize,             // 错误码（0=无错误）
    message: []const u8,     // 错误描述
    timestamp_ns: i128,      // 时间戳
};

/// 错误日志收集器（全量错误留痕）
pub const ErrorLogger = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(ErrorRecord),
    max_records: usize,       // 最大记录数（默认10000）
    drop_count: u64,          // 因超出上限被丢弃的记录数

    pub fn init(allocator: std.mem.Allocator) ErrorLogger {
        return .{
            .allocator = allocator,
            .records = std.ArrayList(ErrorRecord).empty,
            .max_records = 10000,
            .drop_count = 0,
        };
    }

    pub fn deinit(self: *ErrorLogger) void {
        self.records.deinit(self.allocator);
    }

    /// 记录错误（带自动截断保护）
    pub fn logError(
        self: *ErrorLogger,
        level: ErrorLevel,
        module: []const u8,
        operation: []const u8,
        code: usize,
        message: []const u8,
    ) void {
        if (self.records.items.len >= self.max_records) {
            self.drop_count += 1;
            return; // 超出上限时静默丢弃（防止日志本身导致OOM）
        }
        // 日志记录失败不影响主流程（此处的 catch {} 是有意为之：
        // 日志系统自身的 append 失败不应递归调用日志记录导致无限循环）
        const ts = now();
        self.records.append(self.allocator, .{
            .level = level,
            .module = module,
            .operation = operation,
            .code = code,
            .message = message,
            .timestamp_ns = ts,
        }) catch {};
    }

    /// 获取所有错误记录
    pub fn getRecords(self: *const ErrorLogger) []const ErrorRecord {
        return self.records.items;
    }

    /// 获取丢弃计数
    pub fn getDropCount(self: *const ErrorLogger) u64 {
        return self.drop_count;
    }

    /// 清空错误记录
    pub fn clear(self: *ErrorLogger) void {
        self.records.clearRetainingCapacity();
        self.drop_count = 0;
    }
};

/// 获取纳秒级时间戳
fn now() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// 全局错误日志器实例（懒初始化）
var global_logger: ?ErrorLogger = null;
var global_logger_initialized: bool = false;

/// 初始化全局错误日志器
pub fn initGlobalLogger(allocator: std.mem.Allocator) void {
    global_logger = ErrorLogger.init(allocator);
    global_logger_initialized = true;
}

/// 释放全局错误日志器
pub fn deinitGlobalLogger() void {
    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
        global_logger_initialized = false;
    }
}

/// 全局错误日志记录（线程安全单线程版本）
pub fn logGlobalError(
    level: ErrorLevel,
    module: []const u8,
    operation: []const u8,
    code: usize,
    message: []const u8,
) void {
    if (global_logger_initialized) {
        if (global_logger) |*logger| {
            logger.logError(level, module, operation, code, message);
        }
    }
}

/// 获取全局错误日志器引用
pub fn getGlobalLogger() ?*ErrorLogger {
    if (global_logger_initialized) {
        if (global_logger) |*logger| {
            return logger;
        }
    }
    return null;
}

// ============================================================
// 安全降级辅助函数
// ============================================================

/// 安全写入缓存操作的包装器
/// 替代 catch {} 静默吞没模式
/// 记录警告日志但不中断流程（缓存写入失败不应导致系统崩溃）
pub fn safeCachePut(
    module: []const u8,
    operation: []const u8,
    comptime performPut: anytype,
) void {
    performPut() catch |err| {
        logGlobalError(.Warning, module, operation, @intFromError(err), "Cache put failed, continuing");
    };
}

/// 安全ArrayList append的包装器
/// 替代 catch {} 静默吞没模式
/// 记录警告日志但不中断流程
pub fn safeAppend(
    module: []const u8,
    operation: []const u8,
    comptime performAppend: anytype,
) void {
    performAppend() catch |err| {
        logGlobalError(.Warning, module, operation, @intFromError(err), "Append failed, continuing");
    };
}

/// 安全初始化：替代 catch unreachable
/// 失败时返回默认值并记录错误
pub fn safeInitOrElse(
    module: []const u8,
    operation: []const u8,
    comptime performInit: anytype,
    comptime default: anytype,
) @TypeOf(default) {
    return performInit() catch |err| {
        logGlobalError(.Error, module, operation, @intFromError(err), "Init failed, using default");
        return default;
    };
}

/// 安全格式化：替代 catch unreachable 的bufPrint
/// 失败时返回截断字符串
pub fn safeBufPrint(
    module: []const u8,
    buffer: []u8,
    comptime fmt: []const u8,
    args: anytype,
) []u8 {
    return std.fmt.bufPrint(buffer, fmt, args) catch |err| {
        logGlobalError(.Warning, module, "safeBufPrint", @intFromError(err), "Buffer too small, truncating");
        if (buffer.len > 0) {
            buffer[0] = 0;
            return buffer[0..1];
        }
        return buffer;
    };
}

/// 将错误码转换为usize（用于ErrorRecord）
/// Zig 0.16.0兼容：@intFromError 接受error类型
pub fn errorCode(err: anyerror) usize {
    return @intFromError(err);
}

// ============================================================
// 安全数值转换工具函数
// ============================================================

/// 安全整数转换：i64 → u64（负数返回 0 并记录警告）
pub fn safeI64ToU64(module: []const u8, operation: []const u8, val: i64) u64 {
    if (val < 0) {
        logGlobalError(.Warning, module, operation, 0, "negative value clamped to 0 in i64→u64 conversion");
        return 0;
    }
    return @as(u64, @intCast(val));
}

/// 安全整数转换：u64 → u32（超出范围截断并记录警告）
pub fn safeU64ToU32(module: []const u8, operation: []const u8, val: u64) u32 {
    if (val > std.math.maxInt(u32)) {
        logGlobalError(.Warning, module, operation, 0, "u64 value exceeds u32 max, clamping");
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(val));
}

/// 安全整数转换：u64 → u8（超出范围截断并记录警告）
pub fn safeU64ToU8(module: []const u8, operation: []const u8, val: u64) u8 {
    if (val > std.math.maxInt(u8)) {
        logGlobalError(.Warning, module, operation, 0, "u64 value exceeds u8 max, clamping");
        return std.math.maxInt(u8);
    }
    return @as(u8, @intCast(val));
}

/// 安全整数转换：usize → u32（超出范围截断并记录警告）
pub fn safeUsizeToU32(module: []const u8, operation: []const u8, val: usize) u32 {
    if (val > std.math.maxInt(u32)) {
        logGlobalError(.Warning, module, operation, 0, "usize value exceeds u32 max, clamping");
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(val));
}

/// 安全整数转换：usize → u64（无风险，在64位系统上usize ≤ u64）
pub fn safeUsizeToU64(val: usize) u64 {
    return @as(u64, @intCast(val));
}

// ============================================================
// 单元测试
// ============================================================

test "ErrorLogger 基本功能" {
    var logger = ErrorLogger.init(std.testing.allocator);
    defer logger.deinit();

    logger.logError(.Info, "test", "test_op", 0, "test message");
    try std.testing.expectEqual(@as(usize, 1), logger.records.items.len);
    try std.testing.expectEqualStrings("test message", logger.records.items[0].message);
}

test "ErrorLogger 上限保护" {
    var logger = ErrorLogger.init(std.testing.allocator);
    defer logger.deinit();
    logger.max_records = 5;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        logger.logError(.Info, "test", "test_op", 0, "test");
    }
    try std.testing.expectEqual(@as(usize, 5), logger.records.items.len);
    try std.testing.expectEqual(@as(u64, 5), logger.drop_count);
}

test "safeBufPrint 回退安全" {
    var buf: [4]u8 = undefined;
    const result = safeBufPrint("test", &buf, "hello_{d}", .{12345});
    // 缓冲区太小，应返回截断结果
    try std.testing.expect(result.len > 0);
}

test "GlobalError 类型可用性" {
    // 验证错误类型可以被引用并转换
    const err: GlobalError = error.OutOfMemory;
    try std.testing.expect(@typeInfo(@TypeOf(err)) == .error_set);
}

test "safeI64ToU64 负数返回0" {
    // 负数输入应安全地返回 0，而非 panic
    const result = safeI64ToU64("test", "test", -5);
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "safeI64ToU64 正数正常" {
    // 正数输入应正常转换为 u64
    const result = safeI64ToU64("test", "test", 42);
    try std.testing.expectEqual(@as(u64, 42), result);
}

test "safeU64ToU32 最大值截断" {
    // 超出 u32 范围的值应截断到 maxInt(u32)，而非 panic
    const val: u64 = std.math.maxInt(u64);
    const result = safeU64ToU32("test", "test", val);
    try std.testing.expectEqual(std.math.maxInt(u32), result);
}

test "safeU64ToU32 正常范围" {
    // 正常范围内的值应正常转换
    const result = safeU64ToU32("test", "test", 100);
    try std.testing.expectEqual(@as(u32, 100), result);
}

test "safeBufPrint 边界情况" {
    // 缓冲区极小时应安全截断，而非 panic
    var buf: [1]u8 = undefined;
    const result = safeBufPrint("test", &buf, "hello", .{});
    try std.testing.expect(result.len > 0);
}