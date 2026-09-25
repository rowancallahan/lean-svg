# The fixed harness: one main, many proven cores

Idea: a single, never-changing program shell reads one file, calls a pure
core, and writes one file. Cores are written in safe Rust, translated to Lean
by Aeneas (via Charon), and proven to satisfy a pre-specified contract. The
shell's file-system behaviour is a handful of lines read by eye, like `main`
in `Main.lean`; every core inherits it.

```
argv ─▶ [ main.rs: read(in) ─▶ core::run(bytes, opts) ─▶ write(out) | exit 1 ]
                    │                    │                     │
                 trusted            translated to Lean       trusted
                 (fixed)          proven per core           (fixed)
```

## The core contract (pre-specified, per tool)

A core is a Rust library crate with:

C1. Exactly this entry point, nothing else public:
    `pub fn run(input: &[u8], opts: &Options) -> Result<Vec<u8>, Error>`
    where `Options` and `Error` are plain data (`Error` prints as a message).
C2. `#![forbid(unsafe_code)]`, `#![no_std]` + `alloc` (so `std::fs`, `net`,
    `process`, `env`, `time`, `thread` do not exist to call), no dependencies.
C3. Translates with Aeneas with **no opaque functions** other than Aeneas's
    own model of core/alloc primitives. Any I/O would appear here as an
    opaque axiom, so this check is what makes the file-system claim obvious.
C4. Total: the translated `run` is not marked divergent, or its termination
    is proven in Lean.
C5. Panic-free: `∀ input opts, run input opts ≠ .fail` at the Aeneas level
    (the inner `Result::Err` is the tool's own error and is allowed).
C6. Output bound: `∀ input opts png, run input opts = .ok (.Ok png) →
    png.size ≤ bound opts` for a stated `bound` (for the renderer,
    `Png.sizeFor w h` with `w, h` capped).

C1–C3 are checked mechanically by the harness build. C4–C6 are Lean theorems
per core, and they are the "extra work" that buys halting and no-panic.

## The shell (read by eye, not proved)

`main.rs` does what `main` in `Main.lean` does: read the input, refuse if the
output path exists, call the core, create the output exclusively and write
it. The earlier plan proved this against a model file system
(`LeanSvg/Effect.lean`); that layer was removed on 2026-09-25 because its
interpreter had to be trusted anyway (`docs/DECISIONS.md`).

A translated core `run` is plugged in through a five-line adapter
`asRender opts : ByteArray → Except String ByteArray` that maps Aeneas's
`Result` and the tool's `Error` onto `Except`, so the per-core theorems are
stated against the same kind of function `Main.lean` calls.

## Trusted computing base

rustc and the Rust standard library used by `main.rs`; Charon (MIR
extraction); Aeneas (translation, argued sound on paper, not machine-checked);
the Aeneas Lean library's model of core/alloc; Lean; the OS; the fixed
`main.rs` (a handful of lines). The claim is about the
Lean model of the Rust; the link to the produced binary rests on rustc and
the translation being faithful. That is the expansion of trust accepted here.

## Layout

```
harness/
  README.md            this file
  rust/
    Cargo.toml         workspace
    harness-main/      the fixed shell (binary). Never edited per tool.
    cores/<tool>/      one library crate per core (C1–C2)
  lean/
    lakefile.toml      depends on the Aeneas Lean library
    Harness/Adapter.lean asRender + per-core contract statements
    Generated/<tool>/  Aeneas output (do not edit)
```
