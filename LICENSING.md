# Licensing and credits

lean-svg is licensed under the Apache License 2.0 (`LICENSE`). `NOTICE`
carries these credits and accompanies any redistribution. A per-component
review with links to every upstream licence is in `docs/LICENSING-REVIEW.md`.

This file, the README and `NOTICE` do not restate third-party copyright notices. Those
are in the upstream files, shipped unchanged:

- `licenses/` holds each upstream licence file as a byte-for-byte copy.
  `licenses/MANIFEST.csv` gives each file's pinned source URL, SHA-256 and
  download date.
- Each embedded font keeps its own copyright record (OpenType `name` ID 0)
  unchanged in the binary. `licenses/FONT-SOURCES.csv` gives the upstream
  font file each subset was made from: pinned URL, SHA-256 and download date.

`python3 tests/check_licenses.py` checks the hashes and file lists (CI runs
it). `python3 tests/check_licenses.py --online` re-downloads every licence
file and every upstream font, checks their SHA-256, and checks that each
embedded font's copyright record is identical to the upstream font's. All
these files were downloaded on 2026-09-24.

## Redistributed by this repository

Fonts are subsetted (variable fonts pinned to one instance) into
`LeanSvg/Fonts/*.lean` and compiled into the binary, which their licences
permit. Per-module versions and source URLs: `LeanSvg/Fonts/README.md`.

| component | used for | licence | licence text | downloaded from (2026-09-24) |
|---|---|---|---|---|
| **Noto Sans** Regular, Bold, Italic, Thin, Light, Black, ExtraCondensed 2.000; **Noto Sans Devanagari** 2.003 | Latin/Greek/Cyrillic and Devanagari text | SIL OFL 1.1 | `licenses/fonts/NotoSans-OFL.txt` | [resvg-test-suite@d8e0643 `fonts/`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Noto-LICENSE-OFL.txt) |
| **Mplus 1p** 1.061 | Japanese text | SIL OFL 1.1 | `licenses/fonts/Mplus1p-OFL.txt` | [resvg-test-suite@d8e0643 `fonts/`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/MPLUS1p-LICENSE-OFL.txt) |
| **Amiri** 000.109 | Arabic text | SIL OFL 1.1 | `licenses/fonts/Amiri-OFL.txt` | [resvg-test-suite@d8e0643 `fonts/`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Amiri-LICENSE-OFL.txt) |
| **Noto Sans SC, KR** 2.004 | Chinese, Korean text | SIL OFL 1.1; Reserved Font Name "Source" not used | `licenses/fonts/NotoSans{SC,KR}-OFL.txt` | [google/fonts@23e54b5 `ofl/notosanssc/`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanssc/OFL.txt), [`ofl/notosanskr/`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanskr/OFL.txt) |
| **Noto Sans Thai** 2.002, **Armenian** 2.008, **Georgian** 2.005, **Ethiopic** 2.102, **Hebrew** 3.001 | text in those scripts | SIL OFL 1.1 | `licenses/fonts/NotoSans{Thai,Armenian,Georgian,Ethiopic,Hebrew}-OFL.txt` | google/fonts@23e54b5 `ofl/notosans<script>/` |
| **DejaVu Sans** (Book, Bold, Oblique), **Sans Mono**, **Serif** 2.37 | matplotlib's default family | Bitstream Vera / Arev licence (permissive); names "Bitstream", "Vera", "Arev" not used | `licenses/fonts/DejaVu-LICENSE.txt` | licence: [dejavu-fonts@9b5d1b2 `LICENSE`](https://raw.githubusercontent.com/dejavu-fonts/dejavu-fonts/9b5d1b2ffeec20c7b46aa89c0223d783c02762cf/LICENSE); fonts: [dejavu-fonts-ttf-2.37.tar.bz2](https://sourceforge.net/projects/dejavu/files/dejavu/2.37/dejavu-fonts-ttf-2.37.tar.bz2/download) |
| **Arimo** 1.341, **Cousine** 1.241 | metric-compatible sans and mono | SIL OFL 1.1 | `licenses/fonts/{Arimo,Cousine}-OFL.txt` | [google/fonts@23e54b5 `ofl/arimo/`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/arimo/OFL.txt), [`ofl/cousine/`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/cousine/OFL.txt) |
| **Tinos** 1.340 | metric-compatible serif | SIL OFL 1.1 | `licenses/fonts/Tinos-OFL.txt` | [googlefonts/tinos@3b4482a](https://raw.githubusercontent.com/googlefonts/tinos/3b4482a99b80ea5fc75f187b1be3120a3f5905b3/OFL.txt) (google/fonts no longer has `ofl/tinos`) |
| **STIX Two Math** 2.12, **STIX Two Text** 2.13 | matplotlib's STIX mathtext | SIL OFL 1.1; Reserved Font Name "TM Math" not used | `licenses/fonts/STIXTwo{Math,Text}-OFL.txt` | [google/fonts@23e54b5 `ofl/stixtwomath/`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwomath/OFL.txt), [`ofl/stixtwotext/`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwotext/OFL.txt) |
| **CMU** Serif, Serif Italic, Sans Serif, Typewriter Text 0.7.0 | matplotlib's Computer Modern mathtext | SIL OFL 1.1; Reserved Font Family Name "Computer Modern Unicode fonts" not used | `licenses/fonts/CMU-OFL.txt` | [cm-unicode-0.7.0-ttf.tar.xz](https://sourceforge.net/projects/cm-unicode/files/cm-unicode/0.7.0/cm-unicode-0.7.0-ttf.tar.xz/download) |
| **harfrust** 0.12.0 tables | `LeanSvg/ShapeData.lean`, mirroring table in `LeanSvg/Bidi.lean` | MIT | `licenses/code/harfrust-LICENSE.txt` | [harfbuzz/harfrust@0.12.0 `LICENSE`](https://raw.githubusercontent.com/harfbuzz/harfrust/0.12.0/LICENSE) |
| **unicode-bidi** 0.3.18 tables | Bidi_Class and bracket tables in `LeanSvg/Bidi.lean` | MIT (of MIT OR Apache-2.0) | `licenses/code/unicode-bidi-LICENSE-MIT.txt` | [servo/unicode-bidi@v0.3.18 `LICENSE-MIT`](https://raw.githubusercontent.com/servo/unicode-bidi/v0.3.18/LICENSE-MIT) |
| **brotli** 1.2.0 static dictionary, transforms and context tables | `LeanSvg/BrotliData.lean` | MIT | `licenses/code/brotli-LICENSE.txt` | [google/brotli@v1.2.0 `LICENSE`](https://raw.githubusercontent.com/google/brotli/v1.2.0/LICENSE) |
| **matplotlib** 3.9.2 `stix_virtual_fonts` table | `LeanSvg/StixNonUnicodeTable.lean` | Matplotlib License | `licenses/code/matplotlib-LICENSE.txt` | [matplotlib@v3.9.2 `LICENSE/LICENSE`](https://raw.githubusercontent.com/matplotlib/matplotlib/v3.9.2/LICENSE/LICENSE) |
| **Original artwork and renders** — `tests/svg/*.svg`, `docs/readme/*.svg`, and the README's renders of them | | Apache-2.0, authored for this project. The README's renders of real-world charts are listed with each chart's own licence | `LICENSE` | |

Fonts embedded in an input SVG (`@font-face` with a `data:` URL) are decoded
only to render that one file. They are never stored, cached, written out or
used for any other file, and lean-svg does not redistribute them; their
licences are the concern of whoever made the SVG.

## Real-world test corpus (committed, test data only)

`tests/corpora/realworld/` holds 848 chart SVGs used only as test inputs; none
is compiled into the binary. `SOURCES.csv` records the source, author and
licence of every downloaded file; the licence texts are in
`licenses/corpora/` (sources in `licenses/MANIFEST.csv`).

| component | licence |
|---|---|
| **matplotlib test-suite baseline SVGs** (`mpl-tests/`, 515 files) | Matplotlib License (PSF-based, BSD-compatible). `matplotlib-LICENSE.txt`. |
| **janosh/diagrams** (`web-tikz/`, 50 files) | MIT. `janosh-diagrams-license.txt`. |
| **Vega-Lite examples** (`web-vega/`, 31 files) | BSD-3-Clause. `vega-lite-LICENSE.txt`. |
| **Generated charts** (`tikz/`, `tikz-fonts/`, `graphviz/`, `mermaid/`, `plantuml/`, `matplotlib/`, `matplotlib-text/`) and their sources in `src/` | Apache-2.0, authored for this project. The TikZ SVGs contain glyphs of the AMS Type 1 Computer Modern and AMS symbol fonts (cmr, cmmi, cmsy, cmex, msam, msbm), embedded by dvisvgm as the SIL Open Font License 1.1 permits for fonts embedded in documents. `licenses/corpora/amsfonts-OFL.txt`. |

## Not redistributed

The other test corpora are cloned locally by the test harnesses, are excluded
by `.gitignore`, and are neither committed to this repository nor included in
any release artifact.

| component | licence |
|---|---|
| **resvg test suite** (`tests/corpora/resvg-test-suite`) | MIT |
| **simple-icons** | CC0-1.0 |
| **Feather icons** | MIT |
| **resvg** binary, used as the rendering oracle | Apache-2.0 OR MIT |
| **Pillow**, **NumPy**, **fontTools**, used by the test scripts | MIT-CMU, BSD-3-Clause, MIT |

## Algorithms re-implemented

| component | licence |
|---|---|
| **tiny-skia** — [linebender/tiny-skia](https://github.com/linebender/tiny-skia) | BSD-3-Clause. `licenses/code/tiny-skia-LICENSE.txt`, from [tiny-skia@5d47547 `LICENSE`](https://raw.githubusercontent.com/linebender/tiny-skia/5d4754777746eef0828be166896eaf482c49f8f2/LICENSE) (downloaded 2026-09-24). |
| **Brotli** decoder — RFC 7932, checked against [google/brotli](https://github.com/google/brotli) 1.2.0 | MIT. `LeanSvg/Brotli.lean` is written from the RFC; no C source is included. |

The anti-aliased scan converter, hairline stroking, cubic and quadratic
subdivision counts, dash-splitting rules, `lowp` blend arithmetic, `f32`
layer-compositing pipeline and gradient evaluation in
`LeanSvg/{Raster,Geom,Canvas,Shader}.lean` are fixed-point Lean
re-implementations of tiny-skia's algorithms. No Rust or C++ source is included
in this repository. The licence text, with its notices, is in
`licenses/code/tiny-skia-LICENSE.txt`.

## Behavioural references

| component | licence |
|---|---|
| **resvg** and **usvg** — [linebender/resvg](https://github.com/linebender/resvg) | Apache-2.0 OR MIT, as declared in the workspace manifest at tag `v0.48.1` and on `main`. Releases prior to the relicensing were MPL-2.0. |
| **simplecss** — [linebender/simplecss](https://github.com/linebender/simplecss) | Apache-2.0 OR MIT |
| **svgtypes** — [linebender/svgtypes](https://github.com/linebender/svgtypes) | Apache-2.0 OR MIT |

resvg and usvg define the reference behaviour for this renderer: parsing
defaults, conditional processing, the CSS cascade, paint servers, clipping and
text layout. The CSS selector subset in `LeanSvg/Css.lean` follows simplecss's
grammar; colour, length and transform parsing follow svgtypes. No source from
these projects is included in this repository.

## Language and toolchain

| component | licence |
|---|---|
| **Lean 4** and **Lake** — [leanprover/lean4](https://github.com/leanprover/lean4) | Apache-2.0 |

The project has no other build dependencies.

## Prior art

**lean-zip** — [kim-em/lean-zip](https://github.com/kim-em/lean-zip),
Apache-2.0. The single-input, single-output effect-boundary structure of this
project follows its design. No code is shared.

If you believe something here is miscredited or missing, please open an issue.
