# 全面移除所有硬编码 + 清除旧代码 Spec（v4 全量审查版 + 补充扫描）

## Why

v2 spec 遗漏了大量硬编码参数和旧代码残留。本次**全量深度循环审查**发现了 **50项以上新增/遗漏硬编码**，涵盖 15+ 个模块。所有遗漏项严重违背"零硬编码常数、零全局规则、零独立参数实体"的核心原则。

## 扫描方法

使用 Grep 工具实施系统性扫描：
1. `@max(N, ...)` / `@min(N, ...)` 中 N > 0 的硬编码下限/上限
2. 浮点乘除系数（`* 0.x`, `/ 100`, `/ 1000` 等）
3. 非零预设的 struct 字段默认值（`= 1`, `= 2`, `= 100`, `= 1e-10`, `= 0.001` 等）
4. 模运算周期（`i % N`, `% 1000`, `% 10000` 等）
5. 预设 sleep/等待时长（`nsec = 100_000_000` 等）
6. `//（已移除）` 旧代码注释残留
7. 已删除功能的注释引用
8. 硬编码阈值比较（`> 0.7`, `< 0.05` 等）

## What Changes

### B1. trainer.zig — 硬编码运行时配置（6处新增）
- [新增] 第96-103行：`M3_PARALLEL_WORKERS = 4`, `M3_SIMD_LANES_F64 = 2`, 6个 M3 上限阈值（500K/1M/3M/1.5M/3M/8M）
- [新增] 第308行：`verifyConvergence(fp, 1.0, 1.0)` — hardcoded f_weight/g_weight fallback 1.0
- [新增] 第1242-1247行：`long_run = num_steps >= 1000`, `heavy_interval = 1000/10`, `light_interval = 100/5`, `bootstrap_interval = 100000`
- [新增] 第1755/1757行：`.top_k = 3`, `.min_strength = 0.3` — 主动回忆硬编码参数
- [新增] 第2914行：`@min(..., 0.1) else 0.01` — 元自由能更新率硬编码上限和fallback
- [新增] 第1408行：`+ 1000.0` — knowledge_gap 计算中硬编码除数

### B2. trainer.zig — 硬编码周期调度（15处新增）
所有 `l3_total_steps % N` 和 `i % N` 调度周期：
- 第1243-1245行：hardcoded heavy_interval/light_interval/bootstrap_interval
- 第1329行：`i % 500` — 持续自主学习步
- 第1488行：`% 10000` — 保存检查点
- 第1493行：`% 1000` — 更新L3监控
- 第1499行：`% 1000` — Grothendieck宇宙注册
- 第1536行：`% 100000` — 长期持久化
- 第1642行：`% 1000` — 记忆重组
- 第1667行：`% 1000` — 元认知自我评估
- 第1709行：`% 10000` — 创造性思维
- 第1749行：`% 1000` — 主动回忆
- 第1771行：`% 10000` — 课程器同步
- 第1807行：`% 10000` — 一致性验证
- 第1842行：`% 10000` — 冻结区更新
- 第1880行：`% 1000` — 漂移检测
- 第1896行：`i % 100` — CPU散热节流
- 第2271行：`% 1000` — 锚点验证
- 第2580行：`/ 1000` — 规则检测频率
- 第1811行：`cap_idx <= 14` — 冻结区能力遍历上限

### B3. trainer.zig — 硬编码 sleep 等待（2处新增）
- [新增] 第375行：`nsec = 100 * 1000 * 1000` — 重试等待100ms
- [新增] 第1897行：`sec = 1, nsec = 500_000_000` — CPU散热 sleep 1.5s

### B4. main.zig — 未修复硬编码（4处原有+1处新增）
- [未修复] 第501行：`@max(1, ...)` — 检查间隔下限1
- [未修复] 第561行：`@max(1000, ... * 10)` — BATCH_SIZE 下限1000和乘10
- [未修复] 第594行：`@max(1, ... / 100000)` — 故障计数下限1和除数100000
- [未修复] 第678行：`@max(1, ...)` — 对象数告警下限1
- [新增] 第601行：`nsec = 1_000_000` — 1ms sleep 硬编码

### B5. training_session.zig — 未修复硬下限（3处原有）
- [未修复] 第519行：`@max(1, ...)` — range_start 硬编码下限1
- [未修复] 第576行：`if (new_bs < 1) new_bs = 1` — bootstrap间隔硬编码下限1
- [未修复] 第666行：`if (l1.step_count < 1) l1.step_count = 1` — 步数硬编码下限1

### B6. creativity.zig — 预设非零默认值（2处新增）
- [新增] 第128行：`max_depth: u32 = 1` — 预设非零深度
- [新增] 第129行：`max_candidates: u32 = 2` — 预设非零候选数

### B7. l3_verification.zig — 预设非零默认值+测试（5处新增）
- [新增] 第22行：`max_depth: u32 = 100` — 预设非零深度（文档要求100，需内生决定）
- [新增] 第23行：`constant_c: f64 = 1.0` — 预设非零收敛常数
- [新增] 第24行：`tolerance: f64 = 1e-10` — 预设非零容差
- [新增] 第818-819行（测试）：`sample_size = 600`, `domain_count = 6` — 测试中硬编码

### B8. audit.zig — 预设非零间隔和采样（2处新增）
- [新增] 第555行：`l3_full_check_interval = 10000` — 硬编码校验间隔
- [新增] 第556行：`l3_full_check_sample_size = 27000` — 硬编码采样数

### B9. long_term_memory.zig — 残留硬编码（6处新增）
- [新增] 第465行：`target_lambda = 0.001 * (...)` — 基础衰减率系数 0.001
- [新增] 第467-468行：`< 0.0` / `> 1.0` — 硬编码夹逼
- [新增] 测试中多处 `top_k = 1/2/10` — 测试硬编码参数

### B10. meta_learner.zig — 残留硬编码（4处新增）
- [新增/原A16] 第412行：`@max(0.05, @min(0.95, ...))` — 置信度夹逼 0.05/0.95
- [新增] 第415行：`oscillation < 0.05` — 稳定状态震荡阈值
- [新增] 第460行：`oscillation > 0.08` — 高震荡阈值
- [新增] 第465行：`oscillation * 10.0` — 调整系数

### B11. macro_bootstrap.zig — 硬编码阈值和系数（4处新增）
- [新增] 第415行：`bottleneck_score > 0.7` — 高瓶颈阈值
- [新增] 第420行：`redundancy_score > 0.5` — 高冗余阈值
- [新增] 第423行：`priority = 0.8` — 硬编码优先级
- [新增] 第424行：`redundancy_score * 0.3` — 硬编码系数

### B12. curriculum_learner.zig — 硬编码边界（2处新增）
- [新增] 第201行：`@as(u64, 3)` — difficulty_bonus 硬编码上限3
- [新增] 第204行：`@min(... , 10)` — 最大难度硬编码10

### B13. 旧代码注释清理（Part B补充）
- main.zig 第246行：`// v5.0：recordStudentRule/lookupStudentRule/inferStudentRuleComposed已移除` — 说明性注释可保留但仍可精简
- main.zig 第740-745行：`// v5.0：CDL表达式——getObjectFWeight/getObjectGWeight已移除` + 硬编码 1.0 值
- main.zig 第988行：`// v5.0：证伪假设试验套件（falsification_experiments.zig）已移除`
- trainer.zig 第205-209行：`// v5.0.0：移除 taskTypeToDomain 和 domainToTaskType` 说明注释块
- trainer.zig 第307行：`// 标量权重已移除，使用默认值1.0`
- trainer.zig 第432行：`// v5.0.0：ability_configs已移除`
- trainer.zig 第723行：`// v5.0.0：domain_tracker 已移除`
- trainer.zig 第816行：`// v5.0.0：移除 curriculum.updateSkill`
- trainer.zig 第835行：`// v5.0.0：TaskType已移除`
- trainer.zig 第951行：`// v5.0.0：移除针对性训练反馈`
- trainer.zig 第1052行：`// v5.0.0：移除 curriculum.updateSkill`
- trainer.zig 第1400-1401行：`// computeH10Metric已移除`
- trainer.zig 第1665行：`// getObjectFWeight/getObjectGWeight已移除`
- trainer.zig 第1770行：`// getObjectFWeight/getObjectGWeight已移除`
- trainer.zig 第2224行：`// ability_configs/domain_tracker已移除`
- trainer.zig 第2584行：`// recordStudentRule 已移除`
- trainer.zig 第2641行：`// v4.0.5：标量权重已移除`
- trainer.zig 第2649行：`// 标量权重已移除`
- trainer.zig 第2868行：`// 标量权重已移除，使用默认值0.0`
- trainer.zig 第3046行：`// 已移除（保留字段兼容）`
- trainer.zig 第3318行：`// 标量权重缓存已移除，无需序列化`
- trainer.zig 第3324行：`// 标量权重缓存已移除，无需反序列化`
- trainer.zig 第3791行：`// 标量权重缓存已移除`
- trainer.zig 第3801行：`// 标量权重已移除，使用默认值0.0`
- delta_engine.zig 第765行：`// 替代已移除的标量权重FFI freeEnergy调用`
- delta_engine.zig 第1043-1095行：多处"已移除"注释
- reasoning_manifold.zig 第272行：`// studentRuleCount/provenanceCount已移除`
- reasoning_manifold.zig 第325行：`// studentRuleCount已移除`
- reasoning_manifold.zig 第364行：`// v5.0：provenance已移除`
- macro_bootstrap.zig 第543行：`// 不再合并标量权重（已移除）`
- macro_bootstrap.zig 第550/566/634行：多处"已移除"注释
- cdl_expr.zig 第5行：`// 所有节点固有属性（value/f_weight/g_weight）已移除`
- continuous_learner.zig 第83行：`// student_rules已移除`
- training_session.zig 第20-22行：`// 已移除学生规则、provenance跟踪和教师模式支持`
- main.zig 第410-415行（注释）：`// v4.2.0：参数解析重构` — 记录历史重构但非功能代码

### B14. trainer.zig — 间隔基线和除数硬编码（20处新增，v4扫描新发现）
v3修复引入了 `@max(1, XXX / (1 + obj_count / YY))` 模式，但XXX和YY仍然是硬编码常数：
- 第1170行：`1000 / (1 + object_count / 100)` — 硬编码基线1000和除数100
- 第1171行：`100 / (1 + object_count / 100)` — 硬编码基线100和除数100
- 第1172行：`100000 / (1 + object_count / 1000)` — 硬编码基线100000和除数1000
- 第1419行：`10000 / (1 + obj_count / 100)` — 检查点间隔基线10000
- 第1426行：`1000 / (1 + obj_count / 50)` — 监控间隔基线1000
- 第1464行：`1000 / (1 + obj_count_g / 50)` — 宇宙注册间隔基线1000
- 第1489行：`100 / (1 + obj_count_ccc / 100)` — CCC持久化基线100
- 第1514行：`500 / (1 + obj_count_cr / 50)` — 创造力间隔基线500
- 第1534行：`500 / (1 + obj_count_ent / 50)` — 格熵监控间隔基线500
- 第1549行：`200 / (1 + obj_count_me / 50)` — 元认知评估间隔基线200
- 第1561行：`100 / (1 + obj_count_au / 50)` — 规则检测间隔基线100
- 第1580行：`500 / (1 + obj_count_tr / 50)` — 推理采样间隔基线500
- 第1605行：`1000 / (1 + obj_count_dr / 50)` — 漂移检测间隔基线1000
- 第1630行：`1000 / (1 + obj_count_cv / 50)` — 一致性验证间隔基线1000
- 第1659行：`200 / (1 + obj_count_ml / 50)` — 课程同步间隔基线200
- 第1661行：`10000 / (1 + obj_count_ml / 100)` — 冻结区输出间隔基线10000
- 第1697行：`500 / (1 + obj_count_ltm / 50)` — 长期记忆间隔基线500
- 第1718行：`1000 / (1 + obj_count_rc / 50)` — 主动回忆间隔基线1000
- 第1732行：`1000 / (1 + object_count / 50)` — 冻结区更新间隔基线1000
- 第2231行：`1000 / (1 + obj_count_anc / 50)` — 锚点验证间隔基线1000

### B15. trainer.zig — 残留模运算调度（7处新增）
v3修复改用了scheduler_epoch事件驱动，但仍有硬编码模运算残留：
- 第1256行：`scheduler_epoch % 500 == 0` — 持续学习模500
- 第1570行：`scheduler_epoch % 5000 == 0` — 推理诊断模5000
- 第1758行：`scheduler_epoch % 10000 == 0` — 一致性缓存更新模10000
- 第1795行：`scheduler_epoch % 10000 == 0` — 冻结区状态输出模10000
- 第1847行：`scheduler_epoch % 100 == 0` — CPU散热节流模100
- 第1504行：`scheduler_epoch % 10` — 创造力种子计算模10
- 第1173-1176行：`i % heavy_interval`, `i % bootstrap_interval` — 循环内模运算

### B16. trainer.zig — 自由能更新率硬编码（1处新增）
- 第2883行：`@min(1.0 / (1.0 + current_f), 0.1) else 0.01` — 硬编码上限0.1和fallback 0.01

### B17. trainer.zig — sleep参数硬编码（1处新增）
- 第1848行：`* 10_000_000.0 + 50_000_000.0` — 硬编码10M ns和50M ns sleep常量

### B18. frozen_zone.zig — 测试中硬编码模运算（2处新增）
- 第660行：`step % 1000 == 999` — 测试中硬编码模1000
- 第667行：`step % 10000 == 9999` — 测试中硬编码模10000

### B19. l3_verification.zig — 学习目标和边界硬编码（12处新增）
- 第77行：`0.5 + convergence_rate * 0.5` — 硬编码目标C计算系数0.5/0.5
- 第80-81行：`< 0 → 0`, `> 2.0 → 2.0` — learned_constant_c硬编码钳位边界
- 第86行：`1e-10` — 高收敛率下目标容差硬编码
- 第90行：`1e-8` — 低收敛率下目标容差硬编码
- 第93-94行：`< 0 → 0`, `> 1e-6 → 1e-6` — learned_tolerance硬编码钳位边界
- 第284行：注释中`70%`, `90%`, `100%` — 硬编码达标阈值
- 第623-630行：上述容差目标和边界完全重复（第二处学习器）
- 第635行：`+ 0.01` 和 `0.99` — 达标阈值学习中的硬编码增量/上限
- 第639行：`* 0.2` — 未达标时阈值衰减的硬编码系数
- 第641-642行：`< 0 → 0`, `> 1.0 → 1.0` — consistency_threshold硬编码钳位

### B20. creativity.zig — 测试中旧硬编码断言（6处新增）
默认值已改为0，但测试仍断言旧值：
- 第436行：`c.config.max_depth == 4` — 应改为 == 0
- 第437行：`c.config.novelty_threshold == 0.1` — 应改为 == 0.0
- 第442行：`config.max_depth == 4` — 应改为 == 0
- 第443行：`config.max_candidates == 64` — 应改为 == 0
- 第444行：`config.novelty_threshold == 0.1` — 应改为 == 0.0
- 第385-387行：learned_max_depth调整中硬编码`+1`, `> 1`, `else 1`

### B21. meta_cognition.zig — 测试中旧硬编码断言（3处新增）
- 第446行：`mc.max_depth == 100` — 默认值已改为0，应改为 == 0
- 第447行：`mc.constant_c == 1.0` — 默认值已改为0.0，应改为 == 0.0
- 第448行：`mc.tolerance == 1e-10` — 默认值已改为0.0，应改为 == 0.0

### B22. curriculum_learner.zig — 初始成功率硬编码（2处新增）
- 第37行：`up_success_rate = 0.5` — 初始值0.5，应由调整历史内生决定，初始为0.0
- 第38行：`down_success_rate = 0.5` — 同上

### B23. dust_graph.zig — 测试中硬编码权重（12处新增）
- 第1776-1777行：`0.5`, `0.8` — 2-态射权重硬编码
- 第1787行：`0.8` — 复合权重断言硬编码
- 第1800-1802行：`0.8`, `0.6`, `0.9` — 1-态射权重硬编码
- 第1805-1806行：`0.3`, `0.9` — 2-态射权重硬编码
- 第1814行：`0.9` — 复合权重断言硬编码
- 第1914-1915行：`0.4`, `0.6` — 2-态射复合测试权重
- 第1919,1923行：`0.6` — 复合上界断言硬编码

### B24. training_session.zig — 测试中硬编码调整常数（2处新增）
- 第896行：`accelerate_step_reduction = 0.10` — 测试赋值硬编码
- 第897行：`consolidate_step_increase = 0.50` — 测试赋值硬编码

### B25. 残留旧代码注释（约8处新增，v3清理不彻底）
- delta_engine.zig 第1092行：`// 所有预设运算类型已移除...`
- trainer.zig 第307行：`// 标量权重已移除，使用默认值1.0`
- trainer.zig 第650行：`// v5.0.0：domain_tracker 已移除...`
- trainer.zig 第876行：`// v5.0.0：移除针对性训练反馈...`
- trainer.zig 第2176行：`// v5.0.0：移除能力域调整逻辑...`
- trainer.zig 第2601行：`// v4.0.5：标量权重已移除...`
- trainer.zig 第2837行：`// 标量权重已移除，使用默认值0.0`
- trainer.zig 第3173行：`// 跳过二进制格式中已删除的 capability records...`
- trainer.zig 第3637行：`// 使用统一Δ运算替代已删除的deltaAdd/deltaMultiply等`
- trainer.zig 第3758行：`/// 标量权重缓存已移除，使用默认值0.0。`
- trainer.zig 第3768行：`// 标量权重已移除，使用默认值0.0`
- macro_bootstrap.zig 第40行：`// Zig 0.16.0: now() 已移除...`
- macro_bootstrap.zig 第543行：`// v5.0：CDL表达式系统——不再合并标量权重（已移除）`
- endogenous_dataset.zig 第222行：`/// v5.3：使用统一 Δ 运算替代已删除的...`
- endogenous_dataset.zig 第530行：`// v5.3：使用统一Δ运算替代已删除的...`
- audit.zig 第266行：`// v5.0：CDL表达式——使用deltaExpr自指运算替代已移除的fixedPoint方法`

## Impact（v4 补充）

- **B14 间隔基线/除数**（20处）：trainer.zig 中所有 `@max(1, XXX / (1 + obj_count / YY))` 需去掉硬编码 XXX 和 YY，由系统状态（对象数、激活频率、自由能水平）内生决定
- **B15 残留模运算**（7处）：`scheduler_epoch % N` 需全部替换为事件计数器比较，间隔由历史统计内生决定
- **B16 自由能更新率**（1处）：0.1/0.01硬编码需替换为由当前自由能水平内生计算
- **B17 sleep参数**（1处）：10M/50M ns硬编码需由系统运行时长内生决定
- **B18 测试模运算**（2处）：frozen_zone.zig测试中step%1000/10000需改为事件驱动
- **B19 学习边界**（12处）：l3_verification.zig中所有目标值、钳位边界、增量系数需内生
- **B20 测试断言**（6处）：creativity.zig测试需更新以匹配新的0初始默认值
- **B21 测试断言**（3处）：meta_cognition.zig测试需更新
- **B22 初始值**（2处）：curriculum_learner.zig初始成功率从0.5改为0.0
- **B23 测试权重**（12处）：dust_graph.zig测试中的权重值需从硬编码改为由传导历史内生
- **B24 测试常数**（2处）：training_session.zig测试中的调整常数需移除
- **B25 注释清理**（16处）：v3遗漏的"已移除"注释需全部删除

## ADDED Requirements

### Requirement: 全模块零硬编码（v4 覆盖范围扩展到全代码库）
系统中所有阈值、步数、系数、边界值、预设运算类型、sleep 时长、调度周期、学习目标值、测试断言中的预设值不得以任何预设非零值存在。

#### Scenario: 深度扫描 v4 覆盖
- **WHEN** 深度扫描检测到以下模式：
  - `@max(N, ...)` / `@min(N, ...)` 中的任何 N > 0
  - 任何非零的 struct 字段默认值（`= 1`, `= 2`, `= 100`, `= 0.001`, `= 1e-N` 等）
  - 模运算调度周期（`i % N`, `l3_total_steps % N`, `scheduler_epoch % N`）
  - 硬编码 sleep/等待时长
  - 硬编码阈值比较（`> 0.05`, `> 0.7` 等）
  - M3 硬件特定硬编码上限
  - 间隔计算中的硬编码基数和除数（`@max(1, XXX / (1 + obj_count / YY))` 中的 XXX 和 YY）
  - 学习算法中的硬编码目标值、钳位边界、增量系数
  - 测试代码中引用旧默认值的硬编码断言
- **THEN** 必须全部替换为由传导历史、激活频率、事件计数、自由能等内生统计量驱动的计算表达式

### Requirement: 硬编码调度周期替换
- 所有 `l3_total_steps % N` 和 `i % N` 必须替换为事件驱动触发
- 检查点保存 → 由自由能显著变化或累积事件计数触发
- 监控指标更新 → 由事件计数器自增触发
- CPU 散热 sleep → 由温度/持续时间内生决定
- 规则检测频率 → 由匹配事件计数触发

### Requirement: 所有 struct 默认值从 0 开始
- DepthProbeConfig.max_depth → 0（从0内生增长）
- DepthProbeConfig.constant_c → 0.0（从0内生学习）
- DepthProbeConfig.tolerance → 0.0（从0内生学习）
- CreativityConfig.max_depth → 0（从0内生增长）
- CreativityConfig.max_candidates → 0（从0内生增长）

### Requirement: 旧代码/注释清理
- 所有"已移除"标记的注释块必须删除（保留历史痕迹违反"零残留"原则）
- 所有被注释掉的代码块必须删除
- 清理后文件体量应明显减少

## REMOVED Requirements

无。v4 是 v3 的全面补充扫描，覆盖从 20+ 模块扩展到全代码库所有文件（含测试代码）。
v4 相较 v3 新增发现约 80 处硬编码/旧注释残留，涵盖 12 个新的类别。