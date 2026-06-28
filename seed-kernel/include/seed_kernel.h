#ifndef SEED_KERNEL_H
#define SEED_KERNEL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============ 核心类型 ============

typedef uint64_t ObjectId;
typedef uint64_t MorphismId;
typedef uint64_t Morphism2Id;
typedef uint8_t RewriteType;

typedef struct {
    ObjectId id;
    double value;
    bool frozen;
} Object;

typedef struct {
    ObjectId source;
    ObjectId target;
    MorphismId morphism_id;
    double delta;
    uint8_t security_level;
} Morphism;

typedef struct {
    Morphism2Id morphism_id;
    MorphismId source_morphism;
    MorphismId target_morphism;
    uint8_t rewrite_type;
} Morphism2;

typedef struct {
    uint64_t total_cycles;
    uint64_t contradictions;
    double consistency_rate;
    double total_delta_sum;
} ConsistencyReport;

typedef uint32_t FFIError;
#define FFI_SUCCESS 0
#define FFI_INVALID_INPUT 1
#define FFI_CONSISTENCY_VIOLATION 2
#define FFI_ANCHOR_VIOLATION 3

// ============ 版本 ============
extern uint32_t seed_kernel_version(void);

// ============ 对象管理 ============
extern Object seed_create_object(uint64_t id, double value, bool frozen);
extern double seed_get_object_value(const Object* obj);
extern bool seed_get_object_frozen(const Object* obj);

// ============ 态射管理 ============
extern Morphism seed_create_morphism(uint64_t source, uint64_t target, uint64_t morphism_id, double delta, uint8_t security_level);
extern Morphism2 seed_create_morphism2(uint64_t morphism_id, uint64_t source_morphism, uint64_t target_morphism, uint8_t rewrite_type);

// ============ 格运算 ============
extern double seed_lattice_join(double a, double b);
extern double seed_lattice_meet(double a, double b);

// ============ 自洽性校验 ============
extern ConsistencyReport seed_validate_consistency(const Object* objects, uint64_t obj_count, const Morphism* morphisms, uint64_t mor_count);
extern ConsistencyReport seed_validate_consistency_leveled(const Object* objects, uint64_t obj_count, const Morphism* morphisms, uint64_t mor_count, uint8_t level, uint64_t step_count);

// ============ 公理校验 ============
extern bool seed_axiom_check_structure(const Object* objects, uint64_t obj_count, const Morphism* morphisms, uint64_t mor_count, const Morphism2* morphisms2, uint64_t mor2_count);

// ============ 安全管控 ============
extern bool seed_check_permission(uint8_t source_level, uint8_t target_level);

#ifdef __cplusplus
}
#endif

#endif // SEED_KERNEL_H

// 2-态射重写类型常量
#define REWRITE_EQUIVALENT 0
#define REWRITE_OPTIMIZATION 1
#define REWRITE_ABSTRACTION 2
#define REWRITE_INVERSE 3
#define REWRITE_TRANSITIVE 4
#define REWRITE_CONTENT_TO_RULE 5
#define REWRITE_RULE_TO_CONTENT 6
