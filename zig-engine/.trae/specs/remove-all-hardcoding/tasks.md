# Tasks（v3 全量审查版）

- [ ] Task 1: 去除 trainer.zig M3硬编码阈值和运行时配置（B1）
  - 第96-103行：M3_PARALLEL_WORKERS=4, M3_SIMD_LANES_F64=2 → 从0内生检测
  - 6个M3上限阈值（500K/1M/3M/1.5M/3M/8M）→ 由实际系统负载内生决定
  - 第308行：verifyConvergence(fp, 1.0, 1.0) → 移除1.0 fallback
  - 第1408行：+ 1000.0 → 由knowledge_size分布内生决定
  - 第1755行：.top_k = 3 → 由记忆召回历史内生决定
  - 第1757行：.min_strength = 0.3 → 由强度分布内生决定（从0开始）
  - 第2914行：@min(..., 0.1) else 0.01 → 由自由能水平内生决定
  - 验证编译通过

- [ ] Task 2: 去除 trainer.zig 硬编码调度周期（B2）
  - 第1242-1247行：long_run阈值、heavy/light/bootstrap_interval → 由事件计数内生决定
  - 第1329行：i % 500 → 持续自主学习由事件计数触发
  - 第1488行：% 10000 保存检查点 → 由自由能变化触发
  - 第1493行：% 1000 监控更新 → 由事件计数器触发
  - 第1499行：% 1000 宇宙注册 → 由新对象计数触发
  - 第1536行：% 100000 持久化 → 由累积事件触发
  - 第1642行：% 1000 记忆重组 → 由记忆数量变化触发
  - 第1667行：% 1000 元认知评估 → 由元认知事件触发
  - 第1709行：% 10000 创造性思维 → 由生成数量触发
  - 第1749行：% 1000 主动回忆 → 由训练步数事件触发
  - 第1771行：% 10000 课程同步 → 由课程事件触发
  - 第1807行：% 10000 一致性验证 → 由修改事件触发
  - 第1842行：% 10000 冻结区更新 → 由稳定度变化触发
  - 第1880行：% 1000 漂移检测 → 由漂移事件触发
  - 第1896行：i % 100 CPU散热 → 由持续时间/温度触发
  - 第2271行：% 1000 锚点验证 → 由锚点事件触发
  - 第2580行：/ 1000 规则检测 → 由匹配计数触发
  - 第1811行：cap_idx <= 14 → 由能力数量内生决定
  - 验证编译通过

- [ ] Task 3: 去除 trainer.zig 硬编码 sleep 等待（B3）
  - 第375行：nsec = 100*1000*1000（100ms）→ 由重试次数/负载内生决定
  - 第1897行：sec=1, nsec=500_000_000（1.5s）→ 由持续运行时间/温度内生决定
  - 验证编译通过

- [ ] Task 4: 去除 main.zig 残留硬编码（B4）
  - 第501行：@max(1, ...) → 移除硬编码下限1
  - 第561行：@max(1000, ... * 10) → 由系统容量内生决定
  - 第594行：@max(1, ... / 100000) → 由恢复统计内生决定
  - 第601行：nsec = 1_000_000（1ms sleep）→ 由系统负载内生决定
  - 第678行：@max(1, ...) → 移除硬编码下限1
  - 验证编译通过

- [x] Task 5: 去除 training_session.zig 残留硬下限（B5）
  - 第519行：@max(1, ...) → 移除硬编码下限1
  - 第576行：if (new_bs < 1) new_bs = 1 → 移除硬编码下限1
  - 第666行：if (l1.step_count < 1) l1.step_count = 1 → 移除硬编码下限1
  - 验证编译和测试通过

- [ ] Task 6: 去除 creativity.zig 预设非零默认值（B6）
  - 第128行：max_depth: u32 = 1 → 改为 0（从0内生增长）
  - 第129行：max_candidates: u32 = 2 → 改为 0（从0内生增长）
  - 验证编译和测试通过

- [ ] Task 7: 去除 l3_verification.zig 预设非零默认值（B7）
  - 第22行：max_depth: u32 = 100 → 改为 0（从0内生增长）
  - 第23行：constant_c: f64 = 1.0 → 改为 0.0（从0内生学习）
  - 第24行：tolerance: f64 = 1e-10 → 改为 0.0（从0内生学习，通过 convergence_history 调整）
  - 第818-819行（测试）：sample_size=600, domain_count=6 → 改为从0开始的相对断言
  - 验证编译和测试通过

- [ ] Task 8: 去除 audit.zig 预设非零间隔和采样（B8）
  - 第555行：l3_full_check_interval = 10000 → 改为 0（由事件计数内生决定）
  - 第556行：l3_full_check_sample_size = 27000 → 改为 0（由对象数内生决定）
  - 验证编译通过

- [ ] Task 9: 去除 long_term_memory.zig 残留硬编码（B9）
  - 第465行：0.001 * (...) → 由访问频率内生决定（从0开始）
  - 第467-468行：< 0.0 / > 1.0 夹逼 → 移除上限夹逼，保留 >= 0 约束
  - 测试中 top_k = 1/2/10 → 由召回历史内生决定或从1开始
  - 验证编译和测试通过

- [ ] Task 10: 去除 meta_learner.zig 残留硬编码（B10）
  - 第412行：@max(0.05, @min(0.95, ...)) → 移除夹逼，由统计内生决定
  - 第415行：oscillation < 0.05 → 由震荡历史标准差内生决定
  - 第460行：oscillation > 0.08 → 由震荡历史标准差内生决定
  - 第465行：oscillation * 10.0 → 由震荡幅度内生决定
  - 验证编译和测试通过

- [x] Task 11: 去除 macro_bootstrap.zig 硬编码阈值和系数（B11）
  - 第415行：bottleneck_score > 0.7 → 由瓶颈度分布内生决定
  - 第420行：redundancy_score > 0.5 → 由冗余度分布内生决定
  - 第423行：priority = 0.8 → 由结构压缩收益内生决定
  - 第424行：redundancy_score * 0.3 → 由压缩历史内生决定
  - 验证编译和测试通过

- [x] Task 12: 去除 curriculum_learner.zig 硬编码边界（B12）
  - 第201行：@as(u64, 3) → 由调整历史内生决定
  - 第204行：@min(... , 10) → 由能力范围内生决定
  - 验证编译和测试通过

- [x] Task 13: 全面旧代码注释清理（B13）
  - 删除所有"已移除"标记的注释行（~40处）
  - 清理后文件：trainer.zig（20+处）、main.zig（4处）、delta_engine.zig（3处）、
    reasoning_manifold.zig（3处）、macro_bootstrap.zig（4处）、
    cdl_expr.zig（1处）、continuous_learner.zig（1处）、training_session.zig（1处）
  - 删除 trainer.zig 第205-209行移除函数说明注释块（非功能代码）
  - 删除 trainer.zig 第3046行保留字段兼容注释
  - 删除 main.zig 第410-415行参数解析重构注释
  - 验证编译通过

- [ ] Task 14: 全面编译和测试验证（v3任务）
  - 运行 `zig build` 确保无编译错误
  - 运行 `zig build test` 确保全部测试通过
  - 运行 `zig build run` 确保主程序可正常启动

- [ ] Task 15: 去除 trainer.zig 间隔基线和除数硬编码 — B14（20处，v4新增）
  - 第1170-1172行：heavy_interval/light_interval/bootstrap_interval中的硬编码1000/100/100000基线和100/1000除数
  - 第1419行：checkpoint_step中的10000/100
  - 第1426行：monitor_step中的1000/50
  - 第1464行：grothendieck_step中的1000/50
  - 第1489行：persist_step中的100/100
  - 第1514行：creativity_step中的500/50
  - 第1534行：recombine_step中的500/50
  - 第1549行：meta_eval_step中的200/50
  - 第1561行：rule_step中的100/50
  - 第1580行：recall_step中的500/50
  - 第1605行：drift_step中的1000/50
  - 第1630行：consistency_step中的1000/50
  - 第1659行：curriculum_step中的200/50
  - 第1661行：frozen_step中的10000/100
  - 第1697行：persist_step(LTM)中的500/50
  - 第1718行：recall_step中的1000/50
  - 第1732行：fz_update_interval中的1000/50
  - 第2231行：anchor_step中的1000/50
  - 全部替换为由事件计数/对象数/自由能水平内生决定的间断表达式
  - 验证编译通过

- [ ] Task 16: 去除 trainer.zig 残留模运算调度 — B15（7处，v4新增）
  - 第1256行：scheduler_epoch % 500 → 由持续学习事件计数驱动
  - 第1570行：scheduler_epoch % 5000 → 由诊断事件计数驱动
  - 第1758行：scheduler_epoch % 10000 → 由一致性缓存事件驱动
  - 第1795行：scheduler_epoch % 10000 → 由冻结区事件驱动
  - 第1847行：scheduler_epoch % 100 → 由运行时间/温度内生决定
  - 第1504行：scheduler_epoch % 10 → 由创造力事件计数驱动
  - 第1173-1176行：i % heavy_interval / i % bootstrap_interval → 由循环内事件计数器驱动
  - 验证编译通过

- [ ] Task 17: 去除 trainer.zig 自由能更新率硬编码 — B16（1处，v4新增）
  - 第2883行：@min(1.0 / (1.0 + current_f), 0.1) else 0.01 → 0.1和0.01由自由能历史分布内生决定
  - 验证编译通过

- [ ] Task 18: 去除 trainer.zig sleep参数硬编码 — B17（1处，v4新增）
  - 第1848行：* 10_000_000.0 + 50_000_000.0 → 由系统连续运行时长和对象数内生决定
  - 验证编译通过

- [ ] Task 19: 去除 frozen_zone.zig 测试中硬编码模运算 — B18（2处，v4新增）
  - 第660行：step % 1000 == 999 → 由事件计数驱动
  - 第667行：step % 10000 == 9999 → 由事件计数驱动
  - 验证编译和测试通过

- [ ] Task 20: 去除 l3_verification.zig 学习目标和边界硬编码 — B19（12处，v4新增）
  - 第77行：0.5 + convergence_rate * 0.5 → 目标C由收敛历史分布内生决定
  - 第80-81行：< 0 → 0 和 > 2.0 → 2.0 钳位 → 移除钳位，由学习过程自然收敛
  - 第86行：1e-10 目标容差 → 由收敛历史内生决定
  - 第90行：1e-8 目标容差 → 由收敛历史内生决定
  - 第93-94行：< 0 → 0 和 > 1e-6 → 1e-6 钳位 → 移除钳位
  - 第284行：注释中 70%/90%/100% → 更新注释或删除
  - 第623-630行：同上重复项
  - 第635行：+ 0.01 和 0.99 → 由历史阈值分布内生决定
  - 第639行：* 0.2 → 由阈值衰减历史内生决定
  - 第641-642行：< 0 → 0 和 > 1.0 → 1.0 钳位 → 移除钳位
  - 验证编译和测试通过

- [ ] Task 21: 更新 creativity.zig 测试断言 — B20（6处，v4新增）
  - 第436行：== 4 → == 0（max_depth默认值已改为0）
  - 第437行：== 0.1 → == 0.0（novelty_threshold默认值已改为0）
  - 第442行：== 4 → == 0
  - 第443行：== 64 → == 0
  - 第444行：== 0.1 → == 0.0
  - 第385-387行：+1/ >1/ else 1 → 由实用性统计内生决定
  - 验证编译和测试通过

- [ ] Task 22: 更新 meta_cognition.zig 测试断言 — B21（3处，v4新增）
  - 第446行：mc.max_depth == 100 → == 0
  - 第447行：mc.constant_c == 1.0 → == 0.0
  - 第448行：mc.tolerance == 1e-10 → == 0.0
  - 验证编译和测试通过

- [ ] Task 23: 去除 curriculum_learner.zig 初始成功率 — B22（2处，v4新增）
  - 第37行：up_success_rate = 0.5 → 0.0（由调整历史内生决定）
  - 第38行：down_success_rate = 0.5 → 0.0
  - 验证编译和测试通过

- [ ] Task 24: 去除 dust_graph.zig 测试中硬编码权重 — B23（12处，v4新增）
  - 第1776-1777行、1787行：0.5/0.8 权重 → 由传导历史内生决定或以变量表示
  - 第1800-1806行：0.8/0.6/0.9/0.3 → 同上
  - 第1914-1915行：0.4/0.6 → 同上
  - 验证编译和测试通过

- [ ] Task 25: 去除 training_session.zig 测试中硬编码调整常数 — B24（2处，v4新增）
  - 第896行：accelerate_step_reduction = 0.10 → 移除，由学习过程内生决定
  - 第897行：consolidate_step_increase = 0.50 → 移除
  - 验证编译和测试通过

- [ ] Task 26: 清理残留旧代码注释 — B25（16处，v4新增）
  - trainer.zig：第307/650/876/2176/2601/2837/3173/3637/3758/3768行
  - delta_engine.zig：第1092行
  - macro_bootstrap.zig：第40/543行
  - endogenous_dataset.zig：第222/530行
  - audit.zig：第266行
  - 验证编译通过

- [ ] Task 27: 全面编译和测试验证（v4阶段）
  - 运行 `zig build` 确保无编译错误
  - 运行 `zig build test` 确保全部测试通过
  - 运行 `zig build run` 确保主程序可正常启动

## Task Dependencies
- Task 2（trainer调度周期18处）为最复杂任务，侵入性最高
- Task 1（M3阈值+运行时配置）与 Task 3（sleep等待）可并行
- Task 4（main.zig）与 Task 5（training_session.zig）可并行
- Task 6（creativity.zig）、Task 7（l3_verification.zig）、Task 8（audit.zig）均为 struct 默认值修改，可并行
- Task 9-12 为独立模块修改，可并行
- Task 13（注释清理）相对独立，可在 Task 1-12 完成前提前执行
- Task 14（全面验证）依赖所有前置任务完成
- **v4 新增任务依赖：**
  - Task 15（间隔基线/除数）依赖 Task 2（基础调度周期替换）
  - Task 16（残留模运算）依赖 Task 15
  - Task 17（自由能更新率）独立
  - Task 18（sleep参数）依赖 Task 3
  - Task 19（frozen_zone测试）独立
  - Task 20（l3_verification学习边界）依赖 Task 7
  - Task 21（creativity测试断言）依赖 Task 6
  - Task 22（meta_cognition测试断言）独立
  - Task 23（curriculum_learner初始值）独立
  - Task 24（dust_graph测试权重）独立
  - Task 25（training_session测试常数）依赖 Task 5
  - Task 26（注释清理）独立
  - Task 27（全面验证）依赖所有前置任务完成

## 高优先级
- Task 2（trainer调度周期）— 18处修改，核心架构变更
- Task 1（M3阈值/运行时配置）— 与硬件相关的6处硬编码
- Task 7（l3_verification struct默认值）— 预设非零违反核心原则
- Task 13（注释清理）— 体量大但简单，可快速完成
- **v4新增：**
- Task 15（间隔基线/除数）— 20处，量最大
- Task 20（l3_verification学习边界）— 学习算法中硬编码目标值
- Task 21（creativity测试断言）— 当前测试会失败，需优先修复