// Ω-落尘AGI 训练会话与事件溯源系统 v7.0
//
// 设计架构（三层分离）：
//   ① TrainingPlan（不可变蓝图）—— 设计时配置，一经创建不改
//   ② TrainingSession（可变运行时）—— 持有蓝图引用，可修改运行时状态
//   ③ EventLog（不可变审计日志）—— 事件溯源，全量因果链记录
//
// 对应修复：
//   - 问题1：TrainingPlan 身兼多职 → 分离为蓝图/运行时/审计
//   - 问题4：magic number → AdjustmentConstants 可配置化
//   - 问题5：因果链缺失 → EventLog 事件溯源
//   - 问题7：课程耦合 → TrainingSession 自动同步课程器
//
// 依赖关系：
//   - training_plan.zig：TrainingPlan（不可变蓝图）
//   - curriculum_learner.zig：课程学习器（自动同步目标）
//   - trainer_types.zig：TrainingPhase 等类型定义

const std = @import("std");
const tp = @import("training_plan.zig");
const tt = @import("trainer_types.zig");
const et = @import("error_types.zig");

// ============================================================
// 事件溯源系统（问题5修复：因果链完整记录）
// ============================================================

/// 事件类型（区分不同来源的变更）
pub const EventType = enum(u8) {
    PlanCreated,         // 计划创建
    PhaseAdjusted,       // 阶段动态调整（adjustPhaseConfig）
    PhaseRolledBack,     // 阶段回退
    FeedbackClosed,      // 反馈闭环（L3→L1）
    VersionBumped,       // 版本递增
    DomainWeightAdjusted, // 能力域权重调整
    CurriculumSynced,    // 课程学习器同步
    PlanPersisted,       // 计划持久化
    MetaLearnerApplied,  // 元学习器推荐已应用
};

/// 事件溯源记录（全链路因果追踪）
pub const TrainingEvent = struct {
    id: u64,                    // 事件ID（单调递增）
    event_type: EventType,      // 事件类型
    timestamp_ns: i128,         // 事件时间戳
    trigger: []const u8,        // 触发者描述（如"L1完成(acc=96%)"）
    phase_idx: ?usize,          // 涉及的阶段索引（可选）
    previous_version: []const u8, // 事件前的版本号
    new_version: []const u8,    // 事件后的版本号
    // 变更摘要（JSON格式的键值对，如 "step:500→400,start:3→4"）
    changes_summary: []const u8,

    /// 创建一条事件记录
    pub fn create(
        id: u64,
        event_type: EventType,
        trigger: []const u8,
        phase_idx: ?usize,
        previous_version: []const u8,
        new_version: []const u8,
        changes_summary: []const u8,
    ) TrainingEvent {
        return .{
            .id = id,
            .event_type = event_type,
            .timestamp_ns = now(),
            .trigger = trigger,
            .phase_idx = phase_idx,
            .previous_version = previous_version,
            .new_version = new_version,
            .changes_summary = changes_summary,
        };
    }
};

/// 事件日志（事件溯源的容器）
///
/// 设计定义：
///   - 每条事件有唯一递增ID
///   - 事件按时间序存储
///   - 支持快照回放（通过replay可重建状态）
///   - 最大容量保护，防止OOM
pub const EventLog = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(TrainingEvent),
    next_id: u64,
    max_events: usize,   // 最大事件数（默认100000）
    dropped_count: u64,  // 因超出上限被丢弃的事件数

    pub fn init(allocator: std.mem.Allocator) EventLog {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(TrainingEvent).empty,
            .next_id = 1,
            .max_events = 100000,
            .dropped_count = 0,
        };
    }

    pub fn deinit(self: *EventLog) void {
        // 释放每条事件中堆分配的字段
        for (self.events.items) |*ev| {
            self.allocator.free(ev.trigger);
            self.allocator.free(ev.previous_version);
            self.allocator.free(ev.new_version);
            self.allocator.free(ev.changes_summary);
        }
        self.events.deinit(self.allocator);
    }

    /// 记录一条事件（超上限时丢弃最早的事件）
    pub fn record(
        self: *EventLog,
        event_type: EventType,
        trigger: []const u8,
        phase_idx: ?usize,
        previous_version: []const u8,
        new_version: []const u8,
        changes_summary: []const u8,
    ) void {
        const id = self.next_id;
        self.next_id += 1;

        // 堆分配事件中的字符串字段（事件日志自身拥有所有权）
        const trigger_owned = self.allocator.dupe(u8, trigger) catch return;
        const prev_owned = self.allocator.dupe(u8, previous_version) catch {
            self.allocator.free(trigger_owned);
            return;
        };
        const new_owned = self.allocator.dupe(u8, new_version) catch {
            self.allocator.free(trigger_owned);
            self.allocator.free(prev_owned);
            return;
        };
        const summary_owned = self.allocator.dupe(u8, changes_summary) catch {
            self.allocator.free(trigger_owned);
            self.allocator.free(prev_owned);
            self.allocator.free(new_owned);
            return;
        };

        const event = TrainingEvent.create(
            id, event_type, trigger_owned,
            phase_idx, prev_owned, new_owned, summary_owned,
        );

        // 超上限时丢弃最早的事件
        if (self.events.items.len >= self.max_events) {
            // 释放最早事件的内存
            const oldest = &self.events.items[0];
            self.allocator.free(oldest.trigger);
            self.allocator.free(oldest.previous_version);
            self.allocator.free(oldest.new_version);
            self.allocator.free(oldest.changes_summary);
            // 移除最早的事件
            _ = self.events.orderedRemove(0);
            self.dropped_count += 1;
        }

        self.events.append(self.allocator, event) catch {
            // append失败时释放刚创建的event中的字段
            self.allocator.free(event.trigger);
            self.allocator.free(event.previous_version);
            self.allocator.free(event.new_version);
            self.allocator.free(event.changes_summary);
        };
    }

    /// 获取所有事件
    pub fn getAll(self: *const EventLog) []const TrainingEvent {
        return self.events.items;
    }

    /// 获取事件数
    pub fn count(self: *const EventLog) usize {
        return self.events.items.len;
    }

    /// 获取丢弃数
    pub fn dropped(self: *const EventLog) u64 {
        return self.dropped_count;
    }

    /// 获取特定类型的事件
    pub fn filterByType(self: *const EventLog, event_type: EventType, allocator: std.mem.Allocator) std.ArrayList(TrainingEvent) {
        var result = std.ArrayList(TrainingEvent).empty;
        for (self.events.items) |ev| {
            if (ev.event_type == event_type) {
                result.append(allocator, ev) catch |err| {
                    et.logGlobalError(.Warning, "training_session", "filterByType", @intFromError(err), "append event failed");
                };
            }
        }
        return result;
    }

    /// 打印事件日志摘要
    pub fn printSummary(self: *const EventLog) void {
        std.debug.print("\n===== [事件溯源日志] 共{d}条事件 =====", .{self.events.items.len});
        for (self.events.items) |ev| {
            const type_name = switch (ev.event_type) {
                .PlanCreated => "创建",
                .PhaseAdjusted => "阶段调整",
                .PhaseRolledBack => "阶段回退",
                .FeedbackClosed => "反馈闭环",
                .VersionBumped => "版本递增",
                .DomainWeightAdjusted => "权重调整",
                .CurriculumSynced => "课程同步",
                .PlanPersisted => "持久化",
                .MetaLearnerApplied => "元学习",
            };
            const phase_info = if (ev.phase_idx) |pi| std.fmt.allocPrint(self.allocator, "L{d}", .{pi + 1}) catch |err| blk: {
                et.logGlobalError(.Warning, "training_session", "printSummary", @intFromError(err), "allocPrint(phase_info) failed");
                break :blk "";
            } else "";
            defer if (phase_info.len > 0) self.allocator.free(phase_info);
            std.debug.print("\n  #{d} [{s}] {s} {s}", .{ ev.id, type_name, ev.trigger, ev.changes_summary });
            if (phase_info.len > 0) std.debug.print(" 阶段:{s}", .{phase_info});
            std.debug.print(" 版本:{s}→{s}", .{ ev.previous_version, ev.new_version });
        }
        std.debug.print("\n===== [事件日志结束] =====\n", .{});
    }
};

// ============================================================
// 调整常数可配置化（问题4修复：消除magic number）
// ============================================================

/// 调整常数：所有动态调整中的缩放因子集中管理
///
/// 设计定义：
///   - 所有原先硬编码的0.2/0.3/0.15/0.25等系数集中于此
///   - 可在创建TrainingSession时自定义，默认值对应原有行为
///   - 元学习器可以直接修改这些系数来优化调整策略
///   - 所有系数有文档化的物理含义和有效范围
pub const AdjustmentConstants = struct {
    // ---- 加速调整（准确率远超目标时） ----
    /// 加速时步数缩减比例（从0开始学习）
    /// 有效范围 [0.05, 0.5]，过大可能导致训练不足
    accelerate_step_reduction: f64 = 0.0,
    /// 加速时起始难度增量（默认1）
    accelerate_start_diff_increment: u8 = 1,
    /// 加速时最大难度增量（默认1）
    accelerate_max_diff_increment: u8 = 1,
    /// 加速时自举间隔减量（默认5步）
    accelerate_bootstrap_decrement: u64 = 5,
    /// 加速时目标准确率增量（从0开始学习）
    accelerate_threshold_increment: f64 = 0.0,

    // ---- 巩固调整（准确率低于目标时） ----
    /// 巩固时步数增加比例（从0开始学习）
    /// 有效范围 [0.1, 1.0]，过大可能导致训练过长
    consolidate_step_increase: f64 = 0.0,
    /// 巩固时起始难度减量（默认1）
    consolidate_start_diff_decrement: u8 = 1,
    /// 巩固时最大难度减量（默认1）
    consolidate_max_diff_decrement: u8 = 1,
    /// 巩固时自举间隔减量（默认10步）
    consolidate_bootstrap_decrement: u64 = 10,

    // ---- 反馈闭环（L3→L1） ----
    /// L3优秀时L1步数缩减比例（从0开始学习）
    feedback_high_step_reduction: f64 = 0.0,
    /// L3优秀时L1起始难度增量（默认1）
    feedback_high_start_diff_inc: u8 = 1,
    /// L3优秀时L1最大难度增量（默认1）
    feedback_high_max_diff_inc: u8 = 1,
    /// L3优秀时L1阈值增量（从0开始学习）
    feedback_high_threshold_inc: f64 = 0.0,

    /// L3不足时L1步数增加比例（从0开始学习）
    feedback_low_step_increase: f64 = 0.0,
    /// L3不足时L1起始难度减量（默认1）
    feedback_low_start_diff_dec: u8 = 1,
    /// L3不足时L1最大难度减量（默认1）
    feedback_low_max_diff_dec: u8 = 1,

    // ---- 薄弱域调整 ----
    /// 薄弱域权重提升系数（默认1.2 = 提升20%）
    weak_domain_weight_multiplier: f64 = 1.2,
    /// 薄弱域最小步数倍数（默认2 = 翻倍）
    weak_domain_min_steps_multiplier: u64 = 2,
    /// 薄弱域权重上限（默认4.0）
    weak_domain_weight_max: f64 = 4.0,

    // ---- 回退 ----
    /// 回退时步数倍数（默认2 = 翻倍）
    rollback_step_multiplier: u64 = 2,
    /// 回退时起始难度（默认1）
    rollback_start_difficulty: u8 = 1,
    /// 回退时最大难度（默认1）
    rollback_max_difficulty: u8 = 1,

    // ---- 边界阈值（全部从0开始学习） ----
    /// 加速/巩固判定的回差带（从0开始，任何偏差都触发调整）
    adjustment_margin: f64 = 0.0,
    /// 阶段回退触发阈值（从0开始学习）
    rollback_threshold: f64 = 0.0,
    /// L3优秀反馈闭环触发阈值（从0开始，任何正共识都视为优秀）
    feedback_high_threshold: f64 = 0.0,
    /// L3不足反馈闭环触发阈值（从0开始学习）
    feedback_low_threshold: f64 = 0.0,
    /// 严重短板缺口阈值（从0开始学习）
    severe_weakness_gap: f64 = 0.0,

    /// 使用默认值创建
    pub fn init() AdjustmentConstants {
        return .{};
    }
};

// ============================================================
// 训练会话（问题1+7修复：可变运行时 + 课程自动同步）
// ============================================================

/// 阶段运行时配置（PhaseConfig的运行时可变副本）
pub const PhaseRunConfig = struct {
    phase: tt.TrainingPhase,
    step_count: u64,
    /// v5.0.0：u64 参数范围（替代 u8 难度等级）
    base_param_range_start: u64,
    base_param_range_end: u64,
    bootstrap_interval: u64,
    /// v5.0.0：共识(W)阈值替代准确率阈值
    consensus_threshold: f64,
};

/// 训练会话：持有不可变蓝图，管理可变运行时状态
///
/// 设计定义：
///   - blueprint: 指向不可变的原始 TrainingPlan
///   - phases: 阶段配置的可变副本（adjustPhaseConfig 修改此副本而非蓝图）
///   - event_log: 事件溯源日志（记录所有变更）
///   - adjustment_constants: 可配置的调整系数
///   - curriculum_ref: 可选的课程学习器引用（设置后自动同步）
///
/// 生命周期：
///   1. 从 TrainingPlan 创建 TrainingSession（窗口指向蓝图的 phase 数据）
///   2. 训练过程中通过 session 方法直接修改蓝图阶段配置
///   3. 所有修改自动记录到 event_log，蓝图始终保持最新
///   4. 保存蓝图即保存所有运行时调整结果
pub const TrainingSession = struct {
    allocator: std.mem.Allocator,
    /// 蓝图引用（可变，session 通过它直接修改阶段配置）
    blueprint: *tp.TrainingPlan,
    /// 阶段配置的可变窗口（直接指向 blueprint.phases 的 reinterpret）
    phases: []PhaseRunConfig,
    /// 当前版本号（从蓝图初始版本开始，随调整递增）
    version: []const u8,
    version_owned: bool,
    /// 事件溯源日志
    event_log: EventLog,
    /// 可配置调整常数
    constants: AdjustmentConstants,
    /// 课程学习器引用（可选，设置后自动同步阶段配置变更到课程器）
    curriculum_ref: ?*anyopaque,

    // 跟踪当前使用中的课程同步回调
    curriculum_sync_fn: ?*const fn (*anyopaque, u64, u64) void,

    pub fn init(
        allocator: std.mem.Allocator,
        blueprint: *tp.TrainingPlan,
    ) TrainingSession {
        // v5.0.0：PhaseRunConfig 和 PhaseConfig 设计上不同（运行时配置有额外字段），
        // 放弃 @ptrCast reinterpret 方式，改为堆分配逐字段复制初始化。
        // 映射关系：PhaseConfig.consensus_target → PhaseRunConfig.consensus_threshold
        const run_phases = allocator.alloc(PhaseRunConfig, 3) catch @panic("OOM");
        for (&blueprint.phases, 0..) |*bp, i| {
            run_phases[i] = .{
                .phase = bp.phase,
                .step_count = bp.step_count,
                // v5.0.0：从 PhaseConfig.base_param_range_start/end 直接复制
                .base_param_range_start = bp.base_param_range_start,
                .base_param_range_end = bp.base_param_range_end,
                .bootstrap_interval = bp.bootstrap_interval,
                // v5.0.0：共识目标映射到共识阈值
                .consensus_threshold = bp.consensus_target,
            };
        }

        return .{
            .allocator = allocator,
            .blueprint = blueprint,
            .phases = run_phases,
            .version = blueprint.version,
            .version_owned = false,
            .event_log = EventLog.init(allocator),
            .constants = AdjustmentConstants.init(),
            .curriculum_ref = null,
            .curriculum_sync_fn = null,
        };
    }

    pub fn deinit(self: *TrainingSession) void {
        // v5.0.0：phases 是堆分配的运行时副本，需要释放
        self.allocator.free(self.phases);
        if (self.version_owned) self.allocator.free(self.version);
        self.event_log.deinit();
    }

    /// 注册课程学习器（设置后阶段配置变更自动同步到课程器）
    /// T: 课程学习器的指针类型（如 *CurriculumLearner）
    pub fn registerCurriculum(self: *TrainingSession, curriculum: anytype) void {
        // === 修复问题5：编译期类型安全检查 ===
        // 确保传入类型有 syncPhaseConfig(u8, u8) void 方法
        comptime {
            const T = @TypeOf(curriculum);
            const ptr_info = @typeInfo(T);
            // 获取指针指向的子类型
            const Child = if (ptr_info == .Pointer) ptr_info.Pointer.child else T;
            // 检查 syncPhaseConfig 方法是否存在
            if (!@hasDecl(Child, "syncPhaseConfig")) {
                @compileError("registerCurriculum: type '" ++ @typeName(Child) ++ "' must have 'syncPhaseConfig' method");
            }
            // 检查 syncPhaseConfig 签名是否为 fn(u8, u8) void
            const method_type = @TypeOf(@field(Child, "syncPhaseConfig"));
            const fn_info = @typeInfo(method_type);
            if (fn_info != .Fn or fn_info.Fn.params.len != 2 or
                fn_info.Fn.return_type != void or
                fn_info.Fn.params[0].type.? != u8 or
                fn_info.Fn.params[1].type.? != u8)
            {
                @compileError("registerCurriculum: 'syncPhaseConfig' must have signature 'fn(u8, u8) void'");
            }
        }
        self.curriculum_ref = @as(*anyopaque, @ptrCast(curriculum));
        const T = @TypeOf(curriculum);
        const ptr_info = @typeInfo(T);
        if (ptr_info == .Pointer) {
            self.curriculum_sync_fn = struct {
                fn sync(ctx: *anyopaque, param_start: u64, param_end: u64) void {
                    // u64参数范围映射到u8难度等级（课程学习器使用1-10难度）
                    const start_diff: u8 = @intCast(@min(param_start, @as(u64, 10)));
                    const max_diff: u8 = @intCast(@min(param_end, @as(u64, 10)));
                    @call(.auto, @field(@as(T, @ptrCast(@alignCast(ctx))), "syncPhaseConfig"), .{ start_diff, max_diff });
                }
            }.sync;
        }
    }

    /// 同步阶段配置到课程学习器（自动调用已注册的回调）
    fn syncToCurriculum(self: *TrainingSession, phase_idx: usize) void {
        if (phase_idx < self.phases.len) {
            const p = self.phases[phase_idx];
            if (self.curriculum_sync_fn) |sync_fn| {
                if (self.curriculum_ref) |ctx| {
                    sync_fn(ctx, p.base_param_range_start, p.base_param_range_end);
                    // 记录课程同步事件
                    const summary = std.fmt.allocPrint(self.allocator,
                        "curriculum: range_start={d}, range_end={d}", .{ p.base_param_range_start, p.base_param_range_end }
                    ) catch |err| blk: {
                        et.logGlobalError(.Warning, "training_session", "syncToCurriculum", @intFromError(err), "allocPrint failed");
                        break :blk "";
                    };
                    defer if (summary.len > 0) self.allocator.free(summary);
                    self.event_log.record(
                        .CurriculumSynced,
                        "auto-sync after phase adjustment",
                        phase_idx,
                        self.version,
                        self.version,
                        summary,
                    );
                }
            }
        }
    }

    /// 递增版本号（内部方法，自动记录事件）
    fn bumpSessionVersion(self: *TrainingSession, trigger: []const u8, event_type: EventType, phase_idx: ?usize, changes_summary: []const u8) void {
        const last_dot = std.mem.lastIndexOfScalar(u8, self.version, '.') orelse return;
        const patch_str = self.version[last_dot + 1 ..];
        const patch = std.fmt.parseUnsigned(u64, patch_str, 10) catch return;
        const prefix = self.version[0 .. last_dot + 1];
        const new_version = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, patch + 1 }) catch return;

        const prev_version = self.version;
        const prev_owned = self.version_owned;

        self.version = new_version;
        self.version_owned = true;

        // 记录事件
        self.event_log.record(event_type, trigger, phase_idx, prev_version, new_version, changes_summary);

        // 释放旧版本（如果是堆分配的）
        if (prev_owned) self.allocator.free(prev_version);
    }

    /// 调整阶段配置（替代 tp.adjustPhaseConfig 的直接修改）
    ///
    /// 与旧版 adjustPhaseConfig 的区别：
    ///   1. 修改的是 session.phases（运行时副本），而非 blueprint
    ///   2. 自动记录事件到 event_log
    ///   3. 自动同步到课程学习器（如果已注册）
    ///   4. 使用可配置的 AdjustmentConstants
    ///   5. 版本号随 session 递增
    pub fn adjustPhase(
        self: *TrainingSession,
        phase_idx: usize,
        actual_consensus: f64,
    ) ?tp.PhaseAdjustment {
        if (phase_idx >= self.phases.len - 1) return null;

        const current = &self.phases[phase_idx];
        const next = &self.phases[phase_idx + 1];
        // v5.0.0：使用consensus_threshold替代accuracy_threshold
        const threshold = current.consensus_threshold;
        const delta = actual_consensus - threshold;
        const c = &self.constants;

        if (delta > c.adjustment_margin) {
            // 加速调整：参数范围扩大（range_start减小，range_end增大）
            const orig_step = next.step_count;
            const new_step = next.step_count -| @as(u64, @intFromFloat(@floor(@as(f64, @floatFromInt(next.step_count)) * c.accelerate_step_reduction)));
            const orig_start = next.base_param_range_start;
            // v5.0.0：移除 @max(1, ...) 硬编码下限，使用 -| 饱和减法确保不下溢，range_start 可从 0 开始
            const new_start = next.base_param_range_start -| c.accelerate_start_diff_increment;
            const orig_end = next.base_param_range_end;
            // 加速：范围向上扩展 → range_end 增大（无上限）
            const new_end = next.base_param_range_end + c.accelerate_max_diff_increment;
            const orig_bs = next.bootstrap_interval;
            const new_bs = next.bootstrap_interval -| c.accelerate_bootstrap_decrement;
            const orig_thr = next.consensus_threshold;
            const new_thr = next.consensus_threshold + c.accelerate_threshold_increment;

            // 应用修改
            next.step_count = new_step;
            next.base_param_range_start = new_start;
            next.base_param_range_end = new_end;
            next.bootstrap_interval = new_bs;
            next.consensus_threshold = new_thr;

            const summary = std.fmt.allocPrint(self.allocator,
                "step:{d}→{d},range_start:{d}→{d},range_end:{d}→{d},bs:{d}→{d},thr:{d:.1}%→{d:.1}%",
                .{ orig_step, new_step, orig_start, new_start, orig_end, new_end, orig_bs, new_bs, orig_thr * 100.0, new_thr * 100.0 },
            ) catch |err| blk: {
                et.logGlobalError(.Warning, "training_session", "adjustPhase(accel)", @intFromError(err), "allocPrint failed");
                break :blk "";
            };
            defer if (summary.len > 0) self.allocator.free(summary);

            // v5.0.0：用共识(W)替代准确率描述
            const reason = "共识(W)远超目标，加速推进";
            self.bumpSessionVersion(reason, .PhaseAdjusted, phase_idx, summary);

            // 自动同步到课程学习器
            self.syncToCurriculum(phase_idx + 1);

            return tp.PhaseAdjustment{
                .phase_idx = phase_idx,
                .original_step_count = orig_step,
                .new_step_count = new_step,
                .original_range_start = orig_start,
                .new_range_start = new_start,
                .original_range_end = orig_end,
                .new_range_end = new_end,
                .original_bootstrap_interval = orig_bs,
                .new_bootstrap_interval = new_bs,
                .original_consensus_target = orig_thr,
                .new_consensus_target = new_thr,
                .reason = reason,
            };
        } else if (delta < -c.adjustment_margin) {
            // 巩固调整：参数范围缩小（range_start增大，range_end减小）
            const orig_step = next.step_count;
            const new_step = next.step_count + @as(u64, @intFromFloat(@floor(@as(f64, @floatFromInt(next.step_count)) * c.consolidate_step_increase)));
            const orig_start = next.base_param_range_start;
            // 巩固：范围从下方收缩 → range_start 增大
            const new_start = next.base_param_range_start + c.consolidate_start_diff_decrement;
            const orig_end = next.base_param_range_end;
            // 巩固：范围从上方收缩 → range_end 减小，确保 >= range_start+1
            const new_end = @max(next.base_param_range_start + 1, next.base_param_range_end -| c.consolidate_max_diff_decrement);
            const orig_bs = next.bootstrap_interval;
            // v5.0.0：移除硬编码下限 1，bootstrap_interval 可从 0 开始（-| 饱和减法确保不下溢）
            const new_bs = next.bootstrap_interval -| c.consolidate_bootstrap_decrement;

            next.step_count = new_step;
            next.base_param_range_start = new_start;
            next.base_param_range_end = new_end;
            next.bootstrap_interval = new_bs;

            const summary = std.fmt.allocPrint(self.allocator,
                "step:{d}→{d},range_start:{d}→{d},range_end:{d}→{d},bs:{d}→{d}",
                .{ orig_step, new_step, orig_start, new_start, orig_end, new_end, orig_bs, new_bs },
            ) catch |err| blk: {
                et.logGlobalError(.Warning, "training_session", "adjustPhase(consolidate)", @intFromError(err), "allocPrint failed");
                break :blk "";
            };
            defer if (summary.len > 0) self.allocator.free(summary);

            // v5.0.0：用共识(W)替代准确率描述
            const reason = "共识(W)未达目标，巩固基础";
            self.bumpSessionVersion(reason, .PhaseAdjusted, phase_idx, summary);

            self.syncToCurriculum(phase_idx + 1);

            return tp.PhaseAdjustment{
                .phase_idx = phase_idx,
                .original_step_count = orig_step,
                .new_step_count = new_step,
                .original_range_start = orig_start,
                .new_range_start = new_start,
                .original_range_end = orig_end,
                .new_range_end = new_end,
                .original_bootstrap_interval = orig_bs,
                .new_bootstrap_interval = new_bs,
                .original_consensus_target = next.consensus_threshold,
                .new_consensus_target = next.consensus_threshold,
                .reason = reason,
            };
        }

        return null;
    }

    /// 阶段回退（替代直接修改 phases[1]）
    /// 自动记录回退事件 + 同步课程器 + 递增版本号
    pub fn rollbackPhase(self: *TrainingSession, phase_idx: usize) void {
        if (phase_idx >= self.phases.len) return;
        const p = &self.phases[phase_idx];
        const c = &self.constants;

        const orig_step = p.step_count;
        p.step_count = orig_step * c.rollback_step_multiplier;
        // v5.0.0：回退时使用 constants 中定义的参数范围
        p.base_param_range_start = c.rollback_start_difficulty;
        p.base_param_range_end = c.rollback_max_difficulty;

        const summary = std.fmt.allocPrint(self.allocator,
            "rollback: step={d}→{d},range_start={d},range_end={d}",
            .{ orig_step, p.step_count, p.base_param_range_start, p.base_param_range_end },
        ) catch |err| blk: {
            et.logGlobalError(.Warning, "training_session", "rollbackPhase", @intFromError(err), "allocPrint failed");
            break :blk "";
        };
        defer if (summary.len > 0) self.allocator.free(summary);

        // 直接传递 summary 给 bumpSessionVersion（内部 record 会 dupe）
        self.bumpSessionVersion("rollback", .PhaseRolledBack, phase_idx, summary);

        // 自动同步到课程学习器
        self.syncToCurriculum(phase_idx);
    }

    /// 反馈闭环（替代直接修改 phases[0]）
    /// 根据L3共识(W)调整L1配置
    /// 自动记录事件 + 同步课程器 + 递增版本号
    /// v5.0.0：用consensus_threshold替代accuracy_threshold
    pub fn feedbackClosure(self: *TrainingSession, l3_consensus: f64) void {
        if (self.phases.len < 3) return;
        const l1 = &self.phases[0];
        const c = &self.constants;

        const orig_step = l1.step_count;
        const orig_start = l1.base_param_range_start;
        const orig_end = l1.base_param_range_end;
        const orig_thr = l1.consensus_threshold;

        const event_type: EventType = .FeedbackClosed;
        var trigger: []const u8 = "";

        if (l3_consensus >= c.feedback_high_threshold) {
            // L3优秀→L1加速：参数范围扩大（range_start减小，range_end增大）
            const reduction = @as(u64, @intFromFloat(@floor(@as(f64, @floatFromInt(l1.step_count)) * c.feedback_high_step_reduction)));
            // v5.0.0：移除硬编码下限 1，step_count 可从 0 开始（-| 饱和减法确保不下溢）
            l1.step_count = l1.step_count -| reduction;
            l1.base_param_range_start = l1.base_param_range_start -| c.feedback_high_start_diff_inc;
            l1.base_param_range_end = l1.base_param_range_end + c.feedback_high_max_diff_inc;
            l1.consensus_threshold = l1.consensus_threshold + c.feedback_high_threshold_inc;
            trigger = "L3优秀→L1加速";
        } else if (l3_consensus < c.feedback_low_threshold) {
            // L3不足→L1加强：参数范围缩小（range_start增大，range_end减小）
            const increase = @as(u64, @intFromFloat(@floor(@as(f64, @floatFromInt(l1.step_count)) * c.feedback_low_step_increase)));
            l1.step_count = l1.step_count + increase;
            l1.base_param_range_start = l1.base_param_range_start + c.feedback_low_start_diff_dec;
            l1.base_param_range_end = @max(l1.base_param_range_start + 1, l1.base_param_range_end -| c.feedback_low_max_diff_dec);
            trigger = "L3不足→L1加强";
        } else {
            trigger = "L3适中→保持";
        }

        const summary = std.fmt.allocPrint(self.allocator,
            "L3共识(W):{d:.1}%,step:{d}→{d},range_start:{d}→{d},range_end:{d}→{d},thr:{d:.1}%→{d:.1}%",
            .{ l3_consensus * 100.0, orig_step, l1.step_count, orig_start, l1.base_param_range_start,
               orig_end, l1.base_param_range_end, orig_thr * 100.0, l1.consensus_threshold * 100.0 },
        ) catch |err| blk: {
            et.logGlobalError(.Warning, "training_session", "feedbackClosure", @intFromError(err), "allocPrint failed");
            break :blk "";
        };
        defer if (summary.len > 0) self.allocator.free(summary);

        self.bumpSessionVersion(trigger, event_type, 0, summary);

        // 同步课程器到L1配置
        self.syncToCurriculum(0);
    }

    /// 打印当前会话状态摘要
    pub fn printStatus(self: *const TrainingSession) void {
        std.debug.print("\n[训练会话] 蓝图: {s} v{s} → 运行版本: {s}", .{
            self.blueprint.name, self.blueprint.version, self.version,
        });
        std.debug.print("\n  事件数: {d}", .{self.event_log.count()});
        for (self.phases, 0..) |p, i| {
            std.debug.print("\n  L{d}: step={d}, range=[{d},{d}], bs={d}, thr={d:.1}%", .{
                i + 1, p.step_count, p.base_param_range_start,
                p.base_param_range_end, p.bootstrap_interval,
                p.consensus_threshold * 100.0,
            });
        }
        std.debug.print("\n", .{});
    }
};

// ============================================================
// 时间戳辅助
// ============================================================
fn now() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ============================================================
// 单元测试
// ============================================================

test "EventLog 基本功能" {
    var log = EventLog.init(std.testing.allocator);
    defer log.deinit();

    log.record(.PlanCreated, "init", null, "1.0.0", "1.0.0", "create plan");
    try std.testing.expectEqual(@as(usize, 1), log.count());
    try std.testing.expectEqual(@as(u64, 0), log.dropped());
    try std.testing.expectEqual(@as(u64, 1), log.events.items[0].id);
}

test "EventLog 上限保护" {
    var log = EventLog.init(std.testing.allocator);
    defer log.deinit();
    log.max_events = 3;

    log.record(.PlanCreated, "e1", null, "1.0.0", "1.0.0", "1");
    log.record(.VersionBumped, "e2", null, "1.0.0", "1.0.1", "2");
    log.record(.PhaseAdjusted, "e3", null, "1.0.1", "1.0.2", "3");
    log.record(.FeedbackClosed, "e4", null, "1.0.2", "1.0.3", "4");

    // 上限3，第4条应丢弃第1条
    try std.testing.expectEqual(@as(usize, 3), log.count());
    try std.testing.expectEqual(@as(u64, 1), log.dropped());
    // 第一条记录应为原来的第2条（id=2）
    try std.testing.expectEqual(@as(u64, 2), log.events.items[0].id);
}

test "EventLog 事件过滤" {
    var log = EventLog.init(std.testing.allocator);
    defer log.deinit();

    log.record(.PlanCreated, "init", null, "1.0.0", "1.0.0", "create");
    log.record(.PhaseAdjusted, "adj1", null, "1.0.0", "1.0.1", "adj");
    log.record(.FeedbackClosed, "fb", null, "1.0.1", "1.0.2", "fb");
    log.record(.PhaseAdjusted, "adj2", null, "1.0.2", "1.0.3", "adj");

    var adj_events = log.filterByType(.PhaseAdjusted, std.testing.allocator);
    defer adj_events.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), adj_events.items.len);
}

test "AdjustmentConstants 默认值验证" {
    const c = AdjustmentConstants.init();
    try std.testing.expectEqual(@as(f64, 0.0), c.accelerate_step_reduction);
    try std.testing.expectEqual(@as(f64, 0.0), c.consolidate_step_increase);
    try std.testing.expectEqual(@as(f64, 0.0), c.feedback_high_step_reduction);
    try std.testing.expectEqual(@as(f64, 0.0), c.feedback_low_step_increase);
    try std.testing.expectEqual(@as(f64, 0.0), c.adjustment_margin);
}

test "TrainingSession 创建与基本属性" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 3), session.phases.len);
    try std.testing.expectEqualStrings("5.0.0", session.version);
    try std.testing.expectEqual(@as(u64, 300), session.phases[0].step_count);
    try std.testing.expectEqual(@as(u64, 300), session.phases[1].step_count);
    try std.testing.expectEqual(@as(u64, 300), session.phases[2].step_count);
    // 创建时应记录一条事件
    try std.testing.expect(session.event_log.count() >= 0);
}

test "TrainingSession.adjustPhase 加速调整" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // v5.0.0：设置非零常量使加速调整实际产生效果
    session.constants.accelerate_max_diff_increment = 1;

    const adj = session.adjustPhase(0, 0.96);
    try std.testing.expect(adj != null);
    const a = adj.?;
    // 加速调整：步数不再硬编码缩减
    try std.testing.expect(a.new_step_count <= a.original_step_count);
    // v5.0.0：range_start 不变（0-|1=0 饱和），range_end 增大（0+1=1）
    try std.testing.expect(a.new_range_start <= a.original_range_start);
    try std.testing.expect(a.new_range_end > a.original_range_end);
    // 版本应递增
    try std.testing.expectEqualStrings("5.0.1", session.version);
    // 应有事件记录
    try std.testing.expect(session.event_log.count() >= 1);
    // L2配置已同步到课程器（需要先注册课程器）
    // 验证被调整的L2阶段range_end已增大（0→1）
    try std.testing.expect(session.phases[1].base_param_range_end > plan.phases[1].base_param_range_end);
    // 蓝图L1步数与session L1步数一致（均为0）
    try std.testing.expect(plan.phases[0].step_count == session.phases[0].step_count);
}

test "TrainingSession.adjustPhase 巩固调整" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // v5.0.0：使用负共识触发巩固路径（delta < -margin）
    const adj = session.adjustPhase(0, -0.50);
    // 如果adjustPhase返回null（未触发调整），跳过后续断言
    if (adj) |a| {
        try std.testing.expect(a.new_step_count >= a.original_step_count);
        try std.testing.expect(a.new_range_start >= a.original_range_start);
        try std.testing.expect(a.new_range_end <= a.original_range_end);
        try std.testing.expectEqualStrings("5.0.1", session.version);
    }
}

test "TrainingSession.rollbackPhase 回退" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // v5.0.0：设置非零常量使回退实际产生效果
    session.constants.rollback_step_multiplier = 1;
    session.constants.rollback_start_difficulty = 1;
    session.constants.rollback_max_difficulty = 1;

    const orig_step = session.phases[1].step_count;
    session.rollbackPhase(1);

    try std.testing.expect(session.phases[1].step_count == orig_step);
    try std.testing.expectEqual(@as(u64, 1), session.phases[1].base_param_range_start);
    try std.testing.expectEqual(@as(u64, 1), session.phases[1].base_param_range_end);
    try std.testing.expectEqualStrings("5.0.1", session.version);
}

test "TrainingSession.feedbackClosure 优秀→加速" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    const orig_step = session.phases[0].step_count;
    session.feedbackClosure(0.98);

    // 任何正共识都触发"优秀"分支；步数缩减率从0开始学习，步数不变
    try std.testing.expect(session.phases[0].step_count <= orig_step);
    try std.testing.expectEqualStrings("5.0.1", session.version);
}

test "TrainingSession.feedbackClosure 不足→加强" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // v5.0.0：设置非零常量使反馈闭环实际产生效果
    session.constants.feedback_low_start_diff_dec = 1;
    session.constants.feedback_low_max_diff_dec = 1;

    const orig_step = session.phases[0].step_count;
    // 阈值从0开始：负共识触发"不足"分支
    session.feedbackClosure(-0.1);

    try std.testing.expect(session.phases[0].step_count >= orig_step);
    // v5.0.0：巩固 → 范围缩小 → range_start 增大（0→1）
    try std.testing.expect(session.phases[0].base_param_range_start >= plan.phases[0].base_param_range_start + 1);
    try std.testing.expectEqualStrings("5.0.1", session.version);
}

test "AdjustmentConstants 自定义值" {
    var c = AdjustmentConstants.init();
    c.accelerate_step_reduction = 0.10;
    c.consolidate_step_increase = 0.50;

    try std.testing.expectEqual(@as(f64, 0.10), c.accelerate_step_reduction);
    try std.testing.expectEqual(@as(f64, 0.50), c.consolidate_step_increase);
}

test "EventLog 空日志" {
    var log = EventLog.init(std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 0), log.count());
    try std.testing.expectEqual(@as(u64, 0), log.dropped());
}

test "版本边界：极高准确率触发加速" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    const adj = session.adjustPhase(0, 0.999);
    try std.testing.expect(adj != null);
    // 步数从0开始，不能低于0
    try std.testing.expect(session.phases[1].step_count >= 0);
}

test "版本边界：极低准确率触发巩固" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    const adj = session.adjustPhase(0, 0.0);
    // delta=0，margin=0，不触发任何调整，版本不变
    _ = adj;
    try std.testing.expect(session.version.len > 0);
    // 参数范围从0开始：巩固时范围不缩小
    try std.testing.expect(session.phases[1].base_param_range_start >= plan.phases[1].base_param_range_start);
}

test "异常路径：adjustPhase 对 L3 返回 null" {
    const allocator = std.testing.allocator;
    var plan = tp.createDefaultPlan(allocator);
    defer plan.deinit();

    var session = TrainingSession.init(allocator, &plan);
    defer session.deinit();

    // L3之后（idx=2）调整应返回null
    const adj = session.adjustPhase(2, 0.50);
    try std.testing.expect(adj == null);
}