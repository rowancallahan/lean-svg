#!/usr/bin/env bash
# Fetch matplotlib's whole test-baseline SVG set (T103) at a pinned commit.
#
#   bash tests/corpora/realworld/src/fetch_matplotlib_tests.sh
#
# SVGs  -> tests/corpora/realworld/mpl-tests/<test module>/<name>.svg (committed)
# PNGs  -> tests/corpora/matplotlib-baseline-png/<test module>/<name>.png
#          (gitignored, 16 MB): matplotlib's own Agg render of the same
#          figure, the third column of tests/make_realworld_review.py.
# Also rewrites the mpl-tests rows of ../SOURCES.csv.
# Licence: Matplotlib License (PSF-based), LICENSE/LICENSE in that repo.
set -euo pipefail
SHA=bc6a4dc0d3b5839a708791398b9c0be24b76d8b6
HERE="$(cd "$(dirname "$0")" && pwd)"
RW="$HERE/.."
PNG_OUT="$RW/../matplotlib-baseline-png"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone -q --filter=blob:none --no-checkout https://github.com/matplotlib/matplotlib.git "$TMP/mpl"
git -C "$TMP/mpl" sparse-checkout set --no-cone '/lib/matplotlib/tests/baseline_images/**/*.svg' \
  '/lib/matplotlib/tests/baseline_images/**/*.png'
git -C "$TMP/mpl" checkout -q "$SHA"
python3 - "$TMP/mpl/lib/matplotlib/tests/baseline_images" "$RW" "$PNG_OUT" "$SHA" <<'EOF'
import csv, shutil, sys
from pathlib import Path
base, rw, png_out, sha = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
dest = rw / "mpl-tests"
shutil.rmtree(dest, ignore_errors=True)
shutil.rmtree(png_out, ignore_errors=True)
svgs = sorted(base.rglob("*.svg"))
assert len(svgs) > 400, len(svgs)
rows = []
for svg in svgs:
    rel = svg.relative_to(base)
    (dest / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(svg, dest / rel)
    png = svg.with_suffix(".png")
    if png.is_file():
        (png_out / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(png, png_out / rel.with_suffix(".png"))
    rows.append(["mpl-tests/" + rel.as_posix(),
                 "https://raw.githubusercontent.com/matplotlib/matplotlib/%s/lib/matplotlib/tests/baseline_images/%s" % (sha, rel.as_posix()),
                 "Matplotlib Development Team", "Matplotlib License (PSF-based, BSD-compatible)",
                 "https://github.com/matplotlib/matplotlib/blob/%s/LICENSE/LICENSE" % sha])
src = rw / "SOURCES.csv"
with src.open(newline="") as fh:
    old = [r for r in csv.reader(fh)]
header, keep = old[0], [r for r in old[1:] if not r[0].startswith("mpl-tests/")]
with src.open("w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(header)
    w.writerows(keep + rows)
print("mpl-tests: %d SVGs, %d with a PNG baseline" % (len(svgs), sum(1 for s in svgs if s.with_suffix(".png").is_file())))
EOF
