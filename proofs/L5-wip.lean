/-
Historical note: the pre-T46 proof attempt expanded nested range loops and
failed to finish elaborating. It was an unverified candidate, not a checked
proof; its source remains in git history at 96d355c.

Superseded by proofs/SizeBound.lean. The encoder now uses two structurally
recursive helpers. Their size proofs count copied row bytes once, rather
than charging 65535 bytes for every fragment. The complete encoder and
renderer bounds check at the default heartbeat limit, without proof holes.

Public square bound: 5 * max(w, h)^2 + 132 bytes.
Pure render's global cap under the current limits: 67,452,996 bytes.
Filesystem behavior is outside these statements.
-/
