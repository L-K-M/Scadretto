# Executed property bindings

The pinned evaluator records the arguments it actually consumes. Positional
slots follow the upstream parameter loop. Later explicit arguments mark
superseded slots, and geometry built-ins mark radius aliases they ignored.
The worker keeps each real occurrence and its source provenance even when
it shares an operand mesh with other instances.

Cube vector dimensions, sphere and cylinder size aliases, height, separate
cylinder ends, translation components, explicit module arguments and
`$fn` are carried in the optional v1 property records. The stock evaluator
still chooses the geometry and interpretation of defaults. Numeric vector
edits require a directly supplied vector. A computed vector or missing
component carries an inspect-only status. Definition-site defaults preserve
their actual file and their lookup chain.

The range-loop pitch rule recognizes an executed `base + i * pitch` in
the X component of a directly supplied translation. Other axes and
algebraic forms keep numeric entry. A spatial pitch handle needs one
observed loop under operation groups, an independent base, range and
other components, and the general drag rule below.

## Impact and drag eligibility

Each observed value carries the literals that can supply it. The worker
records every evaluated variable read. A literal's impact set is complete
only when each read carrying it leads to a recorded property. Reads below
a call, index, member or comprehension result stay unexplained. So do
special variables, which built-ins read without a lookup. An incomplete
set is a lower bound and the editor must say so.

A drag is verified only for a complete set in a known frame. No other
recorded property on the same ancestor and descendant path may consume
the edited literal. Without that rule a pitch preview was wrong whenever
a child translation, rotation or size also read pitch. Hull, Minkowski,
resize, extrusion and other operations without a traced placement make
descendant frames opaque. These rules can refuse a safe drag. Numeric
entry remains available for the verified literal.

## Bounds

Releasing a provenance chain recurses once per link. Chains stop at 4,096
links and emitted chains at 256. Computed results share one node per set
of possible literals, so long lists retain no per-element history. A
union of more than 32 literals marks those literals partial.

Executions of a call site share their property definitions and argument
lists in result-level tables. If the records still exceed the 16 MiB
manifest limit, the worker omits them, sets `propertiesOmitted`, and
publishes the scene as inspect-only.

## Worker verification

```sh
Scripts/build-engine
Scripts/verify-engine
```

The Apple M4 Max development machine ran macOS 27.0.1 (26A434) with Xcode
27.2 (27B52), SDK 27.2 and CMake 4.4.5. The OpenSCAD and Manifold revisions
remain the ones recorded in [the engine spike](engine-spike.md).
The worker SHA-256 was
`aaff99c8635af3f295ff67c877f2a2a03715483e002b44649cf3d984d7c5a175`.
Raw records are in `.build/engine/verification.ONsmfhk8/v1/`.

The v1 verifier exercised real positional and named slots, an ignored
radius, a superseded height, an unbound ninth argument, two-component
and invalid translations, lexical module shadowing, definition-site
library defaults and dynamic `$fn`. It compared the fixture solids with
the unmodified reference. The baseline third translation exposed a
pitch of 20 at iteration 2, with its literal at bytes `[96,98)`. Dependent
base offsets, range limits, another axis and an unproven parent
transformation each withheld spatial pitch editing while retaining the
literal trace.

The verifier also covers partial impact sets, dependent child frames, a
3,000-hole loop, 200,000 linked evaluations and a 500,000-element computed
list. The first revision of this patch exceeded the manifest limit on
that loop and crashed on the linked evaluations. The current worker
renders all three. The list peaked at 53 MB, against 54 MB for the worker
without property records. Geometry payloads for the plate, the stress fixture and the loop
variants up to 7,500 holes were byte-identical to that worker's.
