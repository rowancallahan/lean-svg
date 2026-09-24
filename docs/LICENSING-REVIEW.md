# Licensing review (for Rowan to confirm)

Date: 2026-09-24. Scope: everything third-party that this repository **commits**
or **compiles into the binary**. lean-svg itself is Apache-2.0 (`LICENSE`); the
credits that travel with any redistribution are in `NOTICE` and in README
"Licensing and credits".

How this was checked:
- each licence file here was compared with the upstream licence at its source;
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

| Font (modules) | Licence | Reserved Font Name | Embedded name (checked) | Licence file here | Upstream to compare |
|---|---|---|---|---|---|
| Noto Sans Regular, Bold, Italic, Thin, Light, Black, ExtraCondensed | OFL 1.1 | none | "Noto Sans …" | `LeanSvg/Fonts/LICENSE-OFL.txt` | [notofonts/latin-greek-cyrillic OFL.txt](https://github.com/notofonts/latin-greek-cyrillic/blob/main/OFL.txt) (the embedded 2.000 files are the resvg test suite's copies; same licence) |
| Noto Sans SC, Noto Sans KR | OFL 1.1 | **"Source"** (Adobe) | "Noto Sans SC", "Noto Sans KR": RFN not used | `LICENSE-OFL-NotoSansCJK.txt` | [google/fonts ofl/notosanssc](https://github.com/google/fonts/tree/main/ofl/notosanssc), [ofl/notosanskr](https://github.com/google/fonts/tree/main/ofl/notosanskr) |
| Noto Sans Thai, Armenian, Georgian, Ethiopic, Hebrew, Devanagari | OFL 1.1 | none | "Noto Sans …" | `LICENSE-OFL-NotoScripts.txt` (6 copyright lines) | [google/fonts ofl/notosansthai](https://github.com/google/fonts/tree/main/ofl/notosansthai) (and the other 5 script folders) |
| Mplus 1p | OFL 1.1 | none | "Mplus 1p" | `LICENSE-OFL-Mplus1p.txt` | [google/fonts ofl/mplus1p](https://github.com/google/fonts/tree/main/ofl/mplus1p) |
| Amiri 000.109 | OFL 1.1 | none | "Amiri" | `LICENSE-OFL-Amiri.txt` (notice of the embedded version, 2010-2016 Khaled Hosny) | [aliftype/amiri OFL.txt](https://github.com/aliftype/amiri/blob/main/OFL.txt) |
| DejaVu Sans (Book, Bold, Oblique), Sans Mono, Serif 2.37 | Bitstream Vera + Arev (permissive), DejaVu changes public domain | names "Bitstream", "Vera", "Arev" | "DejaVu …" | `LICENSE-DejaVu.txt` (identical to upstream) | [dejavu-fonts LICENSE](https://github.com/dejavu-fonts/dejavu-fonts/blob/master/LICENSE) |
| Arimo, Tinos, Cousine | OFL 1.1 (Google relicensed these from Apache 2.0; google/fonts metadata says `license: "OFL"`) | none | "Arimo", "Tinos", "Cousine" | `LICENSE-OFL-Croscore.txt` | [googlefonts/arimo OFL.txt](https://github.com/googlefonts/arimo/blob/main/OFL.txt), [tinos](https://github.com/googlefonts/tinos/blob/main/OFL.txt), [cousine](https://github.com/googlefonts/cousine/blob/main/OFL.txt) |
| STIX Two Math, STIX Two Text (Regular, Italic) | OFL 1.1 | **"TM Math"** | "STIX Two …": RFN not used | `LICENSE-OFL-STIXTwo.txt` | [google/fonts ofl/stixtwomath](https://github.com/google/fonts/tree/main/ofl/stixtwomath), [stipub/stixfonts](https://github.com/stipub/stixfonts) |
| CMU Serif (Roman, Italic), Sans Serif, Typewriter 0.7.0 | OFL 1.1 | **"Computer Modern Unicode fonts"** (family name) | "CMU Serif", "CMU Sans Serif", "CMU Typewriter Text" | `LICENSE-OFL-CMU.txt` | [cm-unicode on SourceForge](https://sourceforge.net/projects/cm-unicode/) (not re-downloaded today: the network policy blocked it in T106) |

No embedded font's name records contain "Source", "TM Math", "Computer
Modern Unicode", "Bitstream Vera" or "Vera".

### Fixed during this review

- `LICENSE-OFL-Croscore.txt` had only Arimo's copyright line. Tinos's and
  Cousine's are now added.
- `LICENSE-OFL-Mplus1p.txt` lacked upstream's second line, "Copyright 2016
  The Rounded M+ Project Authors.". It is now added.

### Deliberately **not** embedded

| Font | Why not |
|---|---|
| **Source Sans Pro** (Adobe, OFL) | Its Reserved Font Name is "Source". A subset is a Modified Version and could not be called "Source Sans Pro" without Adobe's written permission. T118 left it out; 2 resvg-suite files fail as a result. |
| matplotlib's **BaKoMa** `cmr10.ttf` etc. | Its licence forbids modification, and subsetting is a modification. CMU is used instead. |
| Microsoft core fonts (Arial, Times New Roman, …) | Not freely redistributable. Metric-compatible Arimo, Tinos and Cousine are used instead. |
| Liberation fonts | Not a licence problem: the download was refused. Arimo, Tinos and Cousine are the same designs. |
| Colour emoji | Your decision: not now. |

## 2. Generated data and re-implemented algorithms

| Component | Licence | What we ship | Licence text here |
|---|---|---|---|
| harfrust 0.12.0 (port of HarfBuzz) | MIT | tables in `LeanSvg/ShapeData.lean` and `Bidi.lean`; shaping algorithms re-implemented in Lean | `LeanSvg/LICENSE-harfrust.txt` |
| unicode-bidi 0.3.18 | MIT OR Apache-2.0 (MIT chosen) | Bidi tables and the UAX #9 algorithm in `LeanSvg/Bidi.lean` | `LeanSvg/LICENSE-unicode-bidi.txt` |
| brotli 1.2.0 | MIT | static dictionary and transforms in `LeanSvg/BrotliData.lean`; decoder written from RFC 7932 | `LeanSvg/LICENSE-brotli.txt` |
| tiny-skia | BSD-3-Clause (Google 2011, Reizner 2020) | scan converter, strokes, dashes, blending and gradients re-implemented in Lean | `LeanSvg/LICENSE-tiny-skia.txt` (**added in this review**) |
| Unicode Character Database (via harfrust) | Unicode License v3 | property values inside the generated tables | credited in `NOTICE` |

MIT and BSD require the copyright notice and licence text to travel with
copies. All four texts are now in the repository and referenced from
`NOTICE`.

## 3. Test data committed to the repository (`tests/corpora/realworld/`)

These are test inputs only; none is in the binary. `SOURCES.csv` lists the
source URL (at a pinned commit), author and licence of every downloaded file.

| Files | Licence | Licence text here |
|---|---|---|
| `mpl-tests/` (515 matplotlib test baseline SVGs) | Matplotlib License (PSF-based, BSD-compatible) | `tests/corpora/realworld/LICENSES/LICENSE-matplotlib.txt` |
| `web-tikz/` (50 files from janosh/diagrams) | MIT | `LICENSE-janosh-diagrams-MIT.txt` |
| `web-vega/` (31 Vega-Lite examples) | BSD-3-Clause | `LICENSE-vega-lite-BSD-3-Clause.txt` |
| everything else (`tikz/`, `tikz-fonts/`, `graphviz/`, `mermaid/`, `plantuml/`, `matplotlib*/`, `src/`) | Apache-2.0: generated for this project from our own sources | none needed |

The `tikz-fonts/` SVGs embed WOFF2 subsets of the AMS Type 1 Computer Modern
and AMS symbol fonts (cmr, cmmi, cmsy, cmex, msam, msbm). These are OFL 1.1,
and the OFL allows fonts embedded in documents to be distributed with the
documents. The `tikz/` SVGs contain the same glyphs as plain outlines.

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
