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
  Tests/ScadrettoCoreTests/        source, range, patch and transaction contracts
  Tests/ScadrettoSyntaxTests/      byte/UTF-16 conversion and grammar queries
  Tests/ScadrettoEngineClientTests/ request encoding, result decoding and scheduler tests
  Tests/ScadrettoViewportTests/   camera, hit-testing and handle math tests
Engine/
  upstream.lock                    upstream commit, dependency revisions, build flags
  patches/                         ordered, replayable changes against that commit
  protocol/                        manifest specification, examples and binary layouts
Tests/Fixtures/                    handwritten SCAD, includes, assets and golden edits
Tests/UITests/                     XCUITest target for document-window and interaction tests
Scripts/                           bootstrap, verification, packaging
Docs/Decisions/                    engine spike, coordinates, packaging and benchmark record
```

SwiftPM discovers one test target per subdirectory of `Packages/ScadrettoKit/Tests/`; declare each target in `Package.swift`. A single flat `Tests/` directory is not a target, so `swift test --package-path Packages/ScadrettoKit` would report no tests. Keep the root `Tests/Fixtures/` files reachable as a resource bundle from both the package tests and the Xcode UI-test target; `Tests/UITests/` is an Xcode target, not a SwiftPM target.

Start with a checked-in `.xcodeproj`, a shared `Scadretto` scheme, Swift Package Manager lockfiles and one pinned engine dependency manifest. Build scripts resolve their own repository root and support spaces in paths. Keep fetched upstream sources and generated binaries in an ignored build directory. Check in the revision, patch series and instructions required to reproduce them.

Format `Engine/patches/` as a `git format-patch` series — `NNNN-*.patch` files applied in order with `git am` onto the pinned commit, each commit message describing the observation hook it adds. `Scripts/build-engine` applies the series rather than assuming a prepared tree, and `Scripts/verify-engine` replays it onto a pristine upstream checkout and compares the resulting source tree, so the shipped worker cannot silently depend on unrecorded working-tree state or a patch that only applies manually.

## Data ownership

| Type | Owner | Contents and lifetime |
|---|---|---|
| `SourceDocument` | One `NSDocument` per open model | Canonical source bytes, acknowledged disk baseline, original encoding metadata, current revision and one undo manager |
| `SyntaxSnapshot` | Editor parser | Incremental concrete syntax tree and line index for a single source revision. Supplies syntax ranges and errors while typing. |
| `EvaluationKey` | Document controller | Document UUID, monotonically increasing source revision, dependency generation, resolution-context digest, evaluation options digest and build identity. The resolution context includes the logical main URL or untitled base directory, ordered library roots and resource roots. A new document UUID is issued even for another window opening a separate copy. Accepting a result additionally requires the per-request job token from [the worker contract](03-OpenSCAD-Worker.md), which changes on an explicit retry or cancellation even when the key is unchanged. |
| `EvaluationOutcome` | Engine client | Immutable result for one key, including status, diagnostics, observed dependencies and file digests even when evaluation fails. A successful outcome also carries the scene. |
| `SceneSnapshot` | Document controller | Last accepted successful scene: mesh, bounds, executed instances, source map and editable binding candidates. A failed outcome does not replace it. |
| `Selection` | Per document window | Snapshot-scoped instance and source anchor. Camera and selection survive only when their targets can be re-established. |
| `EditIntent` | Inspector or viewport | Requested operation, explicitly selected target and scope, units, original value, and the key at gesture start |
| `SourcePatch` | Pure edit planner | Expected document key and source slices, replacements and an undo label. Applied only on the document's serial mutation path. |

Save serializes the current source buffer. The outline and inspector read the current successful scene only while its key matches the document; otherwise they show its geometry as stale and disable write-back. Diagnostics and evaluation status come from the latest accepted outcome, not from the last-good scene. Presentation state such as camera and panel visibility can live in window restoration or preferences. It must be possible to discard every cache and reconstruct a model by opening the source again.

## End-to-end event flow

1. An AppKit text edit, a numeric inspector entry, undo, redo or an accepted viewport gesture enters the same document transaction API. Accepting a transaction increments revision even when undo returns to bytes seen before. An unchanged transaction produces no undo item.
2. Update text storage and the byte/UTF-16 index in one mutation. Refresh highlighting asynchronously. Schedule a worker request after about 150 ms of idle typing. Enter in an inspector or releasing a handle evaluates immediately.
3. Capture immutable UTF-8 bytes, the current dependency generation and the exact resolution context. The worker returns the same key plus digests of all files read. A filesystem notification changes the generation even when the main source has identical bytes. Changing the logical path, base directory or search roots changes the resolution-context digest and cancels the old request even if the source bytes are unchanged.
4. Accept an outcome on the main actor only if the complete key matches, the echoed request/job token is the latest one issued for the document, source digests still agree and the document is open. A cancelled or superseded child therefore can never win against its replacement. Update status, diagnostics and dependency observations together for that outcome. On success, swap all scene-derived state in one operation. On parse/evaluation failure, retain the previous good mesh as a visibly stale preview but do not expose its old bindings or handles as current. Empty valid geometry is a successful result with no mesh and clears the old preview.
5. While dragging, calculate a tentative value and draw a local overlay. Commit a single patch on release. Escape, a concurrent source change, an incoming file conflict or a lost selection cancels the tentative edit. A cancelled gesture leaves no bytes or undo entry behind.

Keep disk I/O, parsing large files, tessellation, worker waits and mesh decoding off the main actor. Mutate document state, AppKit views and undo registrations on the main actor. Upload buffers ahead of presentation and release old GPU buffers only after their in-flight command buffers finish.

## Concurrency and thread safety

The document is the single synchronization point. `ScadrettoCore` value types (`SourceDocument` state, `SyntaxSnapshot`, `EvaluationKey`, `SceneSnapshot`, `EditIntent`, `SourcePatch`) are `Sendable`, and the document's serial mutation path is the only writer of source bytes, revision, undo history and accepted scene. Every transaction — typing, inspector entry, undo/redo and a graphical commit — enters that path on the main actor. No two workers mutate a document at once.

Off the main actor: Tree-sitter parsing, worker encoding and decoding, mesh processing, BVH construction and file I/O. Those workers receive immutable inputs and return immutable values; they never touch document state or AppKit. The engine client publishes results to the main actor, which checks the key, job token and dependency digests before swapping state.

Cancellation is cooperative and propagated. A superseded request cancels its task; closing a document cancels its queued and active work; a drag that loses its selection or observes a revision change abandons its tentative patch. Tasks report cancellation rather than writing partial state. Tests assert main-actor isolation and that no off-main worker blocks typing or camera control.

## Stable meaning across evaluations

A source range identifies a span in one version of one file. An execution path identifies an *occurrence* during that evaluation. They serve different purposes. A `for` loop can produce four cylinders from one span, and the same imported module can be called at many sites.

For each instance, record the shape operator, authoring file, call path, loop iteration and local-to-world transform. Reconcile selection after a rebuild by carrying the original source anchor (file identity, content digest at gesture time and span) through known edits, then matching call path, operation and iteration bindings in the new evaluation. Prefer a unique instance with the same anchor and call path; when an edit is expected to move or duplicate the occurrence, follow the occurrence token recorded by that transaction. With several candidates, select the nearest ancestor that still contains the original anchor and whose call path matches; with none, clear. Order equal candidates deterministically (shortest differing call-path depth, then smallest source-anchor offset). Persist the anchor plus call path for state restoration and apply the same rule after reopening. Worker IDs, triangle indices and line numbers are unsuitable as persistent document IDs.

## File resolution and the reference evaluator

Give new documents a private temporary workspace. For saved files use the logical main file URL for includes, diagnostics and relative imports. Pass the unsaved bytes as an overlay at that URL. Resolve nested dependencies relative to their authoring file and record the engine's actual resolution order. Apply user-selected library roots and bundled resources consistently to the worker and reference CLI. Start from upstream's search order so existing projects resolve unchanged: `OPENSCADPATH` entries, then the user library folder `~/Documents/OpenSCAD/libraries`, then the bundled `libraries` resource folder. Use `OPENSCADPATH` from the app's own environment when it is set, for example with `launchctl setenv`. A Finder or Dock launch never sees a variable exported in a shell profile, so let users add roots in Preferences. Search them first, in their listed order, and show the effective ordered list there. Pass the resolved roots to the worker in the request; the worker never reads them from its environment. The reference CLI has no option for library roots. It searches `OPENSCADPATH`, then its own user library and bundled folders, so run it with `OPENSCADPATH` set to the preference and environment roots, and record its two built-in folders with the comparison. Reading under `~/Documents` can trigger the macOS privacy prompt for the Documents folder. Defer that access until an evaluation actually needs a root there, never at launch. Report a denied or missing root as an unresolved-library diagnostic that names it. An untitled document with an unresolved relative import should offer Save As or selection of a base directory. Save As changes the logical path and resolution roots, immediately invalidates the scene and write-back handles, and starts a request with the new resolution-context digest.

The engine owns OpenSCAD evaluation, boolean operations, and expression values. The editor owns preservation of source formatting and explicit rewrite policy. Introduce a revision-pinned trace bridge between them. A plain exported mesh does not include the authoring decisions needed by the inspector. The OpenSCAD bidirectional editing research provides a worked example of tracing selected operands and other affected instances. [Research prototype and limitations](https://cil.csit.carleton.ca/bidirectional-programming-csg-cad/)

## Dependency choices

| Component | Use | M0 check |
|---|---|---|
| AppKit `NSDocument` and `NSTextView` | Native save, reopen, first responder, Undo and text input | Use the same document undo manager for keyboard and viewport edits. Prototype line numbers on the intended TextKit version without an unplanned fallback to TextKit 1; M1 records the choice |
| MetalKit `MTKView` | Final shaded mesh, cutter overlays, manipulation handles | Render offscreen, pick with Retina scaling and render on the minimum target |
| Tree-sitter runtime and OpenSCAD grammar | Error-tolerant syntax and byte spans | Pin compatible runtime/grammar revisions, verify fixtures with comments, Unicode and `include` |
| OpenSCAD headless build | Geometry and evaluation trace | Build upstream reference and patched worker from the same revision, compare the same options |

References: [NSDocument](https://developer.apple.com/documentation/appkit/nsdocument), [MTKView](https://developer.apple.com/documentation/metalkit/mtkview), [OpenSCAD Tree-sitter grammar](https://github.com/openscad/tree-sitter-openscad), [incremental parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html), [OpenSCAD source and build instructions](https://github.com/openscad/openscad).
