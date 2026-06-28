-- 测试基础语法
def testSub (x y : Nat) : Nat := x - y

theorem test_sub_self (x : Nat) : testSub x x = 0 := by
  unfold testSub
  apply Nat.sub_self

theorem test_lemma_syntax (x y : Nat) (h : ¬(x <= y)) : y <= x := by
  cases Nat.le_total x y with
  | inl h1 => exact absurd h1 h
  | inr h1 => exact h1
