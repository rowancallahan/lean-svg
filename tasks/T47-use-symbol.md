# T47 — `<use>` and `<symbol>`  (branch `claude/feat-use-symbol`)

Implement same-document `<use>` expansion and `<symbol>` instancing, matching
usvg 0.48.1 (`crates/usvg/src/parser/use_node.rs`). Target directories in the
resvg suite: `structure/use` (29/41 failing), `structure/symbol` (15/16),
`structure/defs` (some), and `painting/context` (`context-fill` /
`context-stroke` on use; 14/15 failing — do what falls out naturally, markers
are another agent's).

Scope: `href` and `xlink:href` to `#id` only (never external, never data:);
`x`/`y` translate; `width`/`height` for symbol/svg targets; symbol viewBox +
preserveAspectRatio + overflow clip; `use` of a `g`, shape, `use` (chains)
and `symbol`. Style inheritance from the `use` element, not the definition
site. **Security requirements (hard):** reject or skip recursive references
(self, mutual cycles) exactly as usvg does; bound expansion with a total
budget (depth ≤ existing `maxLayerDepth`, and a total expanded-node budget,
e.g. the existing element cap) so a "billion laughs" of nested `use` cannot
blow up; add an adversarial case to `tests/adversarial/` showing exponential
use-nesting is rejected or bounded, and make sure `run_adversarial.py` covers it.
Mention in the report how the budget was chosen.

Another agent (T48) is doing nested `<svg>` viewports at the same time; if
you need a viewport/viewBox helper, put it in a small separate function so
the integrator can unify them.

---

## Common rules (every lean-svg agent)

You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

---

## Spec implemented

`LeanSvg/Use.lean` (new) expands `use` on the XML event stream; `Svg.interpret`
calls `Use.expand` first and sees the expanded stream. `Render`, `defsScan`
and the proofs are untouched.

- **Links**: `href` wins over `xlink:href`; only `#id`; the id map is
  first-occurrence-wins over every element (usvg `id_map`), including ones
  under unknown elements (`xlink-to-a-child-of-a-non-SVG-element`).
- **Recursion** (usvg `parse_svg_use_element`): skip when the link is the
  `use` itself or the origin `use`, or when any `use` inside the link points
  back at this `use` or at the link. The `use` element stays and renders empty.
- **Targets copied**: `g switch svg symbol a use` and the graphic elements.
  Anything else renders nothing in usvg, so nothing is copied.
- **Copies**: `style` elements are dropped (CSS is collected once). `id` is
  kept so CSS `#id` rules still match the copy, since usvg matches CSS against
  the original node. The exception is definition elements (`clipPath`,
  gradients, `mask`, `pattern`, `filter`, `marker`): their `id` is dropped so a
  copy never shadows the original.
- **`use` in `interpret`**: a `g` whose `x`/`y` (lengths or percentages of the
  root viewport) post-multiply its own transform, so `transform-origin` and a
  CSS `transform` behave as in usvg. It keeps its parent's mode, so a `use`
  of a shape is a valid `clipPath` child. A `g` inside it is not, and a
  symbol under a `clipPath` is dropped, as in usvg.
- **`symbol`**: the `use` width and height (with usvg's quirky double
  percentage resolution) and the symbol's `viewBox` and
  `preserveAspectRatio` give the viewBox matrix, applied on a `g` that carries
  the symbol's own attributes in place of its `transform`. Unless the
  symbol's `overflow` is `visible` or `auto`, a generated `clipPath` with the
  rect `(0,0,w,h)` clips it. Its ids use a reserved prefix, and a document that
  uses that prefix itself is rejected.
- **`use` → `svg`**: the `use` width and height replace the copied `svg`'s
  own. Nested `svg` rendering itself is T48's job.
- **`context-fill` / `context-stroke`**: new `PaintSpec.context`. A `use`
  records its resolved fill and stroke (paint only, colour alpha dropped, as
  usvg's `ContextElement`) in two inherited `Style` fields. Outside any `use`
  they resolve to `none`.
- **Viewport helper for T48**: `Use.parseAspect` and `Use.viewBoxMat` are
  standalone (usvg `ViewBox::to_transform`).

### Security bounds and how they were chosen

- **Depth**: expansion recurses on `Use.maxDepth = 10` fuel.
  `Svg.use_maxDepth_le` checks `Use.maxDepth ≤ maxLayerDepth` at compile
  time. Deeper nesting is an **error**, which is also where usvg ends up for
  a cycle its checks miss: it errors at its 1024-node depth limit.
- **Elements**: the expanded stream may hold at most `Xml.maxElements` (10^6)
  elements. That is the parser's own cap, so the expanded document is never
  bigger than one the parser would accept directly, and every bound
  downstream of the parser still holds. Exceeding it is an error.
- **Work**: at most `16 × Xml.maxElements` events visited, counting copies
  *and* recursion-check scans. Those scans copy nothing, so the element cap
  alone would not bound them (`use_recursion_scan` would otherwise do about
  10^9 steps).
- **Viewport clips**: a generated clip past `Svg.maxClipPaths` would be
  dropped silently by `defsScan`, so producing one is an error.

Adversarial cases: `tests/adversarial/use_billion_laughs.svg` (10^10 copies,
rejected in 0.3 s) and `use_cycle.svg` (a 3-cycle plus a self-reference,
rejected). The generated cases in `run_adversarial.py` are `use_chain_10`
(renders), `use_chain_11` (rejected), `use_fanout_1e5` (10^5 rects, renders
in 2.9 s), `use_recursion_scan` (work budget) and `use_symbol_5000` (clip
cap).

## Skipped, and why

- Percentages inside a symbol are not rescoped to the `use` viewport. The
  `use` `x`/`y` and shape percentages still resolve against the root.
  `Style.pctRef*` is shared with T48's nested-`svg` work.
- The `use` element's own `clip-path` on a `symbol` target is applied in the
  `use`'s transformed space. usvg applies it in the parent space, because it
  resets the group transform. No test covers this.
- CSS selectors that depend on structure (`>`, descendant, `:first-child`)
  are matched against the expanded position, not the definition site. Type
  selectors on `g` also hit the generated `g` wrappers. `#id` and class
  selectors work.
- Context paint from gradients and patterns uses the shape's bbox, not the
  `use`'s. Context paint on markers and text decoration belong to other
  agents. That is the remaining 11 failures in `painting/context`.
- The 7 remaining `structure/use` failures are all `use` → nested `svg`
  (T48).

## Report

Files: `LeanSvg/Use.lean` (new), `LeanSvg/Svg.lean` (import, `rootViewport`,
`use_maxDepth_le`, the `use` branch, `PaintSpec.context`, `Style.ctxFill` and
`Style.ctxStroke`, module doc), `LeanSvg.lean` (import), `DESIGN.md` §3.3,
`tests/run_adversarial.py`, `tests/adversarial/use_*.svg`,
`tests/svg/28_use_symbol.svg`.

resvg suite, `--fast --route direct` (pass counts):

| dir | files | before | after |
|---|---|---|---|
| structure/use | 41 | 12 | 34 |
| structure/symbol | 16 | 1 | 16 |
| structure/defs | 7 | 5 | 7 |
| painting/context | 15 | 1 | 4 |
| masking/clipPath | 52 | 50 | 51 |
| structure/svg | 42 | 9 | 11 |
| painting/color | 4 | 3 | 4 |
| **whole suite** | 1679 | **835** | **881** |

46 newly passing and 0 newly failing. No file's within-8 score dropped.

Other checks:
- `lake build`: clean, no warnings.
- `check-theorems.sh`: `theorems ok`. The proof is untouched, because the
  expansion happens inside `interpret`.
- `run_tests.py`: 24/28 pass. The 4 failures are the same ones as before, and
  no score changed. The new `28_use_symbol` scores 99.40.
- `run_adversarial.py`: 69/69 clean.
- `run_tiles.py`: 28/28 byte-identical.
