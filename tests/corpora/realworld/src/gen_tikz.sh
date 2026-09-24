#!/usr/bin/env bash
# Regenerate the TikZ/LaTeX part of the realworld corpus (T103).
#
#   bash tests/corpora/realworld/src/gen_tikz.sh
#
# Needs latex + dvisvgm (Ubuntu: texlive-latex-extra texlive-pictures
# texlive-science dvisvgm). Each src/tikz/NAME.tex is compiled to DVI once,
# then converted twice:
#   ../tikz/NAME.svg        dvisvgm --no-fonts   (glyphs as <path>/<use>)
#   ../tikz-fonts/NAME.svg  dvisvgm --font-format=woff2  (embedded @font-face + <text>)
# A source that fails to compile stops the script. The tikz-fonts output is
# not byte-reproducible: dvisvgm stamps the current time into each embedded
# font, so regenerating changes those files even with identical sources.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$OUT/tikz" "$OUT/tikz-fonts"
n=0
for tex in "$HERE"/tikz/*.tex; do
  name="$(basename "$tex" .tex)"
  (cd "$BUILD" && latex -interaction=nonstopmode -halt-on-error "$tex" >"$name.log") \
    || { echo "latex failed: $name (log: $BUILD/$name.log)"; tail -20 "$BUILD/$name.log"; trap - EXIT; exit 1; }
  dvisvgm --no-fonts --exact-bbox --verbosity=1 -o "$OUT/tikz/$name.svg" "$BUILD/$name.dvi" >/dev/null
  dvisvgm --font-format=woff2 --exact-bbox --verbosity=1 -o "$OUT/tikz-fonts/$name.svg" "$BUILD/$name.dvi" >/dev/null
  n=$((n + 1))
done
echo "tikz: $n sources -> $((2 * n)) SVGs"
