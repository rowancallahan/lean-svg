# lean-svg
## Human Preamble
An experiment in specification based programming.
The overall goal here is to my understanding of theorems on programs, and how to use theorems on programs to allow for more unrestricted use of computer generated code.
A few goals of this program are as follows:

- One input one ouptut, only the specified files should be touched and there should be no side effects asides from reading the input file and writing to the output file. This should be fairly easy to prove also by way of the Input output Monad. But does require us to trust the commands that it is calling. This also makes the program safer to run because I know it won't be able to touch other files despite how it is optimized.
- No hang states, this program should have some limits to how long it can run and how much memory it uses, to prevent it from overflowing.
- maximum output size, this program should have a maximum output size defined by the canvas size.

Long term
- Defined file output type: this program should only be able to create a valid PNG output, this will require a specification for the PNG filetype which may take considerably more time since this entire spec may need to be hand written.
- more features for SVGs
- Better font support, curently fonts ship with the program and can't use system fonts, I want to find a safer way of reading the font cache but haven't decided on what that means yet.
- Better multi core and gpu support
- aenas translation to rust. Getting provable guarantees is also possible by translating rust into lean and proving things about the translation. The eventual goal of this project is to see how close to speed parity we can get with resvg. This won't work for all rust but it might be enough to get major speedups and get things close enough to be happy.
- have all tests and harnesses for performance be written in lean
- Rewrite entire spec and go over it in closer detail


## Generated Readme

Fidelity is checked against [resvg](https://github.com/linebender/resvg); 

## Build and run

```bash
lake build
.lake/build/bin/lean-svg tests/svg/01_triangle.svg out.png
.lake/build/bin/lean-svg in.svg out.png --width 800 --background white
# one 512x512 tile of a 4000 px wide image, for a zoomable viewer
.lake/build/bin/lean-svg in.svg tile.png --width 4000 --viewport 1744 1744 512 512
```

Exit codes: 0 success, 1 render error (message on stderr, no file written),
2 bad arguments.

## Test

```bash
brew install resvg        # oracle
make test                 # fidelity vs resvg → tests/out/report.html
make adversarial          # hostile inputs: no crash, no hang, no stray files
make tiles                # --viewport tiles stitch back to the full render
python3 playground/server.py   # http://127.0.0.1:8765 — draw and compare
```

## Read next

- `DESIGN.md` — what is proven, what is trusted, threat model, algorithms.
- `PLAN.md` — milestones, settled decisions, what to delegate.

## Licensing and credits

lean-svg is licensed under the **Apache License 2.0** (`LICENSE`). `NOTICE`
carries the same credits as this section and travels with any redistribution,
as clause 4(d) of that licence requires.

This project has no build dependencies: the trusted computing base is Lean
core only. Everything below is either embedded in the binary, an algorithm
this code re-implements, a behavioural reference that was read but not
copied, or a tool used only when running the tests.

### Embedded in the binary, and so redistributed

| what | licence |
|---|---|
| **Noto Sans** Regular, Bold and Italic, Latin subsets, generated into `LeanSvg/Fonts/*.lean` | SIL Open Font License 1.1 — Copyright 2022 The Noto Project Authors, [notofonts/latin-greek-cyrillic](https://github.com/notofonts/latin-greek-cyrillic). Full text in `LeanSvg/Fonts/LICENSE-OFL.txt`. The fonts are subsetted, which the OFL permits; Noto declares no Reserved Font Name. |

### Algorithms this code re-implements

| what | licence |
|---|---|
| **tiny-skia** — [linebender/tiny-skia](https://github.com/linebender/tiny-skia) | BSD-3-Clause — Copyright (c) 2020 Yevhenii Reizner |
| **Skia**, which tiny-skia is itself a port of | BSD-3-Clause — Copyright (c) 2011 Google Inc. |

The anti-aliased scan converter, hairline stroking, the cubic and quadratic
subdivision counts, the dash-splitting rules, the `lowp` blend arithmetic,
the `f32` layer-compositing pipeline and the gradient evaluation in
`LeanSvg/{Raster,Geom,Canvas,Shader}.lean` are fixed-point Lean
re-implementations of tiny-skia's algorithms, written from reading its
source. No Rust source is copied into this repository, but these are close
enough to its work that its notice is carried here and in `NOTICE`
regardless of how the derivative-work line is drawn.

### Behavioural references, read but not copied

| what | licence |
|---|---|
| **resvg** and **usvg** — [linebender/resvg](https://github.com/linebender/resvg) | MPL-2.0 — Copyright (c) 2017 Yevhenii Reizner |
| **simplecss** — [linebender/simplecss](https://github.com/linebender/simplecss) | MIT or Apache-2.0 |
| **svgtypes** — [linebender/svgtypes](https://github.com/linebender/svgtypes) | MIT or Apache-2.0 |

resvg and usvg define what "correct" means here: parsing defaults,
conditional processing, the CSS cascade, paint servers, clipping and text
layout were all matched by reading them. The supported CSS selector subset in
`LeanSvg/Css.lean` follows simplecss's grammar, and colour, length and
transform parsing follow svgtypes' behaviour. No MPL-covered source is
included in this repository.

### Build and language

| what | licence |
|---|---|
| **Lean 4** and **Lake** — [leanprover/lean4](https://github.com/leanprover/lean4) | Apache-2.0 |

### Used only when running the tests, never distributed

| what | licence |
|---|---|
| **resvg** binary, the rendering oracle | MPL-2.0 |
| **resvg test suite** (`tests/corpora/resvg-test-suite`) | MPL-2.0 |
| **simple-icons** (`tests/corpora/simple-icons`) | CC0-1.0 |
| **Feather icons** (`tests/corpora/feather`) | MIT |
| **Pillow** | MIT-CMU |
| **NumPy** | BSD-3-Clause |
| **fontTools** | MIT |

The corpora are cloned locally by the harnesses and are listed in
`.gitignore`; none of them is committed here or shipped in a release. If a
published page or release ever includes renders derived from the resvg test
suite, that material is MPL-2.0 and must carry the suite's licence and a note
that the files are unmodified.

### Prior art that shaped the project

**lean-zip** — [kim-em/lean-zip](https://github.com/kim-em/lean-zip),
Apache-2.0. The "one input, one output, proven effect boundary" shape of this
project follows its example. No code is shared.

If you believe something here is miscredited or missing, please open an issue.
