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
| `instances` | Executed occurrences containing `id`, optional `parent`, `name`, optional `span` and `definitionSpan`, `iteration` map (numeric values), column-major affine matrices `local` and `world`, optional operand ID `operand`, and optional `diameter`, `arguments` and `properties`. |
| `operations` | Records containing `instanceID` and ordered `children` with `instanceID` and `role` (`positive`, `subtracted`, `intersection`). |
| `dependencyEdges` | Records with a source `span`, an `instanceID` and a `property` string. |
| `lookups` | Records with optional `requestingFileID`, lookup `name`, ordered absolute `candidates`, optional selected `winner` candidate, and optional `resolvedWinner` giving its canonical path at evaluation time. |

Spans are `{fileID, start, end}` in the original file bytes, including BOM.
IDs are unsigned 32-bit integers, separate for files, instances and
operands. The all-ones value is reserved for unknown triangle ownership.
Only the main snapshot is writable in this editor session. Dependency paths
are available for diagnostics and navigation. A dependency edge represents one
binding step, so separate steps can point to the same source range. The
worker reports `modelError` if it cannot retain a complete dependency search.

The optional `arguments` array records `name`, `formal`, `status` and
`expression` span for supplied arguments. A positional argument has an empty
`name`. An unbound argument has an empty `formal`. Status is `bound`,
`superseded`, `unbound` or `ignored`. These records follow source argument
order. Built-in defaults are represented by the applicable property status.

Each optional `properties` entry carries `semantic`, `formal`, `status`,
finite `value`, `displayMultiplier`, `centered`, an optional `expression`
span and an ordered `chain` from the supplied value to its observed origin.
The displayed scalar equals the authored scalar times the multiplier.
Statuses are `bound`, `default`, `computedVector` or `invalid`. A bound
value can still be an inspectable expression. A branching arithmetic step
ends the chain, and its observed dependencies appear in `dependencyEdges`.
`diameter` retains its original `value` and `chain` fields. Each chain link
carries a `kind`, `name` and optional `span`.

Semantics cover uniform and axis-specific cube sizes, sphere diameter,
cylinder height, uniform diameter and separate end radii, fragment count,
translation vector components, module arguments and pitch. Pitch includes
`pitch: {iteration, dragVerified}` when evaluated in a range loop. The flag
describes dependency and frame independence. Iteration zero offers numeric
entry because spatial displacement cannot determine pitch there.

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
