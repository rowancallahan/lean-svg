# Licensing review (for Rowan to confirm)

Date: 2026-09-24. Scope: everything third-party that this repository **commits**
or **compiles into the binary**. lean-svg itself is Apache-2.0 (`LICENSE`); the
credits that travel with any redistribution are in `NOTICE` and in README
"Licensing and credits".

How this was checked:
- each licence file here is a byte-for-byte copy of a pinned upstream file,
  and each embedded font's copyright record is identical to its upstream
  font's, both checked by `tests/check_licenses.py --online` (see
  "Byte-identical licence texts and font sources" below);
- the `name` table of every embedded font was decoded (from the Lean modules)
  and searched for Reserved Font Names;
- `git ls-files` was used to list what is actually committed.

## 1. Fonts compiled into the binary (`LeanSvg/Fonts/*.lean`)

All are subsets (glyph and table subsets, variable fonts pinned to one
instance), stored as base64 in generated Lean modules.

### What the licences require

**SIL OFL 1.1** ([text and FAQ](https://openfontlicense.org/)) allows
bundling fonts with any software, as long as three conditions hold:

- **(2)** Each copy contains the copyright notice and the licence.
- **(3)** A Modified Version (a subset is one) does not use a Reserved Font
  Name as its primary font name.
- **(5)** The font stays under the OFL. That does not affect our Apache-2.0
  code.

A font may not be sold by itself, but that does not apply to software that
contains it.

**Bitstream Vera / Arev** (DejaVu) requires two things:

- The notice is kept.
- A modified font must not be named "Bitstream", "Vera" or "Arev".

### Per font

| Font (modules) | Licence | Reserved Font Name | Embedded name (checked) | Licence file here | Upstream licence file (pinned, downloaded 2026-09-24) |
|---|---|---|---|---|---|
| Noto Sans Regular, Bold, Italic, Thin, Light, Black, ExtraCondensed | OFL 1.1 | none | "Noto Sans …" | [`licenses/fonts/NotoSans-OFL.txt`](../licenses/fonts/NotoSans-OFL.txt) (the resvg test suite's copy; also covers Noto Sans Devanagari) | [linebender/resvg-test-suite@d8e0643 `fonts/Noto-LICENSE-OFL.txt`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Noto-LICENSE-OFL.txt) ([browse](https://github.com/linebender/resvg-test-suite/blob/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Noto-LICENSE-OFL.txt)) |
| Noto Sans SC, Noto Sans KR | OFL 1.1 | **"Source"** (Adobe) | "Noto Sans SC", "Noto Sans KR": RFN not used | [`licenses/fonts/NotoSansSC-OFL.txt`](../licenses/fonts/NotoSansSC-OFL.txt), [`licenses/fonts/NotoSansKR-OFL.txt`](../licenses/fonts/NotoSansKR-OFL.txt) | [google/fonts@23e54b5 `ofl/notosanssc/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanssc/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanssc/OFL.txt)); [google/fonts@23e54b5 `ofl/notosanskr/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanskr/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanskr/OFL.txt)) |
| Noto Sans Thai, Armenian, Georgian, Ethiopic, Hebrew, Devanagari | OFL 1.1 | none | "Noto Sans …" | [`licenses/fonts/NotoSansThai-OFL.txt`](../licenses/fonts/NotoSansThai-OFL.txt), [`licenses/fonts/NotoSansArmenian-OFL.txt`](../licenses/fonts/NotoSansArmenian-OFL.txt), [`licenses/fonts/NotoSansGeorgian-OFL.txt`](../licenses/fonts/NotoSansGeorgian-OFL.txt), [`licenses/fonts/NotoSansEthiopic-OFL.txt`](../licenses/fonts/NotoSansEthiopic-OFL.txt), [`licenses/fonts/NotoSansHebrew-OFL.txt`](../licenses/fonts/NotoSansHebrew-OFL.txt) (Devanagari: `NotoSans-OFL.txt`, the resvg test suite's copy) | [google/fonts@23e54b5 `ofl/notosansthai/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansthai/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansthai/OFL.txt)); [google/fonts@23e54b5 `ofl/notosansarmenian/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansarmenian/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansarmenian/OFL.txt)); [google/fonts@23e54b5 `ofl/notosansgeorgian/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansgeorgian/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansgeorgian/OFL.txt)); [google/fonts@23e54b5 `ofl/notosansethiopic/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansethiopic/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansethiopic/OFL.txt)); [google/fonts@23e54b5 `ofl/notosanshebrew/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanshebrew/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanshebrew/OFL.txt)) |
| Mplus 1p | OFL 1.1 | none | "Mplus 1p" | [`licenses/fonts/Mplus1p-OFL.txt`](../licenses/fonts/Mplus1p-OFL.txt) (the resvg test suite's copy) | [linebender/resvg-test-suite@d8e0643 `fonts/MPLUS1p-LICENSE-OFL.txt`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/MPLUS1p-LICENSE-OFL.txt) ([browse](https://github.com/linebender/resvg-test-suite/blob/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/MPLUS1p-LICENSE-OFL.txt)) |
| Amiri 000.109 | OFL 1.1 | none | "Amiri" | [`licenses/fonts/Amiri-OFL.txt`](../licenses/fonts/Amiri-OFL.txt) (the resvg test suite's copy) | [linebender/resvg-test-suite@d8e0643 `fonts/Amiri-LICENSE-OFL.txt`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Amiri-LICENSE-OFL.txt) ([browse](https://github.com/linebender/resvg-test-suite/blob/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Amiri-LICENSE-OFL.txt)) |
| DejaVu Sans (Book, Bold, Oblique), Sans Mono, Serif 2.37 | Bitstream Vera + Arev (permissive), DejaVu changes public domain | names "Bitstream", "Vera", "Arev" | "DejaVu …" | [`licenses/fonts/DejaVu-LICENSE.txt`](../licenses/fonts/DejaVu-LICENSE.txt) | [dejavu-fonts/dejavu-fonts@9b5d1b2 `LICENSE`](https://raw.githubusercontent.com/dejavu-fonts/dejavu-fonts/9b5d1b2ffeec20c7b46aa89c0223d783c02762cf/LICENSE) ([browse](https://github.com/dejavu-fonts/dejavu-fonts/blob/9b5d1b2ffeec20c7b46aa89c0223d783c02762cf/LICENSE)) |
| Arimo, Tinos, Cousine | OFL 1.1 (Google relicensed these from Apache 2.0; google/fonts metadata says `license: "OFL"`) | none | "Arimo", "Tinos", "Cousine" | [`licenses/fonts/Arimo-OFL.txt`](../licenses/fonts/Arimo-OFL.txt), [`licenses/fonts/Tinos-OFL.txt`](../licenses/fonts/Tinos-OFL.txt), [`licenses/fonts/Cousine-OFL.txt`](../licenses/fonts/Cousine-OFL.txt) | [google/fonts@23e54b5 `ofl/arimo/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/arimo/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/arimo/OFL.txt)); [googlefonts/tinos@3b4482a `OFL.txt`](https://raw.githubusercontent.com/googlefonts/tinos/3b4482a99b80ea5fc75f187b1be3120a3f5905b3/OFL.txt) ([browse](https://github.com/googlefonts/tinos/blob/3b4482a99b80ea5fc75f187b1be3120a3f5905b3/OFL.txt)); [google/fonts@23e54b5 `ofl/cousine/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/cousine/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/cousine/OFL.txt)) |
| STIX Two Math, STIX Two Text (Regular, Italic) | OFL 1.1 | **"TM Math"** | "STIX Two …": RFN not used | [`licenses/fonts/STIXTwoMath-OFL.txt`](../licenses/fonts/STIXTwoMath-OFL.txt), [`licenses/fonts/STIXTwoText-OFL.txt`](../licenses/fonts/STIXTwoText-OFL.txt) | [google/fonts@23e54b5 `ofl/stixtwomath/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwomath/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwomath/OFL.txt)); [google/fonts@23e54b5 `ofl/stixtwotext/OFL.txt`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwotext/OFL.txt) ([browse](https://github.com/google/fonts/blob/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwotext/OFL.txt)) |
| CMU Serif (Roman, Italic), Sans Serif, Typewriter 0.7.0 | OFL 1.1 | **"Computer Modern Unicode fonts"** (family name) | "CMU Serif", "CMU Sans Serif", "CMU Typewriter Text" | [`licenses/fonts/CMU-OFL.txt`](../licenses/fonts/CMU-OFL.txt) | [`cm-unicode-0.7.0-ttf.tar.xz` member `OFL.txt`](https://sourceforge.net/projects/cm-unicode/files/cm-unicode/0.7.0/cm-unicode-0.7.0-ttf.tar.xz/download#cm-unicode-0.7.0/OFL.txt) (SourceForge) |

Each font's upstream file (pinned URL, SHA-256, download date) is in
`licenses/FONT-SOURCES.csv` and in the "Sources" table of
`LeanSvg/Fonts/README.md`.

No embedded font's name records contain "Source", "TM Math", "Computer
Modern Unicode", "Bitstream Vera" or "Vera".

### Fixed during this review

- The old licence files (`LeanSvg/Fonts/LICENSE-*.txt`,
  `LeanSvg/LICENSE-*.txt`, `tests/corpora/realworld/LICENSES/`) were edited
  by hand: some combined several fonts, some had explanatory headers, and
  copyright lines had been typed in. They were not verbatim. They are
  replaced by byte-for-byte copies of the upstream files in `licenses/`, one
  per upstream file, shipped as-is. The explanatory headers moved to
  `NOTICE`.
- `NOTICE`, the READMEs and this review no longer restate any third-party
  copyright line. The notices are the upstream licence files and, per font,
  the font's own copyright record (`name` ID 0), which the subsets keep
  unchanged and which is identical to the upstream font's.

### Byte-identical licence texts and font sources

Every file under `licenses/` except the two CSVs is a byte-for-byte copy of
one upstream file:

- `licenses/MANIFEST.csv` lists each licence file with its SHA-256, pinned
  source URL (a commit or tag), download date and what it covers.
- `licenses/FONT-SOURCES.csv` lists, for each `LeanSvg/Fonts/*.lean` module,
  the pinned URL of the upstream font file it was subset from, that file's
  SHA-256 and the download date.

`tests/check_licenses.py` checks both:

- `python3 tests/check_licenses.py` (offline; CI runs it) checks the licence
  files' SHA-256 and that the file lists match;
- `--online` also re-downloads every licence file and every upstream font,
  checks their SHA-256, and checks that each embedded font's copyright
  record is identical to the upstream font's (all 35 are).

All were downloaded on 2026-09-24. A URL with a `#` fragment names a file
inside a SourceForge archive (the CMU licence and fonts, the DejaVu fonts).
Tinos's licence and fonts come from googlefonts/tinos, because google/fonts
no longer has `ofl/tinos`.

### Open question: notices in a binary-only distribution

The subsets keep each font's copyright record (`name` ID 0) but drop the
licence record (ID 13). A copy of the `lean-svg` binary on its own therefore
carries the copyright lines but not the OFL text. OFL condition 2 is met only
when `NOTICE` and the licence files travel with the binary, which is the case
for a copy of this repository. Anyone who ships the binary alone must ship
those files next to it.

### Deliberately **not** embedded

| Font | Why not |
|---|---|
| **Source Sans Pro** (Adobe, OFL) | Its Reserved Font Name is "Source". A subset is a Modified Version and could not be called "Source Sans Pro" without Adobe's written permission. T118 left it out; 2 resvg-suite files fail as a result. |
| matplotlib's **BaKoMa** `cmr10.ttf` etc. | Its licence forbids modification, and subsetting is a modification. CMU is used instead. |
| Microsoft core fonts (Arial, Times New Roman, …) | Not freely redistributable. Metric-compatible Arimo, Tinos and Cousine are used instead. |
| Liberation fonts | Not a licence problem: the download was refused. Arimo, Tinos and Cousine are the same designs. |
| Colour emoji | Your decision: not now. |

## 2. Generated data and re-implemented algorithms

| Component | Licence | What we ship | Licence text here | Upstream (downloaded) |
|---|---|---|---|---|
| harfrust 0.12.0 (port of HarfBuzz) | MIT | tables in `LeanSvg/ShapeData.lean` and `Bidi.lean`; shaping algorithms re-implemented in Lean | [`licenses/code/harfrust-LICENSE.txt`](../licenses/code/harfrust-LICENSE.txt) | [pinned](https://raw.githubusercontent.com/harfbuzz/harfrust/0.12.0/LICENSE), 2026-09-24 |
| unicode-bidi 0.3.18 | MIT OR Apache-2.0 (MIT chosen) | Bidi tables and the UAX #9 algorithm in `LeanSvg/Bidi.lean` | [`licenses/code/unicode-bidi-LICENSE-MIT.txt`](../licenses/code/unicode-bidi-LICENSE-MIT.txt) | [pinned](https://raw.githubusercontent.com/servo/unicode-bidi/v0.3.18/LICENSE-MIT), 2026-09-24 |
| brotli 1.2.0 | MIT | static dictionary and transforms in `LeanSvg/BrotliData.lean`; decoder written from RFC 7932 | [`licenses/code/brotli-LICENSE.txt`](../licenses/code/brotli-LICENSE.txt) | [pinned](https://raw.githubusercontent.com/google/brotli/v1.2.0/LICENSE), 2026-09-24 |
| tiny-skia | BSD-3-Clause | scan converter, strokes, dashes, blending and gradients re-implemented in Lean | [`licenses/code/tiny-skia-LICENSE.txt`](../licenses/code/tiny-skia-LICENSE.txt) (**added in this review**) | [pinned](https://raw.githubusercontent.com/linebender/tiny-skia/5d4754777746eef0828be166896eaf482c49f8f2/LICENSE), 2026-09-24 |
| Unicode Character Database (via harfrust) | Unicode License v3 | property values inside the generated tables | credited in `NOTICE` | |
| matplotlib 3.9.2 | Matplotlib License | STIXNonUnicode table in `LeanSvg/StixNonUnicodeTable.lean` | [`licenses/code/matplotlib-LICENSE.txt`](../licenses/code/matplotlib-LICENSE.txt) | [pinned](https://raw.githubusercontent.com/matplotlib/matplotlib/v3.9.2/LICENSE/LICENSE), 2026-09-24 |

MIT and BSD require the copyright notice and licence text to travel with
copies. The upstream licence files, which carry those notices, are in
`licenses/code/` as-is and are referenced from `NOTICE`.

## 3. Test data committed to the repository (`tests/corpora/realworld/`)

These are test inputs only; none is in the binary. `SOURCES.csv` lists the
source URL (at a pinned commit), author and licence of every downloaded file.

| Files | Licence | Licence text here | Upstream (downloaded) |
|---|---|---|---|
| `mpl-tests/` (515 matplotlib test baseline SVGs) | Matplotlib License (PSF-based, BSD-compatible) | [`licenses/corpora/matplotlib-LICENSE.txt`](../licenses/corpora/matplotlib-LICENSE.txt) | [pinned](https://raw.githubusercontent.com/matplotlib/matplotlib/bc6a4dc0d3b5839a708791398b9c0be24b76d8b6/LICENSE/LICENSE), 2026-09-24 |
| `web-tikz/` (50 files from janosh/diagrams) | MIT | [`licenses/corpora/janosh-diagrams-license.txt`](../licenses/corpora/janosh-diagrams-license.txt) | [pinned](https://raw.githubusercontent.com/janosh/diagrams/028a16ada31669870ed59a5d484aa1c8b4bedcbd/license), 2026-09-24 |
| `web-vega/` (31 Vega-Lite examples) | BSD-3-Clause | [`licenses/corpora/vega-lite-LICENSE.txt`](../licenses/corpora/vega-lite-LICENSE.txt) | [pinned](https://raw.githubusercontent.com/vega/vega-lite/831e308cf9feba791db0c279dea5f7983ca98445/LICENSE), 2026-09-24 |
| everything else (`tikz/`, `tikz-fonts/`, `graphviz/`, `mermaid/`, `plantuml/`, `matplotlib*/`, `src/`) | Apache-2.0: generated for this project from our own sources | none needed | |

The `tikz-fonts/` SVGs embed WOFF2 subsets of the AMS Type 1 Computer Modern
and AMS symbol fonts (cmr, cmmi, cmsy, cmex, msam, msbm). These are OFL 1.1,
and the OFL allows fonts embedded in documents to be distributed with the
documents (OFL FAQ 1.1: an embedded subset needs no licence file, and a
rendered image is not subject to the OFL). The `tikz/` SVGs contain the same
glyphs as plain outlines. The AMSFonts licence is shipped anyway, verbatim:
`licenses/corpora/amsfonts-OFL.txt`, taken from Ubuntu's texlive-base 2023.20240207-1
package (CTAN was not reachable from the build environment); the checker
extracts it from the pinned `.deb` and compares SHA-256. Its Reserved Font
Names include "cmr10", "cmmi10" and the other font names; dvisvgm keeps those
names on the embedded subsets, which FAQ 1.1 permits for embedding in documents.

Not committed: the resvg test suite, simple-icons and Feather icons are
cloned by the test scripts, excluded by `.gitignore`, and absent from
`git ls-files`.

## 4. What to confirm

1. The approach for OFL fonts: embed subsets in the binary, never use a
   Reserved Font Name, and ship the licence texts plus `NOTICE`.
2. Source Sans Pro stays out, because of its Reserved Font Name.
3. CMU: the family names "CMU …" and the lookup aliases for `cmr10`,
   "Computer Modern …" and "Latin Modern …" are acceptable. The RFN is the
   full phrase "Computer Modern Unicode fonts". "CMU" is the upstream
   project's own family name, and the aliases are lookup keys mapping a
   requested name to the font, not names the font presents.
4. Committing the third-party test SVGs (matplotlib, MIT, BSD-3) with their
   licence texts, as test data only.
