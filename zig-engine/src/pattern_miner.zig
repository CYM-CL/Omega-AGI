// Ω-落尘AGI 模式挖掘 v1.0 — doc10 事件序列+周期+关联规则
const std = @import("std");

pub const EventRecord = struct {
    step: u64, event_type: u8, value: f64, description: []const u8,
};

pub const SequencePattern = struct {
    event_types: []u8, frequency: f64, support: usize, confidence: f64,
};

pub const PeriodicPattern = struct {
    event_type: u8, period: u64, std_dev: f64, confidence: f64, occurrences: usize,
};

pub const AssociationRule = struct {
    antecedent: u8, consequent: u8, support: f64, confidence: f64, lift: f64,
};


 pub const TransitionPrecursor = struct {
     metric_name: []const u8,
     direction: enum { rising, falling, stable },
     change_magnitude: f64,
     lead_time: u64,
     confidence: f64,
 };
 
 /// doc10 §2.3 通用模式结构
 pub const Pattern = struct {
     id: u64,
     description: []const u8,
     support: f64,
     confidence: f64,
     lift: f64,
     discovered_at_step: u64,
     active: bool,
 };
 
 /// doc10 §2.3 模式库：管理和查询已发现的模式
 pub const PatternLibrary = struct {
     allocator: std.mem.Allocator,
     patterns: std.ArrayList(Pattern),
     next_id: u64,
 
     pub fn init(allocator: std.mem.Allocator) PatternLibrary {
         return .{ .allocator = allocator, .patterns = std.ArrayList(Pattern).empty, .next_id = 1 };
     }
 
     pub fn deinit(self: *PatternLibrary) void {
         self.patterns.deinit(self.allocator);
     }
 
     pub fn addPattern(self: *PatternLibrary, description: []const u8, support: f64, confidence: f64, lift: f64, step: u64) u64 {
         const id = self.next_id; self.next_id += 1;
         self.patterns.append(self.allocator, .{
             .id = id, .description = description, .support = support,
             .confidence = confidence, .lift = lift, .discovered_at_step = step,
             .active = true,
         }) catch return 0;
         return id;
     }
 
     pub fn querySimilar(self: *const PatternLibrary, target: Pattern) !std.ArrayList(Pattern) {
         var results = std.ArrayList(Pattern).empty;
         for (self.patterns.items) |p| {
             if (!p.active) continue;
             if (@abs(p.confidence - target.confidence) < 0.2 and @abs(p.lift - target.lift) < 0.5) {
                 try results.append(self.allocator, p);
             }
         }
         return results;
     }
 
     pub fn getHighestConfidence(self: *const PatternLibrary, min_support: f64) ?Pattern {
         var best: ?Pattern = null;
         for (self.patterns.items) |p| {
             if (p.support < min_support) continue;
             if (best == null or p.confidence > best.?.confidence) best = p;
         }
         return best;
     }
 
     pub fn deactivateLowConfidence(self: *PatternLibrary, threshold: f64) void {
         for (self.patterns.items) |*p| { if (p.confidence < threshold) p.active = false; }
     }
 };
 
 /// doc10 §2.1 跃迁前兆挖掘：分析跃迁前各指标的变化趋势

pub const PatternMiner = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(EventRecord),
    sequences: std.ArrayList(SequencePattern),
    periods: std.ArrayList(PeriodicPattern),
    rules: std.ArrayList(AssociationRule),

    pub fn init(allocator: std.mem.Allocator) PatternMiner {
        return .{ .allocator = allocator, .events = std.ArrayList(EventRecord).empty,
            .sequences = std.ArrayList(SequencePattern).empty,
            .periods = std.ArrayList(PeriodicPattern).empty,
            .rules = std.ArrayList(AssociationRule).empty };
    }

    pub fn deinit(self: *PatternMiner) void {
        self.events.deinit(self.allocator);
        self.sequences.deinit(self.allocator);
        self.periods.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }

    pub fn recordEvent(self: *PatternMiner, step: u64, event_type: u8, value: f64, description: []const u8) void {
        self.events.append(self.allocator, .{ .step = step, .event_type = event_type,
            .value = value, .description = description }) catch {};
    }

    pub fn mineSequences(self: *PatternMiner, min_support: usize) void {
        self.sequences.clearRetainingCapacity();
        var counts: [256]usize = .{0} ** 256;
        for (self.events.items) |e| counts[e.event_type] += 1;
        for (0..256) |et| {
            if (counts[et] >= min_support) {
                const seq = std.heap.page_allocator.alloc(u8, 1) catch continue;
                seq[0] = @intCast(et);
                self.sequences.append(self.allocator, .{
                    .event_types = seq, .frequency = @as(f64, @floatFromInt(counts[et])) /
                        @as(f64, @floatFromInt(@max(1, self.events.items.len))),
                    .support = counts[et], .confidence = 1.0,
                }) catch {};
            }
        }
    }

    pub fn detectPeriodicity(self: *PatternMiner, event_type: u8) ?PeriodicPattern {
        var steps = std.ArrayList(u64).empty;
        defer steps.deinit(self.allocator);
        for (self.events.items) |e| {
            if (e.event_type == event_type) steps.append(self.allocator, e.step) catch {};
        }
        if (steps.items.len < 3) return null;
        var intervals = std.ArrayList(u64).empty;
        defer intervals.deinit(self.allocator);
        for (1..steps.items.len) |i|
            intervals.append(self.allocator, steps.items[i] - steps.items[i - 1]) catch {};
        var sum_int: u64 = 0;
        for (intervals.items) |iv| sum_int += iv;
        const avg = sum_int / @as(u64, @intCast(intervals.items.len));
        var var_int: f64 = 0;
        for (intervals.items) |iv| {
            const d = @as(f64, @floatFromInt(iv)) - @as(f64, @floatFromInt(avg));
            var_int += d * d;
        }
        const std_dev = @sqrt(var_int / @as(f64, @floatFromInt(intervals.items.len)));
        const cv = std_dev / @max(@as(f64, @floatFromInt(avg)), 1.0);
        return .{ .event_type = event_type, .period = avg, .std_dev = std_dev,
            .confidence = @max(0, 1.0 - cv), .occurrences = steps.items.len };
    }

    pub fn mineAssociationRules(self: *PatternMiner, min_confidence: f64) void {
        self.rules.clearRetainingCapacity();
        for (0..self.events.items.len) |i| {
            for (i + 1..self.events.items.len) |j| {
                const a = self.events.items[i].event_type;
                const b = self.events.items[j].event_type;
                if (a == b) continue;
                const pair_count = countPair(self.events.items, a, b);
                const total = self.events.items.len;
                const support = @as(f64, @floatFromInt(pair_count)) / @as(f64, @floatFromInt(total));
                if (support < 0.01) continue;
                const a_count = countEvent(self.events.items, a);
                const conf = @as(f64, @floatFromInt(pair_count)) / @as(f64, @floatFromInt(a_count));
                if (conf < min_confidence) continue;
                const b_freq = @as(f64, @floatFromInt(countEvent(self.events.items, b))) / @as(f64, @floatFromInt(total));
                self.rules.append(self.allocator, .{
                    .antecedent = a, .consequent = b, .support = support,
                    .confidence = conf, .lift = conf / @max(b_freq, 0.001),
                }) catch {};
            }
        }
    }

    // ------------------------------------------------------------------------
    // 深化版：更长序列模式挖掘（类 PrefixSpan 简化版）
    // ------------------------------------------------------------------------

    /// 挖掘长度为 2 的序列模式（深化版）
    /// 实现策略：
    ///   1. 找出所有频繁 1-项集
    ///   2. 对每个频繁 1-项集，找出紧随其后的事件
    ///   3. 统计频繁 2-项序列
    ///   4. 计算置信度和支持度
    pub fn mineLength2Sequences(self: *PatternMiner, min_support: usize) void {
        if (self.events.items.len < 2) return;

        // 1. 统计所有 2-长度序列的出现次数
        var seq_counts = std.AutoHashMap(u16, usize).init(self.allocator);
        defer seq_counts.deinit();

        for (1..self.events.items.len) |i| {
            const a = self.events.items[i - 1].event_type;
            const b = self.events.items[i].event_type;
            const key: u16 = (@as(u16, a) << 8) | @as(u16, b);
            const entry = seq_counts.getOrPut(key) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }

        // 2. 过滤频繁序列并添加到结果
        var iter = seq_counts.iterator();
        while (iter.next()) |entry| {
            const count = entry.value_ptr.*;
            if (count < min_support) continue;

            const key = entry.key_ptr.*;
            const a: u8 = @intCast((key >> 8) & 0xFF);
            const b: u8 = @intCast(key & 0xFF);

            const seq = std.heap.page_allocator.alloc(u8, 2) catch continue;
            seq[0] = a;
            seq[1] = b;

            const total = self.events.items.len;
            const a_count = countEvent(self.events.items, a);
            const support: f64 = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(@max(1, total - 1)));
            const confidence: f64 = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(@max(1, a_count)));

            self.sequences.append(self.allocator, .{
                .event_types = seq,
                .frequency = support,
                .support = count,
                .confidence = confidence,
            }) catch {};
        }
    }

    // ------------------------------------------------------------------------
    // 深化版：跃迁前兆模式挖掘
    // ------------------------------------------------------------------------

    /// 挖掘事件类型前兆模式（深化版）
    /// 实现策略：
    ///   1. 找出所有跃迁事件的位置
    ///   2. 对每个跃迁事件，往前看 N 步
    ///   3. 统计跃迁前频繁出现的事件类型
    ///   4. 计算前兆的置信度和提前时间
    pub fn mineEventTypePrecursors(
        self: *PatternMiner,
        transition_event_type: u8,
        window_size: u64,
    ) std.ArrayList(TransitionPrecursor) {
        var precursors = std.ArrayList(TransitionPrecursor).empty;

        // 1. 找出所有跃迁事件的位置
        var transition_steps = std.ArrayList(u64).empty;
        defer transition_steps.deinit(self.allocator);

        for (self.events.items) |e| {
            if (e.event_type == transition_event_type) {
                transition_steps.append(self.allocator, e.step) catch {};
            }
        }

        if (transition_steps.items.len == 0) return precursors;

        // 2. 统计跃迁前窗口内的事件类型
        var event_before_count: [256]usize = .{0} ** 256;
        var event_lead_time_sum: [256]u64 = .{0} ** 256;

        for (transition_steps.items) |trans_step| {
            // 往前看 window_size 步
            for (self.events.items) |e| {
                if (e.step >= trans_step) break;
                if (trans_step - e.step <= window_size) {
                    event_before_count[e.event_type] += 1;
                    event_lead_time_sum[e.event_type] += trans_step - e.step;
                }
            }
        }

        // 3. 计算每个事件类型作为前兆的置信度
        const total_transitions = transition_steps.items.len;
        for (0..256) |et| {
            const count = event_before_count[et];
            if (count == 0) continue;
            if (et == transition_event_type) continue; // 排除自身

            const support: f64 = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total_transitions));
            const avg_lead_time: u64 = if (count > 0) event_lead_time_sum[et] / count else 0;

            // 置信度 = 该事件出现在跃迁前的比例
            const confidence = support;

            precursors.append(self.allocator, .{
                .metric_name = "event_type",
                .direction = .stable,
                .change_magnitude = @as(f64, @floatFromInt(count)),
                .lead_time = avg_lead_time,
                .confidence = confidence,
            }) catch {};
        }

        return precursors;
    }

    fn countEvent(events: []const EventRecord, event_type: u8) usize {
        var c: usize = 0;
        for (events) |e| { if (e.event_type == event_type) c += 1; }
        return c;
    }

 /// doc10 §2.1 跃迁前兆：跃迁发生前各指标的变化趋势
 pub fn mineTransitionPrecursors(events: []const EventRecord, transition_steps: []const u64, window: u64) std.ArrayList(TransitionPrecursor) {
     var results = std.ArrayList(TransitionPrecursor).init(std.heap.page_allocator);
     for (transition_steps) |ts| {
         if (ts < window) continue;
         const window_start = ts - window;
         var before_events: f64 = 0; var mid_events: f64 = 0;
         var before_val: f64 = 0; var mid_val: f64 = 0;
         for (events) |e| {
             if (e.step >= window_start and e.step < ts - window / 2) {
                 before_events += 1; before_val += e.value;
             } else if (e.step >= ts - window / 2 and e.step < ts) {
                 mid_events += 1; mid_val += e.value;
             }
         }
         if (before_events > 0 and mid_events > 0) {
             const avg_before = before_val / before_events;
             const avg_mid = mid_val / mid_events;
             const change = avg_mid - avg_before;
             const magnitude = if (@abs(avg_before) > 1e-9) @abs(change / avg_before) else 0.0;
             if (magnitude > 0.05) {
                 results.append(.{
                     .metric_name = "aggregate",
                     .direction = if (change > 0) .rising else .falling,
                     .change_magnitude = magnitude,
                     .lead_time = window / 2,
                     .confidence = @min(1.0, magnitude * 5.0),
                 }) catch {};
             }
         }
     }
     return results;
 }
 
/// doc10 §2.1 PrefixSpan 简化版：挖掘多事件序列模式
/// PrefixSpan简化版: 挖掘多事件序列模式
pub fn mineMultiEventSequences(allocator: std.mem.Allocator, events: []const EventRecord, min_support: usize) std.ArrayList(SequencePattern) {
    var results = std.ArrayList(SequencePattern).empty;
     if (events.len < 2) return results;
    var seq_counts = std.AutoHashMap(u64, usize).init(allocator);
     defer seq_counts.deinit();
     for (0..events.len - 1) |i| {
         const key = (@as(u64, events[i].event_type) << 8) | events[i + 1].event_type;
         const entry = seq_counts.getOrPut(key) catch continue;
         if (entry.found_existing) entry.value_ptr.* += 1 else entry.value_ptr.* = 1;
     }
     var iter = seq_counts.iterator();
     while (iter.next()) |entry| {
         if (entry.value_ptr.* >= min_support) {
             const a = @as(u8, @intCast(entry.key_ptr.* >> 8));
             const b = @as(u8, @intCast(entry.key_ptr.* & 0xFF));
             const seq = allocator.alloc(u8, 2) catch continue;
             seq[0] = a; seq[1] = b;
             results.append(allocator, .{
                 .event_types = seq,
                 .frequency = @as(f64, @floatFromInt(entry.value_ptr.*)) / @as(f64, @floatFromInt(events.len)),
                 .support = entry.value_ptr.*,
                 .confidence = @as(f64, @floatFromInt(entry.value_ptr.*)) / @as(f64, @floatFromInt(@max(1, countEvent(events, a)))),
             }) catch {};
         }
     }
     return results;
 }
 
 /// 修复 countPair：现在统计事件 a 之后紧接着出现事件 b 的次数（时间顺序）
 fn countPair(events: []const EventRecord, a: u8, b: u8) usize {
     var c: usize = 0;
     for (0..events.len - 1) |i| {
         if (events[i].event_type == a and events[i + 1].event_type == b) c += 1;
     }
     return c;
 }
};

test "PatternMiner 初始化" {
    var pm = PatternMiner.init(std.testing.allocator);
    defer pm.deinit();
    try std.testing.expectEqual(@as(usize, 0), pm.events.items.len);
}

test "PatternMiner 事件记录" {
    var pm = PatternMiner.init(std.testing.allocator);
    defer pm.deinit();
    pm.recordEvent(0, 1, 0.5, "Pareto改进");
    pm.recordEvent(100, 2, 0.8, "饱和检测");
    try std.testing.expectEqual(@as(usize, 2), pm.events.items.len);
}

test "PatternMiner 周期检测" {
    var pm = PatternMiner.init(std.testing.allocator);
    defer pm.deinit();
    for (0..10) |i| pm.recordEvent(@as(u64, i) * 100, 1, 0.5, "周期事件");
    const result = pm.detectPeriodicity(1);
    try std.testing.expect(result != null);
    if (result) |r| try std.testing.expect(r.period == 100);
}

test "PatternLibrary 添加与查询" {
    var lib = PatternLibrary.init(std.testing.allocator);
    defer lib.deinit();
    const id1 = lib.addPattern("高模块化→高持久度", 0.15, 0.85, 2.1, 1000);
    const id2 = lib.addPattern("低不平衡→低持久度", 0.12, 0.78, 1.8, 1200);
    try std.testing.expect(id1 > 0 and id2 > 0);
    try std.testing.expectEqual(@as(usize, 2), lib.patterns.items.len);
}

test "PatternLibrary 最高置信度" {
    var lib = PatternLibrary.init(std.testing.allocator);
    defer lib.deinit();
    _ = lib.addPattern("低置信模式", 0.05, 0.3, 1.0, 500);
    _ = lib.addPattern("高置信模式", 0.15, 0.92, 2.5, 1000);
    const best = lib.getHighestConfidence(0.1);
    try std.testing.expect(best != null);
    try std.testing.expect(best.?.confidence > 0.9);
}

test "PatternLibrary 低置信模式去激活" {
    var lib = PatternLibrary.init(std.testing.allocator);
    defer lib.deinit();
    _ = lib.addPattern("可靠模式", 0.2, 0.85, 2.0, 500);
    _ = lib.addPattern("不可靠模式", 0.1, 0.35, 0.8, 600);
    lib.deactivateLowConfidence(0.5);
    try std.testing.expect(lib.patterns.items[0].active);
}

test "mineMultiEventSequences 多事件序列" {
    var events = std.ArrayList(EventRecord).empty;
    defer events.deinit(std.testing.allocator);
    events.append(std.testing.allocator, .{ .step = 0, .event_type = 1, .value = 0.5, .description = "改进" }) catch {};
    events.append(std.testing.allocator, .{ .step = 50, .event_type = 2, .value = 0.6, .description = "饱和" }) catch {};
    events.append(std.testing.allocator, .{ .step = 100, .event_type = 1, .value = 0.7, .description = "改进" }) catch {};
    events.append(std.testing.allocator, .{ .step = 150, .event_type = 2, .value = 0.8, .description = "饱和" }) catch {};
    events.append(std.testing.allocator, .{ .step = 200, .event_type = 3, .value = 0.9, .description = "跃迁" }) catch {};
    var result = PatternMiner.mineMultiEventSequences(std.testing.allocator, events.items, 1);
    defer {
        for (result.items) |*s| std.testing.allocator.free(s.event_types);
        result.deinit(std.testing.allocator);
    }
    try std.testing.expect(result.items.len >= 1);
}
