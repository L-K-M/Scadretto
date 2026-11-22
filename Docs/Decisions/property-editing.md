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

## Native verification

The Apple M4 Max development machine ran macOS 27.0.1 (26A434) with Xcode
27.2 (27B52) and SDK 27.2, on a 1920 × 1080 display at backing scale 1.
The app bundled worker SHA-256
`60a9b08a19a8c3326286d84c6f3f525adf63fc4d369fbfa4f771928bd7f4332e`.

```sh
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath "$PWD/.build/m4/DerivedData" \
  -resultBundlePath "$PWD/.build/m4/ui-suite-06.xcresult" \
  CODE_SIGN_IDENTITY='Apple Development' test
Scripts/verify-engine --saved-plate .build/m4/ui-suite-06-attachments/saved-plate.scad
```

The run split that `test` action into `build-for-testing` and
`test-without-building`. All 10 UI tests passed in 397 seconds. They drive
the real app through the Open panel, mouse picks and drags, the inspector,
menus, save and reopen.

Walkthrough steps 1 to 5 saved a plate that differs from the fixture only
in `hole_d = 5;` and `count = 5;`. The unmodified reference rendered it
with five bores and a symmetric difference of 0.000245 from the worker.
Steps 6 and 7 dragged pitch to 22, cancelled a drag with Escape while the
button was held, recovered from a syntax error and typed pitch at
iteration zero. The saved file differs only in `pitch = 22;`. Its cutters
are at 15, 37, 59 and 81, and it differs from the reference by 0.000177.

Earlier runs failed, and their recordings gave these causes:

- A failed test left its windows and fixture folders to the next one.
  Tests now launch without restored windows and clean up on failure.
- Other applications on the shared test Mac took the focus or put a dialog
  over Scadretto. The suite needs an uncontested screen.
- One Undo menu click had no effect and no cause was found. Six repeats
  of that test and the final suite passed.

Not exercised natively: selecting an enclosed shape through the outline,
a drag guide of another occurrence, a comma-decimal system locale, a
Retina display and macOS 14.
