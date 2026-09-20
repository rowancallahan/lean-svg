# microsvg — work plan

Goal: a micro-SVG → PNG rasterizer in Lean 4 whose *only* claim is safety.
Bytes in, bytes out. It reads exactly one file, then either fails with a message
(writing nothing) or writes exactly one PNG of bounded size. No floats, no
`partial`, no `unsafe`, no FFI, no dependencies. Rendering fidelity is checked
empirically against resvg; it is not a theorem.

Model for the project: [kim-em/lean-zip](https://github.com/kim-em/lean-zip)
(verified DEFLATE in Lean). This is the same idea for a rasterizer.

Legend: **[done]**, **[Opus]** = straightforward coding, spec below is complete,
**[design]** = needs conceptual work first (do not delegate blind).

---

## M0 — Scaffold, proofs, first renderer  [done]

- Lake project, no dependencies (`lakefile.toml`, `lean-toolchain` = v4.34.0).
- `MicroSvg/Effect.lean`: free monad `Prog` over two ops; theorems
  `runFS_frame`, `runFS_input_only`, `renderProgram_spec`,
  `renderProgram_error_no_write`, `renderProgram_ok_output`,
  `renderProgram_ok_frame`. Axioms used: `propext` only.
- Pure pipeline: `Xml.parse` → `Svg.interpret` → `Render.canvasSetup` →
  `flatten`/`strokePoly` → `Raster.rasterize` → `Canvas.fillMask` → `Png.encode`.
- First corpus: `tests/svg/01..11`. All ≥ 99% pixels within tolerance 32 of
  resvg; triangle is 99.00% *exact*, 100% within 8.
- Adversarial corpus `tests/adversarial/`: billion laughs and XXE rejected at
  the DOCTYPE, external refs ignored, huge dims rejected, all < 20 ms, no
  output file on error.

## M1 — Test harness  [Opus, in progress]

`tests/run_tests.py` (resvg oracle, Hamming-style metrics, composites, HTML
report), `tests/run_adversarial.py` (generated hostile inputs, checks exit
code ∈ {0,1}, no stray files, no timeouts), `Makefile`.

Metric definition (fixed): per pixel `d = max channel |ours − ref|`.
`exact = P(d = 0)`, `within = P(d ≤ 8)`. Pass = `within ≥ 0.99`. Report exact
too. Anti-aliasing seams differ by a few levels along every edge, so `exact`
alone would fail on thin strokes even when the render is right.

## M2 — Browser playground  [Opus, in progress]

`playground/server.py` + `playground/index.html`: type or draw an SVG, see
browser / resvg / microsvg / diff, with the metrics. `.claude/launch.json`
entry `playground`.

## M3 — Output-shape theorem  [design → then Opus for the proof grind]

User's requirement: "either errors or writes to another file *at the size
expected*". Statement to prove:

```lean
theorem render_ok_shape (opts inp png) (h : render opts inp = .ok png) :
    ∃ w h, 0 < w ∧ 0 < h ∧ w ≤ maxDim ∧ h ≤ maxDim ∧ w * h ≤ maxPixels ∧
      png.size = Png.sizeFor w h ∧ png.extract 16 24 = Png.be32 w ++ Png.be32 h
```

Approach (decided):
1. Add `Png.sizeFor w h := 8 + 25 + (12 + 2 + 5·nblocks + raw + 4) + 12` with
   `raw = h·(4w+1)`, `nblocks = max 1 ⌈raw/65535⌉`.
2. Prove `ByteArray.size_append`, `size_push`, `size_extract` style lemmas as
   needed (core has most; check `ByteArray.size_append`).
3. Prove `Canvas.toRgbaBytes_size : (cv.toRgbaBytes).size = 4 · cv.px.size`
   and `Canvas.fillMask` preserves `px.size` (it only uses `setIfInBounds`).
4. Prove `zlibStored_size` by rewriting the `for` loop as `Nat.fold` or a
   recursive helper (easier to reason about than `forIn` over `Std.Range`).
   Recommendation: restructure `Png.zlibStored` and `Png.encode` as explicit
   recursion over `Nat` with `termination_by`, keep behaviour identical, then
   prove by induction.
5. `render` is a `do` block in `Except`; unfold and case on each bind.

## M3b — Stronger effect theorems  [design → Opus for the proofs; future]

Requested 2026-09-20, not started. Statements to add to `Effect.lean`:

1. **No-clobber.** The program only writes the output path if that path did
   not exist when the program started. Model: `FS := String → Option ByteArray`
   (`none` = absent); add `Op.outputExists : Op` with `Res = Bool`; the
   renderer program becomes: read input; if output exists, fail; else render
   and write. Theorems: `runFS_frame` as today; new
   `renderProgram_no_clobber : fs out = some b → (run …).2 = fs`; and the
   existing input-only theorem generalises to "depends only on `fs inp` and
   on whether `fs out` is present". The trusted `execIO` gains one
   `System.FilePath.pathExists` call, still on the two given paths only.
2. **Output size bound (reach; strengthens M3).** `render opts inp = .ok png →
   png.size ≤ Png.maxSize` where `Png.maxSize = sizeFor maxDim maxDim` is the
   uncompressed size of the largest permitted canvas: no blown-up files by
   construction. M3's exact `sizeFor w h` implies it.
3. **Bounded work (reach).** Two options, cheapest first: (a) a step budget
   threaded through `render` as fuel (pure, provable: "returns within N
   steps or fails"); (b) a wall-clock cap in the trusted shell (default one
   hour, resettable to unlimited by flag), not provable but simple. Totality
   already guarantees termination; this bounds *how long*.
4. **Max input size.** `render` rejects `inp.size > maxInput` (say 64 MiB)
   before parsing; theorem `render_rejects_large : inp.size > maxInput →
   render opts inp = .error _`. Trivial once the check exists.

## M4 — Fidelity features  [Opus]

Each is self-contained. Keep the invariants: no `partial`, every loop bounded
by input size or a constant, every parsed number clamped, indices via
`getD`/`setIfInBounds`.

- Remaining CSS named colours (147 total; ~70 present).
- `stroke-dasharray` / `stroke-dashoffset`: split each flattened polyline into
  dashes before `strokePoly`. Bound the dash count: if pattern sum ≤ 0 or the
  number of dashes on a subpath would exceed 100 000, draw solid.
- Percent lengths for `width`/`height` on root (relative to viewBox).
- `display`/`visibility` on the root `<svg>`.
- Nested `<svg>` as a group with its own viewport (currently skipped).
- Elliptical arc `A`/`a` in path data [design note]: use the standard
  center-parameterisation, then emit cubics per ≤90° slice. Needs one
  fixed-point `sqrt` (have `Nat.sqrt`) and `atan2` (write via the existing
  `sinCos16` plus a small binary search over the angle; 32 iterations, bounded).
  usvg already converts arcs to cubics, so this only matters for hand-written
  files.
- `<use href="#id">` [design note]: requires a definitions table and a cycle
  guard. Bound expansion by a fuel of 64 nested uses and 100 000 total
  instantiated elements; otherwise error. Never follow anything but `#local`.
- Group opacity done correctly (offscreen layer for `<g opacity>`); today it
  is multiplied into children, wrong where children overlap. Layer = a second
  `Canvas`, then `over` with alpha. Bound: layers count as pixels against
  `maxPixels`.
- Linear/radial gradients (`url(#id)` fill): a paint that is evaluated per
  pixel from the mask. Fixed-point gradient parameter; `spreadMethod` pad only
  first. Moderate work; do after `<use>` since both need the defs table.

## M5 — Full-SVG route via usvg + resvg test suite  [Opus]

- `tests/run_suite.py`: for a checkout of `linebender/resvg-test-suite`
  (`tests/*.svg`, MIT), run `usvg in.svg micro.svg` (usvg ships with resvg;
  install `cargo install usvg` or `brew` if a formula exists), then render
  `micro.svg` with microsvg and with resvg, compare with the M1 metric. Report
  pass rate per test-suite directory (structure, painting, shapes, ...).
  Text becomes paths through usvg, so `text/` tests become testable.
- Feed failures back as items in M4.

## M6 — Performance  [Opus]

- Benchmark script: render each corpus file 20× with `--width 2000`, report
  median ms for microsvg vs resvg. Also a 5 000-shape generated file.
- Likely wins, in order: (1) skip rows of the mask that are all zero before
  blending; (2) in `accumPiece`, use `USize` indexing with proofs or keep
  `setIfInBounds` but hoist `base + c`; (3) avoid re-allocating the mask per
  shape by reusing a scratch `Array Int` (thread it through `drawShape`);
  (4) `Canvas.px` as `Array UInt32`? No: `UInt32` boxes in arrays; keep `Nat`.
- Target: within 5× of resvg on the corpus at 2000 px. Report, don't guess.

## M6b — Parallel rendering with `Task`, same theorems  [design done → Opus]

Requested 2026-09-20. Lean's `Task.spawn : (Unit → α) → Task α` and
`Task.get : Task α → α` are *pure*: `Task` is a structure holding its result
and `Task.get (Task.spawn f) = f ()` is definitional. So parallelism lives
inside `render` with no change to its type and no change to `Effect.lean`;
every effect theorem carries over untouched, and totality is unaffected
(each task body is one of our existing total functions).

Design (decided):
1. **Horizontal bands.** Split the canvas into `k` bands of rows
   (`k = min(cores, H / 64)`, never more than 64). For each band, cull shapes
   against the band (T10's test with the band rectangle), render the band as
   its own `Canvas` with the band's translate composed into the root matrix
   (exactly the viewport mechanism of T4, so band borders are byte-identical
   by the same argument), then concatenate the bands' RGBA rows. Blending
   order per pixel is unchanged, so the output is **byte-identical** to the
   serial render; `tests/run_tiles.py`'s stitching check is the test.
2. Wrap each band in `Task.spawn` (priority default), collect with
   `Task.get` in order. Provide `Options.threads : Nat` (0 = serial) so the
   serial path remains available and is the reference.
3. Theorem: `renderPar opts inp = render opts inp` — by unfolding the band
   composition and the `Task.get`/`Task.spawn` identity; if the band
   composition is stated as "concatenate rows of independent band renders",
   the proof reduces to the tile-identity argument (M4-level effort; at
   minimum state it and prove the `Task` layer, leaving band-identity as a
   tested claim).
4. PNG output stays serial (Adler-32 is sequential); T8 made it cheap.
   Later: per-band Adler combination is possible (Adler-32 is combinable)
   if it shows up.
5. Runtime: Lean executables run tasks on a thread pool sized to the
   machine; check `LEAN_NUM_THREADS` behaviour and report scaling on
   `16_stress_2000` at 1600 px for 1, 2, 4, 8 threads. Memory: each band
   canvas is `4·W·rows`, total unchanged.

Not started. Do after T11/T12 land to avoid touching `Render.drawShape`
concurrently.

## M7 — Verified DEFLATE via lean-zip  [Opus after checking the API]

- Add `kim-em/lean-zip` as a Lake dependency; replace `Png.zlibStored` with
  its compressor (zlib framing may or may not be provided; Adler-32 is).
  Keep the stored-block encoder as the default until the size theorem in M3
  is redone for the compressed case (compressed size is not a closed form, so
  M3 becomes an upper bound: `png.size ≤ sizeFor w h`).
- Separately (user): open a PR to lean-zip. Candidate contributions: a zlib
  wrapper if missing, or a fuzz harness like `tests/run_adversarial.py`.

## M8 — Fuzzing  [Opus]

- `tests/fuzz.py`: mutation fuzzer over the corpus (byte flips, splices,
  number replacement with extreme values, tag duplication). N iterations,
  seeded. Same checks as the adversarial harness. Run for 10 minutes in CI.

## M10 — Rust cores via Aeneas, fixed harness  [deferred, ideation only]

Idea (2026-09-19): one never-changing `main.rs` (read one path, call a pure
core, write one path) plus cores written in safe `no_std` Rust, translated to
Lean by Aeneas and proven against a pre-specified contract (pure, total,
panic-free, output bound). `Effect.lean`'s theorems apply to any core
unchanged. Design in `harness/README.md`, vertical-slice spike spec in
`tasks/T9-aeneas-spike.md`. Not started; revisit once the Lean renderer's
speed work (T6–T8) has reported.

## M9 — Write-up  [user]

Design and results, in the user's own words. `DESIGN.md` has the material.

---

## Decisions that are settled (do not relitigate in delegated work)

1. **Fixed point, no floats.** `Fx = Int`, 8 fractional bits; matrices 16.16.
   Lean's `Float` is opaque and admits NaN/Inf; integers are provable and
   deterministic.
2. **Hot loops in `Nat`.** Lean's unboxed `Int` is 31-bit on 64-bit hosts,
   `Nat` is 63-bit. The rasterizer clips to the canvas so all coordinates are
   non-negative before the per-row loop.
3. **Event-based XML, no tree, no DTD.** Rejecting `[` in DOCTYPE is the
   whole XXE/billion-laughs defence. Depth cap 64, element cap 1 000 000.
4. **Accumulation rasterizer** (font-rs scheme) with exact per-column area.
   Even-odd via triangle fold of the accumulated winding.
5. **Strokes are unions of consistently oriented polygons** filled nonzero.
6. **Trusted computing base:** Lean compiler + runtime, the C compiler,
   `Prog.execIO` (6 lines), `Main.lean` (arg parsing), the OS.
7. **Every loop is a `for` over a finite range**, so termination is
   structural. Never introduce `partial`.
8. **Resource caps:** output ≤ 16384 px per edge and ≤ 16 Mpx; numbers clamp
   to ±2^22 px; 18 significant digits; exponents saturate.
