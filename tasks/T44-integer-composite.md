# T44 — Integer layer compositing, and a packed gradient ramp  [Opus]

**Rowan has authorised a fidelity trade here** (2026-09-21): small pixel
differences are acceptable if the image still looks the same and the corpora
pass rates hold. This is the only task in the project with that permission.
It does not extend to anything else.

## Measurements (this machine, 8-core arm64, `--width 2000`, 2.6 Mpx, median of 7)

Cost per pixel *above a flat fill of the same rectangle*:

| operation | ours | resvg | ratio |
|---|---|---|---|
| one layer, `normal` blend | **210.0 ns/px** | 3.4 ns/px | 62x |
| one layer, `multiply` | 230.9 ns/px | 3.1 ns/px | 74x |
| gradient fill | 25.1 ns/px | 1.3 ns/px | 19x |

Absolute: a full-canvas `<g opacity="0.6">` takes us 641 ms against resvg's
24 ms. Layers are now the single largest remaining cost in the renderer, about
eight times the cost of a gradient over the same area.

## Why

`Canvas.blendPixel` runs the f32 pipeline per pixel. For `.normal` that is
eight table reads, then four `F32.mul`, four `F32.add`, one `F32.sub` and four
`toU8`, each emulating IEEE binary32 in `Nat` with mantissa alignment and
round-to-nearest-even. Roughly 13 software-float operations per pixel where an
integer source-over needs about eight machine instructions.

T22 chose this deliberately and correctly: resvg composites layers through
tiny-skia's **f32** pipeline, because `Pattern::push_stages` emits `Gather`,
which has no lowp implementation, so `is_lowp_compatible` fails. Matching it
bit-for-bit required emulating f32. That was the right call for fidelity and
it is what we are now trading away, for `normal` only.

## The change

1. **Integer source-over for `mode == .normal`.** The canvas already stores
   premultiplied u8 and `Canvas.blendOver` already implements exactly this.
   Fold the group opacity in with `div255 (c * op8)`, quantising the opacity to
   a u8 once per layer the way `opacityToU8` already does elsewhere, then run
   the existing integer source-over. Keep the `copyOpaque` fast path.
   - Leave every other blend mode on the f32 path. They are rarer, and the
     non-separable modes in particular are not worth the risk.
   - Expect the per-pixel cost to fall from ~210 ns to the 15-30 ns range, so
     roughly a 7-10x improvement on layer-heavy content. **Measure it; do not
     assume it.** If the measured gain is under 3x, stop and report rather
     than accepting pixel changes for little in return.
2. **Pack the gradient ramp into one array.** `Grad.rampAt`'s table path reads
   four separate `Array Nat`. One `Array Nat` of packed RGBA is one read and
   one unpack instead of four bounds-checked reads. This one should be
   **bit-exact** — it changes layout, not arithmetic. Do it only if it measures
   as a win; the gradient is now a much smaller target than layers.

## The fidelity bar

This is what "small differences" means, and it is not negotiable:

- **No corpora directory may lose a single passing file.** Run the full suite
  at `--width 200`, direct route, against a same-width baseline built from
  main's binary. The pass metric is 99% of pixels within 8 levels, and a
  one-level rounding difference must not move it.
- **Maximum per-pixel difference of 2 levels** against main's binary, over all
  27 files in `tests/svg` at natural size and at `--width 800`. Report the
  worst file's max delta and the percentage of pixels that changed.
- **Report the changed-pixel percentage per file.** Rowan's guidance was around
  0.5%; treat a file above 2% as a signal that something is wrong with the
  arithmetic rather than a rounding difference, and investigate before
  proceeding.
- `26_layers.svg` and `07_opacity.svg` are the files that exercise this. Render
  both before and after at 800 px and confirm by eye that they are
  indistinguishable, then report the numbers.
- Threads must stay deterministic: `--threads 1/2/4/8` byte-identical to each
  other on `26_layers` at 800 px. Tiles byte-identical. `run_adversarial.py`
  clean. `LeanSvg/Effect.lean` untouched, `render`'s type unchanged, and the
  usual invariants from `tasks/README.md`.

`tests/run_tests.py` byte-identity against main **will** break for files with
layers, and that is expected and authorised. Every other file should stay
byte-identical; say which ones changed.

## Report

Give the measurement table above re-taken before and after, the changed-pixel
percentages, and the corpora before and after. Commit with author
Rowan Callahan <rowan.l.callahan@gmail.com> and a message ending
`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, push, and open a pull
request against main whose description is the report and ends with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do not merge.
