# OpenSCAD worker, evaluation trace and geometry

## Build the smallest integration that proves the design

Use a source-pinned headless OpenSCAD executable as a separate process. Build two variants from the same revision and dependencies: an untouched reference CLI for CI and a Scadretto worker carrying the trace patch. The worker is the geometry backend for the shipped app. The reference CLI is a development and verification tool. Upstream documents headless and no-OpenGL CMake options. Inspect the chosen revision's CMake settings before freezing flags and backend. [Upstream CMake](https://github.com/openscad/openscad/blob/master/CMakeLists.txt) · [Command-line usage](https://en.wikibooks.org/wiki/OpenSCAD_User_Manual/Using_OpenSCAD_in_a_command_line_environment)

In M0, look for the actual parser location record, expression evaluation, module and builtin argument binding, control-flow expansion, transformation nodes, dependency resolution and final geometry export in the pinned tree. Record source paths and symbols in `Docs/Decisions/engine-spike.md`. Add narrow observation hooks and a new worker entry point in the patched build. The protocol below is an API for Scadretto to implement. Stock `.ast`, `.csg` or STL export does not supply this contract.

### Spike pass conditions

- Evaluate in-memory main-file contents at a real logical path. A sibling include and nested relative asset resolve from the same locations as in the reference build.
- Evaluate the plate once and return one base plus four cutter occurrences with their four iteration values, the call site, the cylinder's source span, the numeric `d` value and the chain back to `hole_d`.
- Export a final mesh with the same bounds and volume as the reference. Select the cylindrical wall of the third hole and resolve it to the correct cutter. Capture the candidate list for a click exactly on a rim.
- If face ancestry does not survive the pinned boolean backend, implement the surface-hit comparison below and prove it on the fixture. If a trace hook cannot expose resolved argument bindings, instrument the binding step. Do not infer shared parameters from equal values or manufacture source IDs from mesh order.

## Version 1 transport

For v1, start one child per evaluation with `Process` and a private job directory. This gives cancellation by terminating the child, including while inside a long native boolean. Keep the wire contract transport-independent for later worker reuse. Use direct executable URLs and argv entries. Resolve paths from the app bundle. Drain stdout/stderr concurrently and bound diagnostic output. Protocol data is exchanged through files; stdout and stderr are logs.

Proposed invocation for the patched executable:

```text
scadretto-engine --scadretto-job /absolute/job/request.json
```

| Item | Required contents |
|---|---|
| `request.json` | `protocolVersion`, `requestID`, `EvaluationKey`, logical main URL, relative path to main UTF-8 snapshot, permitted library search roots, preview mode, selected geometry backend/options and expected worker build |
| `main.scad` | Exact unsaved source bytes for this job. Resolve paths and report diagnostics against the logical URL in the request. |
| `result.json` | Echoed protocol, request ID, key, build SHA, status (`ok`, `error`), file table with digests, diagnostics, observed dependencies, scene tables and payload descriptors |
| `mesh.bin` | Versioned final vertex and index buffers. Optional triangle-to-instance table has an explicit unknown value. |
| `operands.bin` | Pickable or highlightable operand meshes and transforms, with per-range descriptors. Identical local meshes may share storage across instances. |

The parent creates the job directory with private permissions. The child writes payloads first, closes them, writes a temporary manifest and atomically renames it to `result.json` last. On success exit 0, including for valid empty geometry. On a model error, write an error manifest then exit 1. Distinguish signal, timeout, protocol mismatch and internal exit separately. Parent accepts only a matching, fully validated result after child exit. A nonzero status with an `ok` manifest is a worker failure. A model error may still report dependencies and a diagnostic source span. Make protocol mismatch a visible development or packaging error.

The parent schedules at most one active job and one latest pending request per document, with an app-wide bounded queue. A newer request supersedes older work. Send termination, allow a short grace period, then force termination of that child if necessary; always reap it. Release job files after decoder/GPU users have relinquished any mapped data. On document close cancel queued and active work. Make the first version's timeout configurable for slow valid models, with a visible cancel control. Never reapply an old result after user cancellation.

## Snapshot and geometry conventions

For the first golden protocol pair, use a request for `cube(2);` and a successful response with one file, one executed cube and one mesh. Give the JSON keys fixed spellings in `Engine/protocol/`. Represent byte offsets as integers, digests as lowercase SHA-256 hex, file identifiers and instance identifiers as distinct integer domains, and versions as integers. Use paths relative to the private job directory for binary payloads. Reject absolute paths and paths resolving outside it when loading worker-produced payloads. The main model's logical URL and user library roots are deliberately separate inputs. A second golden response should report invalid source with no mesh. A third pair, for the mounting plate, covers the trace contract itself: parent links, the four iteration bindings, the cylinder's `PropertyRecord` and its binding chain to `hole_d`, the difference's operand roles, the four cutters' operand mesh references, which may share storage when the implementation caches identical local meshes, and the triangle-owner table when the backend supplies one. Decode all three from Swift and validate them against the worker's schema in CI. `verify-engine` also compares the worker's actual output for each request with its golden response semantically: it canonicalizes request-local IDs and record order, and still decodes and validates the fixed little-endian payload layouts.

For each dependency, hash the bytes the worker actually consumed. If a watched file changed while a job was running, reject the result and schedule the latest snapshot; install watchers and check the newly discovered dependency baselines before publishing the first result. Use a new job token for an explicit retry or cancellation even when the source key is unchanged, so a cancelled child cannot win against its replacement.

Use explicit versioned formats with fixed-width little-endian fields and IEEE floating-point values. Store source/evaluation metadata and affine transforms in double precision. Specify right-handed axes, Z up, 4×4 column-major matrices, column vectors, `world = parent × local × point`. Shared operand vertices are local; final mesh vertices are world coordinates. Convert to GPU floats relative to a scene origin if necessary. Normals use the inverse-transpose transform with appropriate treatment of reflections.

Mesh descriptors declare byte offsets, counts, stride, scalar types, triangle winding and bounding box. Initial layout can be packed `float32 xyz` positions, `uint32` triangle indices and optional `uint32` triangle owner IDs. Derive face normals from triangles for the first release. A missing owner table is distinct from a table assigning zero to all triangles. The decoder bounds-checks counts and multiplication, indices, offsets, file length, finite coordinates/transforms, and acyclic parent links before allocating or indexing. Protocol tests cover zero triangles, bad ranges, overflow and unknown fields. Unknown optional fields may be ignored; incompatible major versions fail cleanly.

## Trace contract

| Record | Required information |
|---|---|
| `FileRecord` | Logical path, canonical resolved URL if on disk, content digest, source/asset kind and writability in this document |
| `InstanceRecord` | Request-local ID, parent ID, operator or module name, call span and definition span when known, evaluation path with iteration bindings, local/world transform, local bounds, nearest editable authoring call, operand mesh reference when available |
| `PropertyRecord` | Display semantic such as diameter, evaluated numeric value and unit, originally supplied arguments, resolved formal, token/expression span, definition and binding chain when observed |
| `OperationRecord` | Ordered child IDs for union, difference and intersection. Store operand role relative to its parent; a single “negative” flag does not encode nested differences. |
| `DependencyEdge` | From a resolved declaration or call-site argument to a currently executed property/instance. Track consumers conservatively; unknown impact must be displayed as unknown. |
| `Diagnostic` | Severity, message, file and optional byte span, optional call path, evaluation key |

Collect provenance per occurrence, even when geometry evaluation uses a cached local mesh. Each loop iteration gets its own path and transform. Two equal cylinders can share vertex buffers, but each keeps a distinct runtime ID and parameter environment. Preserve include/use boundaries and original files for definition navigation. Treat imported assets or unsupported operators as opaque nodes with bounds and limited metadata.

Keep a scoped binding stack while evaluating module calls, loops, `let` and assignments. Capture the evaluated argument → formal parameter → resolved declaration chain for supported scalar slots. Mark opaque arithmetic as an expression boundary unless a specific edit rule handles it. Track control dependencies when provable or mark the impact set partial. Keep the stock evaluator in charge of scoping, defaults, special variables and evaluation order. Never re-run random or time-dependent expressions merely to collect trace information.

## Picking a boolean result

1. Raycast the final visible surface, using a CPU BVH for v1. Return a world hit, triangle and normal. If the backend has a proven unique primitive ancestry for the triangle, use it and follow the instance chain to candidate authoring scopes.
2. Otherwise intersect candidate operand meshes around the *same world hit*, narrowing by transformed bounds, surface distance and normal alignment. Account for inverted cutter normals, nonuniform transforms and reflected winding. Document a scene-scaled distance tolerance with a floor and a cap; test small solids and close parallel walls. Matching the front face of a cutter somewhere else on the ray is insufficient.
3. Offer multiple candidates for coincident surfaces, rims and ambiguous operation paths. If no reliable owner exists, keep the result selected and offer the outline or operand-isolation mode. The outline selects an exact executed instance independently of triangle ancestry.
4. Selecting a cutter reveals a translucent operand and the subtracting operation. Selecting a shared declaration highlights all proven dependent occurrences. Render helpers, ghosts and gizmos in a separate pass so they cannot corrupt final-surface picks.

### Performance fallback

Cache local primitive buffers per scene, build BVHs off the main thread, instance repeated operands and load detailed overlay meshes on demand for expensive subtrees. Return explicit availability if budgets are exceeded. A large model can still render when fine picking for a branch must use the outline. An opaque preview is acceptable for unsupported constructions; the plate's through-hole wall must be pickable in the normal shaded view for release.
