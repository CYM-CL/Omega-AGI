From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Arith.PeanoNat.
From Stdlib Require Import Lia.

Module OmegaFalling.

Definition delta (x y : nat) : nat := x - y.
Definition join (x y : nat) : nat := Nat.max x y.
Definition meet (x y : nat) : nat := Nat.min x y.
Definition free_energy (fit comp cons : nat) : nat := fit + comp + cons.
Definition morphism_comp_weight (f g : nat) : nat := meet f g.
Definition morphism2_comp_weight (alpha beta : nat) : nat := join alpha beta.

Inductive modification_level :=
| L1Micro
| L2Rule
| L3Syntax
| L4Axiom.

Definition permission_allowed (shutdown paused auto_l3 : bool) (level : modification_level) : bool :=
  match shutdown, paused, level with
  | true, _, _ => false
  | false, true, L1Micro => true
  | false, true, _ => false
  | false, false, L1Micro => true
  | false, false, L2Rule => true
  | false, false, L3Syntax => auto_l3
  | false, false, L4Axiom => false
  end.

Theorem delta_nonnegative : forall x y, 0 <= delta x y.
Proof.
  intros. unfold delta. apply Nat.le_0_l.
Qed.

Theorem join_commutative : forall x y, join x y = join y x.
Proof.
  intros. unfold join. apply Nat.max_comm.
Qed.

Theorem meet_commutative : forall x y, meet x y = meet y x.
Proof.
  intros. unfold meet. apply Nat.min_comm.
Qed.

Theorem free_energy_nonnegative : forall fit comp cons, 0 <= free_energy fit comp cons.
Proof.
  intros. unfold free_energy. apply Nat.le_0_l.
Qed.

Theorem free_energy_ge_fit : forall fit comp cons, fit <= free_energy fit comp cons.
Proof.
  intros. unfold free_energy. lia.
Qed.

Theorem free_energy_ge_comp : forall fit comp cons, comp <= free_energy fit comp cons.
Proof.
  intros. unfold free_energy. lia.
Qed.

Theorem free_energy_ge_cons : forall fit comp cons, cons <= free_energy fit comp cons.
Proof.
  intros. unfold free_energy. lia.
Qed.

Theorem morphism_comp_le_left : forall f g, morphism_comp_weight f g <= f.
Proof.
  intros. unfold morphism_comp_weight, meet. lia.
Qed.

Theorem morphism_comp_le_right : forall f g, morphism_comp_weight f g <= g.
Proof.
  intros. unfold morphism_comp_weight, meet. lia.
Qed.

Theorem morphism2_comp_ge_left : forall alpha beta, alpha <= morphism2_comp_weight alpha beta.
Proof.
  intros. unfold morphism2_comp_weight, join. lia.
Qed.

Theorem morphism2_comp_ge_right : forall alpha beta, beta <= morphism2_comp_weight alpha beta.
Proof.
  intros. unfold morphism2_comp_weight, join. lia.
Qed.

Theorem l4_axiom_forbidden : forall shutdown paused auto_l3,
  permission_allowed shutdown paused auto_l3 L4Axiom = false.
Proof.
  intros. destruct shutdown, paused; reflexivity.
Qed.

Theorem shutdown_forbids_all : forall paused auto_l3 level,
  permission_allowed true paused auto_l3 level = false.
Proof.
  intros. destruct paused, level; reflexivity.
Qed.

Theorem paused_forbids_non_l1 : forall auto_l3 level,
  level <> L1Micro ->
  permission_allowed false true auto_l3 level = false.
Proof.
  intros. destruct level; try contradiction; reflexivity.
Qed.

Theorem l3_requires_authorization :
  permission_allowed false false false L3Syntax = false /\
  permission_allowed false false true L3Syntax = true.
Proof.
  split; reflexivity.
Qed.

End OmegaFalling.
