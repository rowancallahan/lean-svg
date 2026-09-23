#!/usr/bin/env python3
"""T61: check `PngDecode.decode` through the `pngdump` debug exe.

1. Corpus, compared pixel-exact against Pillow:
   * PngSuite (fetched into tests/corpora/pngsuite from image-rs/image-png,
     the `png` crate's own copy; skipped with --no-fetch if absent);
   * PNGs generated here across every colour type / bit depth / interlace,
     random per-row filters (all five), split IDATs, tRNS, and zlib streams of
     every kind (stored, fixed, dynamic Huffman; several levels/strategies).
   Pillow gives the samples; the crate's EXPAND | STRIP_16 rules (high byte
   of 16-bit, gray scaled by 255/(2^d-1), tRNS keys as `png` 0.18 compares
   them) are applied here. 16-bit RGB tRNS needs the low bytes Pillow drops,
   so that one key is checked against `raw_samples` (a zlib+unfilter reader).
   PngSuite's x*.png (corrupt) must decode to none.
2. Adversarial inputs: zip bomb, huge IHDR, truncations; each must be `none`
   (or the exact image) and fast.
3. Fuzz: N mutated files (half with CRCs repaired so the mutation reaches the
   inflater and unfilter); every result must be a clean `none` or a
   `w h` whose RGBA file is exactly w*h*4 bytes; no crash, no hang.

Usage: python3 tests/check_png_decode.py [--fuzz N] [--no-fetch]
"""
import argparse
import io
import random
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
EXE = REPO / ".lake" / "build" / "bin" / "pngdump"
SUITE = REPO / "tests" / "corpora" / "pngsuite"
MAX_PIXELS = 16777216


# ---------------------------------------------------------------- PNG bits

def chunk(typ: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + typ + data + struct.pack(">I", zlib.crc32(typ + data))


def chunks(b: bytes):
    """(offset, type, data) of every complete chunk."""
    pos = 8
    while pos + 12 <= len(b):
        n = struct.unpack(">I", b[pos:pos + 4])[0]
        if pos + 12 + n > len(b):
            return
        yield pos, b[pos + 4:pos + 8], b[pos + 8:pos + 8 + n]
        pos += 12 + n


def info(b: bytes):
    """(w, h, depth, ctype, interlace, plte, trns) as the crate keeps them:
    only chunks before the first IDAT, first PLTE/tRNS."""
    w = h = d = ct = il = None
    plte = trns = None
    for _, t, data in chunks(b):
        if t == b"IHDR":
            w, h, d, ct, _, _, il = struct.unpack(">IIBBBBB", data)
        elif t == b"IDAT":
            break
        elif t == b"PLTE" and plte is None:
            plte = data
        elif t == b"tRNS" and trns is None and len(data) <= 256:
            if (ct == 0 and len(data) >= 2) or (ct == 2 and len(data) >= 6) or (ct == 3 and plte is not None):
                trns = data
    return w, h, d, ct, il, plte, trns


CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def passes(w, h, il):
    for x0, y0, dx, dy in (ADAM7 if il else [(0, 0, 1, 1)]):
        pw = (w - x0 + dx - 1) // dx if w > x0 else 0
        ph = (h - y0 + dy - 1) // dy if h > y0 else 0
        if pw and ph:
            yield x0, y0, dx, dy, pw, ph


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def raw_samples(b: bytes) -> np.ndarray:
    """Unpacked samples (h, w, channels) at full depth. Used only for the
    16-bit RGB tRNS key, which Pillow cannot report."""
    w, h, d, ct, il, _, _ = info(b)
    ch = CHANNELS[ct]
    z = zlib.decompressobj().decompress(b"".join(data for _, t, data in chunks(b) if t == b"IDAT"))
    bpp = max(1, ch * d // 8)
    out = np.zeros((h, w, ch), dtype=np.uint32)
    pos = 0
    for x0, y0, dx, dy, pw, ph in passes(w, h, il):
        rb = (pw * ch * d + 7) // 8
        prev = bytearray(rb)
        for y in range(ph):
            f, row = z[pos], bytearray(z[pos + 1:pos + 1 + rb])
            pos += 1 + rb
            for i in range(rb):
                a = row[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + [0, a, prev[i], (a + prev[i]) // 2, paeth(a, prev[i], c)][f]) & 255
            prev = row
            for x in range(pw):
                for c in range(ch):
                    if d == 16:
                        v = row[2 * (x * ch + c)] * 256 + row[2 * (x * ch + c) + 1]
                    elif d == 8:
                        v = row[x * ch + c]
                    else:
                        bit = x * d
                        v = (row[bit // 8] >> (8 - d - bit % 8)) & ((1 << d) - 1)
                    out[y0 + y * dy, x0 + x * dx, c] = v
    return out


def expected(b: bytes) -> np.ndarray:
    """RGBA8 (h, w, 4) that resvg's decode path produces (straight alpha)."""
    w, h, d, ct, il, plte, trns = info(b)
    im = Image.open(io.BytesIO(b))
    im.load()
    a = np.array(im)
    out = np.zeros((h, w, 4), dtype=np.uint8)
    out[..., 3] = 255
    if ct == 3:
        n = len(plte) // 3
        pal = np.zeros((256, 4), dtype=np.uint8)
        pal[:, 3] = 255
        pal[:n, :3] = np.frombuffer(plte[:3 * n], dtype=np.uint8).reshape(n, 3)
        if trns is not None and len(trns) <= n:
            pal[:len(trns), 3] = np.frombuffer(trns, dtype=np.uint8)
        assert im.mode in ("P", "1", "L"), im.mode
        return pal[a.astype(np.intp)]
    if ct == 0:
        if d == 16:
            v = a.astype(np.uint32)
            g = (v >> 8).astype(np.uint8)
            key = trns[0] * 256 + trns[1] if trns is not None and len(trns) == 2 else None
        else:
            g = (a.astype(np.uint8) * 255) if im.mode == "1" else a.astype(np.uint8)
            v = g.astype(np.uint32) // (255 // ((1 << d) - 1))
            key = trns[1] if trns is not None else None
        out[..., 0] = out[..., 1] = out[..., 2] = g
        if key is not None:
            out[..., 3] = np.where(v == key, 0, 255)
        return out
    if ct == 2:
        assert im.mode == "RGB", im.mode
        out[..., :3] = a
        if trns is not None:
            if d == 8:
                m = (a == np.array([trns[1], trns[3], trns[5]], dtype=np.uint8)).all(-1)
                out[..., 3] = np.where(m, 0, 255)
            elif len(trns) == 6:
                key = np.array(struct.unpack(">HHH", trns), dtype=np.uint32)
                m = (raw_samples(b) == key).all(-1)
                out[..., 3] = np.where(m, 0, 255)
        return out
    if ct == 4:
        if im.mode == "RGBA":  # Pillow widens 16-bit LA to RGBA (high bytes)
            return a
        assert im.mode == "LA", im.mode
        out[..., 0] = out[..., 1] = out[..., 2] = a[..., 0]
        out[..., 3] = a[..., 1]
        return out
    assert ct == 6 and im.mode == "RGBA", (ct, im.mode)
    return a


# ---------------------------------------------------------- PNG generator

def pack_row(samples, d):
    """One row of samples (flat list) at depth d, MSB first."""
    if d == 16:
        return b"".join(struct.pack(">H", v) for v in samples)
    if d == 8:
        return bytes(samples)
    out, acc, nb = bytearray(), 0, 0
    for v in samples:
        acc = (acc << d) | v
        nb += d
        if nb == 8:
            out.append(acc)
            acc = nb = 0
    if nb:
        out.append(acc << (8 - nb))
    return bytes(out)


def filt(row: bytes, prev: bytes, f: int, bpp: int) -> bytes:
    out = bytearray(len(row))
    for i in range(len(row)):
        a = row[i - bpp] if i >= bpp else 0
        c = prev[i - bpp] if i >= bpp else 0
        pred = [0, a, prev[i], (a + prev[i]) // 2, paeth(a, prev[i], c)][f]
        out[i] = (row[i] - pred) & 255
    return bytes(out)


def make_png(rng, w, h, ct, d, il, trns_mode, zmode, split):
    ch = CHANNELS[ct]
    top = (1 << d) - 1
    npal = rng.randint(1, 1 << d) if ct == 3 else 0
    hi = npal - 1 if ct == 3 else top
    # Smooth-ish content so tRNS keys and back-references both occur.
    px = np.zeros((h, w, ch), dtype=np.uint32)
    for y in range(h):
        for x in range(w):
            for c in range(ch):
                px[y, x, c] = rng.randint(0, hi) if rng.random() < 0.3 else (x * 7 + y * 3 + c * 11) % (hi + 1)
    ihdr = struct.pack(">IIBBBBB", w, h, d, ct, 0, 0, il)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
    if ct == 3:
        out += chunk(b"PLTE", bytes(rng.randint(0, 255) for _ in range(3 * npal)))
    if trns_mode:
        if ct == 0:
            k = int(px[rng.randrange(h), rng.randrange(w), 0])
            out += chunk(b"tRNS", struct.pack(">H", k))
        elif ct == 2:
            k = px[rng.randrange(h), rng.randrange(w)]
            out += chunk(b"tRNS", struct.pack(">HHH", *map(int, k)))
        elif ct == 3:
            out += chunk(b"tRNS", bytes(rng.randint(0, 255) for _ in range(rng.randint(1, npal))))
    bpp = max(1, ch * d // 8)
    raw = bytearray()
    for x0, y0, dx, dy, pw, ph in passes(w, h, il):
        prev = bytes((pw * ch * d + 7) // 8)
        for y in range(ph):
            row = pack_row([int(v) for v in px[y0 + y * dy, x0::dx][:pw].reshape(-1)], d)
            f = rng.randrange(5)
            raw += bytes([f]) + filt(row, prev, f, bpp)
            prev = row
    level, strategy = zmode
    co = zlib.compressobj(level, zlib.DEFLATED, 15, 9, strategy)
    z = co.compress(bytes(raw)) + co.flush()
    cuts = sorted(rng.sample(range(1, len(z)), min(split, len(z) - 1))) if split else []
    for s, e in zip([0] + cuts, cuts + [len(z)]):
        out += chunk(b"IDAT", z[s:e])
    return out + chunk(b"IEND", b"")


ZMODES = [(0, zlib.Z_DEFAULT_STRATEGY), (1, zlib.Z_FIXED), (6, zlib.Z_DEFAULT_STRATEGY),
          (9, zlib.Z_DEFAULT_STRATEGY), (6, zlib.Z_HUFFMAN_ONLY), (6, zlib.Z_RLE), (9, zlib.Z_FILTERED)]
DEPTHS = {0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]}


def generated(rng):
    files = {}
    for ct, ds in DEPTHS.items():
        for d in ds:
            for il in (0, 1):
                for k in range(4):
                    w, h = rng.randint(1, 37), rng.randint(1, 37)
                    zm = ZMODES[(k + d + ct) % len(ZMODES)]
                    name = f"gen_c{ct}_d{d}_i{il}_{k}.png"
                    files[name] = make_png(rng, w, h, ct, d, il, k % 2 == 1, zm, k)
    # One larger image: long matches and multi-block streams.
    files["gen_big_rgba.png"] = make_png(rng, 300, 211, 6, 8, 0, False, (9, zlib.Z_DEFAULT_STRATEGY), 5)
    files["gen_big_pal_i.png"] = make_png(rng, 257, 190, 3, 4, 1, True, (6, zlib.Z_DEFAULT_STRATEGY), 3)
    return files


# ------------------------------------------------------------------ runner

def run(paths, outdir="-", timeout=120):
    """pngdump over `paths`: {path: None | (w, h)}."""
    res = {}
    for i in range(0, len(paths), 200):
        batch = [str(p) for p in paths[i:i + 200]]
        r = subprocess.run([str(EXE), str(outdir)] + batch, capture_output=True, text=True, timeout=timeout)
        assert r.returncode == 0, f"pngdump crashed (exit {r.returncode}):\n{r.stderr[-2000:]}"
        lines = r.stdout.splitlines()
        assert len(lines) == len(batch), f"pngdump printed {len(lines)} lines for {len(batch)} files"
        for p, line in zip(batch, lines):
            assert line.startswith(p + " "), line
            rest = line[len(p) + 1:].split()
            res[p] = None if rest == ["none"] else (int(rest[0]), int(rest[1]))
    return res


def fetch_suite():
    if SUITE.exists():
        return
    tmp = SUITE.parent / "image-png-sparse"
    subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse",
                    "https://github.com/image-rs/image-png", str(tmp)], check=True)
    subprocess.run(["git", "-C", str(tmp), "sparse-checkout", "set", "tests/pngsuite"], check=True)
    (tmp / "tests" / "pngsuite").rename(SUITE)


def check_corpus(files: dict, work: Path):
    """files: name -> bytes. Every non-x* file must match Pillow exactly."""
    for name, b in files.items():
        (work / name).write_bytes(b)
    out = work / "out"
    out.mkdir()
    res = run([work / n for n in files], out)
    bad = []
    for name, b in files.items():
        r = res[str(work / name)]
        if name.startswith("x"):
            if r is not None:
                bad.append(f"{name}: corrupt file decoded to {r}")
            continue
        if r is None:
            bad.append(f"{name}: none")
            continue
        exp = expected(b)
        got = np.frombuffer((out / (name + ".rgba")).read_bytes(), dtype=np.uint8)
        if r != (exp.shape[1], exp.shape[0]) or got.size != exp.size:
            bad.append(f"{name}: size {r} vs {exp.shape[1]}x{exp.shape[0]}")
            continue
        diff = np.count_nonzero(got.reshape(exp.shape) != exp)
        if diff:
            bad.append(f"{name}: {diff} bytes differ from Pillow")
    return bad


def adversarial(work: Path):
    """(name, bytes, expected result) for the cases that must stay cheap."""
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = lambda w, h, d=8, ct=6: chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, d, ct, 0, 0, 0))
    cases = []
    # Zip bomb: 16x16 RGBA wants 16*65 bytes; the stream holds ~200 MB of zeros.
    co = zlib.compressobj(9)
    bomb = co.compress(bytes(16 * 65)) + b"".join(co.compress(bytes(1 << 20)) for _ in range(200)) + co.flush()
    cases.append(("bomb_small_ihdr", sig + ihdr(16, 16) + chunk(b"IDAT", bomb) + chunk(b"IEND", b""), (16, 16)))
    # The same stream under an IHDR that fits the cap but not the data.
    cases.append(("huge_ihdr", sig + ihdr(100000, 100000) + chunk(b"IDAT", bomb) + chunk(b"IEND", b""), None))
    cases.append(("over_max_pixels", sig + ihdr(4097, 4096) + chunk(b"IDAT", bomb) + chunk(b"IEND", b""), None))
    cases.append(("max_ihdr_tiny_idat", sig + ihdr(4096, 4096) + chunk(b"IDAT", zlib.compress(bytes(1000))) +
                  chunk(b"IEND", b""), None))
    cases.append(("zero_width", sig + ihdr(0, 5) + chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b""), None))
    good = make_png(random.Random(1), 20, 20, 6, 8, 1, False, (6, 0), 2)
    for cut in (7, 8, 20, 33, 40, len(good) // 2, len(good) - 12, len(good) - 9):
        cases.append((f"truncated_{cut}", good[:cut], None))
    cases.append(("no_iend", good[:-12] + b"\0\0\0\0IEND", (20, 20)))
    cases.append(("stops_after_idat_crc", good[:-12], None))
    names = []
    for name, b, _ in cases:
        (work / name).write_bytes(b)
        names.append(work / name)
    t = time.time()
    res = run(names, timeout=60)
    dt = time.time() - t
    bad = [f"{n}: got {res[str(work / n)]}, want {e}" for n, _, e in cases if res[str(work / n)] != e]
    if dt > 20:
        bad.append(f"adversarial cases took {dt:.1f}s")
    return bad, len(cases), dt


def mutate(rng, b: bytes) -> bytes:
    b = bytearray(b)
    for _ in range(rng.randint(1, 4)):
        op = rng.randrange(5)
        i = rng.randrange(len(b))
        if op == 0:
            b[i] ^= 1 << rng.randrange(8)
        elif op == 1:
            b[i] = rng.randrange(256)
        elif op == 2:
            del b[i:i + rng.randint(1, 16)]
        elif op == 3:
            b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
        else:
            b = b[:i]
        if len(b) < 9:
            break
    return bytes(b)


def fix_crcs(b: bytes) -> bytes:
    out = bytearray(b[:8])
    for pos, t, data in chunks(b):
        out += chunk(t, data)
    return bytes(out)


def fuzz(files: dict, n: int, work: Path, rng):
    seeds = [b for k, b in files.items() if not k.startswith("x") and len(b) < 200000]
    names = []
    for k in range(n):
        m = mutate(rng, rng.choice(seeds))
        if k % 2:
            m = fix_crcs(m)
        p = work / f"fuzz_{k:05d}.png"
        p.write_bytes(m)
        names.append(p)
    out = work / "fuzzout"
    out.mkdir()
    t = time.time()
    res = run(names, out, timeout=300)
    dt = time.time() - t
    some = 0
    bad = []
    for p in names:
        r = res[str(p)]
        if r is None:
            continue
        some += 1
        w, h = r
        size = (out / (p.name + ".rgba")).stat().st_size
        if not (w > 0 and h > 0 and w * h <= MAX_PIXELS and size == w * h * 4):
            bad.append(f"{p.name}: {r} with {size} bytes")
    return bad, some, dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=2000)
    ap.add_argument("--no-fetch", action="store_true")
    ap.add_argument("--seed", type=int, default=61)
    args = ap.parse_args()
    assert EXE.exists(), f"{EXE} missing: run `lake build pngdump`"
    rng = random.Random(args.seed)
    files = {}
    if not args.no_fetch:
        fetch_suite()
    if SUITE.exists():
        files.update({p.name: p.read_bytes() for p in sorted(SUITE.glob("*.png"))})
    files.update(generated(rng))
    # Round trip through our own encoder (stored blocks, several > 64 KiB).
    lean_svg = REPO / ".lake" / "build" / "bin" / "lean-svg"
    with tempfile.TemporaryDirectory() as td:
        for svg, width in (("02_rect_circle.svg", 300), ("01_triangle.svg", 401)):
            out = Path(td) / (svg + ".png")
            subprocess.run([str(lean_svg), str(REPO / "tests" / "svg" / svg), str(out), "--width", str(width)],
                           check=True, capture_output=True)
            files[f"leansvg_{svg}.png"] = out.read_bytes()
    failed = False
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        (work / "corpus").mkdir()
        bad = check_corpus(files, work / "corpus")
        nx = sum(k.startswith("x") for k in files)
        print(f"-- corpus: {len(files)} files ({nx} corrupt), {len(bad)} mismatches")
        for line in bad:
            print("   " + line)
        failed |= bool(bad)
        (work / "adv").mkdir()
        bad, n, dt = adversarial(work / "adv")
        print(f"-- adversarial: {n} cases in {dt:.2f}s, {len(bad)} wrong")
        for line in bad:
            print("   " + line)
        failed |= bool(bad)
        (work / "fuzz").mkdir()
        bad, some, dt = fuzz(files, args.fuzz, work / "fuzz", rng)
        print(f"-- fuzz: {args.fuzz} mutants in {dt:.1f}s, {some} decoded, "
              f"{args.fuzz - some} none, {len(bad)} bad")
        for line in bad:
            print("   " + line)
        failed |= bool(bad)
    if failed:
        sys.exit("FAIL")
    print("png decode ok")


if __name__ == "__main__":
    main()
