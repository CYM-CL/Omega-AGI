import Lake
open Lake DSL

package «omega-falling-proofs» where
  leanOptions := #[⟨`autoImplicit, false⟩]

lean_lib «OmegaProofs» where
  srcDir := "."

require mathlib from git
  "https://github.com/leanprover-community/mathlib4.git" @ "v4.5.0"
