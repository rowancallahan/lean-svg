#!/usr/bin/env bash
# Regenerate the Mermaid and PlantUML part of the realworld corpus (T103).
#
#   MMDC=/path/to/node_modules/.bin/mmdc bash tests/corpora/realworld/src/gen_uml.sh
#
# Mermaid: `npm install @mermaid-js/mermaid-cli` (PUPPETEER_SKIP_DOWNLOAD=1)
# anywhere, point MMDC at its mmdc; it drives the container's Chromium.
# PlantUML: Ubuntu `plantuml` package. src/mermaid/*.mmd -> ../mermaid/,
# src/plantuml/*.puml -> ../plantuml/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/.."
: "${MMDC:?set MMDC to the mermaid-cli mmdc binary}"
CHROME="${CHROME:-/opt/pw-browsers/chromium}"
PCFG="$(mktemp --suffix=.json)"
trap 'rm -f "$PCFG"' EXIT
printf '{"executablePath":"%s","args":["--no-sandbox"]}\n' "$CHROME" >"$PCFG"
mkdir -p "$OUT/mermaid" "$OUT/plantuml"
for f in "$HERE"/mermaid/*.mmd; do
  "$MMDC" -q -p "$PCFG" -i "$f" -o "$OUT/mermaid/$(basename "$f" .mmd).svg"
done
for f in "$HERE"/plantuml/*.puml; do
  plantuml -tsvg -pipe <"$f" >"$OUT/plantuml/$(basename "$f" .puml).svg"
done
echo "mermaid: $(ls "$OUT"/mermaid/*.svg | wc -l), plantuml: $(ls "$OUT"/plantuml/*.svg | wc -l)"
