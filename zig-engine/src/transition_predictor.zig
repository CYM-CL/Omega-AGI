// Ω-落尘AGI 跃迁预测MVP —— doc5逻辑回归预测器
const std = @import("std");

pub const TransitionFeatures = struct {
    norm_front: f64,
    norm_stability: f64,
    norm_persistence: f64,
    norm_attempt: f64,
};

pub const TransitionPredictorMVP = struct {
    w_front: f64,
    w_stability: f64,
    w_persistence: f64,
    w_attempt: f64,
    bias: f64,
    learning_rate: f64,
    history: [10]struct { predicted: f64, actual: bool },
    history_idx: usize,

    pub fn init() TransitionPredictorMVP {
        var result: TransitionPredictorMVP = undefined;
        result.w_front = 0.3;
        result.w_stability = 0.4;
        result.w_persistence = 0.2;
        result.w_attempt = -0.1;
        result.bias = -0.5;
        result.learning_rate = 0.1;
        for (&result.history) |*h| {
            h.* = .{ .predicted = 0.5, .actual = false };
        }
        result.history_idx = 0;
        return result;
    }

    pub fn predict(self: *const TransitionPredictorMVP, features: TransitionFeatures) f64 {
        const z = self.w_front * features.norm_front +
                  self.w_stability * features.norm_stability +
                  self.w_persistence * features.norm_persistence +
                  self.w_attempt * features.norm_attempt +
                  self.bias;
        return 1.0 / (1.0 + @exp(-z));
    }

    pub fn update(self: *TransitionPredictorMVP, features: TransitionFeatures,
                  actual_success: bool) void {
        const predicted = self.predict(features);
        const actual: f64 = if (actual_success) 1.0 else 0.0;
        const err_val = actual - predicted;
        self.w_front += self.learning_rate * err_val * features.norm_front;
        self.w_stability += self.learning_rate * err_val * features.norm_stability;
        self.w_persistence += self.learning_rate * err_val * features.norm_persistence;
        self.w_attempt += self.learning_rate * err_val * features.norm_attempt;
        self.bias += self.learning_rate * err_val;
        self.history[self.history_idx] = .{ .predicted = predicted, .actual = actual_success };
        self.history_idx = (self.history_idx + 1) % 10;
    }

    pub fn accuracy(self: *const TransitionPredictorMVP) f64 {
        var correct: f64 = 0;
        for (&self.history) |h| {
            const predicted_bool = h.predicted >= 0.5;
            if (predicted_bool == h.actual) correct += 1;
        }
        return correct / 10.0;
    }
};

test "跃迁预测器初始化" {
    const tp = TransitionPredictorMVP.init();
    try std.testing.expectEqual(@as(f64, 0.3), tp.w_front);
}

test "跃迁预测器预测" {
    var tp = TransitionPredictorMVP.init();
    const prob = tp.predict(.{ .norm_front = 0.8, .norm_stability = 0.9,
        .norm_persistence = 0.7, .norm_attempt = 0.2 });
    try std.testing.expect(prob > 0.5); // 好参数应预测成功
}

test "跃迁预测器在线学习" {
    var tp = TransitionPredictorMVP.init();
    const features = TransitionFeatures{ .norm_front = 0.5, .norm_stability = 0.5,
        .norm_persistence = 0.5, .norm_attempt = 0.5 };
    for (0..5) |_| { tp.update(features, true); }
    const prob_after = tp.predict(features);
    try std.testing.expect(prob_after > 0.5);
}
