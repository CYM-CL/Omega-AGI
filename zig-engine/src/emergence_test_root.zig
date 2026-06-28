// Ω-落尘AGI 涌现性验证测试根模块
//
// 用途：
//   作为 `zig build test-emergence` 的根模块，导入所有涌现性验证模块
//   并触发其内置 test 块。
//
// 设计依据：
//   - 白皮书 8.3 + 任务 T4-2/3/4/5：4 个涌现性验证模块
//   - 解决 Zig 0.16 模块系统约束：
//     src/emergence/*.zig 中的 @import("delta_engine.zig") 解析到 src/ 目录
//     因为根模块的根目录是 src/。
//   - 避免在 src/emergence/*.zig 中使用 ../ 相对路径（Zig 0.16 禁止）。
//
// 注意事项：
//   - 本文件是 build.zig 中 emergence_test_module 的 root_source_file
//   - 使用 comptime { _ = mod; } 抑制未使用警告
//   - 各子模块内的 test "..." 块会被 zig test 编译器自动发现并执行

// 8.3.1 零样本新领域（T4-2）
const _zero_shot_validation = @import("emergence/zero_shot_validation.zig");
// 8.3.2 消融实验（T4-3）
const _ablation_validation = @import("emergence/ablation_validation.zig");
// 8.3.3 数学结构涌现（T4-4）
const _math_structure_emergence = @import("emergence/math_structure_emergence.zig");
// 8.3.4 开放式演化（T4-5）
const _open_ended_evolution = @import("emergence/open_ended_evolution.zig");

comptime {
    _ = _zero_shot_validation;
    _ = _ablation_validation;
    _ = _math_structure_emergence;
    _ = _open_ended_evolution;
}

// 触发所有 test 块执行（通过空 test 块 import 各模块）
test {
    // 零样本新领域 3 个子领域
    _ = _zero_shot_validation;
    // 消融实验 3 个步骤
    _ = _ablation_validation;
    // 数学结构涌现 4 个子实验
    _ = _math_structure_emergence;
    // 开放式演化
    _ = _open_ended_evolution;
}

