# Planner support table (M4)

`ScadrettoPlanning` turns an executed binding and a selection into a checked
plan or a read-only reason. `ScadrettoCore` writes the patch. A target needs a
document-scoped span with the snapshot's digest, a token or expression node in
the current syntax tree, and the worker's binding chain. Anything else stays
inspect-only. `ScadrettoPlanningTests` covers the rows below, most of them
against the real worker.

| Selected target | Planner entry | Drag handle | Written change |
|---|---|---|---|
| Cube size, sphere `r`/`d`, cylinder `h`/`r`/`d`/`r1`/`r2`/`d1`/`d2` with a literal origin | `ScalarLiteral`, positive | Only when the worker sets `dragVerified` | Replace the token |
| Radius shown as a diameter | `ScalarLiteral`, multiplier 2 | As above | Replace with the converted token |
| Explicit module argument, including an enclosing call's | `ScalarLiteral`, finite | None | Replace the token |
| `$fn` with a literal origin | `ScalarLiteral`, finite | None | Replace the token |
| `translate` vector element that is a literal | `ScalarLiteral`, finite | When `dragVerified` | Replace the token |
| Pitch in `base + i * pitch` on X | `ScalarLiteral`, finite | When `dragVerified` and `i` is nonzero | Replace the token |
| `translate` element that is any other expression | `ExplicitSourceEdit.Offset` | Known frame, applied once on each path | `(expr) + c` or `(expr) - c`, never folded |
| Standalone, unrepeated call | `ExplicitSourceEdit.Prefix` | Known frame | `translate([x, y, z]) ` after `!` or `#` modifiers |

Inspect-only in v1:

- `rotate` and `scale`, computed vectors, and indexed, member or function results.
- Defaults, including the built-in `$fn`, and literals authored in a dependency.
- A move on a `%` or `*` statement, on one occurrence of a repeated statement,
  or where a module named `translate` replaces the built-in. A dependency's
  redefinition is detected only after that module has executed.
- Every property of a scene whose detail the worker omitted for size.

Local offsets are limited to translation elements.
An impact set that the worker cannot prove complete is shown as a lower bound.
