# microsvg

A micro-SVG → PNG rasterizer in Lean 4 whose only goal is to be safe.

- **One file in, one file out.** The program is a value of a free monad with
  two operations. Theorems in `MicroSvg/Effect.lean`, checked by the Lean
  kernel, say it reads only the input path and either fails without writing
  or writes exactly the rendered bytes to the output path and nothing else.
- **Total.** No `partial`, no `unsafe`, no FFI, no floats. Every loop is
  bounded by the input size or a constant.
- **Bounded.** Output ≤ 16384 px per side, ≤ 16 Mpx. Numbers, nesting depth,
  and element counts are capped before any allocation.
- **No references of any kind.** No DTD subsets, no entities beyond the five
  predefined, no `href`, no `url()`, no CSS, no scripts. XXE, billion laughs,
  and local-file-read attacks have no code path to reach.

Fidelity is checked against [resvg](https://github.com/linebender/resvg); the
hand-written corpus renders ≥ 99% of pixels within a small tolerance.

## Build and run

```bash
lake build
.lake/build/bin/microsvg tests/svg/01_triangle.svg out.png
.lake/build/bin/microsvg in.svg out.png --width 800 --background white
```

Exit codes: 0 success, 1 render error (message on stderr, no file written),
2 bad arguments.

## Test

```bash
brew install resvg        # oracle
make test                 # fidelity vs resvg → tests/out/report.html
make adversarial          # hostile inputs: no crash, no hang, no stray files
python3 playground/server.py   # http://127.0.0.1:8765 — draw and compare
```

## Read next

- `DESIGN.md` — what is proven, what is trusted, threat model, algorithms.
- `PLAN.md` — milestones, settled decisions, what to delegate.
