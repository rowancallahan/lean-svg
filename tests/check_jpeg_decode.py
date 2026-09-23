#!/usr/bin/env python3
"""T62: check `LeanSvg.JpegDecode.decode` against zune-jpeg (resvg's decoder).

1. Builds `jpegdump` (lake) and the Rust reference in tests/jpeg_ref
   (`jref` = resvg 0.48.1's decode_jpeg on zune-jpeg 0.5.15; `jgen` =
   jpeg-encoder, for sampling layouts Pillow can't write).
2. Generates a corpus: Pillow (gray/YCbCr, 4:4:4/4:2:2/4:2:0, baseline/
   progressive/optimized, qualities, restart markers, odd sizes), jgen (every
   sampling factor it has, progressive, restarts, gray), the resvg suite's
   JPEGs, and files zune refuses or mangles (CMYK, RGB-tagged).
3. Compares pixels: zune with AVX2 vs zune scalar (must agree), and ours vs
   zune (must be byte-identical; `none` only where zune fails too). Two
   known exceptions, reported separately: CMYK / RGB-tagged files, where
   zune's RGBA output is garbage or an error and ours must be `none`; and
   sequential 4x2/1x4/2x4 (4x1 with restarts) files zune garbles, where ours
   must be within 4 levels of libjpeg (Pillow).
4. Fuzzes 2000 mutants: every run must end cleanly with `NONE` or `w h`
   and exactly w*h*4 bytes (no crash, no hang).

Usage: python3 tests/check_jpeg_decode.py [--fuzz N] [--keep DIR]
"""
import argparse
import base64
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
REF = REPO / "tests" / "jpeg_ref"
DUMP = REPO / ".lake" / "build" / "bin" / "jpegdump"
SUITE = REPO / "tests" / "corpora" / "resvg-test-suite"


def build(tmp: Path) -> tuple[Path, Path]:
    env = dict(os.environ, PATH=f"{Path.home()}/.elan/bin:{os.environ['PATH']}")
    subprocess.run(["lake", "build", "jpegdump"], cwd=REPO, env=env, check=True,
                   stdout=subprocess.DEVNULL)
    target = Path(os.environ.get("JPEG_REF_TARGET", tmp / "target"))
    subprocess.run(["cargo", "build", "--release", "-q", "--target-dir", str(target)],
                   cwd=REF, check=True)
    return target / "release" / "jref", target / "release" / "jgen"


def pattern(w: int, h: int, seed: int, gray: bool) -> Image.Image:
    """Deterministic test picture: gradients, hard edges, noise."""
    rnd = random.Random(seed)
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            r = (x * 255) // max(1, w - 1)
            g = (y * 255) // max(1, h - 1)
            b = 255 if (x // 5 + y // 7) % 2 else 20
            if (x * 3 + y) % 11 == 0:
                r, g, b = rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)
            px[x, y] = (r, g, b)
    return im.convert("L") if gray else im


def corpus(tmp: Path, jgen: Path) -> list[Path]:
    out = []
    d = tmp / "corpus"
    d.mkdir()
    sizes = [(1, 1), (7, 5), (8, 8), (16, 16), (17, 13), (33, 31), (64, 48), (100, 75), (257, 3), (3, 130)]
    n = 0
    for (w, h) in sizes:
        for gray in (False, True):
            src = pattern(w, h, w * 1000 + h, gray)
            for q in (5, 50, 90, 100):
                for ss in ((0,) if gray else (0, 1, 2)):
                    for prog in (False, True):
                        for extra in ({}, {"optimize": True}, {"restart_marker_blocks": 3},
                                      {"restart_marker_rows": 1}):
                            if (q + ss + len(extra)) % 2 and extra:  # thin the grid
                                continue
                            p = d / f"pil{n}_{w}x{h}_{'L' if gray else 'C'}_q{q}_s{ss}_p{int(prog)}.jpg"
                            src.save(p, "JPEG", quality=q, subsampling=ss, progressive=prog, **extra)
                            out.append(p)
                            n += 1
    for (w, h) in [(1, 1), (9, 9), (31, 17), (64, 64), (70, 45)]:
        rgb = pattern(w, h, w + h, False)
        raw = tmp / "src.rgb"
        for gray in ("0", "1"):
            data = rgb.convert("L").tobytes() if gray == "1" else rgb.tobytes()
            raw.write_bytes(data)
            for sf in (["11"] if gray == "1" else ["11", "21", "12", "22", "41", "42", "14", "24"]):
                for prog in ("0", "1"):
                    for ri in ("0", "2"):
                        p = d / f"jgen{n}_{w}x{h}_g{gray}_s{sf}_p{prog}_r{ri}.jpg"
                        subprocess.run([str(jgen), str(raw), str(w), str(h), str(p), "80", sf,
                                        prog, ri, gray], check=True)
                        out.append(p)
                        n += 1
    # things zune refuses or garbles as RGBA: must be `none` here
    cmyk = pattern(20, 20, 1, False).convert("CMYK")
    cmyk.save(d / "neg_cmyk.jpg", "JPEG")
    pattern(20, 20, 2, False).save(d / "neg_rgbtag.jpg", "JPEG", keep_rgb=True)
    out += [d / "neg_cmyk.jpg", d / "neg_rgbtag.jpg"]
    # the resvg suite's own JPEGs, and those embedded in its SVGs and ours
    for f in sorted(SUITE.rglob("*.jpg")) + sorted(SUITE.rglob("*.jpeg")):
        p = d / f"suite_{f.name}"
        shutil.copy(f, p)
        out.append(p)
    svgs = sorted(SUITE.rglob("*.svg")) + sorted((REPO / "tests" / "svg").glob("*.svg"))
    seen = set()
    for f in svgs:
        text = f.read_text(errors="replace")
        for m in re.finditer(r"data:image/jpe?g;base64,([A-Za-z0-9+/=\s]+)", text):
            data = base64.b64decode(re.sub(r"\s", "", m.group(1)))
            if data in seen:
                continue
            seen.add(data)
            p = d / f"embedded{len(seen)}_{f.stem}.jpg"
            p.write_bytes(data)
            out.append(p)
    return out


def run_ref(jref: Path, f: Path, out: Path, safe: bool) -> bytes | None:
    args = [str(jref), str(f), str(out)] + (["safe"] if safe else [])
    r = subprocess.run(args, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, (f, r.stderr)
    return None if r.stdout.strip() == "NONE" else out.read_bytes()


def run_dump(pairs: list[tuple[Path, Path]]) -> list[str]:
    args = [str(DUMP)]
    for a, b in pairs:
        args += [str(a), str(b)]
    r = subprocess.run(args, capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, f"jpegdump crashed (rc={r.returncode}): {r.stderr[-400:]}"
    lines = r.stdout.splitlines()
    assert len(lines) == len(pairs), (len(lines), len(pairs))
    return lines


def zune_bug(f: Path, ref: bytes, ours: bytes) -> bool:
    """zune 0.5.15 garbles sequential files with 4x2/1x4/2x4 sampling (and
    4x1 with restarts) -- far from libjpeg's decode, while ours stays within a
    few levels of it (IDCT and upsampling differ slightly). Accept ours there."""
    lib = Image.open(f).convert("RGB").tobytes()
    def rgb(b: bytes) -> bytes:
        return bytes(x for i, x in enumerate(b) if i % 4 != 3)
    ours_err = max(abs(a - b) for a, b in zip(rgb(ours), lib))
    zune_err = max(abs(a - b) for a, b in zip(rgb(ref), lib))
    return ours_err <= 4 and zune_err > 64


def mutate(data: bytes, rnd: random.Random) -> bytes:
    b = bytearray(data)
    kind = rnd.randrange(6)
    if kind == 0:  # flip bytes
        for _ in range(rnd.randint(1, 8)):
            i = rnd.randrange(len(b))
            b[i] = rnd.randrange(256)
    elif kind == 1:  # truncate
        del b[rnd.randrange(2, len(b)):]
    elif kind == 2:  # insert junk
        i = rnd.randrange(len(b))
        b[i:i] = bytes(rnd.randrange(256) for _ in range(rnd.randint(1, 16)))
    elif kind == 3:  # delete a span
        i = rnd.randrange(len(b))
        del b[i:i + rnd.randint(1, 64)]
    elif kind == 4:  # header fields: big sizes / factors / table ids
        for _ in range(rnd.randint(1, 4)):
            i = rnd.randrange(min(len(b), 700))
            b[i] = rnd.choice([0, 1, 0x11, 0x22, 0x44, 0x7F, 0xFF, 0xC0, 0xC2, 0xDA, 0xD9])
    else:  # duplicate a span (repeated segments / scans)
        i = rnd.randrange(len(b))
        j = min(len(b), i + rnd.randint(1, 400))
        b[j:j] = b[i:j]
    return bytes(b)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=2000)
    ap.add_argument("--keep", type=Path, help="keep the work directory here")
    args = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="jpegchk_")) if not args.keep else args.keep
    tmp.mkdir(parents=True, exist_ok=True)
    jref, jgen = build(tmp)
    files = corpus(tmp, jgen)

    outs = tmp / "out"
    outs.mkdir()
    pairs = [(f, outs / f"{i}.lean.rgba") for i, f in enumerate(files)]
    lines = run_dump(pairs)
    exact = both_none = 0
    failures = []
    zune_bugs = []
    for (f, lo), line in zip(pairs, lines):
        ref = run_ref(jref, f, outs / "ref.rgba", safe=False)
        ref_safe = run_ref(jref, f, outs / "ref_safe.rgba", safe=True)
        if ref != ref_safe:
            failures.append(f"{f.name}: zune AVX2 and scalar paths differ")
            continue
        ours = None if line == "NONE" else lo.read_bytes()
        if f.name.startswith("neg_"):
            if ours is not None:
                failures.append(f"{f.name}: expected none (zune output is garbage), got {line}")
            else:
                both_none += 1  # counted with the refusals
            continue
        if ref is not None and ours is not None and ref != ours and zune_bug(f, ref, ours):
            zune_bugs.append(f.name)
            continue
        if ref is None and ours is None:
            both_none += 1
        elif ref is None or ours is None:
            failures.append(f"{f.name}: zune {'none' if ref is None else 'ok'}, ours {line}")
        elif ref == ours:
            exact += 1
        else:
            diffs = [abs(a - b) for a, b in zip(ref, ours)]
            failures.append(f"{f.name}: {sum(1 for x in diffs if x)} bytes differ, "
                            f"max {max(diffs)} (sizes {len(ref)}/{len(ours)})")
    print(f"corpus: {len(files)} files, {exact} byte-identical, {both_none} none as expected, "
          f"{len(zune_bugs)} where zune garbles and ours matches libjpeg, {len(failures)} failures")
    for m in zune_bugs:
        print("  zune-bug", m)
    for m in failures:
        print("  FAIL", m)

    # fuzz
    rnd = random.Random(62)
    seeds = [f.read_bytes() for f in files if f.stat().st_size > 4]
    fz = tmp / "fuzz"
    fz.mkdir()
    fpairs = []
    for i in range(args.fuzz):
        p = fz / f"m{i}.jpg"
        p.write_bytes(mutate(rnd.choice(seeds), rnd))
        fpairs.append((p, fz / f"m{i}.rgba"))
    decoded = agree = 0
    fuzz_fail = []
    for k in range(0, len(fpairs), 100):
        chunk = fpairs[k:k + 100]
        for (p, o), line in zip(chunk, run_dump(chunk)):
            if line == "NONE":
                continue
            w, h = map(int, line.split())
            size = o.stat().st_size
            if size != w * h * 4 or w == 0 or h == 0:
                fuzz_fail.append(f"{p.name}: {line} but {size} bytes")
            decoded += 1
            if run_ref(jref, p, fz / "ref.rgba", safe=False) == o.read_bytes():
                agree += 1
    print(f"fuzz: {len(fpairs)} mutants, all clean exits; {decoded} decoded "
          f"({agree} identical to zune), {len(fpairs) - decoded} none; {len(fuzz_fail)} bad")
    for m in fuzz_fail:
        print("  FAIL", m)
    if not args.keep:
        shutil.rmtree(tmp)
    return 1 if failures or fuzz_fail else 0


if __name__ == "__main__":
    sys.exit(main())
