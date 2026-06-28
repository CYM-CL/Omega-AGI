# Checklist（v3 全量审查版）

## B1. trainer.zig — 硬编码运行时配置
- [ ] M3_PARALLEL_WORKERS=4 已改为内生检测（第96行）
- [ ] M3_SIMD_LANES_F64=2 已移除（第97行）
- [ ] M3_LONGRUN_SOFT_OBJECTS=500000 已移除（第98行）
- [ ] M3_LONGRUN_SOFT_MORPHISMS=1000000 已移除（第99行）
- [ ] M3_LONGRUN_SOFT_MORPHISMS2=3000000 已移除（第100行）
- [ ] M3_LONGRUN_HARD_OBJECTS=1500000 已移除（第101行）
- [ ] M3_LONGRUN_HARD_MORPHISMS=3000000 已移除（第102行）
- [ ] M3_LONGRUN_HARD_MORPHISMS2=8000000 已移除（第103行）
- [ ] verifyConvergence 1.0 fallback 已移除（第308行）
- [ ] knowledge_gap + 1000.0 已移除（第1408行）
- [ ] recall .top_k = 3 已移除（第1755行）
- [ ] recall .min_strength = 0.3 已移除（第1757行）
- [ ] @min(..., 0.1) else 0.01 已移除（第2914行）
- [ ] `zig build` 编译通过

## B2. trainer.zig — 硬编码调度周期
- [ ] long_run = num_steps >= 1000 已移除（第1242行）
- [ ] heavy_interval = 1000/10 已移除（第1243行）
- [ ] light_interval = 100/5 已移除（第1244行）
- [ ] bootstrap_interval = 100000 已移除（第1245行）
- [ ] i % 500 持续学习已替换为事件触发（第1329行）
- [ ] % 10000 检查点保存已替换（第1488行）
- [ ] % 1000 L3监控更新已替换（第1493行）
- [ ] % 1000 Grothendieck注册已替换（第1499行）
- [ ] % 100000 长期持久化已替换（第1536行）
- [ ] % 1000 记忆重组已替换（第1642行）
- [ ] % 1000 元认知评估已替换（第1667行）
- [ ] % 10000 创造性思维已替换（第1709行）
- [ ] % 1000 主动回忆已替换（第1749行）
- [ ] % 10000 课程同步已替换（第1771行）
- [ ] % 10000 一致性验证已替换（第1807行）
- [ ] % 10000 冻结区更新已替换（第1842行）
- [ ] % 1000 漂移检测已替换（第1880行）
- [ ] i % 100 CPU散热已替换（第1896行）
- [ ] % 1000 锚点验证已替换（第2271行）
- [ ] / 1000 规则检测已替换（第2580行）
- [ ] cap_idx <= 14 已移除（第1811行）
- [ ] `zig build` 编译通过

## B3. trainer.zig — 硬编码 sleep
- [ ] 重试等待 100ms 已替换（第375行）
- [ ] CPU散热 sleep 1.5s 已替换（第1897行）
- [ ] `zig build` 编译通过

## B4. main.zig — 残留硬编码
- [ ] @max(1, ...) 检查间隔下限已移除（第501行）
- [ ] @max(1000, ...*10) BATCH_SIZE 已移除（第561行）
- [ ] @max(1, .../100000) 故障计数已移除（第594行）
- [ ] nsec=1_000_000 1ms sleep 已替换（第601行）
- [ ] @max(1, ...) 告警阈值已移除（第678行）
- [ ] `zig build` 编译通过

## B5. training_session.zig — 残留硬下限
- [ ] @max(1, ...) range_start 下限已移除（第519行）
- [ ] if (new_bs < 1) 下限已移除（第576行）
- [ ] if (l1.step_count < 1) 下限已移除（第666行）
- [ ] `zig build test` 通过

## B6. creativity.zig — 预设非零默认值
- [ ] max_depth: u32 = 1 已改为 0（第128行）
- [ ] max_candidates: u32 = 2 已改为 0（第129行）
- [ ] `zig build test` 通过

## B7. l3_verification.zig — 预设非零默认值+测试
- [ ] max_depth: u32 = 100 已改为 0（第22行）
- [ ] constant_c: f64 = 1.0 已改为 0.0（第23行）
- [ ] tolerance: f64 = 1e-10 已改为 0.0（第24行）
- [ ] 测试中 sample_size=600 已改为相对断言（第818行）
- [ ] 测试中 domain_count=6 已移除（第819行）
- [ ] `zig build test` 通过

## B8. audit.zig — 预设非零间隔和采样
- [ ] l3_full_check_interval = 10000 已改为 0（第555行）
- [ ] l3_full_check_sample_size = 27000 已改为 0（第556行）
- [ ] `zig build` 编译通过

## B9. long_term_memory.zig — 残留硬编码
- [ ] target_lambda = 0.001*(...) 已移除（第465行）
- [ ] < 0.0 / > 1.0 夹逼已移除（第467-468行）
- [ ] 测试中 top_k=1/2/10 已改为内生值或相对断言
- [ ] `zig build test` 通过

## B10. meta_learner.zig — 残留硬编码
- [ ] @max(0.05, @min(0.95, ...)) 夹逼已移除（第412行）
- [ ] oscillation < 0.05 阈值已移除（第415行）
- [ ] oscillation > 0.08 阈值已移除（第460行）
- [ ] oscillation * 10.0 系数已移除（第465行）
- [ ] `zig build test` 通过

## B11. macro_bootstrap.zig — 硬编码阈值和系数
- [ ] bottleneck_score > 0.7 阈值已移除（第415行）
- [ ] redundancy_score > 0.5 阈值已移除（第420行）
- [ ] priority = 0.8 已移除（第423行）
- [ ] redundancy_score * 0.3 已移除（第424行）
- [ ] `zig build test` 通过

## B12. curriculum_learner.zig — 硬编码边界
- [ ] @as(u64, 3) difficulty_bonus 上限已移除（第201行）
- [ ] @min(... , 10) 最大难度已移除（第204行）
- [ ] `zig build test` 通过

## B13. 旧代码注释清理
- [ ] trainer.zig 中 20+ 处"已移除"注释已清理
- [ ] main.zig 中 4 处"已移除"注释已清理
- [ ] delta_engine.zig 中 3 处"已移除"注释已清理
- [ ] reasoning_manifold.zig 中 3 处"已移除"注释已清理
- [ ] macro_bootstrap.zig 中 4 处"已移除"注释已清理
- [ ] cdl_expr.zig 中 1 处"已移除"注释已清理
- [ ] continuous_learner.zig 中 1 处"已移除"注释已清理
- [ ] training_session.zig 中 1 处"已移除"注释已清理
- [ ] trainer.zig 第205-209行函数说明注释块已清理
- [ ] main.zig 第410-415行重构注释已清理
- [ ] `zig build` 编译通过

## 最终验证
- [ ] `zig build` 编译零错误
- [ ] `zig build test` 全部测试通过
- [ ] `zig build run` 主程序可正常启动

## B14. trainer.zig — 间隔基线和除数硬编码（v4新增）
- [ ] heavy_interval 中 1000/100 已替换（第1170行）
- [ ] light_interval 中 100/100 已替换（第1171行）
- [ ] bootstrap_interval 中 100000/1000 已替换（第1172行）
- [ ] checkpoint_step 中 10000/100 已替换（第1419行）
- [ ] monitor_step 中 1000/50 已替换（第1426行）
- [ ] grothendieck_step 中 1000/50 已替换（第1464行）
- [ ] persist_step(CCC) 中 100/100 已替换（第1489行）
- [ ] creativity_step 中 500/50 已替换（第1514行）
- [ ] recombine_step 中 500/50 已替换（第1534行）
- [ ] meta_eval_step 中 200/50 已替换（第1549行）
- [ ] rule_step 中 100/50 已替换（第1561行）
- [ ] recall_step(traj) 中 500/50 已替换（第1580行）
- [ ] drift_step 中 1000/50 已替换（第1605行）
- [ ] consistency_step 中 1000/50 已替换（第1630行）
- [ ] curriculum_step 中 200/50 已替换（第1659行）
- [ ] frozen_step 中 10000/100 已替换（第1661行）
- [ ] persist_step(LTM) 中 500/50 已替换（第1697行）
- [ ] recall_step 中 1000/50 已替换（第1718行）
- [ ] fz_update_interval 中 1000/50 已替换（第1732行）
- [ ] anchor_step 中 1000/50 已替换（第2231行）
- [ ] `zig build` 编译通过

## B15. trainer.zig — 残留模运算调度（v4新增）
- [ ] scheduler_epoch % 500 已替换为事件驱动（第1256行）
- [ ] scheduler_epoch % 5000 已替换（第1570行）
- [ ] scheduler_epoch % 10000 一致性缓存已替换（第1758行）
- [ ] scheduler_epoch % 10000 冻结区输出已替换（第1795行）
- [ ] scheduler_epoch % 100 CPU散热已替换（第1847行）
- [ ] scheduler_epoch % 10 种子计算已替换（第1504行）
- [ ] i % heavy_interval / i % bootstrap_interval 已替换（第1173-1176行）
- [ ] `zig build` 编译通过

## B16. trainer.zig — 自由能更新率硬编码（v4新增）
- [ ] 0.1/0.01 硬编码已替换为内生计算（第2883行）
- [ ] `zig build` 编译通过

## B17. trainer.zig — sleep参数硬编码（v4新增）
- [ ] 10M/50M ns 硬编码已替换（第1848行）
- [ ] `zig build` 编译通过

## B18. frozen_zone.zig — 测试模运算（v4新增）
- [ ] step % 1000 == 999 已替换（第660行）
- [ ] step % 10000 == 9999 已替换（第667行）
- [ ] `zig build test` 通过

## B19. l3_verification.zig — 学习目标和边界（v4新增）
- [ ] 0.5 + convergence_rate * 0.5 已替换（第77行）
- [ ] learned_constant_c 钳位边界已移除（第80-81行）
- [ ] 1e-10 目标容差已替换（第86行）
- [ ] 1e-8 目标容差已替换（第90行）
- [ ] learned_tolerance 钳位边界已移除（第93-94行）
- [ ] 70%/90%/100% 注释已更新/删除（第284行）
- [ ] 第二处容差目标/边界重复项已替换（第623-630行）
- [ ] +0.01/0.99 阈值增量已替换（第635行）
- [ ] *0.2 衰减系数已替换（第639行）
- [ ] consistency_threshold 钳位已移除（第641-642行）
- [ ] `zig build test` 通过

## B20. creativity.zig — 测试断言更新（v4新增）
- [ ] max_depth == 4 → == 0（第436行）
- [ ] novelty_threshold == 0.1 → == 0.0（第437行）
- [ ] config.max_depth == 4 → == 0（第442行）
- [ ] config.max_candidates == 64 → == 0（第443行）
- [ ] config.novelty_threshold == 0.1 → == 0.0（第444行）
- [ ] learned_max_depth +1/>1/else 1 已替换（第385-387行）
- [ ] `zig build test` 通过

## B21. meta_cognition.zig — 测试断言更新（v4新增）
- [ ] mc.max_depth == 100 → == 0（第446行）
- [ ] mc.constant_c == 1.0 → == 0.0（第447行）
- [ ] mc.tolerance == 1e-10 → == 0.0（第448行）
- [ ] `zig build test` 通过

## B22. curriculum_learner.zig — 初始成功率（v4新增）
- [ ] up_success_rate = 0.5 → 0.0（第37行）
- [ ] down_success_rate = 0.5 → 0.0（第38行）
- [ ] `zig build test` 通过

## B23. dust_graph.zig — 测试权重（v4新增）
- [ ] 0.5/0.8 2-态射权重已替换（第1776-1777行）
- [ ] 0.8 复合断言已替换（第1787行）
- [ ] 0.8/0.6/0.9 1-态射权重已替换（第1800-1802行）
- [ ] 0.3/0.9 2-态射权重已替换（第1805-1806行）
- [ ] 0.9 横向复合断言已替换（第1814行）
- [ ] 0.4/0.6 复合测试权重已替换（第1914-1915行）
- [ ] 0.6 复合上界断言已替换（第1919/1923行）
- [ ] `zig build test` 通过

## B24. training_session.zig — 测试调整常数（v4新增）
- [ ] accelerate_step_reduction = 0.10 已移除（第896行）
- [ ] consolidate_step_increase = 0.50 已移除（第897行）
- [ ] `zig build test` 通过

## B25. 残留旧代码注释（v4新增）
- [ ] trainer.zig 10处注释已清理（第307/650/876/2176/2601/2837/3173/3637/3758/3768行）
- [ ] delta_engine.zig 第1092行注释已清理
- [ ] macro_bootstrap.zig 2处注释已清理（第40/543行）
- [ ] endogenous_dataset.zig 2处注释已清理（第222/530行）
- [ ] audit.zig 第266行注释已清理
- [ ] `zig build` 编译通过