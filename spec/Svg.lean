/-
# `use` nesting stays within the layer depth (`LeanSvg.Svg`)

`Use.expand` stops at `Use.maxDepth` nested `use` references, and compositing
layers stop at `Svg.maxLayerDepth`; the first must not exceed the second.

Check with `lake env lean spec/Svg.lean`.
-/
import LeanSvg.Svg

namespace LeanSvg
namespace Svg

/-- `Use.expand` must not let `use` nest deeper than compositing layers may. -/
theorem use_maxDepth_le : Use.maxDepth ≤ maxLayerDepth := by decide

end Svg
end LeanSvg
