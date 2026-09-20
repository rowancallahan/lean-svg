# Session summary — 2026-09-19

## What was done

- Pivoted from "PDF renderer" to **micro-SVG → PNG in Lean 4**, safety-only
  goal, after research showed PDF's exploited subsystems (JBIG2, JPX, fonts,
  JS) are out of reach and no verified rasterizer exists anywhere.
- Decided **fixed-point integers, no floats** (Lean `Float` is opaque; NaN/Inf
  are attacker-controlled values). Hot loops in `Nat` because Lean's unboxed
  `Int` is only 31-bit.
- Built the whole pipeline in `/Users/rowancallahan/pdf_renderer`
  (package `microsvg`, Lean v4.34.0, no deps): effect monad + 6 kernel-checked
  theorems (`propext` only), XML subset parser, SVG interpreter, fixed-point
  geometry/stroker, accumulation rasterizer, compositing, PNG writer, CLI.
- First corpus (11 SVGs) vs resvg 0.48.1: triangle 99.00% exact / 100% ≤ 8;
  all files ≥ 99% ≤ 32. Adversarial files (billion laughs, XXE, external
  refs, huge dims/numbers, malformed, empty): all handled < 20 ms, no output
  on error.
- Wrote `PLAN.md` (milestones with Opus/design markers, settled decisions),
  `DESIGN.md` (claims, threat model, algorithms, results), `README.md`.
- Launched two Opus agents: `tests/run_tests.py` + `tests/run_adversarial.py`
  + `Makefile`; and `playground/` (server + single-page draw-and-compare app
  with `.claude/launch.json`).

## State of key files

- `MicroSvg/*.lean`, `Main.lean`: compile clean with `lake build`.
- `tests/svg/01..11*.svg`, `tests/adversarial/*.svg`: corpus.
- `tests/out/`: gitignored scratch (composites `*_cmp.png`).
- Git repo initialised, **nothing committed yet**.

## Next steps

1. Check the two Opus deliverables (`make test`, `make adversarial`, open the
   playground via the `playground` launch config).
2. Commit selectively (source, docs, tests; not `tests/out`).
3. M3 output-shape theorem (see PLAN.md for the approach).
4. M4 fidelity features, M5 usvg route + resvg-test-suite, M6 benchmarks.
5. lean-zip: PR idea and DEFLATE integration (M7).
