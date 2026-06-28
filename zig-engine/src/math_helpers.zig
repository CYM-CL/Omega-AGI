// Ω-落尘AGI 数学辅助函数 v4.0.10 - 从trainer.zig拆分
//
// 严格对应白皮书v2.0：漂移防控锚点查询所需的数学运算
// 设计定义：
//   - 提供gcd/fibonacci/isPrime三个纯函数，用于漂移防控查询回调
//   - 所有函数为纯函数（无副作用、无状态），保证可复现性
//
// 拆分依据：单一职责原则（文档要求单函数/模块职责唯一、体量严格受控）
// 原trainer.zig 2365行职责过重，本模块仅负责数学辅助运算
//
// 依赖关系：无外部依赖（纯函数模块）

const std = @import("std");

/// 最大公约数（欧几里得算法）
///
/// 设计定义：
///   - 输入：两个非负整数a, b
///   - 输出：gcd(a, b)
///   - 算法：欧几里得辗转相除法
///
/// 数学约束：
///   - gcd(a, 0) = a
///   - gcd(0, 0) = 0
///   - gcd(a, b) = gcd(b, a mod b)
///   - 结果非负
///
/// 复杂度：O(log(min(a, b)))
pub fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const temp = y;
        y = x % y;
        x = temp;
    }
    return x;
}

/// 斐波那契数列第n项
///
/// 设计定义：
///   - 输入：非负整数n
///   - 输出：fib(n)
///   - 递推关系：fib(0)=0, fib(1)=1, fib(n)=fib(n-1)+fib(n-2)
///
/// 数学约束：
///   - fib(0) = 0
///   - fib(1) = 1
///   - fib(n) 单调递增（n≥1）
///   - 注意：u32最大支持fib(46)=1836311903，fib(47)溢出
///
/// 复杂度：O(n)
pub fn fibonacci(n: u32) u32 {
    if (n == 0) return 0;
    if (n == 1) return 1;
    var a: u32 = 0;
    var b: u32 = 1;
    var i: u32 = 2;
    while (i <= n) : (i += 1) {
        const c = a + b;
        a = b;
        b = c;
    }
    return b;
}

/// 素数判定
///
/// 设计定义：
///   - 输入：非负整数n
///   - 输出：true=素数，false=合数或0/1
///
/// 数学约束：
///   - 0和1不是素数
///   - 2是素数
///   - 偶数（>2）不是素数
///   - 奇数n：检查3~sqrt(n)范围内的奇数因子
///
/// 复杂度：O(sqrt(n))
pub fn isPrime(n: u32) bool {
    if (n < 2) return false;
    if (n == 2) return true;
    if (n % 2 == 0) return false;
    var i: u32 = 3;
    while (i * i <= n) : (i += 2) {
        if (n % i == 0) return false;
    }
    return true;
}

// ============================================================
// 单元测试（文档要求单元测试分支覆盖率≥95%，核心逻辑100%覆盖）
// ============================================================

test "gcd 基本运算" {
    try std.testing.expectEqual(@as(u32, 6), gcd(12, 18));
    try std.testing.expectEqual(@as(u32, 6), gcd(18, 12));
    try std.testing.expectEqual(@as(u32, 1), gcd(7, 13));
    try std.testing.expectEqual(@as(u32, 5), gcd(15, 25));
}

test "gcd 边界值" {
    try std.testing.expectEqual(@as(u32, 0), gcd(0, 0));
    try std.testing.expectEqual(@as(u32, 5), gcd(5, 0));
    try std.testing.expectEqual(@as(u32, 5), gcd(0, 5));
    try std.testing.expectEqual(@as(u32, 1), gcd(1, 1));
}

test "gcd 交换律" {
    // gcd(a,b) = gcd(b,a)
    try std.testing.expectEqual(gcd(100, 75), gcd(75, 100));
    try std.testing.expectEqual(gcd(12345, 6789), gcd(6789, 12345));
}

test "gcd 结合律" {
    // gcd(a, gcd(b,c)) = gcd(gcd(a,b), c)
    const a: u32 = 12;
    const b: u32 = 18;
    const c: u32 = 24;
    try std.testing.expectEqual(gcd(a, gcd(b, c)), gcd(gcd(a, b), c));
}

test "fibonacci 基本序列" {
    try std.testing.expectEqual(@as(u32, 0), fibonacci(0));
    try std.testing.expectEqual(@as(u32, 1), fibonacci(1));
    try std.testing.expectEqual(@as(u32, 1), fibonacci(2));
    try std.testing.expectEqual(@as(u32, 2), fibonacci(3));
    try std.testing.expectEqual(@as(u32, 3), fibonacci(4));
    try std.testing.expectEqual(@as(u32, 5), fibonacci(5));
    try std.testing.expectEqual(@as(u32, 8), fibonacci(6));
    try std.testing.expectEqual(@as(u32, 13), fibonacci(7));
}

test "fibonacci 递推关系" {
    // fib(n) = fib(n-1) + fib(n-2)
    var n: u32 = 2;
    while (n <= 30) : (n += 1) {
        const fn_val = fibonacci(n);
        const fn1 = fibonacci(n - 1);
        const fn2 = fibonacci(n - 2);
        try std.testing.expectEqual(fn1 + fn2, fn_val);
    }
}

test "fibonacci 单调递增" {
    // fib(n) 单调递增（n≥1）
    var prev: u32 = fibonacci(1);
    var n: u32 = 2;
    while (n <= 40) : (n += 1) {
        const curr = fibonacci(n);
        try std.testing.expect(curr >= prev);
        prev = curr;
    }
}

test "isPrime 基本判定" {
    try std.testing.expect(!isPrime(0));
    try std.testing.expect(!isPrime(1));
    try std.testing.expect(isPrime(2));
    try std.testing.expect(isPrime(3));
    try std.testing.expect(!isPrime(4));
    try std.testing.expect(isPrime(5));
    try std.testing.expect(!isPrime(6));
    try std.testing.expect(isPrime(7));
    try std.testing.expect(!isPrime(8));
    try std.testing.expect(!isPrime(9));
    try std.testing.expect(!isPrime(10));
}

test "isPrime 边界值" {
    try std.testing.expect(!isPrime(0));
    try std.testing.expect(!isPrime(1));
    try std.testing.expect(isPrime(2)); // 最小素数
    try std.testing.expect(isPrime(3)); // 最小奇素数
}

test "isPrime 偶数判定" {
    // 所有偶数（>2）都不是素数
    var n: u32 = 4;
    while (n <= 100) : (n += 2) {
        try std.testing.expect(!isPrime(n));
    }
}

test "isPrime 大数判定" {
    // 已知大素数
    try std.testing.expect(isPrime(97));
    try std.testing.expect(isPrime(101));
    try std.testing.expect(isPrime(997));
    try std.testing.expect(isPrime(1009));
    // 已知大合数
    try std.testing.expect(!isPrime(100));
    try std.testing.expect(!isPrime(1001)); // 7*11*13
    try std.testing.expect(!isPrime(999)); // 3*3*3*37
}

test "isPrime 平方数判定" {
    // 平方数不是素数
    try std.testing.expect(!isPrime(4)); // 2^2
    try std.testing.expect(!isPrime(9)); // 3^2
    try std.testing.expect(!isPrime(16)); // 4^2
    try std.testing.expect(!isPrime(25)); // 5^2
    try std.testing.expect(!isPrime(36)); // 6^2
    try std.testing.expect(!isPrime(49)); // 7^2
    try std.testing.expect(!isPrime(64)); // 8^2
    try std.testing.expect(!isPrime(81)); // 9^2
    try std.testing.expect(!isPrime(100)); // 10^2
}
