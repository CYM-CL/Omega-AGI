// Ω-落尘AGI 训练计划专用测试入口 v7.0
//
// 导入训练计划模块及其直接依赖，
// 同时导入新架构：TrainingSession、MetaLearner
// 避免项目中其他模块的预存编译错误干扰。

const _training_plan = @import("training_plan.zig");
const _trainer_types = @import("trainer_types.zig");
const _training_session = @import("training_session.zig");
const _meta_learner = @import("meta_learner.zig");
const _frozen_zone = @import("frozen_zone.zig");
const _endogenous_dataset = @import("endogenous_dataset.zig");
const _dust_graph = @import("dust_graph.zig");
const _cognitive_simulator = @import("cognitive_simulator.zig");
// Phase 1-5 演化引擎模块
const _pareto_front = @import("pareto_front.zig");
const _evolution_history = @import("evolution_history.zig");
const _attribute_pool = @import("attribute_pool.zig");
const _persistence_estimator = @import("persistence_estimator.zig");
const _saturation_detector = @import("saturation_detector.zig");
const _targeted_evolution = @import("targeted_evolution.zig");
const _transition_predictor = @import("transition_predictor.zig");
const _layer_transition = @import("layer_transition.zig");
const _evolution_debugger = @import("evolution_debugger.zig");
const _experiment_platform = @import("experiment_platform.zig");
const _evolution_graph = @import("evolution_graph.zig");
const _pattern_miner = @import("pattern_miner.zig");
const _meta_evolution = @import("meta_evolution.zig");
const _theory_generator = @import("theory_generator.zig");
const _iar_probe = @import("iar_probe.zig");
const _viz_dashboard = @import("viz_dashboard.zig");
const _internal_consistency = @import("internal_consistency.zig");

pub fn main() void {
    // 直接运行各个模块的测试函数
    // 已注册的测试模块会在 `zig test` 时自动运行
}

comptime {
    _ = _training_plan;
    _ = _trainer_types;
    _ = _training_session;
    _ = _meta_learner;
    _ = _frozen_zone;
    _ = _endogenous_dataset;
    _ = _dust_graph;
    _ = _cognitive_simulator;
    _ = _pareto_front;
    _ = _evolution_history;
    _ = _attribute_pool;
    _ = _persistence_estimator;
    _ = _saturation_detector;
    _ = _targeted_evolution;
    _ = _transition_predictor;
    _ = _layer_transition;
    _ = _evolution_debugger;
    _ = _experiment_platform;
    _ = _evolution_graph;
    _ = _pattern_miner;
    _ = _meta_evolution;
    _ = _theory_generator;
    _ = _iar_probe;
    _ = _viz_dashboard;
    _ = _internal_consistency;
}
