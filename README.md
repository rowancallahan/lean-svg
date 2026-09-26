# lean-svg

Licence: [Apache-2.0](LICENSE). Third-party fonts, data and test files: [LICENSING.md](LICENSING.md).

## Overview
An experiment in specification based programming.
Programming in Lean allows you to prove properties about your code that are then machine checked.
While programming languages like rust can help provide assurances about bugs like use-after-free, Lean can go further and allow you to prove properties about its inputs and outputs.

As a demonstration of the potential advantages, this is an SVG -> PNG rendering program modelled after resvg in rust the main loop can be found in Main.lean.
The main loop ensures that no matter what the rendering function only renders to the output file (and warning file) with no other "side effects", and only reads from the input file.
Certain properties about it are proven in the spec folder suchas input file never equals output file, along with a few other.

With the effects proven we can have more trust that this program wont have issues such as remote code execution when opening a potentially "hostile" svg.
We also have guarantees that this program will not read and write files its not supposed to regardless of what code exists in its internal function.

With these features set we then took a large corpus of images including the resvg test suite and various charting library example SVG and let an agent autonomously generate almost all of the code. 
The only job for the human is to decide on images that are borderline. Identical images are automatically accepted, and bad matches mean this feature must be implemented.
This repository contains the mostly finished results of running this loop combined with decisions on some image drawing behavior, and some edits of the main file for clarity.


## Examples

Test images drawn for this project (Apache-2.0), lean-svg vs resvg 0.48.1 at 800 px.

| | lean-svg | resvg 0.48.1 | difference (12x) |
|---|---|---|---|
| **confetti**<br>gradients, group opacity, blend modes, arcs, dashes, clipping, text | ![confetti rendered by lean-svg](docs/readme/confetti-ours.png)<br>99% within 8<br>98% exact<br>63 ms | ![confetti rendered by resvg](docs/readme/confetti-resvg.png)<br>n/a<br>n/a<br>14 ms | ![difference between the two confetti renders](docs/readme/confetti-diff.png)<br>n/a<br>n/a<br>n/a |
| **icons**<br>arcs, dashes, gradients, clipPath, layers, text | ![icons rendered by lean-svg](docs/readme/icons-ours.png)<br>99% within 8<br>99% exact<br>26 ms | ![icons rendered by resvg](docs/readme/icons-resvg.png)<br>n/a<br>n/a<br>10 ms | ![difference between the two icons renders](docs/readme/icons-diff.png)<br>n/a<br>n/a<br>n/a |
| **stress**<br>~1500 overlapping translucent shapes | ![stress rendered by lean-svg](docs/readme/stress-ours.png)<br>98% within 8<br>93% exact<br>242 ms | ![stress rendered by resvg](docs/readme/stress-resvg.png)<br>n/a<br>n/a<br>87 ms | ![difference between the two stress renders](docs/readme/stress-diff.png)<br>n/a<br>n/a<br>n/a |

Charts from the real-world test corpus at 1000 px on white, lean-svg vs Chromium 141.

<table>
<tr><th colspan="2" align="left">LDA plate diagram (TikZ)<br><sub>SVG Apache-2.0; glyphs AMSFonts, SIL OFL 1.1 (<a href="licenses/corpora/amsfonts-OFL.txt">licence</a>) · <a href="tests/corpora/realworld/src/tikz/bayesnet_plate.tex">source</a></sub></th></tr>
<tr><td>lean-svg</td><td><img src="docs/readme/bayesnet_plate.png" width="500" alt="LDA plate diagram (TikZ), lean-svg"></td></tr>
<tr><td>Chromium</td><td><img src="docs/readme/bayesnet_plate-chromium.png" width="500" alt="LDA plate diagram (TikZ), Chromium"></td></tr>
<tr><th colspan="2" align="left">Snake lemma (TikZ)<br><sub>SVG Apache-2.0; glyphs AMSFonts, SIL OFL 1.1 (<a href="licenses/corpora/amsfonts-OFL.txt">licence</a>) · <a href="tests/corpora/realworld/src/tikz/cd_snake_lemma.tex">source</a></sub></th></tr>
<tr><td>lean-svg</td><td><img src="docs/readme/cd_snake_lemma.png" width="500" alt="Snake lemma (TikZ), lean-svg"></td></tr>
<tr><td>Chromium</td><td><img src="docs/readme/cd_snake_lemma-chromium.png" width="500" alt="Snake lemma (TikZ), Chromium"></td></tr>
<tr><th colspan="2" align="left">Burrows–Wheeler transform (TikZ)<br><sub>MIT (<a href="licenses/corpora/janosh-diagrams-license.txt">licence</a>) · <a href="https://github.com/janosh/diagrams/tree/main/assets/burrows-wheeler-transform">janosh/diagrams</a></sub></th></tr>
<tr><td>lean-svg</td><td><img src="docs/readme/burrows-wheeler-transform.png" width="500" alt="Burrows–Wheeler transform (TikZ), lean-svg"></td></tr>
<tr><td>Chromium</td><td><img src="docs/readme/burrows-wheeler-transform-chromium.png" width="500" alt="Burrows–Wheeler transform (TikZ), Chromium"></td></tr>
<tr><th colspan="2" align="left">3D surface (matplotlib)<br><sub>SVG Apache-2.0; text in DejaVu Sans (<a href="licenses/fonts/DejaVu-LICENSE.txt">licence</a>) · <a href="tests/corpora/realworld/src/gen_matplotlib.py">source</a></sub></th></tr>
<tr><td>lean-svg</td><td><img src="docs/readme/surface_3d.png" width="300" alt="3D surface (matplotlib), lean-svg"></td></tr>
<tr><td>Chromium</td><td><img src="docs/readme/surface_3d-chromium.png" width="300" alt="3D surface (matplotlib), Chromium"></td></tr>
</table>

## Build and run

```bash
lake build
.lake/build/bin/lean-svg tests/svg/01_triangle.svg out.png
.lake/build/bin/lean-svg in.svg out.png --width 800 --background white
# one 512x512 tile of a 4000 px wide image, for a zoomable viewer
.lake/build/bin/lean-svg in.svg tile.png --width 4000 --viewport 1744 1744 512 512
```

## Test

```bash
brew install resvg        # oracle
make test                 # fidelity vs resvg → tests/out/report.html
make adversarial          # hostile inputs: no crash, no hang, no stray files
make tiles                # --viewport tiles stitch back to the full render
make full-check           # every test, whole corpus, byte lock (before finalizing)
```

What is proved: [spec/README.md](spec/README.md) (check with `scripts/check-theorems.sh`).

## Licensing and credits

lean-svg is Apache-2.0. Third-party fonts, data, algorithms and test files, with
their verbatim licence texts: [LICENSING.md](LICENSING.md).
