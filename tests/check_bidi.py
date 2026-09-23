#!/usr/bin/env python3
"""Compare LeanSvg.Bidi (via .lake/build/bin/shapedump) against python-bidi 0.6.11,
which wraps the Rust crate unicode-bidi 0.3.18.

Checked per case and paragraph level:
  * pre-L1 paragraph levels (`paragraphLevels`) == BidiInfo.levels from
    `get_display(debug=True)` (per byte there; mapped to codepoints here);
  * display string: concatenating our `visualRuns` (odd-level runs reversed)
    == `get_display(text)` (reorder_line: L1+L2, no mirroring), for every case
    where reorder_line does not take its "no odd level" shortcut;
  * `levels` is consistent with `visualRuns` (every run is one level).
python-bidi splits paragraphs at class-B characters; Bidi.lean treats its input
as one paragraph, so texts with several paragraphs are fed to Bidi.lean one
paragraph at a time (python's own paragraph ranges).

Also (always) checks the whole `bidiClass` table against python-bidi's
`original_classes` for every non-surrogate codepoint, and `mirror` against
harfrust's table as evaluated independently by gen_bidi_tables.py for the BMP.

Usage: python3 check_bidi.py [N_RANDOM] [SEED]
"""
import json
import os
import random
import re
import subprocess
import sys

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path = [p for p in sys.path if p not in ("", os.getcwd())]
from bidi import get_display  # noqa: E402

LRE, RLE, PDF, LRO, RLO = "‪", "‫", "‬", "‭", "‮"
LRI, RLI, FSI, PDI = "⁦", "⁧", "⁨", "⁩"
HEB = "אבגדהו"
ARA = "ابتثجح"

HAND = [
    "", "abc def", "hello world  ", "אבג דהו", "مرحبا بالعالم", "abc אבג def",
    "אבג 123 דהו", "abc ١٢٣ def", "مرحبا ١٢٣ عالم", "$12.50", "אבג $12.50 דהו",
    "مرحبا $12.50", "1+2-3", "אבג 1,234.5% דהו", "12:30 אבג", "a (אב) c", "אב (cd) גד",
    "אב [cd {אב}] גד", "a (b [c) d] e", "(((אב)))", "abc " + RLE + "אבג def" + PDF + " ghi",
    "abc " + LRE + "abc " + RLE + "אבג" + PDF + PDF + " x", RLO + "abc" + PDF + " def",
    LRO + "אבג" + PDF + " דהו", "abc " + RLI + "def" + PDI + " ghi", "אבג " + LRI + "abc" + PDI,
    FSI + "אבג" + PDI + " abc", FSI + "abc" + PDI + " אבג", FSI + LRI + "אב" + PDI + "c" + PDI,
    "a" + PDI + "b" + PDF + "c", "אבג   ", "abc \t אבג  ", "אְבְ", "اًب",
    "à א̀", "a‍b­c א‍ב", "‏abc", "‎אבג", RLE * 70 + "x" + PDF * 70,
    RLI * 130 + "x" + PDI * 130, LRE * 130 + "אב", "(" * 70 + "אב" + ")" * 70,
    "abc אבג", "אבג ", "a  b", "1.2.3 אב", "אב -5", "ET€12", "٣٤٥,٦", "a ב",
    "〈אב〉 c", "〉a〈", "ab​", "x ‪‬ y",
]

POOL = (list("abcxyz") + list(HEB) + list(ARA) + list("0123456789") + list("٠١٢٣")
        + list("+-.,:/$%#") + [" ", " ", "\t"] + list("()[]{}")
        + [LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI]
        + ["‍", "‎", "‏", "̀", "ً", "ְ", " "]
        # a few extra multi-byte weak/neutral classes
        + [" ", "،", "€", "­", "٫", "۱", "²", "〈", "〉"])


# Skewed pool for a second random phase: mostly controls, brackets, weak types.
STRESS = ([LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI] * 3 + list("()[]{}") * 2
          + list("+-.,:$%") + list("1٣۱") + ["\u00ad", "\u200d", "\u0300", "\u064b", " "]
          + list("aאا"))


def py_expected(text, base):
    dbg = get_display(text, base_dir=base, debug=True)
    disp = get_display(text, base_dir=base)
    tail = dbg[dbg.index("original_classes:"):]
    lv_sec = tail[tail.index("levels: ["):tail.index("paragraphs: [")]
    blevels = [int(x) for x in re.findall(r"Level\(\s*(\d+),?\s*\)", lv_sec)]
    pranges = [(int(a), int(b)) for a, b in re.findall(r"range: (\d+)\.\.(\d+)", tail)]
    b2c, off = {}, 0
    for ci, ch in enumerate(text):
        b2c[off] = ci
        off += len(ch.encode())
    b2c[off] = len(text)
    starts = [0]
    for ch in text:
        starts.append(starts[-1] + len(ch.encode()))
    clevels = [blevels[starts[i]] for i in range(len(text))]
    paras = [(b2c[a], b2c[b]) for a, b in pranges]
    return clevels, paras, disp


def check_tables():
    import importlib.util
    spec = importlib.util.spec_from_file_location("gen_bidi_tables", "tests/gen_bidi_tables.py")
    gen_bidi_tables = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen_bidi_tables)
    cps = [c for c in range(0x110000) if not 0xD800 <= c <= 0xDFFF and c != 0x2068]
    chunks = [cps[i:i + 4096] for i in range(0, len(cps), 4096)]
    lines = ["C " + " ".join("%x" % c for c in ch) for ch in chunks]
    bmp = list(range(0x10000))
    lines += ["M " + " ".join("%x" % c for c in bmp[i:i + 4096]) for i in range(0, 0x10000, 4096)]
    out = subprocess.run([".lake/build/bin/shapedump"], input="\n".join(lines) + "\n",
                         capture_output=True, text=True, check=True).stdout.splitlines()
    bad_cls = 0
    for ch, line in zip(chunks, out):
        mine = [w.rsplit(".", 1)[1] for w in line.split()]
        text = "".join(map(chr, ch))
        dbg = get_display(text, base_dir="L", debug=True)
        sec = dbg[dbg.index("original_classes: ["):dbg.index("levels: [")]
        per_byte = re.findall(r"\b([A-Z]+),", sec[len("original_classes: ["):])
        k, py = 0, []
        for c in ch:
            py.append(per_byte[k])
            k += len(chr(c).encode())
        bad_cls += sum(a != b for a, b in zip(mine, py)) + abs(len(mine) - len(py))
    fsi = get_display("\u2068", base_dir="L", debug=True)
    bad_cls += "FSI" not in fsi
    exp = dict(gen_bidi_tables.mirror_pairs())
    mine_m = [int(w) for l in out[len(chunks):] for w in l.split()]
    bad_m = sum(mine_m[c] != exp.get(c, 0) for c in bmp) + (len(mine_m) != 0x10000)
    print("bidiClass mismatches vs python-bidi: %d / %d codepoints; mirror mismatches "
          "vs harfrust table: %d / 65536 (%d mirrored)" % (bad_cls, len(cps) + 1, bad_m, len(exp)))
    return bad_cls + bad_m


def main():
    bad_tables = check_tables()
    n_rand = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    cases = [(t, b) for t in HAND for b in "LR"]
    for _ in range(n_rand):
        t = "".join(rng.choice(POOL) for _ in range(rng.randint(0, 40)))
        cases.append((t, rng.choice("LR")))
    for _ in range(n_rand // 4):
        t = "".join(rng.choice(STRESS) for _ in range(rng.randint(0, 40)))
        cases.append((t, rng.choice("LR")))
    for _ in range(200):  # long: deep nesting, bracket-stack overflow
        pool = rng.choice([STRESS, POOL, list("([{") * 4 + list(")]}") + list("aא1 ")])
        t = "".join(rng.choice(pool) for _ in range(rng.randint(100, 400)))
        cases.append((t, rng.choice("LR")))
    # expected values, and the paragraph pieces we feed to Bidi.lean
    jobs, exp = [], []
    for text, base in cases:
        clevels, paras, disp = py_expected(text, base)
        if not paras:
            paras = [(0, 0)]
        exp.append((clevels, paras, disp))
        for a, b in paras:
            jobs.append(("1" if base == "R" else "0") + " " +
                        " ".join("%x" % ord(c) for c in text[a:b]))
    out = subprocess.run([".lake/build/bin/shapedump"], input="\n".join(jobs) + "\n",
                         capture_output=True, text=True, check=True).stdout.splitlines()
    assert len(out) == len(jobs), (len(out), len(jobs))
    res = iter(json.loads(l) for l in out)
    bad_lv = bad_disp = bad_cons = multi = n_disp = 0
    shown = 0
    for (text, base), (clevels, paras, disp) in zip(cases, exp):
        mine_pl, mine_disp, cons, ok_disp, cmp = [], "", True, True, False
        if len(paras) > 1:
            multi += 1
        for a, b in paras:
            r = next(res)
            seg = text[a:b]
            mine_pl += r["pl"]
            seg_disp = ""
            for s, e, l in r["runs"]:
                piece = seg[s:e]
                seg_disp += piece[::-1] if l % 2 else piece
                if any(r["lv"][k] != l for k in range(s, e)):
                    cons = False
            covered = sorted(k for s, e, _ in r["runs"] for k in range(s, e))
            cons = cons and covered == list(range(len(seg)))
            # reorder_line (what get_display calls per paragraph) returns the text
            # unchanged, without calling visual_runs, when no pre-L1 level of the
            # paragraph is odd: nothing to compare then.
            if any(l % 2 for l in clevels[a:b]):
                cmp = True
                ok_disp = ok_disp and seg_disp == disp[a:b]
                mine_disp += seg_disp
            else:
                mine_disp += seg
        n_disp += cmp
        ok_lv = mine_pl == clevels
        bad_lv += not ok_lv
        bad_disp += not ok_disp
        bad_cons += not cons
        if (not ok_lv or not ok_disp or not cons) and shown < 8:
            shown += 1
            print("MISMATCH base=%s text=%r" % (base, text))
            print("   cps     ", " ".join("%04x" % ord(c) for c in text))
            print("   py  pl  ", clevels, "\n   our pl  ", mine_pl)
            print("   py disp ", repr(disp), "\n   our disp", repr(mine_disp))
    print("cases: %d (%d hand-written x 2 levels, %d random, %d stress, 200 long; "
          "%d multi-paragraph)" % (len(cases), len(HAND), n_rand, n_rand // 4, multi))
    print("paragraph-level mismatches: %d / %d, display mismatches: %d / %d "
          "(cases with an odd level), inconsistent runs: %d"
          % (bad_lv, len(cases), bad_disp, n_disp, bad_cons))
    return 1 if bad_lv or bad_disp or bad_cons or bad_tables else 0


if __name__ == "__main__":
    sys.exit(main())
