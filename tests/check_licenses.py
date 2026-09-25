#!/usr/bin/env python3
"""Check the licence texts in licenses/ against their upstream sources.

Every file under licenses/ except the two CSVs is a byte-for-byte copy of an
upstream licence file. MANIFEST.csv gives, for each one, its SHA-256, the
pinned URL it was downloaded from and the download date.

FONT-SOURCES.csv gives, for each embedded font (LeanSvg/Fonts/*.lean), the
pinned URL of the upstream font file it was subset from, that file's SHA-256
and the download date. Each subset keeps the font's own copyright record
(OpenType `name` ID 0); --online checks it is identical to the upstream
file's, so the copyright notice inside the binary is upstream's own text.

    python3 tests/check_licenses.py           # offline: hashes and file sets
    python3 tests/check_licenses.py --online  # also re-download every URL and compare

A URL ending in `#member` names a file inside a .tar.xz archive.
"""
import base64
import csv
import hashlib
import io
import re
import struct
import sys
import tarfile
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIC = REPO / "licenses"
FONTS = LIC / "FONT-SOURCES.csv"
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def manifest() -> list[dict]:
    rows = list(csv.DictReader(open(LIC / "MANIFEST.csv", newline="")))
    assert rows and list(rows[0]) == ["file", "sha256", "source_url", "downloaded", "covers"]
    files = [r["file"] for r in rows]
    assert len(files) == len(set(files)), "duplicate manifest entry"
    for r in rows:
        assert re.fullmatch(r"[0-9a-f]{64}", r["sha256"]), r
        assert r["source_url"].startswith("https://"), r
        assert DATE.fullmatch(r["downloaded"]), r
        assert r["covers"].strip(), r
    return rows


def font_sources() -> list[dict]:
    rows = list(csv.DictReader(open(FONTS, newline="")))
    assert rows and list(rows[0]) == ["module", "source_url", "source_sha256", "downloaded", "in_repo_since"]
    mods = sorted(str(p.relative_to(REPO)) for p in (REPO / "LeanSvg" / "Fonts").glob("*.lean"))
    assert sorted(r["module"] for r in rows) == mods, "FONT-SOURCES.csv must list every LeanSvg/Fonts module once"
    for r in rows:
        assert re.fullmatch(r"[0-9a-f]{64}", r["source_sha256"]), r
        assert r["source_url"].startswith("https://"), r
        assert DATE.fullmatch(r["downloaded"]), r
        assert font_copyright(REPO / r["module"]), r
    return rows


def font_copyright(lean: Path) -> str:
    """`name` ID 0 of the font embedded in one LeanSvg/Fonts module."""
    m = re.search(r"def front : Array String := #\[(.*?)\]", lean.read_text(), re.S)
    assert m, lean
    return name0(base64.b64decode("".join(re.findall(r'"([^"]*)"', m.group(1)))), str(lean))


def name0(b: bytes, what: str) -> str:
    """`name` ID 0 (copyright) of a TrueType/OpenType font's bytes."""
    n = struct.unpack(">H", b[4:6])[0]
    tabs = {b[12 + 16 * i:16 + 16 * i]: struct.unpack(">II", b[20 + 16 * i:28 + 16 * i]) for i in range(n)}
    off, ln = tabs[b"name"]
    assert off + ln <= len(b), what
    t = b[off:off + ln]
    cnt, so = struct.unpack(">HH", t[2:6])
    found = {}
    for i in range(cnt):
        pid, eid, lid, nid, l, o = struct.unpack(">HHHHHH", t[6 + 12 * i:18 + 12 * i])
        if nid == 0:
            s = t[so + o:so + o + l]
            found[(pid, lid)] = s.decode("utf-16-be") if pid in (0, 3) else s.decode("latin1")
    for key in ((3, 0x409), (1, 0), (0, 0), (0, 3)):
        if key in found:
            return found[key].strip()
    raise AssertionError(f"{what}: no copyright record")


def fetch(url: str) -> bytes:
    base, _, member = url.partition("#")
    with urllib.request.urlopen(base, timeout=120) as r:
        data = r.read()
    if not member:
        return data
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz" if ".xz" in base else "r:bz2") as tar:
        f = tar.extractfile(member)
        assert f, f"{member} not in {base}"
        return f.read()


def main() -> None:
    rows = manifest()
    on_disk = {str(p.relative_to(LIC)) for p in LIC.rglob("*") if p.is_file()} - {"MANIFEST.csv", "FONT-SOURCES.csv"}
    assert on_disk == {r["file"] for r in rows}, (
        f"not in manifest: {sorted(on_disk - {r['file'] for r in rows})}; "
        f"missing: {sorted({r['file'] for r in rows} - on_disk)}")
    for r in rows:
        got = sha((LIC / r["file"]).read_bytes())
        assert got == r["sha256"], f"{r['file']}: sha256 {got} != manifest {r['sha256']}"
    fonts = font_sources()
    print(f"{len(rows)} licence files match MANIFEST.csv; {len(fonts)} fonts listed in FONT-SOURCES.csv")
    if "--online" in sys.argv:
        for r in rows:
            got = sha(fetch(r["source_url"]))
            assert got == r["sha256"], f"{r['file']}: upstream sha256 {got} != {r['sha256']} ({r['source_url']})"
        print(f"{len(rows)} licence files byte-identical to their upstream URLs")
        cache: dict[str, bytes] = {}
        for r in fonts:
            if r["source_url"] not in cache:
                cache[r["source_url"]] = fetch(r["source_url"])
            b = cache[r["source_url"]]
            assert sha(b) == r["source_sha256"], f"{r['module']}: upstream font changed ({r['source_url']})"
            ours, up = font_copyright(REPO / r["module"]), name0(b, r["source_url"])
            assert ours == up, f"{r['module']}: copyright record differs from upstream:\n  {ours!r}\n  {up!r}"
        print(f"{len(fonts)} embedded fonts: upstream files unchanged, copyright records identical")


if __name__ == "__main__":
    main()
