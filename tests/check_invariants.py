#!/usr/bin/env python3
"""T43 checks: the structural invariants review would otherwise keep by hand.

1. No IO in the library: `LeanSvg.lean` and `LeanSvg/**/*.lean` never
   mention `IO` (as `IO`, `IO.x`, `EIO`, `BaseIO`, `unsafeIO`, ...) or
   `System.` (comments and string literals don't count).
2. `Main.lean`'s file-system calls are exactly an allowlist, counted: one
   `IO.FS.readBinFile`, two `System.FilePath.pathExists`, one
   `IO.FS.withFile` with `.writeNew` and `IO.FS.Handle.write` (in
   `writeNewFile`).  Any other `IO.`/`System.` name, `open IO`/`open System`,
   or a known file-system function name used any other way fails.
3. Mechanical invariants from docs/DECISIONS.md across `LeanSvg/`: no
   `partial`, `unsafe`, `@[extern]`, `panic!`, `Float`, or `!`-indexing
   (`]!`, `get!`, `set!`); comments and string literals are stripped first
   so prose ("never needs `partial`") and string contents can't trigger it.
4. No stdout/stderr on the `lean-svg` main path (T98b): `Main.lean`,
   `LeanSvg.lean` and `LeanSvg/*.lean` (everything the `lean-svg` binary
   links) must not mention a print, a standard stream, a debug trace, a
   panic or a subprocess; the only outputs are the files `main` writes and
   the exit code.
5. No `theorem` under `LeanSvg/`: theorems live in `spec/`, where the axiom
   audit and `spec/README.md` find them.  Small `example`s next to the code
   are fine.

The dev tools (`FontDump.lean`, `ShapeDump.lean`, ...) are separate
executables that `lean-svg` does not link, and `docs/learn/*.lean` is a
teaching file outside the build; none of them is scanned.
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
            out.append(" " * (j - i))
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


IO_RE = re.compile(r"IO(?![a-z])|System\.")


def check_no_io_in_library() -> None:
    offenders = []
    for path in [REPO / "LeanSvg.lean"] + lean_files():
        stripped = strip_comments_and_strings(path.read_text())
        for lineno, line in enumerate(stripped.splitlines(), start=1):
            if IO_RE.search(line):
                offenders.append(f"{path.relative_to(REPO)}:{lineno}: {line.strip()}")
    assert not offenders, "FAIL [no-io]: IO in the library:\n" + "\n".join(offenders)
    print("-- no-io: no IO or System. under LeanSvg/")


# Every `IO.`/`System.` name Main.lean may use, with its exact count.
MAIN_QUALIFIED = {
    "IO.FS.readBinFile": 1,
    "System.FilePath.pathExists": 2,
    "IO.FS.withFile": 1,
    "IO.FS.Handle.write": 1,
    "System.FilePath": 1,  # the type of `writeNewFile`'s path
}
# File-system names by themselves (catches dot notation such as
# `path.pathExists`), with the exact count each may appear.
MAIN_BARE = {"readBinFile": 1, "pathExists": 2, "withFile": 1, "writeNew": 1, "write": 1}
# Other file-system and process names that must not appear in Main.lean at all.
MAIN_FORBIDDEN = [
    "readFile", "writeFile", "writeBinFile", "removeFile", "rename", "createDir",
    "createDirAll", "removeDirAll", "createTempFile", "readDir", "metadata", "isDir",
    "realPath", "lines", "putStr", "putStrLn", "getLine", "readToEnd", "append",
    "readWrite", "truncate", "flush", "Handle", "Process", "dbg_trace", "dbgTrace",
]


def check_main_fs_calls() -> None:
    text = strip_comments_and_strings((REPO / "Main.lean").read_text())
    assert not re.search(r"^\s*open\s+(IO|System)\b", text, re.M), (
        "FAIL [main-fs]: Main.lean opens IO or System")
    qualified = re.findall(r"(?<![A-Za-z0-9_.])((?:IO|System)(?:\.[A-Za-z_][A-Za-z0-9_]*)+)", text)
    counts = {n: qualified.count(n) for n in set(qualified)}
    assert counts == MAIN_QUALIFIED, (
        f"FAIL [main-fs]: Main.lean's IO./System. names are {counts}, expected {MAIN_QUALIFIED}")
    for name, n in MAIN_BARE.items():
        found = len(re.findall(rf"(?<![A-Za-z0-9_]){name}(?![A-Za-z0-9_])", text))
        assert found == n, f"FAIL [main-fs]: Main.lean mentions {name} {found} times, expected {n}"
    for name in MAIN_FORBIDDEN:
        # `Handle` is allowed only inside `IO.FS.Handle.write`.
        rest = text.replace("IO.FS.Handle.write", "")
        assert not re.search(rf"(?<![A-Za-z0-9_]){name}(?![A-Za-z0-9_])", rest), (
            f"FAIL [main-fs]: Main.lean mentions {name}")
    print("-- main-fs: Main.lean's file-system calls are exactly "
          "readBinFile x1, pathExists x2, withFile .writeNew + Handle.write x1")


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


# `IO.println`, bare `println` under `open IO`, `println!`, `getStdout`, the
# streams themselves, `dbg_trace`/`dbgTrace*`, `panic*` and subprocesses.
OUTPUT_RE = re.compile(
    r"(?<![A-Za-z0-9_])(?:e?println!?|e?print!?|putStr\w*|getStdout|getStderr|setStdout|"
    r"setStderr|stdout|stderr|dbg_trace\w*|dbgTrace\w*|panic\w*|Process\w*)(?![A-Za-z0-9_])"
)


def check_no_output_on_main_path() -> None:
    root_exe = re.search(
        r'\[\[lean_exe\]\]\s*name = "lean-svg"\s*root = "(\w+)"', (REPO / "lakefile.toml").read_text()
    )
    assert root_exe and root_exe.group(1) == "Main", "FAIL [no-output]: lean-svg root is not Main"
    main = REPO / "Main.lean"
    imports = re.findall(r"^import\s+(\S+)", main.read_text(), re.M)
    assert imports == ["LeanSvg"], f"FAIL [no-output]: Main.lean imports {imports}, not just LeanSvg"
    offenders = []
    for path in [main, REPO / "LeanSvg.lean"] + lean_files():
        stripped = strip_comments_and_strings(path.read_text())
        for lineno, line in enumerate(stripped.splitlines(), start=1):
            if OUTPUT_RE.search(line):
                offenders.append(f"{path.relative_to(REPO)}:{lineno}: {line.strip()}")
    assert not offenders, (
        "FAIL [no-output]: the lean-svg main path can write to stdout/stderr:\n"
        + "\n".join(offenders)
    )
    print("-- no-output: no print/stream/trace/panic/process on the lean-svg main path")


THEOREM_RE = re.compile(r"^\s*(?:private\s+|protected\s+|noncomputable\s+)*theorem\b")


def check_no_theorems_in_library() -> None:
    offenders = []
    for path in [REPO / "LeanSvg.lean"] + lean_files():
        stripped = strip_comments_and_strings(path.read_text())
        for lineno, line in enumerate(stripped.splitlines(), start=1):
            if THEOREM_RE.match(line):
                offenders.append(f"{path.relative_to(REPO)}:{lineno}: {line.strip()}")
    assert not offenders, "FAIL [spec]: theorem outside spec/:\n" + "\n".join(offenders)
    print("-- spec: no theorem under LeanSvg/ (they are in spec/)")


def main() -> None:
    check_no_io_in_library()
    check_main_fs_calls()
    check_no_output_on_main_path()
    check_mechanical_invariants()
    check_no_theorems_in_library()
    print("invariants ok")


if __name__ == "__main__":
    main()
