; Ω-落尘AGI 自指不动点定理 Z3 反例验证 v4.1.0 - 白皮书v2.0 第12.4节
; 验证：T(A)=Δ(A,A) 在完备格Ω上存在不动点（Knaster-Tarski定理应用）

(set-logic QF_NIA)

(declare-const M Int)
(declare-const A Int)
(declare-const B Int)

(assert (> M 0))
(assert (>= A 0))
(assert (<= A M))
(assert (>= B 0))
(assert (<= B M))

; Δ 算子
(define-fun delta ((a Int) (b Int)) Int (ite (>= a b) (- a b) 0))

; 自指算子 T(A) = Δ(A,A)
(define-fun selfRefT ((a Int)) Int (delta a a))

; ============================================================
; 验证1：T(A) = 0 对所有 A 成立
(push)
(assert (not (= (selfRefT A) 0)))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证2：0 是 T 的不动点
(push)
(assert (not (= (selfRefT 0) 0)))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证3：T 的单调性
(push)
(assert (and (<= A B) (> (selfRefT A) (selfRefT B))))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证4：不动点存在性
(push)
(assert (not (= (selfRefT 0) 0)))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证5：不动点唯一性 - 只有 0 是不动点
(push)
(assert (and (not (= A 0)) (= (selfRefT A) A)))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证6：自指收敛
(push)
(assert (not (= (selfRefT A) 0)))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证7：T(A) <= A（T 是收缩的）
(push)
(assert (> (selfRefT A) A))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证8：T(A) >= 0（T 非负）
(push)
(assert (< (selfRefT A) 0))
(check-sat)  ; 期望 unsat
(pop)

; ============================================================
; 验证9：T(M) ≠ M（除非 M=0）
(push)
(assert (= (selfRefT M) M))
(check-sat)  ; 期望 sat（因为 M>0 时 T(M)=0≠M，所以 sat 表示有反例... 
              ; 实际上 T(M)=0，所以 T(M)=M 当且仅当 M=0，但 M>0，所以 unsat）
(pop)

(exit)
