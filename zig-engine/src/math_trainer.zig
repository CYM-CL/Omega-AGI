// Ω-落尘AGI 数学训练引擎 v1.0
// 生成数学探索任务（无外部expected值）+ Δ不变量一致性评估

const std = @import("std");
const tt = @import("trainer_types.zig");
const dc = @import("delta_consistency.zig");

pub const MathSubject = enum { arithmetic, algebra, calculus, logic, geometry };

pub const SubjectProgress = struct {
    subject: MathSubject,
    score: f64,
    tasks_issued: u64,
};

pub const MathReport = struct {
    subjects: [5]SubjectProgress,
    overall: f64,
};

pub fn initialize() MathReport {
    var subs: [5]SubjectProgress = undefined;
    inline for (std.meta.fields(MathSubject), 0..) |_, i| {
        subs[i] = .{.subject=@as(MathSubject, @enumFromInt(i)),.score=0.0,.tasks_issued=0};
    }
    return .{.subjects=subs,.overall=0.0};
}

pub fn generateTask(step: u64, _: *anyopaque) !?tt.TrainingTask {
    const subject_idx = step % 5;
    var prng = std.Random.DefaultPrng.init(step + 12345);
    const r = prng.random();
    return switch (@as(MathSubject, @enumFromInt(subject_idx))) {
        .arithmetic => tt.TrainingTask{
            .param1 = r.intRangeAtMost(u64, 1, 20),
            .param2 = r.intRangeAtMost(u64, 1, 20),
            .complexity = .Level_1,
        },
        .algebra => tt.TrainingTask{
            .param1 = r.intRangeAtMost(u64, 10, 100),
            .param2 = r.intRangeAtMost(u64, 10, 100),
            .complexity = .Level_2,
        },
        .calculus => tt.TrainingTask{
            .param1 = r.intRangeAtMost(u64, 1, 5),
            .param2 = r.intRangeAtMost(u64, 1, 100),
            .complexity = .Level_2,
        },
        .logic => tt.TrainingTask{
            .param1 = r.intRangeAtMost(u64, 0, 1),
            .param2 = r.intRangeAtMost(u64, 0, 1),
            .complexity = .Level_1,
        },
        .geometry => tt.TrainingTask{
            .param1 = r.intRangeAtMost(u64, 1, 30),
            .param2 = r.intRangeAtMost(u64, 1, 30),
            .complexity = .Level_3,
        },
    };
}

pub fn evaluate(_: *anyopaque) MathReport {
    const r = dc.evaluateDeltaConsistency();
    var subs: [5]SubjectProgress = undefined;
    for (&r.invariants, 0..) |inv, i| {
        if (i < 5) {
            subs[i] = .{
                .subject = @as(MathSubject, @enumFromInt(i % 5)),
                .score = inv.rate,
                .tasks_issued = 1,
            };
        }
    }
    return .{.subjects=subs,.overall=r.overall_score};
}
