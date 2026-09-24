#!/usr/bin/env bash
# Regenerate the Graphviz part of the realworld corpus (T103).
#
#   bash tests/corpora/realworld/src/gen_graphviz.sh
#
# Each src/graphviz/NAME.dot -> ../graphviz/NAME.svg with `dot -Tsvg`; a
# `layout=` attribute inside the file picks neato/fdp/circo/twopi. Graphviz
# embeds its version in a comment, so the output is stable per version.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../graphviz"
mkdir -p "$OUT"
n=0
for f in "$HERE"/graphviz/*.dot; do
  dot -Tsvg "$f" -o "$OUT/$(basename "$f" .dot).svg"
  n=$((n + 1))
done
echo "graphviz: $n SVGs ($(dot -V 2>&1))"
