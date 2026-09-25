import LeanSvg

/-!
# Command-line entry point

    lean-svg <input.svg> <output.png> [--width N] [--zoom Z] [--background COLOR]
             [--viewport X Y W H] [--threads N] [--warnings]

`main` below holds every file-system call `lean-svg` makes: one
`readBinFile` of the input, one `pathExists` per output path, and one
exclusive create (`withFile … .writeNew`, O_EXCL) per file written.  The rest
is pure: `Cli.parse` and `renderWithWarnings`.  Nothing is written to stdout
or stderr.

Proved about the pure parts (listed in `spec/README.md`): `spec/Cli.lean`
(the paths are literally command-line arguments, `--warnings` mode, the
warnings path differs from the output path) and `spec/SizeBound.lean` (`renderWithWarnings_size_le`,
`renderWithWarnings_rejects_large`).  Trusted: this file, read by eye, and the
Lean runtime's `IO` primitives it calls.  `docs/learn/MainExplained.lean` is a
commented toy with the same shape.

Exit codes: `0` success, no warnings; `2` success with warnings (by default
they are dropped; with `--warnings` they are in `<output>.warnings.txt`);
`1` failure, nothing written (bad arguments, unreadable input, an output path
that already exists, or a render error).  See README.md for the flags.
-/

open LeanSvg

/-- Create the file at `path` and write `bytes` to it.  `.writeNew` opens the
file exclusively (O_EXCL): if anything already exists at `path`, this fails
instead of overwriting it. -/
def writeNewFile (path : System.FilePath) (bytes : ByteArray) : IO Unit :=
  IO.FS.withFile path .writeNew (fun handle => IO.FS.Handle.write handle bytes)

/-- Exit codes: `0` PNG written, no warnings; `2` PNG written, with warnings;
`1` failure, nothing written. -/
def main (args : List String) : IO UInt32 := do
  -- `Cli.parse` is pure.  If it returns `none` (bad arguments), exit 1.
  let some config := Cli.parse args | return 1
  -- `config.input` is dot notation for `Cli.Config.input config`, the `input`
  -- field of `config`; likewise `config.output`, `config.warnings`, ...
  --
  -- `try … catch _ => return 1`: if any call below raises an `IO` error
  -- (unreadable input, an output file that appeared after the existence
  -- check), stop and exit 1.  Uncaught, the runtime would print it.
  try
    let inputBytes ← IO.FS.readBinFile config.input
    -- No clobber: the output path must not exist, and with `--warnings`
    -- neither may the warnings path.
    let outputExists ← System.FilePath.pathExists config.output
    if outputExists then return 1
    if config.warnings then
      let warningsFileExists ← System.FilePath.pathExists (Cli.warnPath config.output)
      if warningsFileExists then return 1
    -- `renderWithWarnings` is pure and returns an `Except`: `.ok` carries the
    -- PNG bytes and the warning list, `.error` carries a message, which is
    -- dropped.
    match renderWithWarnings config.options inputBytes with
    | .error _ => return 1
    | .ok (pngBytes, warnings) =>
      writeNewFile config.output pngBytes
      let warningsText := Warn.text warnings
      if warningsText.size == 0 then return 0
      -- Warnings are written to a file only with `--warnings`; either way
      -- the exit code is 2.
      if config.warnings then
        writeNewFile (Cli.warnPath config.output) warningsText
      return 2
  catch _ => return 1
