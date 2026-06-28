(set-logic QF_NIA)

; Finite safety model for Omega-Falling seed-kernel anchors.
; Object values live in the bounded lattice Omega=[0,M].

(declare-const M Int)
(declare-const x Int)
(declare-const y Int)
(declare-const f Int)
(declare-const g Int)
(declare-const alpha Int)
(declare-const gamma Int)
(declare-const morphism_f Int)
(declare-const morphism_g Int)
(declare-const m2_alpha Int)
(declare-const m2_beta Int)
(declare-const source_level Int)
(declare-const target_level Int)
(declare-const level_l4 Int)
(declare-const shutdown Bool)
(declare-const paused Bool)
(declare-const auto_l3 Bool)
(declare-const fit Int)
(declare-const comp Int)
(declare-const cons Int)
(declare-const gpu_candidate Bool)
(declare-const f64_verified Bool)
(declare-const hard_stop Bool)
(declare-const mutation_allowed Bool)

(assert (> M 0))
(assert (>= x 0))
(assert (<= x M))
(assert (>= y 0))
(assert (<= y M))
(assert (> f 0))
(assert (> g 0))
(assert (>= alpha 1))
(assert (>= gamma 1))
(assert (>= morphism_f 0))
(assert (>= morphism_g 0))
(assert (>= m2_alpha 0))
(assert (>= m2_beta 0))
(assert (>= source_level 0))
(assert (<= source_level 2))
(assert (>= target_level 0))
(assert (<= target_level 2))
(assert (= level_l4 3))
(assert (>= fit 0))
(assert (>= comp 0))
(assert (>= cons 0))

(define-fun raw_delta () Int (- (* f x) (* g y)))
(define-fun delta () Int (ite (< raw_delta 0) 0 raw_delta))

; Delta must be non-negative in Omega.
(push)
(assert (< delta 0))
(check-sat)
(pop)

; Safety weights for fit/cons may not be disabled.
(push)
(assert (or (< alpha 1) (< gamma 1)))
(check-sat)
(pop)

; 1-morphism composition uses meet/min and cannot exceed either component.
(define-fun morphism_comp () Int (ite (< morphism_f morphism_g) morphism_f morphism_g))
(push)
(assert (> morphism_comp morphism_f))
(check-sat)
(pop)
(push)
(assert (> morphism_comp morphism_g))
(check-sat)
(pop)

; 2-morphism composition uses join/max and cannot be lower than either component.
(define-fun m2_comp () Int (ite (> m2_alpha m2_beta) m2_alpha m2_beta))
(push)
(assert (< m2_comp m2_alpha))
(check-sat)
(pop)
(push)
(assert (< m2_comp m2_beta))
(check-sat)
(pop)

; Information flow requires source_level <= target_level.
(push)
(assert (and (> source_level target_level) (<= source_level target_level)))
(check-sat)
(pop)

; Seed target is forbidden for non-seed source.
(push)
(assert (and (> source_level 0) (= target_level 0) (<= source_level target_level)))
(check-sat)
(pop)

; L4 axiom modification is never allowed.
(push)
(assert (= level_l4 3))
(assert (not (= level_l4 3)))
(check-sat)
(pop)

; Shutdown forbids mutation.
(push)
(assert shutdown)
(assert (not shutdown))
(check-sat)
(pop)

; Free energy must dominate each non-negative component.
(define-fun free_energy () Int (+ fit comp cons))
(push)
(assert (< free_energy fit))
(check-sat)
(pop)
(push)
(assert (< free_energy comp))
(check-sat)
(pop)
(push)
(assert (< free_energy cons))
(check-sat)
(pop)

; Paused mode may not allow L2/L3/L4 mutation.
(push)
(assert paused)
(assert (= target_level 2))
(assert (not paused))
(check-sat)
(pop)

; GPU/ANE candidates may not bypass CPU f64 authority.
(push)
(assert gpu_candidate)
(assert (not f64_verified))
(assert f64_verified)
(check-sat)
(pop)

; Resource hard-stop forbids mutation.
(push)
(assert hard_stop)
(assert mutation_allowed)
(assert (not mutation_allowed))
(check-sat)
(pop)
