# T25 — TrueType parser as a pure, total function; embedded open-licence fonts  [Sonnet]

## Goal

Milestone M11 step A. A font is bytes; the parser is a **pure total
function** from those bytes to glyph outlines, advances and kerning. It
cannot read, write, or affect anything else: it lives in its own module,
imports only `MicroSvg.Bytes`/`Fixed`/`Geom`, and returns data
(`Array PathCmd` in font units, `Nat` advances). Fonts ship *inside* the
binary as constants, so `Effect.lean` and its theorems are untouched. No
system font is read (that is a separate future item, PLAN M11).

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T25` (branch
`t25-fonts`). New files only, plus `lakefile.toml` (a second executable)
and `MicroSvg.lean` (import lines). Do not modify any existing module.
Invariants in `tasks/README.md` apply: no `partial`, no `unsafe`, no
`panic!`, no `!`-indexing, no `Float`, every loop a bounded `for`.

## Files

- `MicroSvg/Font.lean` — the parser (see below).
- `MicroSvg/Fonts/NotoSans.lean` (and `NotoSansBold.lean`,
  `NotoSansItalic.lean` if the suite ships them) — generated: a hex string
  constant plus `def bytes : ByteArray := Font.hexDecode hexData` (decode
  is total: two hex chars per byte, invalid chars → stop). Keep each
  module under ~300 KB of source by subsetting (below).
- `MicroSvg/Fonts/LICENSE-OFL.txt` — the licence text of the embedded fonts.
- `tests/gen_font_module.py` — `.ttf` → Lean module generator (also runs
  the subsetter).
- `FontDump.lean` + `[[lean_exe]] name = "fontdump"` — a debug tool:
  `fontdump <font.ttf> <text>` prints, as JSON, per character: glyph id,
  advance, the raw quadratic contours (points with on/off flags, font
  units), and the pair kerning to the next character. `fontdump --embedded
  NotoSans <text>` uses the constant. This is the only `IO` (it reads the
  font path given on the command line) and it is a separate executable;
  `microsvg` does not link it.
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

## Parser (`MicroSvg/Font.lean`)

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
3. `lake build` clean (both executables); `git diff main -- MicroSvg/`
   shows only new files plus the import lines; `run_tests.py` byte-identical
   (the renderer is unchanged); `run_adversarial.py` clean.

Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
Append `## Report`: fonts embedded (names, licence, sizes), oracle and
fuzz counts, any table or feature you skipped.
