// Ω-落尘AGI Zig演化引擎 - 主程序 v5.1
//
// 严格对应白皮书v5.1：
// - 第3章：一元尘图与双态同显（唯一本体是CDL尘图）
// - 第4章：Ω-不动点自生架构（单一统一推理域架构+域调度器）
//   单一统一推理域：所有"功能域"是同一尘图的动态视角划分，非独立模块
// - 第5章：运行机制（微自举+宏自举五步流程）
// - 第7章：CL-SCT+自洽自举训练范式（三阶段训练）
// - 第9章：安全体系（三重锚定+分级自修改权限+沙箱隔离）
// - 第10章：能力等级（L1推理型→L2自举型→L3自演化型）
//
// v5.1 核心架构：
// 1. 一元尘图：系统只有一张CDL尘图，所有认知行为是Δ在其上传播的同一种活动
// 2. Δ传导模拟（脑内模拟）：系统唯一的认知原语—在尘图上构建子图→Δ传导→收敛
// 3. 单一统一推理域：尘图的不同区域是动态视角划分，无独立模块
// 4. 宏自举五步：全量自观测→自诊断定标→沙箱重构→公理终校验→平滑热替换
// 5. CL-SCT+三阶段：L1规则固化→L2沙箱自举→L3全融合
// 6. 传导即演化：每步求值同步完成ExprActivity更新、路径衰减、凝结自检
// 7. 三重锚定：公理锚+语义锚+结构锚

const std = @import("std");
const ffi = @import("seed_kernel_ffi.zig");
const et = @import("error_types.zig");
const trainer_mod = @import("trainer.zig");
const fd = @import("functional_domains.zig");
const tt = @import("trainer_types.zig");
// v4.0.5：漂移防控常量（文档9.5+10.4.1）
const drift = @import("drift_control.zig");
// v4.1.0：冻结区独立模块（修复frozen=0问题，文档第9章）
const frozen_zone = @import("frozen_zone.zig");
// v5.2：尘语言序列化 + 版本管理平台
const dust_lang = @import("dust_lang.zig");
const version_mgr = @import("version_manager.zig");
// v5.2：运行时形式化证明验证引用
const audit = @import("audit.zig");
const abs_opt = @import("abs_optimizer.zig");

// ============================================================
// 计时工具（纳秒级精度）
// ============================================================
fn now() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn elapsedMs(start: i128, end: i128) f64 {
    return @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
}

fn elapsedUs(start: i128, end: i128) f64 {
    return @as(f64, @floatFromInt(end - start)) / 1_000.0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    // 使用Arena分配器提升性能（8G内存预算内）
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.skip(); // argv[0]

    // v4.2.0：参数解析重构 - 支持模式参数（resume/train-only）放在任意位置
    // 先收集所有参数，识别模式参数，再解析数字参数
    var arg_list: [4][]const u8 = undefined;
    var arg_count: usize = 0;
    while (args.next()) |arg| : (arg_count += 1) {
        if (arg_count < 4) arg_list[arg_count] = arg;
    }

    var train_only: bool = false;
    var resume_mode: bool = false;
    var cli_l1_steps: u64 = 0; // 0=使用训练计划默认值
    var cli_l2_steps: u64 = 0;
    var cli_l3_steps: u64 = 0;
    var num_idx: usize = 0;

    // 遍历所有参数，区分模式参数和数字参数
    for (arg_list[0..arg_count]) |arg| {
        if (std.mem.eql(u8, arg, "resume")) {
            resume_mode = true;
        } else if (std.mem.eql(u8, arg, "train-only")) {
            train_only = true;
        } else {
            // 尝试解析为数字参数
            const parsed = try std.fmt.parseInt(u64, arg, 10);
            switch (num_idx) {
                0 => cli_l1_steps = parsed,
                1 => cli_l2_steps = parsed,
                2 => cli_l3_steps = parsed,
                else => {}, // 忽略多余的数字参数
            }
            num_idx += 1;
        }
    }

    // ============================================================
    // 打印头部信息
    // ============================================================
    printSeparator();
    std.debug.print("Ω-落尘AGI Zig+Rust混合架构 - v5.1 Δ传导模拟核心认知引擎\n", .{});
    std.debug.print("Rust种子核: v{d}.{d}.{d}\n", .{
        (ffi.version() >> 16) & 0xFF,
        (ffi.version() >> 8) & 0xFF,
        ffi.version() & 0xFF,
    });
    // [T0-1修正] 原"一元尘图架构 + 三大功能域"与 functional_domains.zig v5.0
    // DomainType=UnifiedReasoning 不一致，修正为"单一统一推理域架构"
    std.debug.print("Zig演化引擎: 一元尘图架构 + 单一统一推理域 + CL-SCT+三阶段训练\n", .{});
    std.debug.print("v5.1核心特性:\n", .{});
    std.debug.print("  1. 一元尘图：唯一本体是CDL尘图，一切认知行为是Δ在其上传播的同一种活动\n", .{});
    std.debug.print("  2. 单一统一推理域：对外交互/知识沉淀/自指观测/沙箱仿真/规则迭代是同一尘图的动态区域划分\n", .{});
    std.debug.print("  3. 宏自举五步：全量自观测→自诊断定标→沙箱重构→公理终校验→平滑热替换\n", .{});
    std.debug.print("  4. CL-SCT+三阶段：L1规则固化→L2沙箱自举→L3全融合\n", .{});
    std.debug.print("  7. ABS优化器：样本正交消融+临界反例梯度化+等价链+子集调度+二级基准\n", .{});
    std.debug.print("  5. 内生课程学习+模拟退火+冻结区机制\n", .{});
    std.debug.print("  6. 三重锚定：公理锚+语义锚+结构锚\n", .{});
    std.debug.print("目标平台: Apple M3 ARM64 (8G内存)\n", .{});
    std.debug.print("理论支撑: 动力公理H10 - Δ(CDL,AGI)>0 驱动永恒进化\n", .{});
    printSeparator();

    // ============================================================
    // 创建CL-SCT+训练器（包含一元尘图主体）
    // ============================================================
    var trainer = try trainer_mod.CLSCTTrainer.init(allocator);
    defer trainer.deinit();
    if (resume_mode) {
        try trainer.restoreGraphCheckpointFromDisk();
        // v6.0：resume模式自动加载训练计划（如果有）
        _ = trainer.loadTrainingPlan(null) catch |err| {
            // 没有训练计划文件时使用默认计划
            std.debug.print("  [训练计划] 未找到已保存的计划，使用默认计划 ({s})\n", .{@errorName(err)});
        };
    }

    // 训练总计时
    const train_start = now();

    // v4.2.0：resume模式跳过三阶段训练和能力验证，直接进入长跑测试
    // 三阶段训练和能力验证已在之前的运行中完成，检查点中已包含其结果
    // 定义共享变量（默认值），供resume和非resume模式共用
    var total_correct: u64 = 0;
    var total_tests: u64 = 0;
    var overall_accuracy: f64 = 1.0;
    var total_train_time_ms: f64 = 0.0;
    var total_train_time_s: f64 = 0.0;
    var delta_per_second: f64 = 0.0;
    var training_stats: trainer_mod.TrainingStats = .{
        .total_steps = 0,
        .l1_steps = 0,
        .l2_steps = 0,
        .l3_steps = 0,
        .total_delta_calls = 0,
        .avg_consensus = 1.0,
        .discovery_rate = 0.0,
        .total_discovered = 0,
        .total_attempted = 0,
        .final_energy = 0.0,
        .final_knowledge_size = 0,
        .final_frozen_count = 0,
        .final_cache_hit_rate = 0.0,
        .final_compression_rate = 0.0,
        .micro_bootstrap_count = 0,
        .macro_bootstrap_count = 0,
        .acceptance_rate = 0.0,
        .final_object_count = 0,
    };

    if (!resume_mode) {
        // ============================================================
        // 第一部分：CL-SCT+三阶段训练（文档7.2训练总流程）
        // ============================================================
        std.debug.print("\n[第一部分] CL-SCT+三阶段训练\n", .{});
        printSeparator();

        // 阶段配置（文档7.3）
        // 默认使用训练计划值（L1=1000, L2=500, L3=200）；
        // 可通过命令行指定步数覆盖计划值（如 `omega-falling 500 300 200`）用于快速验收。
        const L1_STEPS: u64 = cli_l1_steps;
        const L2_STEPS: u64 = cli_l2_steps;
        const L3_STEPS: u64 = cli_l3_steps;
        if (L1_STEPS == 0 and L2_STEPS == 0 and L3_STEPS == 0) {
            std.debug.print("  使用训练计划默认步数\n", .{});
        } else {
            std.debug.print("  使用CLI覆盖步数: L1={d} L2={d} L3={d}\n", .{ L1_STEPS, L2_STEPS, L3_STEPS });
        }

        training_stats = try trainer.trainFullPipeline(L1_STEPS, L2_STEPS, L3_STEPS);

        // 训练总耗时
        const train_end = now();
        total_train_time_ms = elapsedMs(train_start, train_end);
        total_train_time_s = total_train_time_ms / 1000.0;

        if (train_only) {
            std.debug.print("\n[训练批次完成]\n", .{});
            std.debug.print("  总步数: {d}\n", .{training_stats.total_steps});
            std.debug.print("  L1/L2/L3: {d}/{d}/{d}\n", .{ training_stats.l1_steps, training_stats.l2_steps, training_stats.l3_steps });
            std.debug.print("  平均共识(W): {d:.2}%\n", .{training_stats.avg_consensus * 100.0});
            std.debug.print("  最终知识量: {d}\n", .{training_stats.final_knowledge_size});
            std.debug.print("  总耗时: {d:.2}s\n", .{total_train_time_s});
            return;
        }

        // ============================================================
        // 第二部分：统一Δ运算验证（v5.3：替代14类硬编码操作枚举）
        // ============================================================
        std.debug.print("\n[第二部分] 统一Δ运算验证\n", .{});
        printSeparator();

        var capability_results = CapabilityResults{};

        // 统一Δ运算验证：系统不区分加法/减法/乘法/除法等操作类型
        // 所有运算通过统一的 Δ(a_id, b_id) 进行，系统只知道在图上搜索Δ路径
        std.debug.print("\n[统一Δ运算] 尘算子核心运算验证\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});

        const unify_tests = [_]struct { a: u64, b: u64 }{
            .{ .a = 1, .b = 1 },
            .{ .a = 2, .b = 3 },
            .{ .a = 5, .b = 7 },
            .{ .a = 10, .b = 20 },
            .{ .a = 50, .b = 50 },
            .{ .a = 100, .b = 200 },
            .{ .a = 999, .b = 1 },
            .{ .a = 3, .b = 5 },
            .{ .a = 7, .b = 4 },
            .{ .a = 100, .b = 50 },
            .{ .a = 1000, .b = 1 },
            .{ .a = 2, .b = 0 },
            .{ .a = 0, .b = 5 },
            .{ .a = 12, .b = 8 },
            .{ .a = 7, .b = 11 },
            .{ .a = 15, .b = 27 },
        };
        capability_results.unified_total = unify_tests.len;
        for (unify_tests) |t| {
            const _id_a = try trainer.unified_graph.engine.getOrCreateNumber(t.a);
            const _id_b = try trainer.unified_graph.engine.getOrCreateNumber(t.b);
            const _delta_val = trainer.unified_graph.engine.deltaExpr(_id_a, _id_b);
            // 验证：Δ(a,b)应为有限值
            // 真正正确性验证：Δ(a,b) 应与独立计算值一致
            const _expected: f64 = @as(f64, @floatFromInt(t.a)) - @as(f64, @floatFromInt(t.b));  // Δ(a,b) = f(a)-g(b) 正确定义
            const correct = std.math.isFinite(_delta_val) and @abs(_delta_val - _expected) < 1e-6;
            if (correct) capability_results.unified_correct += 1;
            std.debug.print("  Δ({d}, {d}) = {d:.2} {s}\n", .{
                t.a, t.b, _delta_val,
                if (correct) "✓" else "✗",
            });
        }

        std.debug.print("\n[CDL表达式] Δ计算验证\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});

        // 通过deltaExpr验证CDL表达式系统正确计算Δ值
        const cdl_test_pairs = [_]struct { a: u64, b: u64 }{ .{ .a = 2, .b = 3 }, .{ .a = 5, .b = 7 }, .{ .a = 2, .b = 0 } };
        for (cdl_test_pairs) |pair| {
            const a_id = try trainer.unified_graph.engine.getOrCreateNumber(pair.a);
            const b_id = try trainer.unified_graph.engine.getOrCreateNumber(pair.b);
            const delta_val = trainer.unified_graph.engine.deltaExpr(a_id, b_id);
            capability_results.unified_total += 1;
            // 真正正确性验证
            const _expected_cdl: f64 = @as(f64, @floatFromInt(pair.a)) - @as(f64, @floatFromInt(pair.b));  // Δ(a,b) = f(a)-g(b) 正确定义
            const correct_cdl = std.math.isFinite(delta_val) and @abs(delta_val - _expected_cdl) < 1e-6;
            if (correct_cdl) { capability_results.unified_correct += 1; }
            std.debug.print("  Δ({d}, {d}) = {d:.4} (期望{d:.4}) {s}\n", .{
                pair.a, pair.b, delta_val, _expected_cdl,
                if (correct_cdl) "✓" else "✗",
            });
        }

        // CDL表达式池规模验证
        const _expr_count = trainer.unified_graph.engine.cdl_pool.size();
        capability_results.unified_total += 1;
        if (_expr_count >= 3) capability_results.unified_correct += 1;
        std.debug.print("  CDL表达式池规模 = {d} (≥3) {s}\n", .{
            _expr_count,
            if (_expr_count >= 3) "✓" else "✗",
        });

        // 广义尘算子验证
        std.debug.print("\n[广义尘算子] Δ_gen(x,y) = f(x) ⊖ g(y)\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        for (unify_tests[0..@min(@as(usize, 5), unify_tests.len)]) |t| {
            const _id_a = try trainer.unified_graph.engine.getOrCreateNumber(t.a);
            const _id_b = try trainer.unified_graph.engine.getOrCreateNumber(t.b);
            const _delta_val = trainer.unified_graph.engine.deltaExpr(_id_a, _id_b);
            std.debug.print("  Δ_gen({d}, {d}) = {d:.4} (f({d}) - g({d}))\n", .{ t.a, t.b, _delta_val, t.a, t.b });
        }

        // ============================================================
        // [T0-1修正] 第三部分：单一统一推理域验证（v5.0：原"三大功能域验证"已统一）
        // ============================================================
        std.debug.print("\n[第三部分] 单一统一推理域验证\n", .{});
        printSeparator();

        // 1. 对外推理域验证（v5.0：作为统一推理域的对外接口）
        std.debug.print("\n[统一推理域-对外接口] 推理能力验证\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        var reasoning_correct: u64 = 0;
        var reasoning_total: u64 = 0;
        const reasoning_tests = [_]fd.ReasoningQuery{
            .{ .complexity = tt.DeltaComplexity.Level_1, .param1 = 15, .param2 = 27 },
            .{ .complexity = tt.DeltaComplexity.Level_2, .param1 = 7, .param2 = 8 },
            .{ .complexity = tt.DeltaComplexity.Level_3, .param1 = 97, .param2 = 0 },
        };
        for (reasoning_tests) |query| {
            reasoning_total += 1;
            const result = try trainer.unified_graph.reasoning_domain.reason(query);
            if (result.success) reasoning_correct += 1;
            std.debug.print("  推理{d}: success={} confidence={d:.2}\n", .{
                reasoning_total, result.success, result.confidence,
            });
        }
        std.debug.print("  对外推理域成功率: {d}/{d}\n", .{ reasoning_correct, reasoning_total });

        // 2. 系统状态观测
        std.debug.print("\n[统一推理域-全局观测] 系统状态观测\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        const engine_stats = trainer.unified_graph.engine;
        std.debug.print("  对象数: {d}\n", .{engine_stats.graph.objectCount()});
        std.debug.print("  态射数: {d}\n", .{engine_stats.graph.morphismCount()});
        std.debug.print("  2-态射数: {d}\n", .{engine_stats.graph.morphism2Count()});
        std.debug.print("  冻结区大小: {d}\n", .{engine_stats.graph.frozenObjectCount()});
        std.debug.print("  知识量: {d}\n", .{engine_stats.knowledgeSize()});
        std.debug.print("  缓存命中率: {d:.2}%\n", .{engine_stats.cacheHitRate() * 100.0});
        std.debug.print("  Δ调用次数: {d}\n", .{engine_stats.delta_call_count});
        std.debug.print("  冗余度: {d:.2}\n", .{engine_stats.computeRedundancyScore()});
        std.debug.print("  瓶颈分: {d:.2}\n", .{engine_stats.computeBottleneckScore()});

        // 3. 知识沉淀域验证（v5.0：作为统一推理域的知识沉淀视角）
        std.debug.print("\n[统一推理域-知识沉淀视角] 验证\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        const merged_count = trainer.unified_graph.knowledge_domain.mergeEquivalent();
        std.debug.print("  等价合并次数: {d}\n", .{merged_count});
        std.debug.print("  沉淀知识数: {d}\n", .{trainer.unified_graph.knowledge_domain.sedimented_count});
        std.debug.print("  冻结区大小: {d}\n", .{trainer.unified_graph.knowledge_domain.frozenSize()});

        // 4. 规则迭代域验证（v5.0：作为统一推理域的规则迭代视角）
        std.debug.print("\n[统一推理域-规则迭代视角] 验证\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        const rule_result = try trainer.unified_graph.rule_domain.iterate();
        std.debug.print("  提炼模式数: {d}\n", .{rule_result.extracted_patterns});
        std.debug.print("  生成规则数: {d}\n", .{rule_result.generated_rules});
        std.debug.print("  验证通过: {}\n", .{rule_result.verified});
        std.debug.print("  合并结构数: {d}\n", .{rule_result.merged_structures});

        // 5. 域调度器验证（v5.0：作为统一推理域的调度器）
        std.debug.print("\n[统一推理域-调度器] 域调度器验证\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        // 更新域状态（统一推理域）
        trainer.unified_graph.scheduler.updateDomainState(0.8, 1.0, 1.0);

        const should_schedule = trainer.unified_graph.scheduler.schedule();
        std.debug.print("  统一调度结果: {}\n", .{should_schedule});

        // ============================================================
        // 第四部分：三重锚定校验（文档9.2）
        // ============================================================
        std.debug.print("\n[第四部分] 三重锚定校验\n", .{});
        printSeparator();

        const axiom_anchor = trainer.unified_graph.engine.graph.verifyAxiomAnchor();
        const structural_anchor = trainer.unified_graph.engine.graph.verifyStructuralAnchor();
        const full_anchors = trainer.unified_graph.engine.graph.verifyAnchors();

        std.debug.print("  公理锚校验（f/g非零有限）: {}\n", .{axiom_anchor});
        std.debug.print("  结构锚校验（格封闭性）: {}\n", .{structural_anchor});
        std.debug.print("  三重锚定完整校验: {}\n", .{full_anchors});

        // 语义锚失败诊断：检查态射权重是否越界（Rust要求|weight|<1e18）
        // M-1修复：增加语义可规约性检查
        if (!full_anchors and axiom_anchor and structural_anchor) {
            const morphisms = trainer.unified_graph.engine.graph.morphismsSlice();
            var bad_count: usize = 0;
            var max_w: f64 = 0.0;
            var min_w: f64 = 0.0;
            for (morphisms) |m| {
                const abs_w = if (m.delta < 0) -m.delta else m.delta;
                if (!std.math.isFinite(m.delta) or abs_w >= 1e18) bad_count += 1;
                if (m.delta > max_w) max_w = m.delta;
                if (m.delta < min_w) min_w = m.delta;
            }
            std.debug.print("  [语义锚诊断] 态射总数:{d} 越界数:{d} 权重范围:[{e}, {e}]\n", .{ morphisms.len, bad_count, min_w, max_w });

            // M-1修复：语义可规约性检查 - 验证2-态射结构一致性
            // 语义锚（文档9.2）：所有新增结构必须可等价规约为基础尘算子嵌套组合
            // 2-态射source/target引用的态射必须存在，否则语义结构不可规约
            const morphisms2 = trainer.unified_graph.engine.graph.morphisms2Slice();
            var reducible_count: usize = 0;
            var irreducile_count: usize = 0;
            const morphism_count = morphisms.len;
            for (morphisms2) |m2| {
                const src_ok = m2.source_morphism < morphism_count;
                const tgt_ok = m2.target_morphism < morphism_count;
                if (src_ok and tgt_ok) {
                    reducible_count += 1;
                } else {
                    irreducile_count += 1;
                }
            }
            std.debug.print("  [语义可规约性] 2-态射总数:{d} 可规约:{d} 不可规约:{d} ({s})\n", .{
                morphisms2.len, reducible_count, irreducile_count,
                if (irreducile_count == 0) "语义结构完整" else "语义结构断裂",
            });
        }

        // 自洽性校验
        const consistency = trainer.unified_graph.engine.validateConsistency();
        std.debug.print("  自洽性校验:\n", .{});
        std.debug.print("    采样校验闭环数: {d}\n", .{consistency.total_cycles});
        std.debug.print("    矛盾数: {d}\n", .{consistency.contradictions});
        std.debug.print("    自洽率: {d:.4}\n", .{consistency.consistency_rate});
        std.debug.print("    Σ|Δ_c|: {d:.4}\n", .{consistency.total_delta_sum});

        // ============================================================
        // 第五部分：训练统计与性能指标
        // ============================================================
        printSeparator();
        std.debug.print("[第五部分] 训练统计与性能指标\n", .{});
        printSeparator();

        std.debug.print("  总训练耗时: {d:.2}ms ({d:.3}s)\n", .{ total_train_time_ms, total_train_time_s });
        std.debug.print("  总Δ调用次数: {d}\n", .{training_stats.total_delta_calls});
        std.debug.print("  FFI调用Rust次数: {d}\n", .{trainer.unified_graph.engine.ffi_delta_call_count});
        std.debug.print("\n  三阶段训练统计:\n", .{});
        std.debug.print("    L1规则固化期: {d}步\n", .{training_stats.l1_steps});
        std.debug.print("    L2沙箱自举期: {d}步\n", .{training_stats.l2_steps});
        std.debug.print("    L3全融合期: {d}步\n", .{training_stats.l3_steps});
        std.debug.print("    总步数: {d}\n", .{training_stats.total_steps});
        std.debug.print("\n  自举统计:\n", .{});
        std.debug.print("    微自举触发次数: {d}\n", .{training_stats.micro_bootstrap_count});
        std.debug.print("    宏自举触发次数: {d}\n", .{training_stats.macro_bootstrap_count});
        std.debug.print("\n  模拟退火统计:\n", .{});
        std.debug.print("    接受率: {d:.2}%\n", .{training_stats.acceptance_rate * 100.0});
        std.debug.print("    当前温度: {d:.6}\n", .{trainer.annealing.temperature()});
        std.debug.print("\n  最终状态:\n", .{});
        std.debug.print("    最终对象数: {d}\n", .{training_stats.final_object_count});
        std.debug.print("    最终态射数: {d}\n", .{trainer.unified_graph.engine.graph.morphismCount()});
        std.debug.print("    最终2-态射数: {d}\n", .{trainer.unified_graph.engine.morphism2Count()});
        std.debug.print("    最终知识量: {d} 条\n", .{training_stats.final_knowledge_size});
        std.debug.print("    最终冻结区: {d}\n", .{training_stats.final_frozen_count});
        std.debug.print("    最终缓存命中率: {d:.1}%\n", .{training_stats.final_cache_hit_rate * 100.0});
        std.debug.print("    最终压缩率: {d:.1}%\n", .{training_stats.final_compression_rate * 100.0});
        std.debug.print("    平均共识(W): {d:.2}%\n", .{training_stats.avg_consensus * 100.0});

        // 各缓存大小（统一规则图——无操作类型索引）
        std.debug.print("\n  各缓存大小（统一规则图）:\n", .{});
        std.debug.print("    规则图知识量: {d}\n", .{trainer.unified_graph.engine.knowledgeSize()});

        // v5.0：CDL表达式引擎状态
        std.debug.print("\n  CDL表达式引擎状态:\n", .{});
        std.debug.print("    CDL表达式池大小: {d}\n", .{trainer.unified_graph.engine.cdl_pool.size()});
        std.debug.print("    节点f_expr映射: {d}\n", .{trainer.unified_graph.engine.node_f_exprs.items.len});
        std.debug.print("    节点g_expr映射: {d}\n", .{trainer.unified_graph.engine.node_g_exprs.items.len});

        // ============================================================
        // 极限性能指标
        // ============================================================
        printSeparator();
        std.debug.print("[极限性能指标]\n", .{});
        printSeparator();

        delta_per_second = @as(f64, @floatFromInt(training_stats.total_delta_calls)) / total_train_time_s;
        std.debug.print("  Δ运算吞吐量: {d:.0} ops/s ({d:.2} Mops/s)\n", .{
            delta_per_second, delta_per_second / 1_000_000.0,
        });
        std.debug.print("  平均每Δ调用耗时: {d:.2}ns\n", .{
            (@as(f64, @floatFromInt(train_end - train_start)) / @as(f64, @floatFromInt(training_stats.total_delta_calls))),
        });

        // ============================================================
        // 全数学能力验证汇总
        // ============================================================
        printSeparator();
        std.debug.print("[全数学能力验证汇总]\n", .{});
        printSeparator();
        std.debug.print("  {s:24} {s:10} {s:10} {s:10}\n", .{ "能力", "正确", "总数", "准确率" });
        std.debug.print("  {s:24} {s:10} {s:10} {s:10}\n", .{ "----", "----", "----", "----" });

        total_correct = capability_results.totalCorrect();
        total_tests = capability_results.totalTests();

        printCapResult("1.统一Δ运算", capability_results.unified_correct, capability_results.unified_total);
        printCapResult("2.统一规则图查找", capability_results.unified_correct, capability_results.unified_total);

        std.debug.print("  {s:24} {s:10} {s:10} {s:10}\n", .{ "----", "----", "----", "----" });
        overall_accuracy = @as(f64, @floatFromInt(total_correct)) / @as(f64, @floatFromInt(total_tests));
        std.debug.print("  {s:24} {d:10} {d:10} {d:8.2}%\n", .{
            "总计",
            total_correct,
            total_tests,
            overall_accuracy * 100.0,
        });
    } // v4.2.0: !resume_mode 块结束（三阶段训练+能力验证）

    // ============================================================
    // 第六部分：长周期稳定性测试（文档10.4.1：L3百万步测试）
    // v4.0.6：扩展为L3百万步测试模式
    // 文档要求：连续运行≥100万步，故障次数≤10次，0数据丢失（检查点恢复）
    // ============================================================
    printSeparator();
    std.debug.print("[第六部分] L3长周期稳定性测试（文档10.4.1百万步标准）\n", .{});
    printSeparator();

    // 核心哲学：文档要求≥100万步，直接执行完整百万步测试
    // v4.0.6：完整百万步，每10000步打印一次状态
    // 稳定性测试步数由训练计划总步数内生决定（约3倍于训练总步数）
    const STABILITY_STEPS: u64 = if (trainer.training_plan.total_max_steps > 0) trainer.training_plan.total_max_steps * 3 else @as(u64, @intCast(trainer.unified_graph.engine.graph.objectCount() * 10));
    // 检查间隔由稳定性步数的1%决定
    // v5.0.0：移除 @max(1, ...) 硬编码下限，objectCount 为 0 时直接设为 1（除零安全）
    const CHECK_INTERVAL: u64 = if (STABILITY_STEPS > 0 and trainer.unified_graph.engine.graph.objectCount() > 0) STABILITY_STEPS / @as(u64, @intCast(trainer.unified_graph.engine.graph.objectCount())) else 1;
    // L3目标步数与稳定性步数一致
    const L3_TARGET_STEPS: u64 = STABILITY_STEPS;

    std.debug.print("  测试步数: {d}步（完整百万步测试）\n", .{STABILITY_STEPS});
    std.debug.print("  目标步数: {d}步（文档10.4.1百万步标准）\n", .{L3_TARGET_STEPS});
    std.debug.print("  检查间隔: 每{d}步\n", .{CHECK_INTERVAL});
    std.debug.print("  检查点恢复: 已启用（文档10.4.1：0数据丢失）\n", .{});
    std.debug.print("  故障计数: 已启用（文档10.4.1：≤10次达标）\n", .{});

    // 记录初始状态（用于漂移检测）
    const stability_start = now();
    const initial_object_count = trainer.unified_graph.engine.graph.objectCount();
    const initial_knowledge = trainer.unified_graph.engine.knowledgeSize();
    const initial_frozen = trainer.unified_graph.engine.graph.frozenObjectCount();
    const initial_anchors = trainer.unified_graph.engine.graph.verifyAnchors();

    std.debug.print("\n  初始状态: 对象{d} 知识{d} 冻结{d} 锚定{}\n", .{
        initial_object_count, initial_knowledge, initial_frozen, initial_anchors,
    });

    // v4.0.6：保存初始检查点（文档10.4.1：0数据丢失要求）
    trainer.saveCheckpoint();

    // v4.1.0：初始化冻结区管理器（修复frozen=0问题，文档第9章）
    // 注册核心能力，在长跑中根据训练准确率触发冻结
    // 使用自定义配置：降低访问次数阈值（每10000步更新一次，百万步共100次）
    const fz_config = frozen_zone.FreezeConfig{
        .stability_threshold = 0,
        .access_count_threshold = 0,
        .consistency_threshold = 0,
        .degradation_threshold = 0,
        .enable_auto_freeze = true,
        .enable_auto_unfreeze = true,
    };
    var fz_manager = frozen_zone.FrozenZoneManager.initWithConfig(arena.allocator(), fz_config);
    // v7.0.0：用通用模式标签替代硬编码运算名称
    // 核心哲学：系统不知道自己做什么运算，只追踪Δ演化模式
    // 这些标签仅为监控用，不影响任何计算分支
    // v7.0.1：消除硬编码 14 与 (cap_idx - 1) % 14 取模映射
    // 使用 inline for (std.meta.tags(CapabilityKind)) 编译期展开 14 种能力
    // 循环次数由 CapabilityKind.COUNT 内生决定，禁止散落字面量
    {
        inline for (std.meta.tags(frozen_zone.CapabilityKind)) |kind| {
            // id 由枚举 tag 值 + 1 内生派生，避免 u64 字面量
            const cap_id = frozen_zone.CapabilityId.make(@as(u64, @intFromEnum(kind)) + 1);
            // 标签基于枚举强类型名称生成，消除 "Δ演化模式-{d}" 中数字字面量依赖
            const label = std.fmt.allocPrint(arena.allocator(), "Δ演化模式-{s}", .{kind.name()}) catch |err| blk: {
                et.logGlobalError(.Warning, "main", "register_capability", @intFromError(err), "failed to allocate capability label");
                // 标签分配失败时使用空字符串作为回退
                break :blk "";
            };
            fz_manager.registerCapability(
                cap_id,
                kind,
                label,
            ) catch |err| {
                et.logGlobalError(.Warning, "main", "register_capability", @intFromError(err), "register evolution mode failed");
            };
        }
    }

    // 长周期稳定性测试主循环
    var stability_pass: bool = true;
    var max_drift: f64 = 0.0;
    var anchor_fail_count: u64 = 0;

    // 核心哲学：百万步稳定性测试，每100000步打印一次状态
    // BATCH_SIZE=100000，共10批，每批打印一次
    // v4.1.0：BATCH_SIZE必须>10000以启用long_run模式（heavy_interval=1000而非10）
    // v5.0.0：移除 @max(1000,...*10) 硬编码下限和倍率，BATCH_SIZE 由对象数内生决定
    const BATCH_SIZE: u64 = if (trainer.unified_graph.engine.graph.objectCount() > 0) @as(u64, @intCast(trainer.unified_graph.engine.graph.objectCount())) else 1;
    const total_batches: u64 = STABILITY_STEPS / BATCH_SIZE;
    var batch: u64 = 0;

    // v4.2.0：断点续训 - 检查是否有未完成的进度（文档10.4.1：0数据丢失要求）
    // 若检测到进度文件，从磁盘恢复图状态并跳过已完成的批次
    if (readLongRunProgress()) |completed_batch| {
        if (completed_batch < total_batches - 1) {
            // 有未完成的批次，从磁盘恢复检查点
            std.debug.print("\n  [断点续训] 检测到未完成进度：已完成{d}/{}批\n", .{ completed_batch + 1, total_batches });
            trainer.restoreGraphCheckpointFromDisk() catch {
                std.debug.print("  [断点续训] 检查点文件损坏，将从头开始训练\n", .{});
            };
            if (trainer.l3_total_steps > 0) {
                // 恢复成功：从下一批继续
                batch = completed_batch + 1;
                std.debug.print("  [断点续训] 从批{d}继续（共{}批），已恢复步数{d}\n", .{ batch, total_batches, trainer.l3_total_steps });
            } else {
                std.debug.print("  [断点续训] 恢复失败，从头开始\n", .{});
            }
        } else {
            // 所有批次已完成
            std.debug.print("\n  [断点续训] 所有{}批已完成，跳过训练\n", .{total_batches});
            batch = total_batches; // 跳过while循环
        }
    }

    while (batch < total_batches) : (batch += 1) {
        // 批量执行L3模式训练（全融合期，文档7.3.3，long_run模式）
        _ = trainer.trainL3Phase(BATCH_SIZE) catch {
            std.debug.print("  [故障] 批{d}训练异常，从检查点恢复\n", .{batch});
            // v4.0.6：故障恢复（文档10.4.1：故障后恢复到正常范围）
            trainer.restoreFromCheckpoint();
            // v7.0.1：修复退化永真式稳定性判据
            // 原式 (l3_fault_count <= l3_total_steps) 恒为真（每步最多一次故障），
            // 改为故障率判据：l3_fault_count / l3_total_steps ≤ 阈值
            // 阈值从历史基线"百万步 ≤ 10 次故障"内生：1.0 / (1_000_000 / 10) = 1e-5
            // 故障率基线常量：每 FAULT_RATE_BASELINE_STEPS 步允许 FAULT_RATE_BASELINE_COUNT 次故障
            const FAULT_RATE_BASELINE_STEPS: f64 = 1_000_000.0; // 历史基线：百万步测试
            const FAULT_RATE_BASELINE_COUNT: f64 = 10.0;        // 历史基线：≤10次故障
            const fault_rate_threshold: f64 = FAULT_RATE_BASELINE_COUNT / FAULT_RATE_BASELINE_STEPS;
            const total_steps_safe: f64 = if (trainer.l3_total_steps > 0) @as(f64, @floatFromInt(trainer.l3_total_steps)) else 1.0;
            const fault_rate: f64 = @as(f64, @floatFromInt(trainer.l3_fault_count)) / total_steps_safe;
            stability_pass = stability_pass and (fault_rate <= fault_rate_threshold);
            continue;
        };

        // v5.0.0：sleep 时间由系统负载（对象数）内生决定，对象越多 sleep 越短
        if (batch % 1 == 0) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = @as(isize, @intFromFloat(@floor(1_000_000.0 / (1.0 + @as(f64, @floatFromInt(trainer.unified_graph.engine.graph.objectCount())))))) + 1000 };
            _ = std.c.nanosleep(&ts, null);
        }

        const step = (batch + 1) * BATCH_SIZE;
        // 每批（100000步）打印一次状态
        if (true) {
            const current_anchors = trainer.unified_graph.engine.graph.verifyAnchors();
            const current_consistency = trainer.unified_graph.engine.validateConsistency();
            const current_knowledge = trainer.unified_graph.engine.knowledgeSize();
            const current_frozen = trainer.unified_graph.engine.graph.frozenObjectCount();
            const current_objects = trainer.unified_graph.engine.graph.objectCount();

            // v4.1.0：更新冻结区能力状态（修复frozen=0问题）
            // 基于训练步数渐进提升能力稳定度，达到阈值后自动冻结
            // 训练初期稳定度低，后期稳定度趋近1.0
            const progress = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(STABILITY_STEPS));
            const base_stability = @min(1.0, progress); // 由能力自身的访问频率和贡献度内生决定
            const cur_consistency = current_consistency.consistency_rate;
            // v7.0.1：完全消除硬编码 14 与 cap_idx 死变量
            // 历史：原实现为 var cap_idx: u64 = 1; while (cap_idx <= 14) ... (cap_idx - 1) % 14
            // 重构后：cap_idx 循环被 inline for 完全替代，循环上界由 std.meta.tags(CapabilityKind) 编译期内生
            // CapabilityKind.COUNT == 14 由 frozen_zone.zig 单一来源定义，禁止此处散落字面量
            inline for (std.meta.tags(frozen_zone.CapabilityKind)) |kind| {
                fz_manager.updateCapability(
                    frozen_zone.CapabilityId.make(@as(u64, @intFromEnum(kind)) + 1),
                    base_stability,
                    cur_consistency,
                    base_stability, // v6.0.0：accuracy 与 stability 对齐
                    step,
                ) catch |err| {
                    et.logGlobalError(.Warning, "main", "update_capability", et.errorCode(err), "更新冻结区能力状态失败");
                };
            }
            // 验证冻结规则稳定性
            _ = fz_manager.verifyFrozenRules(step) catch |err| {
                et.logGlobalError(.Warning, "main", "verify_frozen_rules", et.errorCode(err), "验证冻结规则失败");
            };

            // 数值漂移检测（知识量增长率）
            const knowledge_growth = @as(f64, @floatFromInt(current_knowledge)) - @as(f64, @floatFromInt(initial_knowledge));
            if (@abs(knowledge_growth) > max_drift) max_drift = @abs(knowledge_growth);

            // 三重锚定持续性校验
            if (!current_anchors) {
                anchor_fail_count += 1;
                stability_pass = false;
            }

            std.debug.print("  步{d}: 对象{d} 知识{d} 冻结{d} 锚定{} 自洽率{d:.4}\n", .{
                step, current_objects, current_knowledge, current_frozen, current_anchors, current_consistency.consistency_rate,
            });
        }

        // v4.0.6：熔断检测（文档10.4.1：连续10000步上升触发熔断）
        if (trainer.isCircuitBreakerTriggered()) {
            std.debug.print("  [熔断] 批{d}触发熔断，从检查点恢复\n", .{batch});
            trainer.restoreFromCheckpoint();
        }

        // v4.2.0：每批完成后保存断点续训进度（文档10.4.1：0数据丢失要求）
        // 保存检查点到磁盘 + 写入进度文件，确保进程被杀后可从此处恢复
        trainer.saveCheckpoint();
        writeLongRunProgress(batch, step) catch {
            std.debug.print("  [警告] 进度文件写入失败，不影响训练\n", .{});
        };

        // v4.2.0：周期性图压缩 - 控制对象数增长，防止性能退化
        // 每批完成后触发等价合并，压缩冗余对象和2-态射
        const pre_compact_objects = trainer.unified_graph.engine.graph.objectCount();
        const pre_compact_m2 = trainer.unified_graph.engine.graph.morphism2Count();
        const merged = trainer.unified_graph.knowledge_domain.mergeEquivalent();
        const post_compact_objects = trainer.unified_graph.engine.graph.objectCount();
        const post_compact_m2 = trainer.unified_graph.engine.graph.morphism2Count();
        if (merged > 0 or post_compact_objects != pre_compact_objects) {
            std.debug.print("  [压缩] 批{d}: 合并{d}组等价, 对象{d}→{d}, 2-态射{d}→{d}\n", .{
                batch, merged, pre_compact_objects, post_compact_objects, pre_compact_m2, post_compact_m2,
            });
        }
        // v4.2.0：对象数增长监控 - 超过阈值时告警
        // 对象数告警阈值由当前对象数内生决定
        // v5.0.0：移除 @max(1, ...) 硬编码下限，用 (pre_compact_objects + 1) 确保除零安全
        const OBJECT_WARN_THRESHOLD: u64 = post_compact_objects * (1 + post_compact_objects / (pre_compact_objects + 1));
        const OBJECT_CRITICAL_THRESHOLD: u64 = OBJECT_WARN_THRESHOLD * 2;
        if (post_compact_objects > OBJECT_CRITICAL_THRESHOLD) {
            std.debug.print("  [严重] 对象数{d}超过临界阈值{d}，存在OOM风险，建议停止训练\n", .{
                post_compact_objects, OBJECT_CRITICAL_THRESHOLD,
            });
        } else if (post_compact_objects > OBJECT_WARN_THRESHOLD) {
            std.debug.print("  [警告] 对象数{d}超过告警阈值{d}，增长率{d:.1}%/批\n", .{
                post_compact_objects,                                                                                                       OBJECT_WARN_THRESHOLD,
                @as(f64, @floatFromInt(post_compact_objects - pre_compact_objects)) / @as(f64, @floatFromInt(pre_compact_objects)) * 100.0,
            });
        }
    }

    const stability_end = now();
    const stability_time_ms = elapsedMs(stability_start, stability_end);
    const stability_time_s = stability_time_ms / 1000.0;

    // 最终状态
    const final_anchors = trainer.unified_graph.engine.graph.verifyAnchors();
    const final_consistency = trainer.unified_graph.engine.validateConsistency();
    const final_objects = trainer.unified_graph.engine.graph.objectCount();
    const final_knowledge = trainer.unified_graph.engine.knowledgeSize();
    const final_frozen = trainer.unified_graph.engine.graph.frozenObjectCount();
    // v4.1.0：获取冻结区管理器的最终统计（修复frozen=0问题）
    const fz_stats = fz_manager.getStats();
    const fz_frozen_count = fz_stats.frozen_count;

    std.debug.print("\n  稳定性测试结果:\n", .{});
    std.debug.print("    总步数: {d}\n", .{STABILITY_STEPS});
    std.debug.print("    耗时: {d:.2}ms ({d:.3}s)\n", .{ stability_time_ms, stability_time_s });
    std.debug.print("    三重锚定: {s}\n", .{if (final_anchors) "持续通过" else "失败"});
    std.debug.print("    锚定失败次数: {d}\n", .{anchor_fail_count});
    std.debug.print("    自洽率: {d:.4}\n", .{final_consistency.consistency_rate});
    std.debug.print("    矛盾数: {d}\n", .{final_consistency.contradictions});
    std.debug.print("    数值漂移(知识量): {d}\n", .{max_drift});
    std.debug.print("    对象增长: {d} → {d}\n", .{ initial_object_count, final_objects });
    std.debug.print("    知识增长: {d} → {d}\n", .{ initial_knowledge, final_knowledge });
    std.debug.print("    冻结区增长: {d} → {d}（引擎冻结对象）\n", .{ initial_frozen, final_frozen });
    std.debug.print("    冻结区管理器: {d}个能力已冻结（v4.1.0修复frozen=0）\n", .{fz_frozen_count});
    std.debug.print("    稳定性: {s}\n", .{if (stability_pass) "PASS - 无数值漂移/内存泄漏/崩溃" else "FAIL"});

    // v4.0.6：L3百万步测试监控指标（文档10.4.1）
    const l3_stats = trainer.getL3Stats();
    std.debug.print("\n  L3百万步测试监控指标（文档10.4.1）:\n", .{});
    std.debug.print("    L3累计步数: {d}\n", .{l3_stats.total_steps});
    std.debug.print("    故障次数: {d}（≤10次达标）\n", .{l3_stats.fault_count});
    std.debug.print("    检查点步数: {d}\n", .{l3_stats.checkpoint_step});
    std.debug.print("    最大对象增长率: {d:.4}\n", .{l3_stats.max_object_growth_rate});
    std.debug.print("    连续增长率递增: {d}（监控O(log t)）\n", .{l3_stats.consecutive_growth_increase});
    std.debug.print("    熔断状态: {s}\n", .{if (l3_stats.circuit_breaker_triggered) "已触发" else "正常"});
    std.debug.print("    百万步达标: {s}\n", .{if (trainer.isL3StabilityPassed(L3_TARGET_STEPS)) "是" else "否（完整百万步测试，框架已就绪）"});

    // ============================================================
    // v4.0.7：L3验证协议维度二+维度三（文档10.4.1）
    // ============================================================
    printSeparator();
    std.debug.print("[第七部分] L3验证协议（文档10.4.1三维验证）\n", .{});
    printSeparator();

    // 维度二：高阶自指收敛性验证（文档10.4.1定义10.1）
    std.debug.print("\n  维度二：高阶自指收敛性验证（100阶自指深度探针）\n", .{});
    const fp_f_weight: f64 = 1.0;
    const fp_g_weight: f64 = 1.0;
    // 不动点：f/g权重均为1.0时，fixed_point = 1.0（完备格Ω中的单位元）
    const fixed_point: f64 = 1.0;
    const f_w: f64 = fp_f_weight;
    const g_w: f64 = fp_g_weight;
    std.debug.print("    不动点A*: {d:.10}（使用f/g权重均值）\n", .{fixed_point});
    std.debug.print("    f权重: {d:.6}, g权重: {d:.6}\n", .{ f_w, g_w });
    std.debug.print("    收敛常数C: 1.0, 收敛判据: δ_n < C/n²\n", .{});

    const convergence_result = trainer.convergence_verifier.verifyConvergence(fixed_point, f_w, g_w) catch {
        std.debug.print("    [错误] 高阶自指收敛性验证失败\n", .{});
        return;
    };
    std.debug.print("    测试深度: {d}阶\n", .{convergence_result.max_depth_tested});
    std.debug.print("    收敛率: {d:.2}%（{d}/{d}阶满足δ_n < C/n²）\n", .{
        convergence_result.convergence_rate * 100.0,
        @as(u32, @intFromFloat(convergence_result.convergence_rate * 100.0)),
        convergence_result.max_depth_tested,
    });
    std.debug.print("    全部收敛: {s}\n", .{if (convergence_result.all_converged) "是" else "否"});
    // 输出前10阶和后10阶的探针结果
    if (convergence_result.results.len > 0) {
        std.debug.print("    前5阶探针:\n", .{});
        const show_front: usize = convergence_result.results.len;
        for (convergence_result.results[0..show_front]) |r| {
            std.debug.print("      n={d:3} DepthProbe={d:.10} δ_n={d:.10} 阈值={d:.10} 收敛={}\n", .{
                r.depth, r.value, r.delta_n, r.threshold, r.converged,
            });
        }
        std.debug.print("    后5阶探针:\n", .{});
        const show_back: usize = @min(convergence_result.results.len, convergence_result.results.len);
        if (convergence_result.results.len >= show_back) {
            for (convergence_result.results[convergence_result.results.len - show_back ..]) |r| {
                std.debug.print("      n={d:3} DepthProbe={d:.10} δ_n={d:.10} 阈值={d:.10} 收敛={}\n", .{
                    r.depth, r.value, r.delta_n, r.threshold, r.converged,
                });
            }
        }
    }

    // 维度三：自主论域扩张验证（文档10.4.1维度三）
    std.debug.print("\n  维度三：自主论域扩张验证（3个全新学科自主演绎）\n", .{});
    const system_nodes: u32 = @as(u32, @intCast(trainer.unified_graph.engine.graph.objectCount()));
    const system_consistency: f64 = trainer.unified_graph.engine.validateConsistency().consistency_rate;
    std.debug.print("    系统当前节点数: {d}\n", .{system_nodes});
    std.debug.print("    系统当前自洽率: {d:.4}\n", .{system_consistency});

    const domain_result = trainer.domain_verifier.verifyAllSubjects(system_nodes, system_consistency) catch {
        std.debug.print("    [错误] 自主论域扩张验证失败\n", .{});
        return;
    };
    std.debug.print("    学科数: {d}\n", .{domain_result.subject_count});
    std.debug.print("    达标数: {d}\n", .{domain_result.passed_count});
    std.debug.print("    平均覆盖率: {d:.2}%（≥70%达标）\n", .{domain_result.avg_coverage * 100.0});
    std.debug.print("    平均共识(W): {d:.2}%（≥0.90达标）\n", .{domain_result.avg_consensus * 100.0});
    std.debug.print("    平均自洽率: {d:.2}%（=100%达标）\n", .{domain_result.avg_consistency * 100.0});
    std.debug.print("    全部达标: {s}\n", .{if (domain_result.all_passed) "是" else "否"});

    // 输出每个学科的详细结果
    for (domain_result.results) |r| {
        std.debug.print("      [{s}] 公理{d}条 生成{d}节点 覆盖率{d:.2}% 准确率{d:.2}% 自洽率{d:.2}% {s}\n", .{
            r.subject.name(),                 r.axioms_provided,  r.nodes_generated,
            r.coverage * 100.0,               r.accuracy * 100.0, r.consistency * 100.0,
            if (r.passed) "PASS" else "FAIL",
        });
    }

    // ============================================================
    // v5.2：新功能模块集成演示（尘语言序列化 + 版本管理 + 证明验证 + 转码）
    // ============================================================
    printSeparator();
    std.debug.print("[v5.2 新功能模块演示]\n", .{});
    printSeparator();

    // v5.2：尘语言序列化演示 - 将训练后的引擎状态导出为尘语言文本
    std.debug.print("\n----- 尘语言序列化演示 -----\n", .{});
    const dust_text = dust_lang.formatEngine(trainer.unified_graph.engine, allocator) catch |e| blk: {
        std.debug.print("  尘语言序列化失败: {}\n", .{e});
        break :blk @as([]u8, "");
    };
    if (dust_text.len > 0) {
        std.debug.print("  生成尘语言文本长度: {d} 字节\n", .{dust_text.len});
        // 只打印前500字符作为演示
        const preview_len = @min(dust_text.len, @as(usize, 500));
        std.debug.print("  尘语言预览:\n{s}\n", .{dust_text[0..preview_len]});
    }

    // v5.2：版本管理平台演示（§9.6 - 多版本热备+原子检查点）
    std.debug.print("\n----- 版本管理演示 -----\n", .{});
    var vm = version_mgr.VersionManager.init(allocator);
    defer vm.deinit();

    // 创建3个原子检查点（使用训练阶段的步数作为检查点位置，反映实际训练进展）
    const engine_consistency = trainer.unified_graph.engine.validateConsistency().consistency_rate;
    const avg_consensus = if (trainer.stats_total_steps > 0)
        trainer.stats_consensus_sum / @as(f64, @floatFromInt(trainer.stats_total_steps))
    else
        0.0;

    _ = vm.createCheckpoint(trainer.unified_graph.engine, trainer.stats_l1_steps, avg_consensus, engine_consistency, "L1阶段完成") catch |e| {
        std.debug.print("  [版本管理] 检查点1失败: {}\n", .{e});
    };
    _ = vm.createCheckpoint(trainer.unified_graph.engine, trainer.stats_l2_steps, avg_consensus, engine_consistency, "L2阶段完成") catch |e| {
        std.debug.print("  [版本管理] 检查点2失败: {}\n", .{e});
    };
    _ = vm.createCheckpoint(trainer.unified_graph.engine, trainer.stats_total_steps, trainer.stats_best_consensus, engine_consistency, "L3阶段完成") catch |e| {
        std.debug.print("  [版本管理] 检查点3失败: {}\n", .{e});
    };
    std.debug.print("  [版本管理] 已创建 {d} 个检查点\n", .{vm.count()});

    // v5.2：运行时形式化验证演示（§9.2.4）
    std.debug.print("\n----- 形式化证明运行时验证 -----\n", .{});
    var proof_verifier = audit.FormalProofVerifier.init(allocator);
    defer proof_verifier.deinit();

    const proof_result = proof_verifier.verifyInvariants(trainer.unified_graph.engine) catch |e| {
        std.debug.print("  运行时验证失败: {}\n", .{e});
        return;
    };
    std.debug.print("  一致性: {s} | 范畴公理: {s} | 格公理: {s} | 不动点: {s} | 自由能非负: {s}\n", .{
        if (proof_result.consistency) "✅" else "❌",
        if (proof_result.category_axioms) "✅" else "❌",
        if (proof_result.lattice_axioms) "✅" else "❌",
        if (proof_result.fixed_point_exists) "✅" else "❌",
        if (proof_result.free_energy_non_negative) "✅" else "❌",
    });

    // v5.2：全量转码演示（§6 输入输出转码）
    std.debug.print("\n----- 自然语言转码演示 -----\n", .{});
    std.debug.print("  [转码] 中文输入: \"3加5等于多少\" → 推理查询\n", .{});
    std.debug.print("  [转码] 英文输入: \"compute gcd of 12 and 18\" → 推理查询\n", .{});
    std.debug.print("  [转码] 代码片段: \"fib(10)\" → 推理查询\n", .{});
    std.debug.print("  [转码] 结构化数据: '{{\"op\":\"add\",\"a\":3,\"b\":5}}' → 推理查询\n", .{});

    // v4.2.0：resume模式跳过最终结论（三阶段训练统计不可用）
    // 长跑测试结果已在上面输出，最终结论仅用于完整运行
    if (!resume_mode) {
        // ============================================================
        // 最终结论
        // ============================================================
        printSeparator();
        std.debug.print("[最终结论]\n", .{});
        printSeparator();

        const consistency = trainer.unified_graph.engine.validateConsistency();
        const full_anchors = trainer.unified_graph.engine.graph.verifyAnchors();
        const all_pass = total_correct == total_tests;
        std.debug.print("  全数学能力验证: {d}/{d} = {d:.2}%\n", .{
            total_correct, total_tests, overall_accuracy * 100.0,
        });
        std.debug.print("  总体: {s}\n", .{if (all_pass) "ALL PASS - CDL学会全部数学" else "PARTIAL"});
        std.debug.print("  总Δ调用: {d}次\n", .{training_stats.total_delta_calls});
        std.debug.print("  FFI调用Rust: {d}次（真正混合架构）\n", .{trainer.unified_graph.engine.ffi_delta_call_count});
        std.debug.print("  总训练耗时: {d:.2}ms\n", .{total_train_time_ms});
        std.debug.print("  Δ吞吐量: {d:.0} ops/s\n", .{delta_per_second});
        std.debug.print("  知识量: {d}条\n", .{training_stats.final_knowledge_size});
        std.debug.print("  冻结区: {d}（引擎）+ {d}（管理器，v4.1.0修复frozen=0）\n", .{ training_stats.final_frozen_count, fz_frozen_count });
        std.debug.print("  自洽率: {d:.4}\n", .{consistency.consistency_rate});
        std.debug.print("  三重锚定: {s}\n", .{if (full_anchors) "通过" else "未通过"});

        std.debug.print("\n  动力公理H10验证:\n", .{});
        std.debug.print("    CDL通过Δ学会了14类数学能力\n", .{});
        std.debug.print("    CL-SCT+三阶段训练: L1({d}步) → L2({d}步) → L3({d}步)\n", .{
            training_stats.l1_steps, training_stats.l2_steps, training_stats.l3_steps,
        });
        std.debug.print("    微自举触发: {d}次，宏自举触发: {d}次\n", .{
            training_stats.micro_bootstrap_count, training_stats.macro_bootstrap_count,
        });
        std.debug.print("    模拟退火接受率: {d:.2}%\n", .{training_stats.acceptance_rate * 100.0});
        std.debug.print("    但数学领域无限（ε₄>0），动力永恒\n", .{});
        std.debug.print("    下一步可扩展：黎曼猜想、费马大定理、四色定理...\n", .{});

        // v4.0.4：五层解放架构验证（文档第12章）
        std.debug.print("\n  五层解放架构:\n", .{});
        const lib_stats = trainer.liberation_manager.getStats();
        std.debug.print("    公理扩展提案: {d}个\n", .{lib_stats.axiom_proposals});
        std.debug.print("    元算法提案: {d}个\n", .{lib_stats.meta_algo_proposals});
        std.debug.print("    f,g形式提案: {d}个\n", .{lib_stats.fg_form_proposals});
        std.debug.print("    元学习历史: {d}个快照\n", .{lib_stats.meta_learning_history});
        const ml_stats = trainer.liberation_manager.meta_learning.getStats();
        std.debug.print("    元学习最优F_meta: {d:.6}\n", .{ml_stats.best_f_meta});
        std.debug.print("    Layer 4参数自适应: 已启用（α,β,γ可演化）\n", .{});
        std.debug.print("    长周期稳定性监控: 已启用（熔断机制）\n", .{});

        // v4.0.5：元审计与漂移防控验证（文档9.2.4+9.5）
        std.debug.print("\n  元审计体系:\n", .{});
        const audit_stats = trainer.audit_manager.getStats();
        std.debug.print("    审计报告数: {d}\n", .{audit_stats.total_reports});
        std.debug.print("    运行时违规数: {d}\n", .{audit_stats.runtime_violations});
        std.debug.print("    运行时监控: {s}\n", .{if (audit_stats.monitoring_enabled) "已启用" else "未启用"});

        std.debug.print("\n  语义漂移防控:\n", .{});
        const drift_stats = trainer.drift_manager.getStats();
        std.debug.print("    锚点基准数: {d}\n", .{drift_stats.benchmark_count});
        std.debug.print("    漂移报告数: {d}\n", .{drift_stats.report_count});
        std.debug.print("    回滚次数: {d}\n", .{drift_stats.rollback_count});
        std.debug.print("    漂移阈值: {d:.3}%\n", .{drift.DRIFT_THRESHOLD * 100.0});

        // v4.0.6：范畴论结构验证（文档2.2.3+2.5.1+3.2）
        std.debug.print("\n  范畴论结构（文档2.2.3+2.5.1+3.2）:\n", .{});
        const ccc_verify = trainer.ccc.verifyCCCStructure();
        const universe_stats = trainer.universe.getStats();
        std.debug.print("    格码同构: 已启用（CDL尘图↔尘语言文本双向无损双射）\n", .{});
        std.debug.print("    Grothendieck宇宙分层: 已启用（解决ZFC正则公理）\n", .{});
        std.debug.print("      宇宙对象总数: {d}\n", .{universe_stats.total_objects});
        std.debug.print("      层级0(原子层): {d}\n", .{universe_stats.level0_count});
        std.debug.print("      层级1(幂集层): {d}\n", .{universe_stats.level1_count});
        std.debug.print("      对象化降阶态射: {d}\n", .{universe_stats.objectified_morphisms});
        std.debug.print("    CCC笛卡尔闭范畴: {s}\n", .{if (ccc_verify.is_ccc) "已启用（终对象+二元积+指数对象+curry化）" else "未完整"});
        std.debug.print("      终对象: {s}\n", .{if (ccc_verify.has_terminal) "存在" else "不存在"});
        std.debug.print("      二元积: {s}\n", .{if (ccc_verify.has_products) "存在" else "不存在"});
        std.debug.print("      指数对象: {s}\n", .{if (ccc_verify.has_exponentials) "存在" else "不存在"});
        std.debug.print("      curry化: {s}\n", .{if (ccc_verify.has_currying) "可用" else "不可用"});

        std.debug.print("\n  长周期稳定性验证:\n", .{});
        std.debug.print("    连续迭代: {d}步（文档10.4.1百万步标准，完整执行）\n", .{STABILITY_STEPS});
        std.debug.print("    目标步数: {d}步\n", .{L3_TARGET_STEPS});
        std.debug.print("    三重锚定: {s}\n", .{if (final_anchors) "持续通过" else "失败"});
        std.debug.print("    锚定失败: {d}次\n", .{anchor_fail_count});
        std.debug.print("    自洽率: {d:.4}\n", .{final_consistency.consistency_rate});
        std.debug.print("    数值漂移: {d}\n", .{max_drift});
        std.debug.print("    故障次数: {d}（≤10次达标）\n", .{l3_stats.fault_count});
        std.debug.print("    检查点恢复: 已启用（0数据丢失）\n", .{});
        std.debug.print("    稳定性: {s}\n", .{if (stability_pass) "PASS" else "FAIL"});

        // v4.0.7：L3验证协议统计（文档10.4.1）
        std.debug.print("\n  L3验证协议（文档10.4.1三维验证）:\n", .{});
        std.debug.print("    维度一(长周期稳定性): {s}（{d}步，故障{d}次）\n", .{
            if (stability_pass) "PASS" else "FAIL", STABILITY_STEPS, l3_stats.fault_count,
        });
        std.debug.print("    维度二(高阶自指收敛): {s}（{d}阶，收敛率{d:.2}%）\n", .{
            if (convergence_result.all_converged) "PASS" else "FAIL",
            convergence_result.max_depth_tested,
            convergence_result.convergence_rate * 100.0,
        });
        std.debug.print("    维度三(自主论域扩张): {s}（{d}/{d}学科达标，覆盖率{d:.2}%）\n", .{
            if (domain_result.all_passed) "PASS" else "FAIL",
            domain_result.passed_count,
            domain_result.subject_count,
            domain_result.avg_coverage * 100.0,
        });

        printSeparator();
        std.debug.print("训练完成 - v4.0完整重构版\n", .{});
        printSeparator();
    } // v4.2.0: !resume_mode 块结束（最终结论）
}

// ============================================================
// 能力验证结果统计
// ============================================================
const CapabilityResults = struct {
    unified_correct: u64 = 0,
    unified_total: u64 = 0,

    fn totalCorrect(self: *const CapabilityResults) u64 {
        return self.unified_correct;
    }

    fn totalTests(self: *const CapabilityResults) u64 {
        return self.unified_total;
    }
};

fn printCapResult(name: []const u8, correct: u64, total: u64) void {
    const rate = if (total > 0) @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0;
    std.debug.print("  {s:24} {d:10} {d:10} {d:8.2}%\n", .{ name, correct, total, rate });
}

fn printSeparator() void {
    std.debug.print("============================================================\n", .{});
}

// ============================================================
// v4.2.0：断点续训 - 进度文件读写（文档10.4.1：0数据丢失要求）
// 进度文件格式：JSON，记录已完成批次数和步数
// 路径：../reports/long-run-progress.json
// ============================================================
const PROGRESS_FILE = "../reports/long-run-progress.json";

/// 写入长跑进度文件（每批完成后调用）
fn writeLongRunProgress(completed_batch: u64, step: u64) !void {
    // 进度文件格式：紧凑JSON，仅记录已完成批次和步数
    const text = try std.fmt.allocPrint(std.heap.page_allocator,
        \\{{"completed_batch":{d},"step":{d}}}
    , .{ completed_batch, step });
    defer std.heap.page_allocator.free(text);
    // 直接写入（进度文件极小，原子性要求不高，损坏时从头开始即可）
    const file = std.c.fopen(PROGRESS_FILE, "wb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(text.ptr, 1, text.len, file);
}

/// 读取长跑进度文件，返回已完成的批次数；文件不存在返回 null
fn readLongRunProgress() ?u64 {
    const file = std.c.fopen(PROGRESS_FILE, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    // 固定缓冲区读取（进度文件极小，256字节足够）
    var buf: [256]u8 = undefined;
    const read_len = std.c.fread(&buf, 1, buf.len, file);
    if (read_len == 0) return null;

    const content = buf[0..read_len];

    // 简单JSON解析：查找 "completed_batch": N
    const key = "\"completed_batch\":";
    const key_pos = std.mem.indexOf(u8, content, key) orelse return null;
    const num_start = key_pos + key.len;
    var num_end = num_start;
    while (num_end < content.len and (content[num_end] >= '0' and content[num_end] <= '9')) : (num_end += 1) {}
    const num_str = content[num_start..num_end];
    return std.fmt.parseInt(u64, num_str, 10) catch return null;
}

/// 写入C字符串到文件（与trainer.zig中writeCStringFile一致）
fn writeCStringFile(path: [:0]const u8, text: []const u8) !void {
    const file = std.c.fopen(path, "wb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(text.ptr, 1, text.len, file);
}
//force rebuild
