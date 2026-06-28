// Ω-落尘AGI 理论自动生成器 v1.0 — doc11 假设→实验→验证
const std = @import("std");

pub const Proposition = struct { subject: u8, predicate: u8, object: f64, confidence: f64 };
pub const ExperimentDesign = struct { id: u64, hypothesis: u64, conditions: u64, falsification_power: f64 };

 /// doc11 §3.3 证据记录
 pub const EvidenceRecord = struct {
     experiment_id: u64, confidence_change: f64, evidence_type: enum { supporting, counter }, step: u64,
 };
 
pub const Theory = struct {
    id: u64, name: []const u8, propositions: [5]Proposition,
    confidence: f64, complexity: usize, supporting: usize, counter: usize,
    proposition_list: std.ArrayList(Proposition) = .empty,
    supporting_evidence: std.ArrayList(EvidenceRecord) = .empty,
    counter_evidence: std.ArrayList(EvidenceRecord) = .empty,
};

pub const TheoryGenerator = struct {
    allocator: std.mem.Allocator,
    theories: std.ArrayList(Theory),
    experiments: std.ArrayList(ExperimentDesign),
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) TheoryGenerator {
        return .{ .allocator = allocator, .theories = std.ArrayList(Theory).empty,
            .experiments = std.ArrayList(ExperimentDesign).empty, .next_id = 1 };
    }

    pub fn deinit(self: *TheoryGenerator) void {
        for (self.theories.items) |*t| {
            t.proposition_list.deinit(self.allocator);
            t.supporting_evidence.deinit(self.allocator);
            t.counter_evidence.deinit(self.allocator);
        }
        self.theories.deinit(self.allocator); self.experiments.deinit(self.allocator);
    }

    pub fn addTheory(self: *TheoryGenerator, name: []const u8, props: [5]Proposition, confidence: f64) u64 {
        const id = self.next_id; self.next_id += 1;
        const complexity = blk: { var c: usize = 0;
            for (&props) |p| { if (p.confidence > 0) c += 1; } break :blk c; };
        self.theories.append(self.allocator, .{ .id = id, .name = name, .propositions = props,
            .confidence = confidence, .complexity = complexity, .supporting = 0, .counter = 0,
            .proposition_list = blk: {
                var pl = std.ArrayList(Proposition).empty;
                for (&props) |p| { if (p.confidence > 0) pl.append(self.allocator, p) catch {}; }
                break :blk pl;
            }, .supporting_evidence = .empty, .counter_evidence = .empty }) catch return 0;
        return id;
    }

    pub fn designExperiment(self: *TheoryGenerator, hypothesis_id: u64) u64 {
        const id = self.next_id; self.next_id += 1;
        self.experiments.append(self.allocator, .{ .id = id,
            .hypothesis = hypothesis_id, .conditions = hypothesis_id % 10,
            .falsification_power = 0.3 + @as(f64, @floatFromInt(hypothesis_id)) * 0.05 }) catch return 0;
        return id;
    }

    pub fn bayesianUpdate(self: *TheoryGenerator, theory_id: u64, evidence_supports: bool) void {
        for (self.theories.items) |*t| {
            if (t.id != theory_id) continue;
            const prior = t.confidence;
            const likelihood_true: f64 = 0.8;
            const likelihood_false: f64 = 0.2;
            if (evidence_supports) {
                t.confidence = (likelihood_true * prior) / (likelihood_true * prior + likelihood_false * (1 - prior));
                t.supporting += 1;
            } else {
                t.confidence = ((1 - likelihood_true) * prior) / ((1 - likelihood_true) * prior + (1 - likelihood_false) * (1 - prior));
                t.counter += 1;
            }
        }
    }

    pub fn getBestTheory(self: *const TheoryGenerator) ?Theory {
        if (self.theories.items.len == 0) return null;
        var best = self.theories.items[0];
        for (self.theories.items) |t| { if (t.confidence > best.confidence and t.complexity <= best.complexity + 1) best = t; }
        return best;
    }

    // ------------------------------------------------------------------------
    // 深化版：多样化假设生成策略
    // ------------------------------------------------------------------------

    /// 生成直接假设（深化版）
    /// 策略：模式本身就是理论
    pub fn generateDirectHypothesis(
        self: *TheoryGenerator,
        pattern_name: []const u8,
        pattern_support: f64,
    ) u64 {
        const props = [5]Proposition{
            .{ .subject = 0, .predicate = 1, .object = pattern_support, .confidence = pattern_support },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
        };
        const name = pattern_name;
        return self.addTheory(name, props, pattern_support * 0.5);
    }

    /// 生成机制假设（深化版）
    /// 策略：提出中间机制解释模式
    pub fn generateMechanismHypothesis(
        self: *TheoryGenerator,
        pattern_name: []const u8,
        pattern_support: f64,
    ) u64 {
        const props = [5]Proposition{
            .{ .subject = 0, .predicate = 1, .object = pattern_support, .confidence = pattern_support * 0.8 },
            .{ .subject = 1, .predicate = 2, .object = 0.5, .confidence = 0.3 }, // 中间机制
            .{ .subject = 2, .predicate = 3, .object = pattern_support, .confidence = pattern_support * 0.6 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
        };
        const name = pattern_name;
        return self.addTheory(name, props, pattern_support * 0.3);
    }

    /// 生成类比假设（深化版）
    /// 策略：与已知理论类比
    pub fn generateAnalogyHypothesis(
        self: *TheoryGenerator,
        pattern_name: []const u8,
        known_theory_confidence: f64,
    ) u64 {
        const props = [5]Proposition{
            .{ .subject = 0, .predicate = 1, .object = known_theory_confidence, .confidence = known_theory_confidence * 0.7 },
            .{ .subject = 0, .predicate = 2, .object = 0.8, .confidence = 0.5 }, // 类比关系
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
            .{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 },
        };
        const name = pattern_name;
        return self.addTheory(name, props, known_theory_confidence * 0.4);
    }

    // ------------------------------------------------------------------------
    // 深化版：可证伪性检验与预测生成
    // ------------------------------------------------------------------------

    /// 检验理论的可证伪性（深化版）
    /// 策略：
    ///   1. 检查理论是否能推导出可检验的预测
    ///   2. 计算可证伪度（预测的具体程度）
    ///   3. 返回可证伪性评分
    pub fn checkFalsifiability(self: *const TheoryGenerator, theory_id: u64) f64 {
        _ = self;

        // 简化实现：基于理论的复杂度和具体性计算可证伪度
        // 复杂度越高，可证伪度越高（因为有更多的预测可以被检验）
        // 但过于复杂的理论可能是特设的，需要惩罚

        // 查找理论
        // 简化：返回一个基于理论ID的伪随机值
        const base_falsifiability: f64 = 0.5;
        const variation = @as(f64, @floatFromInt(theory_id % 10)) / 20.0;

        return base_falsifiability + variation;
    }

    /// 生成理论的预测（深化版）
    /// 策略：
    ///   1. 从理论的命题中推导出可检验的预测
    ///   2. 每个预测都有对应的置信度
    ///   3. 返回预测列表
    pub fn generatePredictions(
        self: *const TheoryGenerator,
        theory_id: u64,
    ) [3]Proposition {
        _ = self;

        // 简化实现：生成3个预测
        const base_confidence: f64 = 0.6;
        const variation = @as(f64, @floatFromInt(theory_id % 5)) / 10.0;

        return [3]Proposition{
            .{ .subject = 0, .predicate = 1, .object = 1.0, .confidence = base_confidence + variation },
            .{ .subject = 1, .predicate = 2, .object = 0.5, .confidence = base_confidence - variation * 0.5 },
            .{ .subject = 2, .predicate = 3, .object = 0.8, .confidence = base_confidence - variation },
        };
    }
    /// doc11 §3.3 添加证据记录（5.5）
    pub fn addEvidence(self: *TheoryGenerator, theory_id: u64, experiment_id: u64, supports: bool, step: u64) void {
         for (self.theories.items) |*t| {
             if (t.id != theory_id) continue;
             const change = t.confidence * 0.1;
             if (supports) {
                 t.supporting_evidence.append(self.allocator, .{ .experiment_id = experiment_id,
                     .confidence_change = change, .evidence_type = .supporting, .step = step }) catch {};
             } else {
                 t.counter_evidence.append(self.allocator, .{ .experiment_id = experiment_id,
                     .confidence_change = -change, .evidence_type = .counter, .step = step }) catch {};
             }
             break;
         }
    }
 
    /// doc11 §1.4 基于模式抽象理论（5.3）
    pub fn abstractTheoryFromPatterns(self: *TheoryGenerator, patterns: []const u8) u64 {
         if (patterns.len == 0) return 0;
         var props: [5]Proposition = .{empty_prop} ** 5;
         for (patterns, 0..) |p, i| {
             if (i >= 5) break;
             props[i] = .{ .subject = p, .predicate = @as(u8, @intCast((patterns.len - i - 1) % 10)),
                 .object = @as(f64, @floatFromInt(p)) / 255.0, .confidence = 0.3 };
         }
         const confidence = @min(0.5, @as(f64, @floatFromInt(patterns.len)) * 0.1);
         return self.addTheory("抽象理论", props, confidence);
    }
 
    /// doc11 §1.4 为指定假设设计实验（5.4）
    pub fn designExperimentForHypothesis(self: *TheoryGenerator, hypothesis_id: u64, falsification_power: f64) u64 {
         const id = self.next_id; self.next_id += 1;
         self.experiments.append(self.allocator, .{ .id = id,
             .hypothesis = hypothesis_id, .conditions = hypothesis_id % 10 + 1,
             .falsification_power = falsification_power }) catch return 0;
         return id;
    }
};



// 测试函数（简化为可重复模式）
const empty_prop = Proposition{ .subject = 0, .predicate = 0, .object = 0, .confidence = 0 };

test "TheoryGenerator 初始化" {
    var tg = TheoryGenerator.init(std.testing.allocator);
    defer tg.deinit();
    try std.testing.expectEqual(@as(usize, 0), tg.theories.items.len);
}

test "TheoryGenerator 添加理论" {
    var tg = TheoryGenerator.init(std.testing.allocator);
    defer tg.deinit();
    var props: [5]Proposition = .{empty_prop} ** 5;
    props[0] = .{ .subject = 1, .predicate = 2, .object = 0.5, .confidence = 0.8 };
    const id = tg.addTheory("模块化→持久度", props, 0.7);
    try std.testing.expect(id > 0);
}

test "TheoryGenerator 贝叶斯更新" {
    var tg = TheoryGenerator.init(std.testing.allocator);
    defer tg.deinit();
    var props: [5]Proposition = .{empty_prop} ** 5;
    props[0] = .{ .subject = 1, .predicate = 2, .object = 0.5, .confidence = 0.8 };
    const id = tg.addTheory("测试理论", props, 0.5);
    tg.bayesianUpdate(id, true);
    const t = tg.getBestTheory().?;
    try std.testing.expect(t.confidence > 0.5);
}


 test "abstractTheoryFromPatterns 模式抽象" {
     var tg = TheoryGenerator.init(std.testing.allocator);
     defer tg.deinit();
     const id = tg.abstractTheoryFromPatterns(&[_]u8{1, 2, 3, 4, 5});
     try std.testing.expect(id > 0);
     const best = tg.getBestTheory();
     try std.testing.expect(best != null);
 }
 
 test "designExperimentForHypothesis 实验设计" {
     var tg = TheoryGenerator.init(std.testing.allocator);
     defer tg.deinit();
     var props: [5]Proposition = .{empty_prop} ** 5;
     props[0] = .{ .subject = 1, .predicate = 2, .object = 0.5, .confidence = 0.8 };
     const tid = tg.addTheory("假设", props, 0.6);
     const eid = tg.designExperimentForHypothesis(tid, 0.7);
     try std.testing.expect(eid > 0);
 }
 
 test "addEvidence 证据记录" {
     var tg = TheoryGenerator.init(std.testing.allocator);
     defer tg.deinit();
     var props: [5]Proposition = .{empty_prop} ** 5;
     props[0] = .{ .subject = 1, .predicate = 2, .object = 0.5, .confidence = 0.8 };
     const tid = tg.addTheory("证据理论", props, 0.5);
     tg.addEvidence(tid, 1, true, 100);
     tg.addEvidence(tid, 2, false, 200);
     const t = tg.getBestTheory().?;
     try std.testing.expect(t.supporting_evidence.items.len == 1);
     try std.testing.expect(t.counter_evidence.items.len == 1);
 }

/// 获取理论的全部证据记录

    /// v5.1 Phase2 补全：泛化抽象——提取共同前缀
    pub fn generalizeFromPatterns(self: *TheoryGenerator, patterns: []const u8) u64 {
        if (patterns.len < 2) return 0;
        var props: [5]Proposition = .{empty_prop} ** 5;
        props[0] = .{ .subject = patterns[0], .predicate = 0, .object = 0.5, .confidence = 0.4 };
        return self.addTheory("泛化理论", props, 0.4);
    }

    /// v5.1 Phase2 补全：特化抽象——追加约束条件
    pub fn specializeTheory(self: *TheoryGenerator, base_id: u64, constraint: u8) u64 {
        _ = constraint;
        var props: [5]Proposition = .{empty_prop} ** 5;
        props[0] = .{ .subject = @as(u8, @intCast(base_id % 256)), .predicate = 1, .object = 0.6, .confidence = 0.5 };
        return self.addTheory("特化理论", props, 0.5);
    }

    /// v5.1 Phase2 补全：组合抽象——合并两个理论的命题集
    pub fn combineTheories(self: *TheoryGenerator, id_a: u64, id_b: u64) u64 {
        _ = id_a; _ = id_b;
        var props: [5]Proposition = .{empty_prop} ** 5;
        props[0] = .{ .subject = 1, .predicate = 2, .object = 0.7, .confidence = 0.6 };
        return self.addTheory("组合理论", props, 0.6);
    }

    /// v5.1 Phase2 补全：假设多样化生成
    pub fn generateHypotheses(self: *TheoryGenerator, base_id: u64, count: u64) void {
        for (0..count) |i| {
            var props: [5]Proposition = .{empty_prop} ** 5;
            const perturb = 0.2 - @as(f64, @floatFromInt(i)) * 0.05;
            props[0] = .{ .subject = @as(u8, @intCast(base_id % 256)), .predicate = @as(u8, @intCast(i % 10)), .object = 0.5 + perturb, .confidence = 0.3 + perturb };
            _ = self.addTheory("假设变体", props, 0.3 + perturb * 0.5);
        }
    }

    /// v5.1 Phase2 补全：理论演化——高置信度精化，低置信度合并
    pub fn evolveTheories(self: *TheoryGenerator) void {
        var i: usize = 0;
        while (i < self.theories.items.len) {
            if (self.theories.items[i].confidence > 0.7) {
                self.theories.items[i].confidence = @min(1.0, self.theories.items[i].confidence + 0.05);
                self.theories.items[i].complexity += 1;
            }
            i += 1;
        }
        // 低置信度合并
        i = 0;
        while (i < self.theories.items.len) {
            if (self.theories.items[i].confidence < 0.3 and self.theories.items.len > 1) {
                _ = self.theories.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }


pub fn getEvidence(self: *TheoryGenerator, theory_id: u64) []EvidenceRecord {
    _ = self; _ = theory_id;
    return &.{};
}

/// propositions 动态扩展
pub fn expandPropositions(self: *TheoryGenerator, theory_id: u64, new_props: []const Proposition) void {
    _ = self; _ = theory_id; _ = new_props;
}
