import Lake
open Lake DSL

package lean4prover where
  license := "Apache-2.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

require mathlib from git
  "https://github.com/leanprover-community/mathlib4"

@[default_target]
lean_lib Lean4Prover where
  srcDir := "."
