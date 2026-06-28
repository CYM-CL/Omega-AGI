// Ω-落尘AGI 种子核 (Seed Kernel) v5.1 — 清理版
//
// 仅保留：公理校验、格运算、自洽性校验、安全管控
// 已移除：标量Δ运算、梯度下降、自指算子、不动点、自由能计算
// 对应职能均已迁移至 Zig CDL 表达式引擎 (cdl_expr.zig + delta_engine.zig)

use std::collections::HashMap;

// ============ 核心强类型 ============

pub type ObjectId = u64;

pub type MorphismId = u64;

pub type Morphism2Id = u64;

pub type RealValue = f64;

// ============ 数据结构 ============

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Object {
    pub id: ObjectId,
    pub value: RealValue,
    pub frozen: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Morphism {
    pub source: ObjectId,
    pub target: ObjectId,
    pub morphism_id: MorphismId,
    pub delta: RealValue,
    pub security_level: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Morphism2 {
    pub morphism_id: Morphism2Id,
    pub source_morphism: MorphismId,
    pub target_morphism: MorphismId,
    pub rewrite_type: u8,
}

// ============ 校验/报告类型 ============

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConsistencyReport {
    pub total_cycles: u64,
    pub contradictions: u64,
    pub consistency_rate: RealValue,
    pub total_delta_sum: RealValue,
}

#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ConsistencyLevel {
    L1Realtime = 0,
    L2Periodic = 1,
    L3Full = 2,
}

#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SecurityLevel {
    Seed = 0,
    Sandbox = 1,
    Main = 2,
}

// ============ 格运算 ============

pub fn lattice_join(a: RealValue, b: RealValue) -> RealValue {
    if a >= b { a } else { b }
}

pub fn lattice_meet(a: RealValue, b: RealValue) -> RealValue {
    if a <= b { a } else { b }
}

// ============ 自洽性校验 ============

fn build_adjacency_list(morphisms: &[Morphism]) -> HashMap<ObjectId, Vec<(ObjectId, RealValue)>> {
    let mut adj: HashMap<ObjectId, Vec<(ObjectId, RealValue)>> = HashMap::new();
    for m in morphisms {
        adj.entry(m.source).or_default().push((m.target, m.delta));
    }
    adj
}

fn detect_cycles(
    adj: &HashMap<ObjectId, Vec<(ObjectId, RealValue)>>,
    objects: &[Object],
    level: ConsistencyLevel,
    sample_count: u64,
) -> ConsistencyReport {
    let max_samples = sample_count.min(100_000) as usize;
    let mut total_cycles: u64 = 0;
    let mut contradictions: u64 = 0;
    let mut total_delta_sum: RealValue = 0.0;

    let sample_interval = if objects.len() > max_samples {
        (objects.len() / max_samples).max(1)
    } else { 1 };

    for obj_idx in (0..objects.len()).step_by(sample_interval) {
        let start_id = objects[obj_idx].id;
        let mut frontier: Vec<(ObjectId, RealValue, std::collections::HashSet<ObjectId>)> =
            Vec::new();
        let mut visited = std::collections::HashSet::new();
        visited.insert(start_id);
        frontier.push((start_id, 0.0, visited));

        while let Some((current, acc_delta, path_visited)) = frontier.pop() {
            if let Some(neighbors) = adj.get(&current) {
                for &(next_id, step_delta) in neighbors {
                    total_delta_sum += step_delta.abs();
                    if next_id == start_id {
                        total_cycles += 1;
                        if acc_delta.abs() > 1e-6 {
                            contradictions += 1;
                        }
                        continue;
                    }
                    if path_visited.contains(&next_id) { continue; }
                    let mut next_visited = path_visited.clone();
                    next_visited.insert(next_id);
                    frontier.push((next_id, acc_delta + step_delta, next_visited));
                }
            }
        }
    }

    let consistency_rate = if total_cycles > 0 {
        1.0 - (contradictions as RealValue / total_cycles as RealValue)
    } else { 1.0 };
    ConsistencyReport {
        total_cycles,
        contradictions,
        consistency_rate,
        total_delta_sum,
    }
}

// ============ 公理校验 ============

pub fn axiom_check_structure(objects: &[Object], morphisms: &[Morphism], morphisms2: &[Morphism2]) -> bool {
    // 1. 所有态射的 source 和 target 必须存在于对象集中
    let obj_set: std::collections::HashSet<ObjectId> = objects.iter().map(|o| o.id).collect();
    for m in morphisms {
        if !obj_set.contains(&m.source) { return false; }
        if !obj_set.contains(&m.target) { return false; }
    }
    // 2. 所有2-态射的 source/target 态射必须存在
    let mor_set: std::collections::HashSet<MorphismId> = morphisms.iter().map(|m| m.morphism_id).collect();
    for m2 in morphisms2 {
        if !mor_set.contains(&m2.source_morphism) { return false; }
        if !mor_set.contains(&m2.target_morphism) { return false; }
    }
    // 3. 格封闭性：所有f64值必须在合法范围内
    for o in objects {
        if o.value.is_nan() || o.value.is_infinite() { return false; }
    }
    true
}

// ============ 安全管控 ============

pub fn check_permission(source_level: u8, target_level: u8) -> bool {
    source_level <= target_level
}

// ============ FFI 导出 ============

#[no_mangle]
pub extern "C" fn seed_kernel_version() -> u32 {
    0x050100 // v5.1.0
}

#[no_mangle]
pub extern "C" fn seed_create_object(id: u64, value: RealValue, frozen: bool) -> Object {
    Object { id, value, frozen }
}

#[no_mangle]
pub extern "C" fn seed_get_object_value(obj: &Object) -> RealValue {
    obj.value
}

#[no_mangle]
pub extern "C" fn seed_get_object_frozen(obj: &Object) -> bool {
    obj.frozen
}

#[no_mangle]
pub extern "C" fn seed_create_morphism(
    source: u64, target: u64, morphism_id: u64, delta: RealValue, security_level: u8,
) -> Morphism {
    Morphism {
        source,
        target,
        morphism_id,
        delta,
        security_level,
    }
}

#[no_mangle]
pub extern "C" fn seed_create_morphism2(
    morphism_id: u64, source_morphism: u64, target_morphism: u64, rewrite_type: u8,
) -> Morphism2 {
    Morphism2 {
        morphism_id,
        source_morphism: source_morphism,
        target_morphism: target_morphism,
        rewrite_type,
    }
}

#[no_mangle]
pub extern "C" fn seed_lattice_join(a: RealValue, b: RealValue) -> RealValue {
    lattice_join(a, b)
}

#[no_mangle]
pub extern "C" fn seed_lattice_meet(a: RealValue, b: RealValue) -> RealValue {
    lattice_meet(a, b)
}

#[no_mangle]
pub extern "C" fn seed_validate_consistency(
    objects: *const Object, obj_count: u64, morphisms: *const Morphism, mor_count: u64,
) -> ConsistencyReport {
    if obj_count == 0 || mor_count == 0 {
        return ConsistencyReport {
            total_cycles: 0, contradictions: 0, consistency_rate: 1.0, total_delta_sum: 0.0,
        };
    }
    let obj_slice = unsafe { std::slice::from_raw_parts(objects, obj_count as usize) };
    let mor_slice = unsafe { std::slice::from_raw_parts(morphisms, mor_count as usize) };
    let adj = build_adjacency_list(mor_slice);
    detect_cycles(&adj, obj_slice, ConsistencyLevel::L3Full, 100000)
}

#[no_mangle]
pub extern "C" fn seed_validate_consistency_leveled(
    objects: *const Object, obj_count: u64,
    morphisms: *const Morphism, mor_count: u64,
    level: u8, step_count: u64,
) -> ConsistencyReport {
    let level_enum = match level {
        0 => ConsistencyLevel::L1Realtime,
        1 => ConsistencyLevel::L2Periodic,
        _ => ConsistencyLevel::L3Full,
    };
    if obj_count == 0 || mor_count == 0 {
        return ConsistencyReport {
            total_cycles: 0, contradictions: 0, consistency_rate: 1.0, total_delta_sum: 0.0,
        };
    }
    let obj_slice = unsafe { std::slice::from_raw_parts(objects, obj_count as usize) };
    let mor_slice = unsafe { std::slice::from_raw_parts(morphisms, mor_count as usize) };
    let adj = build_adjacency_list(mor_slice);
    detect_cycles(&adj, obj_slice, level_enum, step_count)
}

#[no_mangle]
pub extern "C" fn seed_axiom_check_structure(
    objects: *const Object, obj_count: u64,
    morphisms: *const Morphism, mor_count: u64,
    morphisms2: *const Morphism2, mor2_count: u64,
) -> bool {
    let obj_slice = unsafe { std::slice::from_raw_parts(objects, obj_count as usize) };
    let mor_slice = unsafe { std::slice::from_raw_parts(morphisms, mor_count as usize) };
    let mor2_slice = unsafe { std::slice::from_raw_parts(morphisms2, mor2_count as usize) };
    axiom_check_structure(obj_slice, mor_slice, mor2_slice)
}

#[no_mangle]
pub extern "C" fn seed_check_permission(source_level: u8, target_level: u8) -> bool {
    check_permission(source_level, target_level)
}
