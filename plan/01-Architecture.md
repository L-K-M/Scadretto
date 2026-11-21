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

Declare each package test target in `Package.swift`. Package tests in the checkout locate the repository’s canonical `Tests/Fixtures/` relative to the test source file. Xcode copies those same files into its UI-test bundle. Verify both suites from a working directory outside the repository.

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
| `EditIntent` | Inspector or viewport | Requested operation, explicitly selected target and scope, units, original value, full key and accepted request ID at gesture start |
| `SourcePatch` | Pure edit planner | Expected document key and source slices, replacements and an undo label. A graphical patch also carries its originating scene’s request ID. Applied only on the document's serial mutation path. |

Save serializes the current source buffer. Source-writing controls require a successful outcome for the latest request and complete key, a writable target and no unresolved disk conflict. While waiting, cancelled or failed, label any last-good scene stale and disable its bindings. Diagnostics and evaluation status come from the latest accepted outcome, not from the last-good scene. Presentation state such as camera and panel visibility can live in window restoration or preferences. It must be possible to discard every cache and reconstruct a model by opening the source again.

## End-to-end event flow

1. An AppKit text edit, a numeric inspector entry, undo, redo or an accepted viewport gesture enters the same document transaction API. Accepting a transaction increments revision even when undo returns to bytes seen before. An unchanged transaction produces no undo item.
2. Update text storage and the byte/UTF-16 index in one mutation. Refresh highlighting asynchronously. Schedule a worker request after about 150 ms of idle typing. Enter in an inspector or releasing a handle evaluates immediately.
3. Capture immutable UTF-8 bytes, the current dependency generation and the exact resolution context. The worker returns the same key plus digests of all files read. A filesystem notification changes the generation even when the main source has identical bytes. Changing the logical path, base directory or search roots changes the resolution-context digest and cancels the old request even if the source bytes are unchanged.
4. Accept an outcome on the main actor only if the complete key matches, the echoed request/job token is the latest one issued for the document, source digests still agree and the document is open. A cancelled or superseded child therefore can never win against its replacement. Update status, diagnostics and dependency observations together for that outcome. On success, swap all scene-derived state in one operation. On parse/evaluation failure, retain the previous good mesh as a visibly stale preview but do not expose its old bindings or handles as current. Empty valid geometry is a successful result with no mesh and clears the old preview.
5. While dragging, calculate a tentative value and draw a local overlay. Commit a single patch on release. Escape, a concurrent source change, an incoming file conflict or a lost selection cancels the tentative edit. A cancelled gesture leaves no bytes or undo entry behind.

Build the app and package in Swift 6 mode with complete concurrency checking. Isolate document mutations to `@MainActor` and the scheduler to its own actor. Keep mutable C parser handles inside their owning isolation domain and send immutable syntax ranges across it. Release old GPU buffers after their in-flight command buffers finish.

## Concurrency and thread safety

The document owns committed bytes, revision, undo history and the accepted outcome. Typing, inspector entry, undo, redo and graphical commits enter one mutation path on the main actor. Immutable snapshots and checked patches can cross that boundary.

Off the main actor: Tree-sitter parsing, worker encoding and decoding, mesh processing, BVH construction and file I/O. Those workers receive immutable inputs and return immutable values; they never touch document state or AppKit. The engine client publishes results to the main actor, which checks the key, job token and dependency digests before swapping state.

Cancel in-process tasks cooperatively and stop native evaluation using the bounded process termination in file 03. A superseded request cancels its task; closing a document cancels its queued and active work; a drag that loses its selection or observes a revision change abandons its tentative patch. Tasks report cancellation rather than writing partial state. Tests assert main-actor isolation and that no off-main worker blocks typing or camera control.

## Stable meaning across evaluations

A source range identifies a span in one version of one file. An execution path identifies an *occurrence* during that evaluation. They serve different purposes. A `for` loop can produce four cylinders from one span, and the same imported module can be called at many sites.

Reconcile each window’s selection using file identity, the source anchor, operation, call path and loop bindings. Map the anchor through known edits into the new revision before matching. Keep a unique match, fall back to the nearest uniquely matched ancestor, or clear selection. Never select an equal sibling by traversal order. On reopen, restore only when the saved file identity and digest still match and the path resolves uniquely. Worker IDs are local to one result.

## File resolution and the reference evaluator

Give new documents a private temporary workspace. For saved files use the logical main file URL for includes, diagnostics and relative imports. Pass the unsaved bytes as an overlay at that URL. Resolve nested dependencies relative to their authoring file and record the engine's actual resolution order. Apply user-selected library roots and bundled resources consistently to the worker and reference CLI. Start from upstream's search order so existing projects resolve unchanged: `OPENSCADPATH` entries, then the user library folder `~/Documents/OpenSCAD/libraries`, then the bundled `libraries` resource folder. Use `OPENSCADPATH` from the app's own environment when it is set, for example with `launchctl setenv`. A Finder or Dock launch never sees a variable exported in a shell profile, so let users add roots in Preferences. Search them first, in their listed order, and show the effective ordered list there. Pass the resolved roots to the worker in the request; the worker never reads them from its environment. M0 records the pinned CLI’s effective search order. Run reference fixtures with explicit roots in the same order and controlled user and bundled folders. For the reference CLI, join explicit search roots in order using its platform delimiter. Omit empty entries. If a root name cannot be represented by that interface, record the limitation. Compare the winning files as well as their bytes. Reading under `~/Documents` can trigger the macOS privacy prompt for the Documents folder. Defer that access until an evaluation actually needs a root there, never at launch. Report a denied or missing root as an unresolved-library diagnostic that names it. An untitled document with an unresolved relative import should offer Save As or selection of a base directory. Save As changes the logical path and resolution roots, immediately invalidates the scene and write-back handles, and starts a request with the new resolution-context digest.

The engine owns OpenSCAD evaluation, boolean operations, and expression values. The editor owns preservation of source formatting and explicit rewrite policy. Introduce a revision-pinned trace bridge between them. A plain exported mesh does not include the authoring decisions needed by the inspector. The OpenSCAD bidirectional editing research provides a worked example of tracing selected operands and other affected instances. [Research prototype and limitations](https://cil.csit.carleton.ca/bidirectional-programming-csg-cad/)

## Dependency choices

| Component | Use | M0 check |
|---|---|---|
| AppKit `NSDocument` and `NSTextView` | Native save, reopen, first responder, Undo and text input | Use the same document undo manager for keyboard and viewport edits. Prototype line numbers on the intended TextKit version without an unplanned fallback to TextKit 1; M1 records the choice |
| MetalKit `MTKView` | Final shaded mesh, cutter overlays, manipulation handles | Render offscreen, pick with Retina scaling and render on the minimum target |
| Tree-sitter runtime and OpenSCAD grammar | Error-tolerant syntax and byte spans | Pin compatible runtime/grammar revisions, verify fixtures with comments, Unicode and `include` |
| OpenSCAD headless build | Geometry and evaluation trace | Build upstream reference and patched worker from the same revision, compare the same options |

References: [NSDocument](https://developer.apple.com/documentation/appkit/nsdocument), [MTKView](https://developer.apple.com/documentation/metalkit/mtkview), [OpenSCAD Tree-sitter grammar](https://github.com/openscad/tree-sitter-openscad), [incremental parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html), [OpenSCAD source and build instructions](https://github.com/openscad/openscad).
