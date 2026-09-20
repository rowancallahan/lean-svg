# Session summary — 2026-09-19 → 2026-09-20

## Update 2026-09-20 afternoon: T8 and T10 merged (main b0a298d)

- **T10 tile culling** merged: byte-identical (80 CLI renders, 160 viewport
  renders, 1 960 stitched tiles, 2 184 synthetic edge cases). 64×64 tile of
  16_stress at 1600 px: 145 → 40 ms; 1×1 tile 137 → 29 ms (the rest is parse).
- **T8 output path** merged: byte-identical (40 renders). Empty 3200² canvas
  fixed cost 600 → 135 ms (4.4×): Adler-32 tuple boxing was 369 ms of it.
  01_triangle at 800 px: 100 → 67 ms.
- After each merge: build clean, 15/20, tiles 20/20, adversarial 37/37, and a
  2000 px spot render sha256-identical to the pre-merge binary.
- **T6 still unmerged on `t6-raster-walk`** (worktree `.worktrees/T6`):
  1.5–1.8× faster rasterizer, −3/−7 within-8 px on two stroke files. Decision
  pending (merge as-is, or fix stroker seams first).
- Conventions added to `tasks/README.md`: multiline shell commands (rule 8),
  short verification loop (rule 9).

## State of `main` at the overnight pause (commit 5db8f14, all local, nothing pushed)

Builds clean. Harnesses on this binary:
- `tests/run_tests.py`: **15/20** at the strict bar (≥ 99% of pixels within 8
  levels of resvg); all 20 files ≥ 99.6% within 32. Failing five: 12_badge,
  14_flower, 15_spiral, 16_stress, 17_koch (hairline strokes, coarse curve
  flattening, stroker seams — see T1's report).
- `tests/run_tiles.py`: **20/20** quadrant tiles byte-identical to full render.
- `tests/run_adversarial.py`: **37/37** clean.
- Theorems in `MicroSvg/Effect.lean` unchanged; `#print axioms` = `propext`.

Merged tonight (each verified before merge): T1 tiny-skia anti-aliasing port,
T2 blend arithmetic, T4/T4m viewport tiles (`--viewport X Y W H`), T5 opacity
quantisation, T7 opaque-coverage fast path (~1.4×). Also added: T3 size
benchmark (`tests/run_sizes.py`), playground (`playground/`), harness design
(`harness/README.md`, deferred M10).

## Paused on branches (worktrees still in place under `.worktrees/`)

| branch | worktree | state | decision needed |
|---|---|---|---|
| `t6-raster-walk` | T6 | **complete**, 1.5× (natural) / 1.8× (1600 px) faster, adversarial clean | loses 3 and 7 within-8 pixels on 15_spiral and 16_stress (0.008 pts), gains 21 on 19_sierpinski; cause is seams in *our* stroker. Merge as-is, or fix the stroker seams first (then it is strictly better). |
| `t8-output` | T8 | code written (Png.lean, Canvas.toRgbaBytes/new); byte-identity and timing verification **not finished** | resume the agent with `tasks/T8-perf-output-path.md`: finish sha256 check + timings, then merge. |
| `t10-cull` | T10 | **partial**: bbox helper in progress, not built | resume from `tasks/T10-tile-culling.md`. |

Resume any of them with an Opus agent pointed at its task file and worktree.
Note T8/T10 branched before T7 merged; expect a trivial conflict in
`Canvas.lean` for T8 (resolve like T7m did: keep main's `fillMask`).

## Measured performance (before T6/T8/T10)

~356 ms/Mpx mean, linear in pixels; ≈35× resvg at 3200 px (T3). 512×512 tile
at 4000 px wide: 600–960 ms, mostly fixed cost of flattening every shape
(T4m) → T10 culling + T8 output path are the levers for interactive tiles.

## Next steps (in order)

1. Decide T6; finish T8; finish T10; merge; re-run `make test tiles adversarial`.
2. Stroker seams (single outline per subpath, like kurbo) — fixes T6's
   regression and part of the five failing files.
3. Hairline strokes (device width ≤ 1 px → tiny-skia's `hairline_aa`) and finer
   curve flattening (Skia's cubic subdivision) — the rest of the failing five.
4. M3 output-size theorem; usvg route + resvg test suite; lean-zip; M10 Aeneas.

## How to run

```bash
lake build && make test && make tiles && make adversarial
python3 playground/server.py   # http://127.0.0.1:8765
```
