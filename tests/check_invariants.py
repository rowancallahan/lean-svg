#!/usr/bin/env python3
"""T43 checks 2-4: the structural invariants review currently keeps by hand.

2. `Op` (LeanSvg/Effect.lean) has exactly the constructors `readInput` and
   `writeOutput`: checked by elaborating an exhaustive match on `Op` with no
   wildcard arm, so an added or renamed constructor fails to compile.
3. No `IO.` outside the effect layer: `LeanSvg/*.lean` other than
   `Effect.lean` must not mention `IO.` (comments and string literals don't
   count).
4. Mechanical invariants from tasks/README.md across `LeanSvg/`: no
   `partial`, `unsafe`, `@[extern]`, `panic!`, `Float`, or `!`-indexing
   (`]!`, `get!`, `set!`); comments and string literals are stripped first
   so prose ("never needs `partial`") and string contents can't trigger it.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LEANSVG = REPO / "LeanSvg"


def strip_comments_and_strings(text: str) -> str:
    """Blank out `--` line comments, nested `/- -/` block comments, and
    `"..."` string literals, keeping newlines so line numbers still line up."""
    out = []
    i, n = 0, len(text)
    depth = 0
    while i < n:
        if depth == 0 and text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(text[i:j])
            i = j
            continue
        if text.startswith("/-", i):
            depth += 1
            out.append("  ")
            i += 2
            continue
        if depth > 0 and text.startswith("-/", i):
            depth -= 1
            out.append("  ")
            i += 2
            continue
        if depth > 0:
            out.append("\n" if text[i] == "\n" else " ")
            i += 1
            continue
        if text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def lean_files(exclude: set[str] = frozenset()) -> list[Path]:
    return sorted(p for p in LEANSVG.rglob("*.lean") if p.name not in exclude)


def check_two_effects() -> None:
    snippet = """import LeanSvg
open LeanSvg
/-- Fails to elaborate (non-exhaustive match) if `Op` gains, loses, or
renames a constructor. Catches a rename too: `.readInput`/`.outputExists`/`.writeOutput`
would no longer resolve. Misses: a constructor added *and* immediately
handled by a matching new arm here, but nothing writes this file but us. -/
example (op : Op) : Unit :=
  match op with
  | .readInput => ()
  | .outputExists => ()
  | .writeOutput _ => ()
"""
    with tempfile.NamedTemporaryFile("w", suffix=".lean", dir=REPO, delete=False) as f:
        f.write(snippet)
        tmp = Path(f.name)
    try:
        r = subprocess.run(
            ["lake", "env", "lean", str(tmp)], cwd=REPO, capture_output=True, text=True
        )
    finally:
        tmp.unlink()
    assert r.returncode == 0 and "error" not in r.stderr.lower(), (
        f"FAIL [two-effects]: Op is not exactly {{readInput, outputExists, writeOutput}}:\n{r.stderr}"
    )
    print("-- two-effects: Op has exactly {readInput, outputExists, writeOutput}")


IO_RE = re.compile(r"(?<![A-Za-z0-9_])IO\.")


def check_no_io_outside_effect() -> None:
    offenders = []
    for path in lean_files(exclude={"Effect.lean"}):
        stripped = strip_comments_and_strings(path.read_text())
        for lineno, line in enumerate(stripped.splitlines(), start=1):
            if IO_RE.search(line):
                offenders.append(f"{path.relative_to(REPO)}:{lineno}: {line.strip()}")
    assert not offenders, "FAIL [no-io]: IO. found outside Effect.lean:\n" + "\n".join(offenders)
    print("-- no-io: no IO. outside LeanSvg/Effect.lean")


MECHANICAL_PATTERNS = {
    "partial": re.compile(r"\bpartial\b"),
    "unsafe": re.compile(r"\bunsafe\b"),
    "@[extern]": re.compile(r"@\[\s*extern"),
    "panic!": re.compile(r"panic!"),
    "Float": re.compile(r"\bFloat\b"),
    "!-indexing (`]!`)": re.compile(r"\]!"),
    "!-indexing (get!)": re.compile(r"\bget!"),
    "!-indexing (set!)": re.compile(r"\bset!"),
}


def check_mechanical_invariants() -> None:
    offenders = []
    for path in lean_files():
        stripped = strip_comments_and_strings(path.read_text())
        for lineno, line in enumerate(stripped.splitlines(), start=1):
            for label, pat in MECHANICAL_PATTERNS.items():
                if pat.search(line):
                    offenders.append(
                        f"{path.relative_to(REPO)}:{lineno}: forbidden {label}: {line.strip()}"
                    )
    assert not offenders, "FAIL [mechanical]: forbidden construct found:\n" + "\n".join(offenders)
    print("-- mechanical: no partial/unsafe/@[extern]/panic!/Float/!-indexing under LeanSvg/")


def main() -> None:
    check_two_effects()
    check_no_io_outside_effect()
    check_mechanical_invariants()
    print("invariants ok")


if __name__ == "__main__":
    main()
