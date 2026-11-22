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
set is a lower bound and the editor must say so. The built-in scope's
literals, such as `$fn = 0`, have no source bytes. They are never an
origin, and their impact set is never complete.

A complete set also needs a literal in the main snapshot and no read that
feeds a range. A range decides how many occurrences run, which no property
records.

A drag is verified only for a complete set in a known frame. No other
recorded property on the same ancestor and descendant path may consume
the edited literal. Without that rule a pitch preview was wrong whenever
a child translation, rotation or size also read pitch. Hull, Minkowski,
resize, extrusion and other operations without a traced placement make
descendant frames opaque. These rules can refuse a safe drag. Numeric
entry remains available for the verified literal.

## Bounds

Releasing a provenance chain recurses once per link. Chains stop at 4,096
links and emitted property chains at 256. The older `diameter` chain is
emitted in full up to the first bound. A recursive forwarding probe kept its
diameter literal at depth 83 and became read-only at depth 84.
Computed results share one node per set of possible literals, so long
lists retain no per-element history. A union of more than 32 literals
marks those literals partial.

Executions of a call site share their property definitions and argument
lists in result-level tables. If the records still exceed the 16 MiB
manifest limit, the worker omits them, sets `propertiesOmitted`, and
publishes the scene as inspect-only. The plate loop kept property detail
at 5,000 holes and lost it at 6,500.

The scene trace keeps its traversal on the heap. When it recursed once
per node, this patch crashed at 2,850 nested modules, which main still
rendered. Both crashed at 2,900, and the unmodified reference rendered
them. The worker and reference now both render that fixture at 6,000
levels and both stop at 8,000 on OpenSCAD's recursion guard. The two
builds reach that guard at slightly different depths. With a `union` at
each level the worker still rendered 4,000 levels, where the reference
reported recursion.

One very long expression can still overflow OpenSCAD's recursive
evaluator, which that guard does not cover. A chain of additions crashed
this worker at 47,500 terms and main's at 47,600. The reference rendered
64,000 and crashed at 80,000. A crash ends only that worker job.

## Worker verification

```sh
Scripts/build-engine
Scripts/verify-engine
```

The Apple M4 Max development machine ran macOS 27.0.1 (26A434) with Xcode
27.2 (27B52), SDK 27.2 and CMake 4.4.5. The OpenSCAD and Manifold revisions
remain the ones recorded in [the engine spike](engine-spike.md).
The worker SHA-256 was
`60a9b08a19a8c3326286d84c6f3f525adf63fc4d369fbfa4f771928bd7f4332e`.
Raw records are machine-local build output in `.build/engine/verification.UHSiPQXg/v1/`.

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
renders all three. The impact case first failed on that revision for its
missing `impactComplete` field. A separate probe showed its unsafe
`dragVerified` result. The 256 MiB memory bound fails on three retained
earlier builds of the patch, which peaked at 285 to 331 MiB.
A later run through the Swift decoder found `null` inputs for built-in
defaults, which both goldens avoided by setting `$fn`. The verifier now
rejects a spanless input in every job, and failed on that worker first.
The nested-module case renders 4,000 levels and failed with signal 11 on
the recursive traversal first.

A mutation check then found that a literal used as a range limit claimed
a complete set, and an independent review found that a library's literal
and pitch at iteration zero were marked draggable. Each has a verifier
case that failed first. The corrected worker had no violation in 11,119
mutations over generated consumer pairs, the fixtures and review probes.
Each mutation replaced a writable literal and compared the reevaluation
with the claimed value, complete set and verified occurrence drag.

## Cost against the worker without property records

A differential run on 14 programs compared worker `3dde4034`, the build
before the traversal fix, with the one on main at `3f27e0f`. `mesh.bin`
and `operands.bin` were byte-identical in each case. Both workers
accepted 7,500 holes and rejected 8,500. The traversal fix left results
and payloads identical on 20 programs in both protocols. Build identity
and timings were excluded from that comparison.

| Program | Peak memory | Manifest |
| --- | --- | --- |
| 500,000 computed elements | 54.3 to 54.5 MiB | 1.95 to 2.61 KB |
| 3,000 holes | 878 to 898 MiB | 6.36 to 7.83 MB |
| 3,000 distinct statements | 105.0 to 173.4 MiB | 1.70 to 7.94 MB |
| 150 recursive modules | 34.6 to 45.6 MiB | 149 KB to 1.02 MB |

KB and MB are decimal. The machine was running other work, so these runs
support no timing claim. The records are in
`.build/m4/resume-probe/compare-payloads-fixed.log` and `memory-red.log`
beside it.
