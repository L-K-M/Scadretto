# Property edits, local moves and scope

The editor plans every inspector and drag edit in `ScadrettoPlanning`, a
package target above `ScadrettoCore`, `ScadrettoSyntax` and
`ScadrettoEngineClient`. The plan asks for pure planning code that tests can
drive without a window. Core cannot hold it because the bindings come from
the engine client, which depends on Core. Core still writes every patch.
The app supplies the selection, shows the plan and commits its transaction.

The [support table](../../Packages/ScadrettoKit/Tests/ScadrettoCoreTests/SupportTable.md)
lists the targets. The [worker record](executed-properties.md) defines what
makes a binding complete and a drag safe.

## Rules

- One property path serves every edit, including the M3 diameter. A round
  feature opens on its diameter.
- A pick also offers explicit arguments of the enclosing calls, unless the
  same literal is already offered under the feature's own name.
- A translation component that is not itself a literal offers "Offset here".
  Its bytes are wrapped verbatim. The declaration keeps its bytes.
- A standalone, unrepeated statement without its own translation offers
  "Move here". The move is withheld where a module named `translate`
  replaces the built-in.
- A field takes the locale's decimal separator or a point. Grouped input
  such as `1.234,5` is refused rather than guessed. The source always
  receives a point.
- A handle appears only without a drag blocker: iteration zero, an unproved
  impact or dependent frame, an untraced placement, or one expression
  applied twice on a path. Numeric entry stays, with the reason.
- A drag guide follows only another occurrence that the worker verified for
  the same literal, along that occurrence's own axis and scale. Other
  affected uses, such as `-d` or `2 * d`, are highlighted without a guide.
- Scope counts rendered operands. A set the worker cannot prove complete
  reads "at least N, other uses unknown".
- A selection follows its call path through edits. A wrapper written since
  the last evaluation is a new ancestor of the same selection, and a removed
  wrapper leaves it selected. A removed selection falls back to its nearest
  authored ancestor or clears. It never matches an equal sibling.
- When the chosen property disappears, the inspector waits for an explicit
  choice. An inserted move continues as the translation it created.

## Limits

- Local offsets cover translation components. Pitch covers
  `base + i * pitch` on X.
- A `translate` redefined in a dependency is detected only after that module
  has executed.
- A scene whose property detail the worker omitted for size is inspect-only.
- The ghost holds 600,000 indices and the moving outlines 256 occurrences.
  The inspector reports anything beyond either bound.

## Verification

```sh
Scripts/build-engine
swift test --package-path Packages/ScadrettoKit
```

`ScadrettoPlanningTests` takes cases from the Scope, Overwritten assignments,
Module scopes, Expressions, Primitive properties, Transforms, Prefix
insertion and Procedural picking rows through the pinned worker. The table
cases evaluate, plan, apply the document transaction, compare the whole
file, reevaluate and undo. The named cases check impact, dependency
ownership, resulting geometry, frames and picks. These tests skip, and say
so, without a built worker. CI restores the checked worker before it runs
them.

Four parts of those rows are checked below the worker. A singular parent's
zero axis is refused by the viewport handle's unit test, and the live case
checks that the worker reports that axis. Ambiguous comments are refused in
the Core edit tests. Decimal-comma entry is tested on the parser that the
field calls, with explicit locales. The live picking cases call the
production picker without a window.

Tests with real worker results and a review of its traces exposed three
defects that hand-written traces and the goldens had hidden. Offsets were
never offered for a formula such as `wall/2`, built-in defaults produced
invalid manifests, and an inserted move lost its selection. Each regression
failed before its fix. A later mutation check of the worker showed that
guides chosen by property name or equal value could point the wrong way.
Their tests compare each guide with reevaluation, and failed first.
