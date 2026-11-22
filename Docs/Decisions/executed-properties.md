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

The range-loop pitch rule observes the executed `base + i * pitch`
operands and the right-hand declaration. Only known arithmetic and
checked lookup links can prove that the base, range and other components
are independent of the written declaration. A spatial pitch handle
requires one observed loop under operation groups and a known frame.
Other paths can still provide numeric entry when the literal is verified.
Opaque arithmetic ends the write-back chain. Observed dependencies on
either side inform current-evaluation impact.

## Worker verification

```sh
SCADRETTO_ENGINE_JOBS=10 Scripts/build-engine
Scripts/verify-engine
```

The Apple M4 Max development machine ran macOS 27.0.1 (26A434) with Xcode
27.2 (27B52), SDK 27.2 and CMake 4.4.5. The OpenSCAD and Manifold revisions
remain the ones recorded in [the engine spike](engine-spike.md).
The worker SHA-256 was
`ac28b2ffa477d6b2dea71a4d995908f167c1356052b19110677a5f2edeb108c4`.
Raw records are in `.build/engine/verification.Gy0GeB4R/v1/`.

The v1 verifier exercised real positional and named slots, an ignored
radius, a superseded height, an unbound ninth argument, two-component
and invalid translations, lexical module shadowing, definition-site
library defaults and dynamic `$fn`. It compared the fixture solids with
the unmodified reference. The baseline third translation exposed a
pitch of 20 at iteration 2, with its literal at bytes `[96,98)`. Dependent
base offsets, range limits, another axis and an unproven parent
transformation each withheld spatial pitch editing while retaining the
literal trace.
