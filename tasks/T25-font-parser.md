# T25 — TrueType parser as a pure, total function; embedded open-licence fonts  [Sonnet]

## Goal

Milestone M11 step A. A font is bytes; the parser is a **pure total
function** from those bytes to glyph outlines, advances and kerning. It
cannot read, write, or affect anything else: it lives in its own module,
imports only `LeanSvg.Bytes`/`Fixed`/`Geom`, and returns data
(`Array PathCmd` in font units, `Nat` advances). Fonts ship *inside* the
binary as constants, so `Effect.lean` and its theorems are untouched. No
system font is read (that is a separate future item, PLAN M11).

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T25` (branch
`t25-fonts`). New files only, plus `lakefile.toml` (a second executable)
and `LeanSvg.lean` (import lines). Do not modify any existing module.
Invariants in `tasks/README.md` apply: no `partial`, no `unsafe`, no
`panic!`, no `!`-indexing, no `Float`, every loop a bounded `for`.

## Files

- `LeanSvg/Font.lean` — the parser (see below).
- `LeanSvg/Fonts/NotoSans.lean` (and `NotoSansBold.lean`,
  `NotoSansItalic.lean` if the suite ships them) — generated: a hex string
  constant plus `def bytes : ByteArray := Font.hexDecode hexData` (decode
  is total: two hex chars per byte, invalid chars → stop). Keep each
  module under ~300 KB of source by subsetting (below).
- `LeanSvg/Fonts/LICENSE-OFL.txt` — the licence text of the embedded fonts.
- `tests/gen_font_module.py` — `.ttf` → Lean module generator (also runs
  the subsetter).
- `FontDump.lean` + `[[lean_exe]] name = "fontdump"` — a debug tool:
  `fontdump <font.ttf> <text>` prints, as JSON, per character: glyph id,
  advance, the raw quadratic contours (points with on/off flags, font
  units), and the pair kerning to the next character. `fontdump --embedded
  NotoSans <text>` uses the constant. This is the only `IO` (it reads the
  font path given on the command line) and it is a separate executable;
  `lean-svg` does not link it.
- `tests/check_font.py` — the oracle check (below).
- `tests/fuzz_font.py` — totality check (below).

## Fonts to embed

Look in `/Users/rowancallahan/pdf_renderer/tests/corpora/resvg-test-suite/fonts/`
(read-only) and list what is there with licences. Prefer **Noto Sans**
(OFL). Subset with fontTools (`pip3 install --user fonttools`, then
`pyftsubset`) to Basic Latin, Latin-1 Supplement, Latin Extended-A and
General Punctuation, `--no-hinting --layout-features=kern --glyph-names`
so the subset keeps `kern`/GPOS pair kerning and the `.notdef` glyph.
Record the exact command and the resulting sizes in the report. If the
suite has no fonts directory, download Noto Sans from
https://github.com/notofonts/latin-greek-cyrillic/releases (OFL) and say so.

## Parser (`LeanSvg/Font.lean`)

```
structure Font where
  unitsPerEm : Nat            -- from head
  numGlyphs  : Nat            -- maxp
  ascender descender lineGap : Int   -- hhea
  ... offsets/lengths of the tables it needs, validated against bs.size
  data : ByteArray

def parse (bs : ByteArray) : Option Font
def glyphId (f : Font) (codepoint : Nat) : Nat            -- 0 = .notdef
def advance (f : Font) (gid : Nat) : Nat                  -- font units
def kern (f : Font) (left right : Nat) : Int              -- font units, 0 if none
def outline (f : Font) (gid : Nat) : Array PathCmd        -- font units, y up, as in the font
def rawContours (f : Font) (gid : Nat) : Array (Array (Int × Int × Bool))  -- for fontdump/check
```

Tables (OpenType spec, https://learn.microsoft.com/typography/opentype/spec/):
`head` (unitsPerEm, indexToLocFormat), `maxp` (numGlyphs), `cmap` (table
record for platform 3 encoding 1 or 10, or platform 0; subtable formats 4
and 12; anything else → `glyphId` returns 0), `loca` (short ×2 / long),
`glyf` (simple glyphs: endPtsOfContours, instructionLength skip, flags with
REPEAT, x/y deltas with the SHORT/SAME bits; composite glyphs: flags
`ARG_1_AND_2_ARE_WORDS`, `ARGS_ARE_XY_VALUES`, `WE_HAVE_A_SCALE`,
`WE_HAVE_AN_X_AND_Y_SCALE`, `WE_HAVE_A_TWO_BY_TWO`, `MORE_COMPONENTS`;
F2Dot14 transforms applied in integer arithmetic with rounding to font
units; point-matching args (`ARGS_ARE_XY_VALUES` clear) may be treated as
offsets 0 and reported), `hhea` (numberOfHMetrics), `hmtx`, `kern` (format 0
subtables, horizontal; linear or binary search over the pair list, bounded
by nPairs), and GPOS pair adjustment (LookupType 2, formats 1 and 2, only
the horizontal advance of the first glyph; if the lookup is absent, fine).

Quadratic contours → `PathCmd`: TrueType rule (implied on-curve midpoint
between two consecutive off-curve points; a contour starting off-curve
starts at the midpoint or the last on-curve point); each quadratic
`(p0, q, p1)` becomes `cubicTo (p0 + 2/3(q−p0)) (p1 + 2/3(q−p1)) p1` with
`Int.ediv` exactly as `Svg.parsePathData` does for `Q`. Close every
contour.

Bounds: every read goes through a helper that returns 0 past `bs.size`;
table offsets are checked against `bs.size` in `parse`; composite
recursion uses fuel 8 and a component cap of 64; points per glyph ≤
`maxp.maxPoints` or 10 000; `numGlyphs ≤ 65 535`. `parse` rejects fonts
over 8 MiB.

## Verify

1. **Oracle check** `python3 tests/check_font.py <font.ttf> [text]`:
   with fontTools, for every character in a default string covering
   ASCII printable plus `éàüß€“”—` and for every glyph in the subset when
   `--all` is given, compare: glyph id (`getBestCmap`), advance
   (`hmtx`), raw contours (`glyph.getCoordinates(glyfTable)` → points and
   `flags & 1` on-curve, per contour via `endPtsOfContours`), and kerning
   pairs for adjacent characters (from `kern` if present, else GPOS via
   fontTools' `getGPOS` pair values, or skip with a note). Exact integer
   equality. Run it on the embedded subset (via `fontdump --embedded`)
   and on the original full Noto Sans (via `fontdump path`). Report
   counts: glyphs compared, mismatches (must be 0).
2. **Totality fuzz** `python3 tests/fuzz_font.py <font.ttf> --iters 2000
   --seed 1`: byte flips, truncations, table-offset corruption, `loca`
   scrambling, composite cycles (point a component at its own glyph id),
   huge `numGlyphs`; run `fontdump` on each mutant with a 20 s timeout and
   assert exit code 0 or 1, no signal, no timeout, no `PANIC`/`Stack
   overflow` in stderr. Report the counts.
3. `lake build` clean (both executables); `git diff main -- LeanSvg/`
   shows only new files plus the import lines; `run_tests.py` byte-identical
   (the renderer is unchanged); `run_adversarial.py` clean.

Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
Append `## Report`: fonts embedded (names, licence, sizes), oracle and
fuzz counts, any table or feature you skipped.

## Report

### Files

New: `LeanSvg/Font.lean` (parser, ~34 KB source), `LeanSvg/Fonts/{NotoSans,
NotoSansBold, NotoSansItalic}.lean` (generated), `LeanSvg/Fonts/LICENSE-OFL.txt`
(copy of `Noto-LICENSE-OFL.txt`), `FontDump.lean`, `tests/gen_font_module.py`,
`tests/check_font.py`, `tests/fuzz_font.py`. Changed: `LeanSvg.lean` (+1 import
line), `lakefile.toml` (+1 `[[lean_exe]]` for `fontdump`, `fontdump` added to
`defaultTargets`). `LeanSvg/Effect.lean` untouched (`git diff <merge-base> --
LeanSvg/Effect.lean` empty). No existing module's logic was edited — confirmed
via `git diff <merge-base> -- LeanSvg/`, which is empty except for the one
import line (the `Font.lean`/`Fonts/` files are new and untracked, so they don't
show in a diff of tracked content; `git status` lists them all as `??`).

`resvg-test-suite/fonts/` (read-only, listed with licences) has Noto Sans
Regular/Bold/Italic/Black/Light/Thin/ExtraCondensed (OFL), Noto Serif, Noto
Mono, Noto Emoji + Color Emoji, Amiri (OFL), M PLUS 1p (OFL), Source Sans Pro
(OFL), Sedgwick Ave Display (OFL), Yellowtail (Apache 2.0). Embedded the three
the spec asks for: Noto Sans Regular, Bold, Italic, all OFL.

### Fonts embedded

Subsetted with `pyftsubset` (fontTools 4.56.0) to Basic Latin, Latin-1
Supplement, Latin Extended-A, General Punctuation, **plus U+20AC** (Euro
sign — it's in the *Currency Symbols* block, not *General Punctuation* as
the four named blocks would suggest, but the spec's own default oracle
probe string includes "€", so it needs a real glyph rather than trivially
matching `.notdef` on both sides of the oracle check):

```
pyftsubset <input.ttf> --output-file=<out.ttf> \
  --unicodes=U+0020-007F,U+00A0-00FF,U+0100-017F,U+2000-206F,U+20AC \
  --no-hinting --layout-features=kern --glyph-names --notdef-outline
```

| Font              | Original   | Subset    | numGlyphs | Lean source | Build time (alone) |
|-------------------|-----------:|----------:|----------:|-------------:|--------------------:|
| NotoSans Regular  | 455,188 B  | 32,096 B  | 445       | 64,779 B     | ~0.25–0.9 s          |
| NotoSans Bold     | 455,164 B  | 32,132 B  | 445       | 64,859 B     | ~0.25 s              |
| NotoSans Italic   | 470,472 B  | 32,800 B  | 446       | 66,199 B     | ~0.25 s              |

All three easily fit the "reasonable time" budget, so no splitting beyond the
generator's default was needed. Each module's hex data is still emitted as an
`Array String` of 4 chunks of 20,000 hex chars (10 KB decoded) each, rather
than one giant string literal, as the spec suggests trying — cheap insurance
even though these subsets (~32 KB decoded, ~64 KB hex) never came close to
the "~2 minute" concern. **Timings**: a full clean `lake build` of both
executables (37 jobs: the `LeanSvg` library incl. `Font.lean` and the three
`Fonts.*` modules, `lean-svg`, and `fontdump`) took **4.5–5.1 s** wall clock
across several from-scratch runs; `LeanSvg.Font` alone built in 0.7–0.9 s,
each `Fonts.*` module in ~0.25–0.28 s. No part of this project's build is
anywhere near a bottleneck from font embedding.

### Oracle check (`tests/check_font.py`)

Default probe text = ASCII printable (U+0020–007E, 95 chars) + `éàüß€“”—`
(103 characters total). `--all` uses every codepoint in the font's own
`cmap` (C0/C1 control codepoints excluded — `chr(0)` can't survive as a
subprocess argv byte, and they carry no shape worth testing).

| Check                                              | Glyphs compared | Mismatches |
|-----------------------------------------------------|----------------:|-----------:|
| Embedded NotoSans, default text                      | 103             | 0          |
| Embedded NotoSans, `--all` (every subset glyph)      | 431             | 0          |
| Embedded NotoSansBold, `--all`                       | 431             | 0          |
| Embedded NotoSansItalic, `--all`                     | 431             | 0          |
| Original NotoSans-Regular.ttf (full font), default   | 103             | 0          |
| Original NotoSans-Regular.ttf (full font), `--all`   | 2,791           | 0          |

Kerning oracle source for every row above: `GPOS` (lookup type 2, both
`PairPos` formats 1 and 2 appear in Noto Sans) — **Noto Sans ships no legacy
`kern` table at all**, confirmed directly against the raw bytes; kerning is
entirely a `GPOS` "kern" feature. `Font.kern`'s legacy-`kern`-table code path
is therefore implemented (format 0, per spec) but unexercised by these
fonts; it was sanity-checked by hand against a synthetic table during
development, not by the oracle.

Two bugs surfaced and fixed *in this oracle script* while chasing
mismatches (neither was a bug in `LeanSvg/Font.lean`):
1. `--all`'s text built from `sorted(cmap.keys())` included U+0000, which
   crashed `subprocess.run` with "embedded null byte" — fixed by excluding
   C0/C1 control codepoints.
2. `Glyph.getCoordinates()` defaults to `round=noRound`; for a
   composite-of-composite glyph (deeply nested combining-mark stacks, e.g.
   in the Cyrillic Extended block — outside our embedded Latin subset, only
   visible when running `--all` against the *original, unsubsetted* Noto
   Sans) it can still return floats even with `round=otRound` passed in
   (by design — see its docstring: it rounds a simple child's coordinates
   before its *immediate* parent's transform, but defers final rounding
   past that to avoid compounding error). Truncating those with plain
   `int()` produced 231 false-positive mismatches, all off by exactly 1 in
   the truncating direction; switching to fontTools' own `otRound` on the
   final per-point result fixed all 231. `LeanSvg/Font.lean`'s own
   composite handling rounds to whole font units after every transform
   level (`Font.roundDiv14`, `Int.ediv (n + 8192) 16384` — the OpenType
   "round half towards +Infinity" rule, the same idiom as `Fx.round`), a
   deliberate simplification the spec itself asks for ("F2Dot14 transforms
   applied in integer arithmetic with rounding to font units"); after
   fixing the oracle to actually round its own floats it matches this
   exactly, with zero mismatches even on the full font's most deeply
   nested composites.

### Totality fuzz (`tests/fuzz_font.py`)

`python3 tests/fuzz_font.py <NotoSans-Regular.ttf, original> --iters 2000 --seed 1`:
**2000/2000 iterations, 0 violations**, 12.1 s (166/iter/s). Mutator mix
(chosen uniformly at random per iteration, falling back to a byte flip if a
mutator's targeted structure isn't present in the current mutant): byte
flips 324, truncation 353, table offset/length corruption 333, `loca`
scrambling 317, composite cycles (a component glyph pointing at its own —
or another composite's — glyph id) 345, huge `numGlyphs` (0xFFFF/0x8000/
0x7FFF/0xFFFE) 328. A 500-iteration run (seed 42) against the embedded
subset's own `.ttf` was also clean (0 violations), as was an initial
100-iteration smoke test. No run ever hit the 20 s per-mutant timeout, was
killed by a signal, exited outside `{0, 1}`, or printed a panic/stack-overflow
marker.

### `lake build` / renderer regression

Clean `lake build`: 37/37 jobs, **no errors, no warnings**, ~4.5–5.1 s wall.
`git diff <merge-base> -- LeanSvg/` is empty (no existing module edited);
`git diff <merge-base> -- LeanSvg.lean lakefile.toml` is exactly the one
import line and the one new `[[lean_exe]]` block plus `defaultTargets`.
`python3 tests/run_tests.py`: **17/21 passed** — identical to the
pre-T25 baseline (`SESSION_SUMMARY.md`), confirming the renderer itself is
byte-for-byte unaffected; the 4 failures are pre-existing and unrelated to
fonts. `python3 tests/run_adversarial.py`: **38/38 clean, 0 violations**.

(Note: `main` has moved on since this branch was cut from merge-base
`4ab8990` — other tasks landed 22–23 corpus files and more adversarial
cases on `main` in the meantime. This worktree was never rebased/merged
(as instructed), so its own 21-file / 38-case baseline is what's compared
against here, and it is unchanged.)

### Skipped / documented limitations

- **Composite point-matching args** (`ARGS_ARE_XY_VALUES` clear — the two
  args name matched points rather than an offset): treated as offset
  `(0, 0)`, as the spec allows ("may be treated as offsets 0 and reported").
  Not exercised by Noto Sans's own composites (all use direct XY offsets,
  confirmed by 0 mismatches on every composite glyph checked).
- **`GPOS` `LookupType 9`** (Extension Positioning, which wraps another
  lookup type behind an indirection) is not unwrapped — only direct
  `LookupType 2` lookups under a `kern` feature are read. Not needed here:
  Noto Sans's kern lookup is a direct type 2.
- **`kern`-feature lookups are gathered across every script/language that
  lists the tag**, not scoped to one script — a harmless superset (Noto
  Sans's `DFLT`/`cyrl`/`grek`/`latn` scripts all reference the same lookup
  index, so this made no observable difference).
- **`.notdef` (glyph id 0)** is never oracle-checked: `fontdump`'s interface
  is codepoint-driven and nothing in `cmap` maps to it. The same simple-glyph
  parsing code path is exercised by every other glyph, so this is a coverage
  footnote, not a suspected correctness gap.
- **Legacy `kern` table**: implemented (format 0, horizontal, per spec) but
  unexercised by any oracle run, since none of the three fonts embed one
  (see above).
