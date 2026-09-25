#!/usr/bin/env python3
"""Axiom audit for the proof boundary (T43/T43b).

Discovers every `theorem` under `proofs/*.lean` and
`LeanSvg/Effect.lean` by scanning the source -- not from a hand-maintained
list, so a new theorem cannot silently dodge the audit -- then elaborates a
`#print axioms` for each and checks the result:

* Theorems in `LeanSvg/Effect.lean` (the six effect-confinement theorems)
  must depend on exactly `[propext]`.
* Theorems in `proofs/*.lean` may depend on any subset of the standard three
  axioms (`propext`, `Classical.choice`, `Quot.sound`) and nothing else.

Either way, `sorryAx` or any other axiom fails the audit, as does a theorem
that fails to elaborate at all.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DECL_RE = re.compile(
    r"^\s*(?:private\s+|protected\s+|noncomputable\s+)*theorem\s+"
    r"([A-Za-z_][A-Za-z0-9_.'!?]*)"
)
NAMESPACE_RE = re.compile(r"^\s*namespace\s+(\S+)")
END_RE = re.compile(r"^\s*end\b")

# Names may themselves contain `'` (e.g. `encode_size_le'`), so the capture
# is greedy up to the last occurrence of the fixed suffix, not `[^']+`.
AXIOM_LINE_RE = re.compile(r"^'(.+)' depends on axioms: \[(.*)\]$")
NO_AXIOM_LINE_RE = re.compile(r"^'(.+)' does not depend on any axioms$")


def theorems_in(path: Path) -> list[str]:
    """Fully-qualified names of every `theorem` declared in `path`, in the
    order namespaces open/close in the source."""
    stack: list[str] = []
    names: list[str] = []
    for line in path.read_text().splitlines():
        m = NAMESPACE_RE.match(line)
        if m:
            stack.append(m.group(1))
            continue
        if END_RE.match(line):
            assert stack, f"{path}: 'end' with no open namespace"
            stack.pop()
            continue
        m = DECL_RE.match(line)
        if m:
            names.append(".".join(stack + [m.group(1)]))
    return names


def run_lean(source: str) -> tuple[int, str, str]:
    with tempfile.NamedTemporaryFile(
        "w", suffix=".lean", dir=REPO, delete=False
    ) as f:
        f.write(source)
        tmp = Path(f.name)
    try:
        r = subprocess.run(
            ["lake", "env", "lean", str(tmp)],
            cwd=REPO,
            capture_output=True,
            text=True,
        )
        return r.returncode, r.stdout, r.stderr
    finally:
        tmp.unlink()


def audit(names: list[str], allowed: set[str], prelude: str, label: str,
          exact: bool) -> None:
    """Elaborate `prelude` followed by a `#print axioms` for each name, then
    check every reported axiom set is within (`exact=False`) or equal to
    (`exact=True`) `allowed`."""
    assert names, f"{label}: no theorems found -- audit would check nothing"
    source = prelude + "\n" + "\n".join(f"#print axioms {n}" for n in names) + "\n"
    code, out, err = run_lean(source)
    print(out, end="")
    if code != 0 or "error:" in err.lower():
        print(err, file=sys.stderr)
        sys.exit(f"FAIL [{label}]: elaboration failed")
    seen: dict[str, set[str]] = {}
    for line in out.splitlines():
        m = AXIOM_LINE_RE.match(line)
        if m:
            seen[m.group(1)] = {a.strip() for a in m.group(2).split(",") if a.strip()}
            continue
        m = NO_AXIOM_LINE_RE.match(line)
        if m:
            seen[m.group(1)] = set()
    missing = set(names) - seen.keys()
    assert not missing, f"FAIL [{label}]: no #print axioms output for {sorted(missing)}"
    for name in names:
        axioms = seen[name]
        ok = axioms == allowed if exact else axioms <= allowed
        if not ok:
            sys.exit(
                f"FAIL [{label}]: '{name}' depends on axioms {sorted(axioms)}, "
                f"{'expected exactly' if exact else 'allowed only a subset of'} "
                f"{sorted(allowed)}"
            )
    print(f"-- {label}: {len(names)} theorem(s) ok")


def main() -> None:
    effect_file = REPO / "LeanSvg" / "Effect.lean"
    effect_names = theorems_in(effect_file)
    audit(effect_names, {"propext"}, "import LeanSvg", str(effect_file.relative_to(REPO)),
          exact=True)

    proofs_dir = REPO / "proofs"
    found_proof_theorem = False
    for path in sorted(proofs_dir.glob("*.lean")):
        names = theorems_in(path)
        if not names:
            continue
        found_proof_theorem = True
        audit(
            names,
            {"propext", "Classical.choice", "Quot.sound"},
            path.read_text(),
            str(path.relative_to(REPO)),
            exact=False,
        )
    assert found_proof_theorem, "no theorem found under proofs/ -- check the glob"

    print("axioms ok")


if __name__ == "__main__":
    main()
