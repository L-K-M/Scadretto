# Worker protocol v1

Launch the pinned worker with `--scadretto-job /absolute/job/request.json`.
The parent keeps the job directory private and writes the exact source bytes
to `main.scad`. Standard input is the parent's lifetime pipe. The child
writes and closes binary payloads, then atomically publishes `result.json`.
Standard output and standard error contain process logs.

## Request

| Field | Value |
| --- | --- |
| `protocolVersion` | Integer 1 |
| `requestID` | UUID for this evaluation attempt |
| `key` | Object with `documentID` UUID, `sourceRevision` and `dependencyGeneration` unsigned integers, and `resolutionDigest`, `optionsDigest` and `workerBuild` SHA-256 digests |
| `logicalPath` | Absolute logical main-file path |
| `untitledBaseDirectory` | Optional absolute base directory for an untitled document |
| `snapshot` | The relative filename `main.scad` |
| `sourceSHA256` | Digest of the exact snapshot, including any BOM |
| `libraryRoots`, `resourceRoots` | Ordered arrays of absolute paths |
| `preview` | Boolean `false` for final evaluation |
| `backend` | String `manifold` |
| `expectedWorkerBuild` | Digest of the executable's file bytes |

All digests are lowercase hexadecimal SHA-256. The worker checks the
expected executable digest and the two context digests before evaluation.
A context field contributes its decimal UTF-8 byte length, an ASCII colon,
then its exact UTF-8 bytes. Concatenate these fields in the given order
and hash the result.

- Resolution fields are `resolution-v1`, logical path, untitled base
  directory or the empty string, library root count in decimal, each
  library root, resource root count in decimal, and each resource root.
- Option fields are `options-v1`, backend, and `false` or `true`.

## Result

The result echoes `protocolVersion`, `requestID` and the complete `key`,
and reports the actual executable digest as `buildSHA`. Exit 0 requires
`status: "ok"` and a `detail` of `rendered` or `empty`. Exit 1 with
`status: "error"` and a `detail` of `modelError` or
`unsupportedDimension` carries a model diagnostic. Other details are
`protocolMismatch`, `buildMismatch` and `internalError`. A process
failure cannot publish a scene.

| Result field | Layout |
| --- | --- |
| `files` | File records with `id`, `logicalPath`, optional `resolvedPath`, `sha256`, `byteLength`, `kind`, and `writable`. Kinds are `main`, `include`, `use`, `import`, `surface`, `dxf`, and `font`. |
| `diagnostics` | Records with `severity` (`error`, `warning`, `deprecated`, `unknown`), `message`, optional `fileID`, optional `span`, optional `callPath` of instance IDs, and optional `repeatCount` of suppressed repetitions, defaulting to zero. |
| `console` | Ordered records with upstream `group`, formatted `text`, optional `fileID`, optional `span`, and optional `callPath`. |
| `droppedConsoleMessages` | Count of messages excluded by the capture limit. |
| `mesh` | Final mesh descriptor or null. |
| `operands` | Array of operand records containing `id` and `mesh` descriptor. |
| `instances` | Executed occurrences containing `id`, optional `parent`, `name`, optional `span` and `definitionSpan`, `iteration` map (numeric values), column-major affine matrices `local` and `world`, optional operand ID `operand`, and optional `diameter`, `arguments`, `properties` and `opaqueFrame`. |
| `operations` | Records containing `instanceID` and ordered `children` with `instanceID` and `role` (`positive`, `subtracted`, `intersection`). |
| `dependencyEdges` | Records with a source `span`, an `instanceID` and a `property` string. They cover the `diameter` chains. |
| `propertyDefinitions` | Optional table of the property fields that executions of a call site share. An index identifies an entry within one result. |
| `argumentLists` | Optional table of argument arrays. An instance refers to one array by index. |
| `propertiesOmitted` | Optional `true` when property detail did not fit the manifest. The scene is then inspect-only. |
| `lookups` | Records with optional `requestingFileID`, lookup `name`, ordered absolute `candidates`, optional selected `winner` candidate, and optional `resolvedWinner` giving its canonical path at evaluation time. |

Spans are `{fileID, start, end}` in the original file bytes, including BOM.
IDs are unsigned 32-bit integers, separate for files, instances and
operands. The all-ones value is reserved for unknown triangle ownership.
Only the main snapshot is writable in this editor session. Dependency paths
are available for diagnostics and navigation. A dependency edge represents one
binding step, so separate steps can point to the same source range. The
worker reports `modelError` if it cannot retain a complete dependency search.

An instance's optional `arguments` is an index into `argumentLists`. Each
argument records `name`, `formal`, `status` and an `expression` span. A
positional argument has an empty `name`. An unbound argument has an empty
`formal`. Status is `bound`, `superseded`, `unbound` or `ignored`. These
records follow source argument order. Built-in defaults are represented by
the applicable property status. Spans are the engine's source locations.
A vector literal's location covers its first element only, and a
`definitionSpan` is the point where the module is defined.

Each entry of an instance's optional `properties` carries a `definition`
index, a finite `value`, an optional `dragVerified` flag and, for pitch,
`pitch: {iteration}`. The indexed definition carries:

- `semantic`, `formal`, `status`, `displayMultiplier` and `centered`.
- An optional `expression` span and an ordered `chain` from the supplied
  value toward its observed origin. A chain holds at most 256 links.
- `inputs`, the literal spans that can supply the value through observed
  operations. An instance is affected by a literal if any of its
  properties lists that literal. Every entry is a span. A built-in default
  such as `$fn = 0` has no source bytes and is never listed.
- `impactComplete`, true only for a property with a writable literal whose
  evaluated reads all lead to recorded properties. A writable literal is
  a numeric literal in the main snapshot that the value reaches through
  names, arguments and elements alone. A range decides how many occurrences
  run, so a read that feeds one leads to no recorded property. When false,
  other uses of the literal are unknown and the affected set is a lower
  bound.

The displayed scalar equals the authored scalar times the multiplier.
Statuses are `bound`, `default`, `computedVector` or `invalid`. A bound
value can still be an inspectable expression. `diameter` retains its
original `value` and `chain` fields, without the 256-link emission limit.
Each chain link carries a `kind`,
`name` and optional `span`. A branching arithmetic step ends a chain. A
`computed` link stands for a call, index, member or comprehension result.
A `truncated` link marks the depth limit. Both end write-back.

Semantics cover uniform and axis-specific cube sizes, sphere diameter,
cylinder height, uniform diameter and separate end radii, fragment count,
translation vector components, module arguments and pitch. Pitch is
recorded when evaluated in a range loop, and its `formal` is the name of
the pitch variable. Module arguments and fragment counts are never
`dragVerified`, because they have no spatial meaning.

`dragVerified` means a drag preview of that property on that occurrence
matches reevaluation. Other affected occurrences can consume the literal
in other ways, so the flag does not describe their motion.
It requires a complete impact set, a known frame, and no other recorded
property on the same ancestor and descendant path that consumes the
literal. A frame is known when only transforms, groups, CSG operations,
color and render enclose it, so its `world` matrix gives the placement.
Pitch also requires that its base, range and other components stay fixed.
Iteration zero is never verified and offers numeric entry only, because a
displacement cannot determine pitch there. An instance with `opaqueFrame`
lies below an operation whose placement the trace cannot represent, so it
offers no spatial handle.

## Binary mesh payloads

`mesh.bin` and `operands.bin` each start with the eight-byte ASCII magic
`SCADMESH`, little-endian UInt32 version 1, and little-endian UInt32 0.
All offsets are relative to the start of the file. An empty scene uses
a null final descriptor.

A descriptor contains `path` (`mesh.bin` or `operands.bin`),
`vertexOffset`, `vertexCount`, `vertexStride` (24),
`positionType` (`float64`), `indexOffset`, `indexCount`,
`indexStride` (4), `indexType` (`uint32`), `winding` (`ccw`),
`bounds` (an object with three-element `min` and `max` arrays), and
an optional `ownerOffset`. Counts and offsets are numbers of records
and bytes respectively. The vertex records are packed little-endian
IEEE Float64 triples. Each sequence of three UInt32 indices describes
one triangle. When present, the owner table stores one UInt32 per triangle.

Final vertices are in world coordinates. Operand vertices are local
coordinates and can be shared by distinct occurrences. Transforms are
right-handed, Z up, with column vectors and `world = parent × local`.
