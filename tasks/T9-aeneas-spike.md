# T9 — Aeneas vertical slice: fixed harness + trivial proven core

## Goal

Prove out the framework in `harness/README.md` end to end on this Mac with a
trivial core, so that porting the real renderer (later) is only "more of the
same". Deliver working tooling, not an essay.

Work in the main tree `/Users/rowancallahan/pdf_renderer` under `harness/`
only (plus this task file). Do not touch `MicroSvg/` or `.worktrees/`.
Do not commit.

## Steps

1. **Toolchain.** Install Charon and Aeneas from source following their
   READMEs (https://github.com/AeneasVerif/charon, https://github.com/AeneasVerif/aeneas).
   Charon pins a specific Rust nightly via `rust-toolchain`; use `rustup` to
   get it (rustup/cargo are at /opt/homebrew/bin). Aeneas is OCaml: install
   `opam` via Homebrew if missing, create a switch, `make` per its README.
   Install into `~/.local/aeneas/` or wherever their docs suggest; record the
   exact commits and commands in the report. If a step needs `sudo` or an
   interactive login, stop and report instead.
   Check what Lean version the Aeneas Lean library (`backends/lean`) pins in
   its `lean-toolchain`; our project is on v4.34.0. Use whatever the Aeneas
   library requires for `harness/lean/` (it is a separate Lake project).

2. **Rust workspace** `harness/rust/`:
   - `harness-main`: binary crate. `main.rs` parses `<in> <out> [--opt ...]`
     (keep option parsing to a simple key/value list passed to the core as
     `Options`), reads `in` with `std::fs::read`, calls `core::run`, on `Ok`
     writes `out` with `std::fs::write` and exits 0; on `Err` prints the
     message to stderr, writes nothing, exits 1; bad args exit 2. Nothing
     else. This file is the fixed shell.
   - `cores/invert`: library crate meeting C1–C2 of `harness/README.md`
     (`#![no_std]`, `#![forbid(unsafe_code)]`, `extern crate alloc`).
     `run` returns the input with every byte XORed with `0xFF`, and returns
     `Err` if the input is empty (to exercise the error path). Keep it
     small but use a `for` loop over indices and `Vec::push`, since those
     are what the real core will use.
   - A `cargo build --release` and a manual run on a small file.

3. **Translate.** Run Charon on `cores/invert` and Aeneas with the Lean
   backend into `harness/lean/Generated/Invert/`. Record the exact commands
   in a `harness/translate.sh`. Report every opaque/external function that
   appears in the output (there should be none besides Aeneas's own model).

4. **Lean side** `harness/lean/`: a Lake project depending on the Aeneas
   Lean library (as their README prescribes, typically a git dependency on
   the `aeneas` repo's `backends/lean`). Files:
   - `Harness/Effect.lean`: copy of `/Users/rowancallahan/pdf_renderer/MicroSvg/Effect.lean`
     with the namespace renamed to `Harness` (it has no other dependencies).
   - `Harness/Adapter.lean`: `asRender` mapping the translated
     `invert.run : ... → Result (core.result.Result (alloc.vec.Vec U8) Error)`
     (whatever Aeneas names it) to `ByteArray → Except String ByteArray`.
     Note Aeneas's `Vec U8` is a `List`/`Array` of `U8`; conversion to
     `ByteArray` is fine here.
   - `Harness/Invert.lean`: the per-core contract for the trivial core:
     C4 (not divergent, or a termination proof), C5 (`run ≠ .fail` for all
     inputs; for XOR over a loop this needs the Aeneas loop-proof idiom,
     use their `progress` tactic and follow the hashmap/tutorial examples),
     C6 (`output.length = input.length`). Then instantiate
     `Harness.Prog.renderProgram (asRender opts)` and restate
     `renderProgram_spec` for it as a one-line corollary.
   - `lake build` must succeed; `#print axioms` of the corollary must list
     only `propext`/`Classical.choice`/`Quot.sound` and whatever axioms the
     Aeneas library itself introduces (list them explicitly in the report;
     they are part of the trusted base).

5. **Report** (append `## Report`): commands, commits, Lean version used,
   which of C1–C6 are mechanically checked vs proven vs not done, the full
   list of opaque functions and axioms, wall-clock time for the translation,
   and a candid paragraph on the friction you hit and what it implies for
   porting a ~1500-line rasterizer (loops, `Vec<Vec<..>>`, structs, integer
   arithmetic in `u64`/`i64`, `Result` propagation).

## Done when

`harness/rust` builds and runs; `harness/translate.sh` reproduces the Lean
output; `harness/lean` builds with the corollary theorem checked; report
appended. If the toolchain cannot be installed, report exactly where it
stopped and what is needed.
