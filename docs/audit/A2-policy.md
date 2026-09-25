# A2 — audit: policy exceptions and edge statuses

Scope: the resvg-test-suite corpus scored by `tests/run_corpora.py`. Every
claim below was checked empirically (resvg 0.48.1 / usvg 0.48.1, pinned to
`tests/corpora/resvg-test-suite/fonts` where noted) and, where useful,
against the resvg source at tag `v0.48.1`
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`).

## 1. External resources — is "strip the href" the right reference model?

`run_corpora.py`'s `strip_external_refs` finds every file with a
non-fragment, non-`data:` `href`/`xlink:href` (skipping `<a href>`, which is
a hyperlink, not a resource) and builds the *reference* image from a copy
with that attribute removed, on the theory that "removed" and "present but
never loaded" render the same. Re-running the regex against the current
checkout finds exactly the 30 files named in the task:

```
filters/feImage/simple-case.svg               feImage
filters/feImage/svg.svg                       feImage
masking/clipPath/image-is-not-a-valid-child.svg  image (in clipPath)
paint-servers/radialGradient/invalid-xlink-href.svg  radialGradient (see below — not really external)
painting/marker/with-an-image-child.svg       image (in marker)
structure/image/{external-gif,external-jpeg,external-png,external-svg,
  external-svgz,float-size,no-height,no-height-on-svg,
  no-width-and-height,no-width-and-height-on-svg,no-width,
  no-width-on-svg,raster-image-and-size-with-odd-numbers,
  recursive-1,recursive-2,url-to-png,url-to-svg,
  width-and-height-set-to-auto,with-zero-width-and-height,
  zero-height,zero-width}.svg                 image  (21 files)
structure/use/xlink-to-an-external-file.svg   use
text/textPath/with-invalid-path-and-xlink-href.svg  textPath (see below — not really external)
text/textPath/with-path-and-xlink-href.svg    textPath (see below — not really external)
text/tref/link-to-an-external-file-element.svg  tref
```

**Verdict: stripping is the right model for all 30, and it is not merely a
convenient assumption — it matches usvg's own control flow exactly.**

usvg's default image resolver (`crates/usvg/src/parser/image.rs:84-111`)
turns any `href` into a filesystem path with `Options::get_abs_path`, and
only reads it if `path.exists()`; a genuinely external reference (an
`http(s)://` URL, or a relative path with nothing there) always fails that
check and falls to:

```rust
// image.rs:110
log::warn!("'{}' is not a path to an image.", href);
None
```

`None` is exactly what a *missing* `href` produces too
(`image.rs:140`: `"Image lacks the 'xlink:href' attribute. Skipped."`,
also `None`). There is no third code path — a reference usvg cannot load and
a reference that was never given both bottom out in the same `None`, so
"remove the attribute" and "point it at something unreachable" are
observationally identical to every consumer downstream (the `<image>`
placement code, `feImage`, `<use>`'s target lookup, `textPath`'s path
lookup, `tref`'s target lookup). I confirmed this isn't just true by
construction of the source but true in rendered pixels, by building a
second reference for all 30 files with the href rewritten to a clearly
nonexistent path instead of removed, and diffing against the harness's
stripped reference:

| check | result |
|---|---|
| `resvg(href → nonexistent path)` vs `resvg(href attribute removed)`, all 30 files | **byte-identical, all 30** |
| `lean-svg direct` vs `resvg(href removed)`, all 30 files, `--width 200`, threshold 0.99/tol 8 | **29/30 pass** (see below for the one exception, which is unrelated to this policy) |

Two nuances worth recording:

* **`structure/image/recursive-1.svg` / `recursive-2.svg`.** These *do* have
  a real file at the far end of the href on this checkout (`recursive-2.svg`
  references itself; `recursive-1.svg` references a resource file that
  chains back). Running resvg on the *original*, unstripped files (which
  succeeds, because the referenced files really are sitting next to them in
  this git checkout) gives a visibly different image from the stripped
  reference for `recursive-2.svg` — resvg's own recursion guard produces
  some content, not a blank frame. That is irrelevant to the policy
  question: our renderer never has filesystem access to a second file
  regardless (`LeanSvg/Image.lean`: "Only `href="data:..."` is ever looked
  at ... There is no code path from an image to a file or a URL"), so the
  behaviour we need to match is "cannot load", not "resvg happens to find a
  copy of this exact test suite on disk." The nonexistent-path experiment
  above is the fair comparison, and it agrees with stripping for both files.
* **Three of the 30 are not actually about *external* resources.** Their
  `href` values are `rect1`, `path1`, `path2` — bare same-document IDs
  *without* the leading `#`, which is what the test is about (an invalid
  IRI reference, since `xlink:href` needs `#id` to name a same-document
  element): `paint-servers/radialGradient/invalid-xlink-href.svg`,
  `text/textPath/with-invalid-path-and-xlink-href.svg`,
  `text/textPath/with-path-and-xlink-href.svg`. They only got caught by
  `EXTERNAL_HREF`'s `(?!\s*#|\s*data:)` because the value doesn't start with
  `#`, not because anything is loaded from outside the document. usvg's own
  stderr says as much: `Failed to parse href value: 'path1'` — the *value*
  is rejected before any resolution is attempted, and would be rejected
  identically whether it's present or absent. This is a harmless heuristic
  false-positive: stripping still gives the right reference for them (both
  ways of losing the (invalid) href produce the same image), it's just not
  really testing "external resource" policy. Worth noting so a future
  reader of the CSV doesn't misread the note text.

**The one non-pass, `text/tref/link-to-an-external-file-element.svg`
(within-8 = 95.19%), is not an external-resource defect.** The stripped
reference already matches the unstripped-original resvg render byte for
byte for this file (`tref` with an unresolvable target renders nothing in
both), so the reference construction is correct; the gap is ordinary text
rendering fidelity (kerning/hinting on the two visible `<text>` runs sharing
the frame), the same kind of small residual difference text tests generally
show elsewhere in the suite. Filed as pre-existing text fidelity, not a
policy problem.

**Recommendation:** no change to `run_corpora.py`'s modeling. Consider
amending the in-code comment/`row["note"]` (or a docstring) to mention the
three non-`#`-prefixed "invalid href" files aren't testing external-resource
policy, so a future reader doesn't read the note text
("external resource not loaded by design") too literally for those three.

## 2. DTD entities — what would a safe, bounded implementation need?

The 4 files are all internal general entities, nothing more exotic:

| file | what it declares | what it does with it |
|---|---|---|
| `structure/svg/attribute-value-via-ENTITY-reference.svg` | `<!ENTITY fill_value "green">` | `fill="&fill_value;"` — text substituted into an attribute value |
| `structure/svg/elements-via-ENTITY-reference-1.svg` | `<!ENTITY Rect "<rect .../>">` | `&Rect;` inside element content — expands to markup |
| `structure/svg/elements-via-ENTITY-reference-2.svg` | one entity, same markup shape | referenced *twice* (`&Rect;` used in two `<g>`s) |
| `structure/svg/elements-via-ENTITY-reference-3.svg` | entity whose expansion itself contains a `<use xlink:href='#rect1'/>` | referenced twice; nesting is one level (entity → markup → ordinary same-doc `use`), not entity → entity |

None declare a parameter entity (`<!ENTITY % ...>`), none use `SYSTEM`/
`PUBLIC` (external entities), and none reference an entity from within
another entity's replacement text (no `&Bomb1;` inside `&Bomb2;`'s
definition) — i.e. none of the four is a billion-laughs shape. resvg
handles all four (`rc=0`); lean-svg rejects all four today with
`DTD internal subset is not allowed` (`LeanSvg/Xml.lean:169`), a deliberate,
documented invariant: "No DTD internal subset ... This removes entity
expansion attacks (billion laughs) and external entities (XXE) by
construction; there is no code path that could expand an entity."

**What usvg actually relies on.** usvg doesn't implement entity expansion
itself — it gets it from its XML dependency, `roxmltree` (`crates/usvg/
Cargo.toml`: `roxmltree = "0.21.1"`). Reading roxmltree's own parser
(`src/parse.rs`), its entity support is already exactly the "safe, bounded"
shape this section is asked to describe, and it's worth using as the
existing precedent rather than inventing one from scratch:

* **General entities only, internal subset only.** roxmltree parses
  `<!ENTITY name "value">` declarations out of the internal `[...]` subset
  and substitutes `&name;` with the *literal replacement text*, re-parsed
  as XML content (that's how `&Rect;` becomes a real `<rect>` element and
  not literal angle-bracket text). It does not implement `SYSTEM`/`PUBLIC`
  external entities (there is an `EntityResolver` hook, but the built-in
  parser never calls out to the filesystem or network for one) and does
  not implement parameter entities (`%name;`).
* **A hard expansion budget**, via a `LoopDetector`: nesting depth capped
  at 10 (an entity's replacement text referencing another entity, ten deep,
  errors as `EntityReferenceLoop`), and at most 255 entity references
  consumed per depth level. That combination is a textbound on total
  expansion work (bounded fan-out × bounded depth), which is precisely what
  defeats "lol9"-style exponential blowup while still allowing the
  legitimate, small, non-recursive uses the 4 test files exercise.

**What a bounded implementation here would need to add**, staying inside
the existing invariants (no recursion beyond fuel, every loop bounded by
input size or a constant, no `partial`):

1. **Collect, don't just skip, the internal subset.** `Xml.lean`'s DOCTYPE
   handling would need to scan `[...]` for `<!ENTITY name "value">`
   declarations only (reject on sight: `%`, `SYSTEM`, `PUBLIC`, or a
   declaration other than `ENTITY` inside `[...]`) into a small table —
   bounded by a constant max-entity count and max-declaration-size, both
   checked before insertion so the table itself can't be the resource sink.
2. **Extend `decodeValue`/text decoding** to look an unrecognized `&name;`
   up in that table (currently: `else throw s!"unsupported entity reference
   &{toStr name};"`), splicing in the replacement bytes.
3. **An expansion budget carried through recursion**, the direct analogue
   of `LoopDetector`: a fuel parameter decremented once per entity
   substitution and once per nesting level, threaded through wherever
   `&name;` can appear (attribute values, text content, and — since
   entities can expand to markup, not just text — the event stream itself,
   which means the entity table has to be available to the *tokenizer*,
   not just to attribute decoding). Cap total expanded bytes, not just
   reference count, since a small reference count can still multiply
   through nested entities (`&A;` = 1000 `&B;`s, `&B;` = 1000 `x`s is 2
   references deep and 10^6 bytes) — roxmltree's depth-10 × 255-refs bound
   is one way to get this; a direct "stop once total emitted bytes exceeds
   N" counter is another and arguably simpler to reason about in Lean.
4. **Markup-shaped entities re-enter the tokenizer**, not just the byte
   stream: `&Rect;`'s replacement text is `<rect .../>` and must become
   real `open_`/`close` events, which means entity expansion has to happen
   as a preprocessing pass over raw bytes before (or interleaved with) the
   existing iterative tokenizer, or the tokenizer needs to be able to
   "splice in and continue" mid-stream. Either way it's a real structural
   change to `Xml.lean`, not a small patch to `decodeValue`.

**Risks**, in rough order of how likely they are to bite:

* **Scope creep back into a general XML entity engine.** The four test
  files only exercise flat, non-nested, twice-at-most-reused entities;
  the temptation once the table exists is to also support parameter
  entities or entity-referencing-entity chains "since we're in there",
  which is exactly the billion-laughs shape the current design refuses by
  construction. Any implementation should keep the "no entity may appear
  in another entity's replacement text" restriction (stricter than
  roxmltree's depth-10, and trivially still enough for these 4 files),
  which removes the exponential-blowup shape entirely rather than merely
  bounding it.
* **New attack surface in the tokenizer**, not just the entity table: once
  entity replacement text can inject markup, a malicious entity value
  becomes a second, less-audited way to smuggle in `<!DOCTYPE`/`<!ENTITY`-
  shaped bytes, XML declarations, or content that reopens elements the
  depth/element caps were sized around — every downstream cap (`maxDepth`,
  `maxElements`) needs to see post-expansion content, and the *pre*-
  expansion byte count is no longer a bound on element count the way it is
  today (one entity reference used many times inflates element count
  without inflating input size, so `maxElements` must be checked against
  the expanded stream, and the loop that expands entities must itself be
  bounded independent of that check, or a document just under the entity
  budget but referencing itself many times could still stall element
  counting).
* **This is 4 files out of 1679** (0.24% of the resvg suite) for a change
  that touches the tokenizer, a security invariant that's called out by
  name in three places (`Xml.lean`'s module doc, `DESIGN.md`'s threat
  model table, `tasks/README.md`'s invariant list) and in the T64 report
  ("Reintroducing entity expansion to pass 4 test files would undo a
  documented security invariant, not fix a bug"). The cost/benefit only
  looks different if entity support is wanted for its own sake, not to
  chase these 4 files.

**This is a question for Rowan, not a recommendation** — per the task, no
implementation was attempted.

## 3. Refused inputs — `zero-size.svg`, `negative-size.svg`

Both set an explicit `width`/`height` (`0`/`0`, and `-50`/`-100`) on the
root `<svg>` with no `viewBox` to fall back to. Both resvg and lean-svg
refuse to render, and refuse for the same structural reason: an explicit
non-positive size on the root element is invalid regardless of anything
`--width`/`-w` could rescale afterwards.

```
$ resvg -w 100 structure/svg/zero-size.svg out.png
Error: SVG has an invalid size.
$ .lake/build/bin/lean-svg structure/svg/zero-size.svg out.png --width 100
lean-svg: error: image size must be positive
```

(Same for `negative-size.svg`, same two messages.) `-w`/`--width` doesn't
change the outcome for either renderer — the check is on the *document's*
declared size, before any rescale, which is `Render.lean:116`:
`if wFx ≤ 0 || hFx ≤ 0 then throw "image size must be positive"`, and this
is exactly the kind of thing `tasks/README.md`'s "fail loudly rather than
silently" invariant asks for: a malformed document is rejected with a clear
error, not coerced into some fallback canvas size.

**What the harness already does, and it's already correct.** In
`run_corpora.py`, `render_one` runs the reference (`resvg`) first; when
`rc_ref != 0` the row is marked `status = "ref_failed"` and the function
returns *before ever invoking lean-svg* (`render_one`, the `if to_ref or
rc_ref != 0` branch). `ref_failed` is not `pass` and is not `fail` — it's
excluded from `pass_all`/`pass_rendered` entirely (`stats_for`'s `Counter`
buckets it separately), so these two files cannot move the score in either
direction. This is already documented policy, not something this audit is
discovering: `tasks/T64-structure-tail-2.md`'s "Skipped" section says so
explicitly ("`status ref_failed` — resvg itself errors out on these ...
so there is no reference image to ever match; not fixable by construction
of the test harness"), and `tasks/T24b-transform-origin-percent.md` and
`tasks/T15-external-corpora.md` both independently note the same two files
the same way.

**What we should count:** keep `ref_failed`, excluded from both pass
percentages, exactly as today. The one thing the current harness doesn't
verify — because it stops before running lean-svg at all — is that our own
refusal is the *right kind* of refusal (an intentional, documented reject
with a clear message, not a crash, hang, or a "succeeds with garbage"
outcome). That's already true by inspection above, but it isn't exercised
by any automated check against these two specific files today; the closest
existing coverage is `tests/run_adversarial.py`'s general malformed-input
suite. If it's ever worth locking in, a cheap one-line addition to
`run_corpora.py` would be: for `ref_failed` rows, also run lean-svg and
assert its exit code is non-zero (never mind matching a reference image,
which doesn't exist) — catches a future regression where our own reject
silently disappears without needing a pixel reference at all. Not
recommending this as a required change, just noting it's the one gap.

**A closely related third file, found while checking this: `structure/svg/
not-UTF-8-encoding.svg`.** Same `ref_failed` bucket (`resvg` errors
`provided data has not an UTF-8 encoding`), same "excluded from scoring, by
design" treatment in the same task docs (`T64`, `T24b`) — but lean-svg does
*not* refuse it (`rc=0`, renders something). Not one of the two files named
in this task, and not scored either way today since it's still
`ref_failed` regardless of what lean-svg does with it, but it's worth
flagging as a real asymmetry (unlike the two size files, where both
renderers agree to refuse): our XML reader is more lenient about invalid
UTF-8 than resvg is. Whether that's worth tightening is a separate,
smaller question than the entity one — noted here, not investigated
further, since it wasn't asked for and doesn't affect any score.

## 4. Fonts

The harness pins the resvg oracle to `tests/corpora/resvg-test-suite/fonts`
(`--skip-system-fonts --use-fonts-dir ...`, `tests/run_tests.py:40-54`,
also used by `run_corpora.py`). That directory has 12 real font families
(Noto Sans in Regular/Bold/Italic/Light/Thin/Black/ExtraCondensed, Noto
Serif, Noto Mono, Noto Emoji/Color Emoji, Noto Sans Devanagari, Amiri,
M PLUS 1p, Source Sans Pro, Sedgwick Ave Display, Yellowtail). lean-svg
embeds exactly three subsetted faces (`tests/gen_font_module.py`'s default
unicode ranges: Basic Latin, Latin-1 Supplement, Latin Extended-A, General
Punctuation, plus U+20AC) — Noto Sans Regular/Bold/Italic — and, per
`LeanSvg/Text.lean`: "`font-family` selects nothing: every family falls
back to Noto Sans. Weight and slant pick among the three." So a result
depends on a font we don't have whenever either (a) `font-family` resolves,
in resvg, to a real face that isn't our embedded Regular/Bold/Italic, or
(b) the text contains characters outside our subset's codepoint ranges,
regardless of `font-family`.

**(a) Family/weight/stretch resolves to a face we don't embed.**

Family, `text/font-family/` (12 files; I rendered all 12 through the pinned
oracle and diffed each against `noto-sans.svg` — the ones that come out
identical are the ones where resvg also lands on plain Noto Sans):

| file | resvg (pinned fonts) picks | fair gap? |
|---|---|---|
| `noto-sans.svg`, `double-quoted.svg`, `fallback-2.svg` | Noto Sans (matches us) | no gap |
| `source-sans-pro.svg` | Source Sans Pro (real match, it's in the fonts dir) | yes |
| `font-list.svg` (`'Source Sans Pro', Noto Sans, serif`) | Source Sans Pro (first candidate matches) | yes |
| `sans-serif.svg`, `bold-sans-serif.svg`, `serif.svg`, `cursive.svg`, `fantasy.svg`, `monospace.svg`, `fallback-1.svg` (`font-family="Invalid"`) | **no font at all** — `usvg::text:143: No match for '<family>' font-family`, text silently dropped | yes, but in the *other* direction: resvg draws nothing, we still draw the text in Noto Sans (over-render, not under-render) |

The generic-keyword and "no match" cases are worth calling out specifically
because the direction of the mismatch is the opposite of the usual "we're
missing a font" story: with `--skip-system-fonts` and this fonts directory,
which has no generic-family aliases configured, resvg cannot resolve
`serif`/`sans-serif`/`cursive`/`fantasy`/`monospace`/an unknown name to
*any* face and drops the text run entirely, while lean-svg's
always-fall-back-to-Noto-Sans policy renders it anyway. Both are "fair" in
the sense that neither is a bug — resvg's behavior here is an artifact of
how the harness pins fonts (a normal, non-`--skip-system-fonts` resvg would
find a real sans-serif on the host and render something), and ours is the
documented, deliberate fallback policy — but they point in opposite
directions, so a fidelity score on these 7 files is really scoring "do we
also fail to find a generic font," which we never will by design.

Weight, `text/font-weight/` (12 files): I isolated resvg's actual
weight-to-face mapping empirically (single-run test files, one weight
each, pinned fonts) rather than guessing from the numbers:

```
{100, 200} -> one face (Thin/Light-ish)         300 -> its own face (Light)
{400, 500, 650} -> Regular                      {600, 700} -> Bold
{800, 900} -> Black
```

`pickFace` (`LeanSvg/Text.lean`) only has Regular/Bold, split at weight 600,
which agrees with resvg's own {400,500,650}/{{600,700}} split — so most of
the directory is fine. Three files land in a bucket we don't have a face
for: `lighter-with-clamping.svg` (resolves to 100), `lighter-without-
parent.svg` (resolves to 200), `bolder-with-clamping.svg` (resolves to
900, i.e. Black, not Bold). `invalid-number-1.svg` (`font-weight="1500"`,
out of the valid CSS range) is *not* a gap — I checked it separately and
resvg falls back to plain 400/Regular for an out-of-range number, which is
what we'd also want, so it isn't scored here as font-dependent (whether our
own parser actually falls back the same way for `1500` is a parsing
question, not a font-availability one, and out of this audit's scope).

Stretch, `text/font-stretch/` (3 files: `extra-condensed.svg`, `inherit.svg`,
`narrower.svg`): the fonts dir has a real `NotoSans-ExtraCondensed.ttf`,
resvg uses it, and lean-svg has no stretch axis at all (ignores
`font-stretch` entirely) — all 3 are a fair font gap.

**A related but distinct finding, not a font-availability gap:**
`text/font/simple-case.svg` uses `font="bold italic 64 Noto Sans"` — a
combination neither renderer has an exact face for (there's no
`NotoSans-BoldItalic.ttf` in the pinned fonts dir either), so this is
genuinely about a *tie-break* between the faces both renderers do have.
I isolated which way resvg breaks the tie (identical single-run test
files, `font-weight="bold" font-style="italic"` vs. each alone): resvg
picks **Italic** (style wins over weight in its matching order). `pickFace`
picks **Bold** — its own comment says so: "bold wins over italic because
there is no bold-italic subset." That's the opposite tie-break from what
resvg actually does with the same two faces available. This isn't a "font
we don't have" — flipping `pickFace`'s tie-break wouldn't need a new font —
so I'm not counting it as a policy exception; it reads like a fixable
correctness gap, flagged here because it surfaced during this audit and
would otherwise get miscategorized as an unavoidable font-fidelity issue if
someone only checked "do we have this font."

**(b) Text containing codepoints outside the embedded subset**, regardless
of what `font-family` says (scanned every `.svg` under `text/` for
characters outside `U+0020-007F, U+00A0-00FF, U+0100-017F, U+2000-206F,
U+20AC`, stripping tags to approximate text/title/desc content):

```
Arabic script:     direction/rtl.svg, font-kerning/arabic-script.svg,
                   letter-spacing/{mixed-scripts,on-Arabic}.svg,
                   text/bidi-reordering.svg, text/fill-rule=evenodd.svg,
                   text/rotate-on-Arabic.svg,
                   text/x-and-y-with-multiple-values-and-arabic-text.svg,
                   text-anchor/on-tspan-with-arabic.svg,
                   textLength/{arabic,arabic-with-lengthAdjust}.svg,
                   tspan/bidi-reordering.svg, unicode-bidi/bidi-override.svg,
                   writing-mode/{arabic-with-rl,mixed-languages-with-tb,
                   mixed-languages-with-tb-and-underline}.svg   (18 files)
CJK (Japanese):    alignment-baseline/hanging-on-vertical.svg,
                   textPath/{complex,writing-mode=tb}.svg,
                   writing-mode/{japanese-with-tb,mixed-languages-with-tb,
                   mixed-languages-with-tb-and-underline,
                   tb-and-punctuation,tb-with-rotate,
                   tb-with-rotate-and-underline}.svg              (8 files,
                   2 already counted above under Arabic — mixed-language)
Devanagari:        dominant-baseline/{hanging,use-script}.svg     (2 files)
Emoji:             text/{emojis,compound-emojis,
                   compound-emojis-and-coordinates-list}.svg      (3 files)
Cyrillic/combining:  text/escaped-text-4.svg (Cyrillic А),
                   text/{complex-grapheme-split-by-tspan,
                   complex-graphemes-and-coordinates-list,
                   complex-graphemes,zalgo,
                   rotate-with-multiple-values-and-complex-text}.svg
                   (combining diacritics)                        (6 files)
letter-spacing/non-ASCII-character.svg (U+534A, CJK)              (1 file)
```

36 files total (some counted in more than one script bucket above; 36 is
the deduplicated file count). None of these are "fair failures" purely
about font coverage in the way (a) is — our embedded subset is Latin-only
by construction (`gen_font_module.py`'s default `--unicodes`), and even a
full Noto Sans face wouldn't help most of them, since `LeanSvg/Text.lean`
also documents "no ligatures, no complex-script shaping, no BiDi
reordering, every run is left to right" and none of writing-mode's
vertical text is implemented either. So font coverage is real (these
codepoints decode to `.notdef`/no outline via `Font.glyphId`'s "`0` if the
codepoint is not mapped", confirmed these render without crashing — `rc=0`
on every file I ran directly), but it's one of several compounding gaps
(shaping, bidi, vertical writing-mode) for most of these 36, not the sole
cause. Fair to exclude from a "fonts" bucket alone; fair to treat as
out-of-scope by the same logic `FEATURES.md` already applies to text
generally ("text and fonts (use the usvg route)").

**Summary table for this section:**

| bucket | files | fair exception? |
|---|---|---|
| family resolves to a real non-Noto-Sans face we have | 2 (`source-sans-pro.svg`, `font-list.svg`) | yes — genuine font gap |
| generic keyword / unknown name resvg also can't resolve | 7 | yes, but direction-reversed (we over-render) |
| weight resolves to Thin/Light/Black, not Regular/Bold | 3 | yes — genuine font gap |
| stretch (condensed) | 3 | yes — genuine font gap |
| bold+italic tie-break | 1 | **no** — fixable tie-break bug, not a font gap |
| non-Latin script / emoji glyph coverage | 36 | yes, compounded with unimplemented shaping/bidi/vertical text |

**Recommendation:** document these buckets (this file, plus a short pointer
from `FEATURES.md`'s "Not doing" list, which currently only says "text and
fonts (use the usvg route)" without enumerating why) so a future
pass-rate regression search doesn't waste time on files that can't pass
under the pinned-font harness by construction. Fixing `pickFace`'s
bold/italic tie-break is cheap and unrelated to font policy — worth a
follow-up task, not part of this audit.

## 5. Anything else that should be a documented policy exception

* **`structure/svg/not-UTF-8-encoding.svg`** — see §3; a third
  `ref_failed` file, already excluded from scoring by construction, but
  the one where our own leniency (we don't refuse) diverges from resvg's
  strictness (it does). Worth a note next to the entity/size exceptions
  since a reader auditing "files resvg refuses" would otherwise find only
  2 of the 3 documented.
* **`structure/svg/{mixed-namespaces,xmlns-validation}.svg`** and
  **`structure/svg/no-size.svg`** — already dispositioned in
  `tasks/T64-structure-tail-2.md`'s "Skipped" section (no XML-namespace
  concept anywhere in the tree walk; `no-size.svg` needs a second,
  bounding-box-driven layout pass). Not re-litigated here since T64 already
  documents them as deliberate scope cuts with reasoning; flagging only so
  this audit's reader knows they were considered and are covered elsewhere.
* **No corpus file trips a hard resource cap.** Checked: no file in the
  1,679-file resvg-test-suite exceeds 1 MiB (`maxInput` is 64 MiB), and the
  deepest element nesting in the corpus is 15 (`Xml.maxDepth` is 64,
  `Svg.maxLayerDepth`/`Use.maxDepth`/clip nesting fuel are all similarly far
  from being reached by anything in this corpus). So none of the DoS-budget
  invariants in `DESIGN.md`'s threat-model table currently produce a
  corpus-scoring artifact — worth recording as a clean bill of health
  rather than leaving it unchecked.
* **`DESIGN.md` §3.11 (Filters) is stale and self-contradictory, which
  matters for correctly scoping "not implemented" claims.** While
  confirming what's font-dependent among filter-adjacent tests, I found
  `LeanSvg/Filter.lean:532`: `def isKnownUnsupported (_ : String) : Bool :=
  false` — a stub that always returns `false`, sitting under a doc comment
  ("The tags usvg converts but this renderer does not implement yet") that
  no longer matches its own body, while every one of the primitives that
  comment used to gate (`feImage`, `feTurbulence`, `feMorphology`,
  `feConvolveMatrix`, `feDiffuseLighting`, `feSpecularLighting`, `feTile`,
  `feDisplacementMap`) is unconditionally listed as a real, parsed
  primitive a few lines later in `isPrimitive`, each with its own
  conversion function and its own `LeanSvg/Filter/*.lean` module. `DESIGN.md`
  still says, twice, in the same section: "Primitives usvg knows but this
  renderer does not implement (lighting, turbulence, morphology,
  convolution, tile, displacement, a `gamma` transfer function) make the
  whole `filter` value resolve to 'no filter'" — immediately followed by a
  paragraph saying `feTile`/`feDisplacementMap`/`gamma` "were added in
  T70," and then the same "does not implement" sentence repeated a third
  time verbatim a few lines later. This isn't a corpus-scoring problem (no
  test file is misclassified by it, since `isKnownUnsupported` is dead code
  that never fires), but it is exactly the kind of stale doc that would
  make a future audit — or a future task picking "unimplemented filter
  primitives" off `DESIGN.md` as a to-do list — repeat work that's already
  done, or worse, remove the now-unnecessary `isKnownUnsupported` stub
  without noticing its doc comment was the only place still claiming a gap
  that no longer exists. Recommend cleaning up `DESIGN.md` §3.11's
  leftover "not implemented" paragraph and removing or repurposing the dead
  `isKnownUnsupported` stub in a follow-up (out of scope for this
  policy audit itself, and `LeanSvg/Filter.lean` isn't the I/O code, but
  it's still a code change this task didn't set out to make).
