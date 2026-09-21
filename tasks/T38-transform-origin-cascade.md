# T38 — restore `transform-origin` under the CSS cascade

T29 replaced `Svg.applyAttrs` with `interpret`'s `applyEffective` closure
(the four-layer cascade) but only carried over the `color`-first handling.
Two blocks from `applyAttrs` were dropped: seeding `pctRefSet`/`pctRefW`/
`pctRefH` on the root push, and resolving the element's own
`transform-origin` into `originDx`/`originDy` before any `transform` is
folded in. `applyProp`'s `"transform"` case therefore always saw
`originDx = originDy = 0`, and `transform-origin` was a no-op everywhere.

Task: port both blocks into `applyEffective`, make `transform-origin`
resolvable from every cascade layer (usvg lists it, like `transform`, in
`is_presentation`, `svgtree/mod.rs`, so CSS sets it like any other
property), remove the dead `applyAttrs`, and re-measure
`structure/transform-origin`.

## Report

Files changed: `MicroSvg/Svg.lean` (plus this file). `git diff main --
MicroSvg/Effect.lean` is empty.

- `applyEffective` now (1) seeds `pctRefSet`/`pctRefW`/`pctRefH` from the
  root's own `viewBox`/`width`/`height` when `parent.pctRefSet` is false
  (only the root push), and (2) resolves `transform-origin` into
  `originDx`/`originDy` before the four folds, from whichever layer wins.
  A single `winning` helper does the layer lookup (`!important` CSS,
  `style=""`, normal CSS, presentation attribute) for both `color` and
  `transform-origin`; both names are skipped by all four folds.
- `applyAttrs` is deleted (dead since T29; the four doc comments that named
  it now name `applyEffective`).
- Branch `t36-text` / worktree `.worktrees/T36` (said to carry a partial
  `pctRef` seed) is not present in this clone (`git branch -a` shows only
  `main`), so nothing to rebase onto; if it lands later, its seed at the
  root push site is redundant with the one inside `applyEffective` and can
  be dropped.

Verification (resvg 0.45.1 as reference in this container; T24b measured
against 0.48.1, which explains the 3 vs 4 baseline):

| check | result |
|---|---|
| `lake build` | clean, 39 jobs, no warnings |
| `structure/transform-origin`, `--fast --route direct` | before (main binary) **4/23**, after **16/23** |
| `python3 tests/run_tests.py` | 19/23, the same 4 pre-existing fails as main |
| `python3 tests/run_adversarial.py` | 42/42 clean |
| `tests/svg/*.svg` main vs fixed binary, natural + `--width 800` | 46/46 byte-identical |

Files that flipped fail → pass: `bottom`, `center`, `keyword-length`,
`left`, `length-percent`, `length-px`, `on-group`, `on-shape`,
`on-text-path`, `right-bottom`, `right`, `top`. Still failing (7), all
unsupported reference kinds, unchanged from T24b's list: `on-clippath`,
`on-clippath-objectBoundingBox`, `on-gradient-object-bounding-box`,
`on-gradient-user-space-on-use`, `on-image`,
`on-pattern-object-bounding-box`, `on-pattern-user-space-on-use`.

Cascade check (no corpus fixture uses CSS for `transform-origin`): five
ad hoc files rendered at `--width 200` against resvg — origin from a
`<style>` rule, from `style=""`, an `!important` rule overriding the
presentation attribute, a root with `width`/`height` and no `viewBox`, and
a `transform` attribute with the origin only in CSS. All five: 100% of
pixels within 8, max diff 0. The main binary scores ~75% on each.

Not in scope, noted while here: `applyProp`'s `"transform"` case
*composes* into `ctm`, so a `transform` given in two layers (attribute and
CSS) is applied twice rather than the winner replacing the loser. usvg
replaces. No corpus file exercises it.
