# Architecture and ownership

## Repository and build targets

Start with one Xcode project and a local Swift package. Keep `ScadrettoCore` usable by `swift test` without launching a window. Keep upstream-dependent C++ out of the Swift module graph. Give the application scheme and test plan the same names used in [the verification guide](06-Verification-and-Release.md).

```text
Scadretto.xcodeproj/               shared scheme Scadretto
App/                               NSDocument, window, commands and bundle configuration
Packages/ScadrettoKit/
  Package.swift
  Sources/ScadrettoCore/           source store, ranges, snapshots, bindings, edit planning
  Sources/ScadrettoSyntax/         Tree-sitter C bridge, syntax queries, byte coordinate index
  Sources/ScadrettoEngineClient/   request scheduling, result decoder, helper process
  Sources/ScadrettoViewport/       Metal renderer, camera, hit testing and handle geometry
  Tests/                           unit, contract and integration tests
Engine/
  upstream.lock                    upstream commit, dependency revisions, build flags
  patches/                         ordered, replayable changes against that commit
  protocol/                        manifest specification, examples and binary layouts
Tests/Fixtures/                    handwritten SCAD, includes, assets and golden edits
Tests/UITests/                     document-window and interaction tests
Scripts/                           bootstrap, verification, packaging
Docs/Decisions/                    engine spike, coordinates, packaging and benchmark record
```

Start with a checked-in `.xcodeproj`, a shared `Scadretto` scheme, Swift Package Manager lockfiles and one pinned engine dependency manifest. Build scripts resolve their own repository root and support spaces in paths. Keep fetched upstream sources and generated binaries in an ignored build directory. Check in the revision, patch series and instructions required to reproduce them.

## Data ownership

| Type | Owner | Contents and lifetime |
|---|---|---|
| `SourceDocument` | One `NSDocument` per open model | Canonical source bytes, acknowledged disk baseline, original encoding metadata, current revision and one undo manager |
| `SyntaxSnapshot` | Editor parser | Incremental concrete syntax tree and line index for a single source revision. Supplies syntax ranges and errors while typing. |
| `EvaluationKey` | Document controller | Document UUID, monotonically increasing source revision, dependency generation, evaluation options digest and build identity. A new document UUID is issued even for another window opening a separate copy. |
| `SceneSnapshot` | Engine client | Immutable result for one key. Mesh, bounds, executed instances, source map, editable binding candidates, file digests, diagnostics and dependencies travel together. |
| `Selection` | Per document window | Snapshot-scoped instance and source anchor. Camera and selection survive only when their targets can be re-established. |
| `EditIntent` | Inspector or viewport | Requested operation, explicitly selected target and scope, units, original value, and the key at gesture start |
| `SourcePatch` | Pure edit planner | Expected document key and source slices, replacements and an undo label. Applied only on the document's serial mutation path. |

Save serializes the current source buffer. The outline and inspector always read the current accepted scene. Presentation state such as camera and panel visibility can live in window restoration or preferences. It must be possible to discard every cache and reconstruct a model by opening the source again.

## End-to-end event flow

1. An AppKit text edit, a numeric inspector entry, undo, redo or an accepted viewport gesture enters the same document transaction API. Accepting a transaction increments revision even when undo returns to bytes seen before. An unchanged transaction produces no undo item.
2. Update text storage and the byte/UTF-16 index in one mutation. Refresh highlighting asynchronously. Schedule a worker request after about 150 ms of idle typing. Enter in an inspector or releasing a handle evaluates immediately.
3. Capture immutable UTF-8 bytes and the current dependency generation. The worker returns the same key plus digests of all files read. A filesystem notification changes the generation even when the main source has identical bytes.
4. Accept results on the main actor only if the complete key matches, source digests still agree and the document is open. Swap all scene-derived state in one operation. Keep the previous good mesh on parse/evaluation failure. Empty valid geometry is a successful result with no mesh.

   Reuse accepted scenes by content. Undo, redo and Revert usually return to bytes that were already evaluated, yet each transaction advances the revision and would otherwise wait for a new job. Keep a small per-document cache of accepted `SceneSnapshot`s keyed by source digest, every dependency digest, resolution context, evaluation options and build identity. When a transaction produces bytes whose source digest matches a cached scene, and the document's current dependency baselines, resolution context, options and build match that entry, install the scene immediately. This is the one exception to the complete-key rule above: re-key the snapshot and its bindings to the new revision on the main actor. Its spans stay valid because the bytes are identical. Otherwise evaluate normally. Bound the cache by total mesh memory, evict the least recently used scene, and never share it between documents.
5. While dragging, calculate a tentative value and draw a local overlay. Commit a single patch on release. Escape, a concurrent source change, an incoming file conflict or a lost selection cancels the tentative edit. A cancelled gesture leaves no bytes or undo entry behind.

Keep disk I/O, parsing large files, tessellation, worker waits and mesh decoding off the main actor. Mutate document state, AppKit views and undo registrations on the main actor. Upload buffers ahead of presentation and release old GPU buffers only after their in-flight command buffers finish.

## Stable meaning across evaluations

A source range identifies a span in one version of one file. An execution path identifies an *occurrence* during that evaluation. They serve different purposes. A `for` loop can produce four cylinders from one span, and the same imported module can be called at many sites.

For each instance, record the shape operator, authoring file, call path, loop iteration and local-to-world transform. Reconcile selection after a rebuild by tracking the original source anchor through known edits and matching the call path, operation and iteration bindings. If there are zero or multiple matches, clear the selection or select the nearest uniquely matched parent in the outline. Worker IDs, triangle indices and line numbers are unsuitable as persistent document IDs.

## File resolution and the reference evaluator

Give new documents a private temporary workspace. For saved files use the logical main file URL for includes, diagnostics and relative imports. Pass the unsaved bytes as an overlay at that URL. Resolve nested dependencies relative to their authoring file and record the engine's actual resolution order. Apply user-selected library roots and bundled resources consistently to the worker and reference CLI. An untitled document with an unresolved relative import should offer Save As or selection of a base directory. Save As changes resolution roots and invalidates the scene.

The engine owns OpenSCAD evaluation, boolean operations, and expression values. The editor owns preservation of source formatting and explicit rewrite policy. Introduce a revision-pinned trace bridge between them. A plain exported mesh does not include the authoring decisions needed by the inspector. The OpenSCAD bidirectional editing research provides a worked example of tracing selected operands and other affected instances. [Research prototype and limitations](https://cil.csit.carleton.ca/bidirectional-programming-csg-cad/)

## Dependency choices

| Component | Use | M0 check |
|---|---|---|
| AppKit `NSDocument` and `NSTextView` | Native save, reopen, first responder, Undo and text input | Use the same document undo manager for keyboard and viewport edits |
| MetalKit `MTKView` | Final shaded mesh, cutter overlays, manipulation handles | Render offscreen, pick with Retina scaling and render on the minimum target |
| Tree-sitter runtime and OpenSCAD grammar | Error-tolerant syntax and byte spans | Pin compatible runtime/grammar revisions, verify fixtures with comments, Unicode and `include` |
| OpenSCAD headless build | Geometry and evaluation trace | Build upstream reference and patched worker from the same revision, compare the same options |

References: [NSDocument](https://developer.apple.com/documentation/appkit/nsdocument), [MTKView](https://developer.apple.com/documentation/metalkit/mtkview), [OpenSCAD Tree-sitter grammar](https://github.com/openscad/tree-sitter-openscad), [incremental parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html), [OpenSCAD source and build instructions](https://github.com/openscad/openscad).
