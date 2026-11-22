# Implementation work packages

Complete milestones in order. Each ends with executable evidence and a usable slice of the application. Record the exact command, fixture, environment and any failing gate in the implementation repository. Keep the unmodified reference executable available throughout. Prefix script paths below with the repository root when running from another directory.

## M0 | Prove the engine on a Mac

**Inputs:** [Architecture](01-Architecture.md), [worker contract](03-OpenSCAD-Worker.md) and the [mounting-plate fixture](06-Verification-and-Release.md#canonical-fixture).

- [x] Verify the checked-in mounting-plate fixture against file 06. Choose a buildable OpenSCAD commit with a working macOS arm64 headless backend. Pin that commit, dependencies, backend options, resource paths and the parser/runtime pair. Record the Xcode, SDK and CMake versions used. Measure fontconfig's cold cache build and the per-job cost of a first `text()` with the bundled configuration.
- [x] Implement `Scripts/bootstrap-macos`, `Scripts/build-engine` and `Scripts/verify-engine`. Bootstrap checks prerequisites with actionable errors, obtains pinned sources and verifies checksums/revisions. Build pinned dependencies for arm64 and the declared deployment target using the pinned tree’s macOS recipes. Include only dependencies required by the headless targets. The resulting binaries must work without Homebrew. Link third-party libraries into the worker statically where their licenses allow, which removes install-name rewriting and nested dylib signing. For a library that must stay dynamic, record why, set its install name to an `@rpath` path, give the worker an `LC_RPATH` to the bundle's Frameworks folder, and fail packaging if `otool -L` still shows an absolute build path. Build both reference and patched executables into separate product roots. Cache against pins, architecture, deployment target, patch digest, build variant (reference or patched), dependency recipe, and the Xcode, SDK, CMake and compiler versions, so a toolchain update never reuses a stale binary. Wire `Scripts/verify-engine` and the reference comparison into the CI workflow so a geometry or trace regression on a pin or fixture change fails CI.
- [x] Verify the pinned engine's behavior on a main file that starts with a UTF-8 BOM; if normalization is needed, offset-adjust all reported source spans and prove it on a BOM fixture.
- [x] Write a tiny worker client that sends unsaved source with a logical path, reads the model and trace, and exercises a ray into the third inner wall. Inventory the pinned engine hooks and implement the minimum instrumentation needed. Capture the corresponding source substring, instance bindings, local/world transforms and actual final mesh evidence. Test with two instances sharing a cached primitive.
- [x] Decide whether Scadretto bundles any library in the bundled `libraries` root, and record each bundled library's license.
- [x] Compare the fixture with the reference. If face ownership is unavailable, implement the matched-surface fallback in file 03. If a compatible backend cannot build on macOS 14, try another supported revision or backend and record the result before changing the platform baseline.
- [x] Measure worker cold start plus engine initialization against the commit-to-frame budget in file 06. If it dominates the 1 s p95 target, test the worker-reuse alternative and its isolation costs before changing transports.

**Exit:** A clean Mac can reproduce both builds. The inner wall maps to iteration 2 with an unbroken link to `hole_d`. The source SHA and reference geometry comparison are in `Docs/Decisions/engine-spike.md`. Do not start a bespoke OpenSCAD interpreter to get past this gate.

## M1 | Ship the source editing core and document shell

**Depends on M0.** Implement `ScadrettoCore`, `ScadrettoSyntax`, the `Scadretto` scheme, initial document window and package tests.

- [x] Enable the Swift 6 language mode before writing core types: `// swift-tools-version: 6.0` in `Package.swift`, which makes Swift 6 its targets' default language mode, and `SWIFT_VERSION = 6.0` in the app target. This requires the Swift 6 toolchain, Xcode 16 or later, for all contributors and CI. Do not opt any target back into Swift 5 mode, including test targets. Implement raw bytes, source spans, a UTF-16 line index, revisioning, immutable snapshots and atomic checked transactions. Add golden input/output tests for the coordinate and undo cases in file 02.
- [x] Keep values crossing isolation boundaries `Sendable` and route document mutations through the main actor; test that off-main parsing, decoding and file I/O never touch document state.
- [x] Add invalid UTF-8, truncated UTF-8 and UTF-16 BOM fixtures; opening one fails with the first bad byte offset, creates no editable buffer and never substitutes replacement characters.
- [x] Bring in the pinned Tree-sitter grammar and runtime. Run its parser off the main thread and discard stale syntax responses. Verify call locations against the worker on the initial corpus. Syntax errors must still yield useful highlighting outside the invalid region.
- [x] As each module lands, declare its test target under `Packages/ScadrettoKit/Tests/` in `Package.swift`, plus the Xcode UI-test target for `Tests/UITests/`. Confirm `swift test --package-path Packages/ScadrettoKit` discovers and runs the package targets rather than reporting no tests.
- [x] Implement a plain `NSTextView` adapter on the recorded TextKit version, an `NSDocument` subclass and ordinary New/Open/Save/Revert. Add native Undo/Redo, unmodified round-trip saving and edited-state tracking. Add external-change baseline tracking before enabling autosave-in-place.

**Exit:** Open a CRLF fixture with a BOM and emoji, edit one number by keyboard, save and compare expected bytes. Undo/redo through the Edit menu; open two separate documents and verify independent undo history. `swift test --package-path Packages/ScadrettoKit` passes.

## M2 | Compile real documents and display the result

**Depends on M1.** Implement the job protocol, `ScadrettoEngineClient`, initial `ScadrettoViewport`, diagnostics and resource resolver.

- [x] Replace the spike client with a versioned job encoder, validated decoder and cancellable scheduler. Check in the three golden protocol pairs from file 03, including the mounting-plate trace. Package the helper and runtime resources in the developer app. Inject the executable location in tests.
- [x] Load and shade the final mesh in Metal. Add camera framing, orbit, pan and zoom with the mouse and trackpad mappings in file 04, the standard views, the Show Edges and Show Axes toggles, the orbit/pan swap preference, orthographic projection, resize/Retina handling, diagnostics that jump to the correct file/range and the evaluation console.
- [x] Add a warning-only fixture and assert that warnings reach the status area and jump to their source while eligible bindings in the new scene remain editable.
- [x] Render from the live buffer, honor include/use/import paths and upstream's default library roots, accept only the current key and latest request ID, clear valid empty scenes, and label stale last-good scenes. Simulate process crash, out-of-order completion and deleted include recovery.
- [x] Build the instance outline from the accepted scene's executed instances: module calls, loops, primitives and boolean operands, with occurrence selection.

**Exit:** Open the handwritten fixture from Finder, change `count` in text, and see the new hole in the shaded mesh and outline. Break and fix a statement without losing work. Running from a path with spaces succeeds.

## M3 | Complete the first bidirectional edit

**Depends on M2.** Build the narrowest complete interaction through normal application entry points.

- [x] Connect the cylinder diameter property, call chain and verified authoring spans from the M2 trace to the edit planner. Connect final-surface hit testing to source highlighting and a scope-aware inspector.
- [x] Implement a diameter field, a diameter handle, affected-instance highlights and one undoable write to a shared literal. Preview with an overlay. On release, verify the patch, update the text view and reevaluate. Implement Escape, zero movement and stale-gesture rejection.
- [x] Add separate integration tests for keyboard entry, real viewport drag, and reopen in the reference CLI. Replay the same interaction with an identical local literal in an unrelated call to prove the correct declaration is chosen.

**Exit:** Steps 1–5 of the mounting-plate walkthrough in file 06 pass. Also run step 7 from a fresh baseline with the M3 diameter handle. Dragging the third hole changes one literal and four bores. Typing changes the count. Source, inspector and geometry agree after undo and reopen. This is the first demonstrable product milestone.

## M4 | Extend properties, transforms and procedural scope

**Depends on M3.** Keep an explicit support table beside the planner tests.

- [ ] Add the remaining cube/sphere/cylinder bindings, explicit module arguments, transform vector edits, active-file named numeric parameters and the eligibility checks from file 02.
- [ ] Implement explicit local offsets and prefix insertion at verified syntax boundaries. Exercise combined transforms, center semantics, negative scales and singular transforms. Disable ambiguous implicit signatures and computed lists.
- [ ] Implement impact tracking and selection reconciliation for shared calls, modules, shadowed names and repeated instances. Add the restricted pitch handle and numeric fallback for iteration zero.
- [ ] Support nested booleans, ghost selection, rim ambiguity and outline fallback. Keep expressions inspectable when they have no approved rewrite.

**Exit:** All seven walkthrough steps in file 06 pass in order, including the pitch drag in step 6 and its cancellation in step 7. The Scope, Expressions, Primitive properties, Transforms and Procedural picking rows of the regression matrix pass. Repeated edits preserve user formatting and formulas. No single-instance action rewrites a shared generator by accident.

## M5 | Harden real macOS workflows

**Depends on M4.** Complete save conflicts, worker resilience, input handling, accessibility and performance measurement.

- [ ] Finish autosave/revert, separate dependency documents, reload/keep/compare flows, file replacement notifications and invalidation across windows. Exercise renamed/missing libraries and relative binary imports.
- [ ] Exercise cancellation, crash recovery, empty results, ambiguous selections, multi-window isolation, rapid typing and text input composition. Make diagnostics accessible and ensure the keyboard can perform every required property edit.
- [ ] Provide a New Window command for the current document and test two windows of the same `NSDocument`: a commit or undo started in either window converges on one buffer and one undo stack, the other window's selection and handles re-anchor or clear safely, and no undo item is double-registered.
- [ ] Benchmark the mounting-plate fixture and `Tests/Fixtures/stress-100-cutters.scad` under file 06's workload using its measurement method, and publish the raw sample logs and environment. Implement caching or instancing for measured bottlenecks. Confirm a slow evaluation never blocks typing or camera control.

**Exit:** App, unit and integration suites pass on arm64. A real-Mac manual report covers trackpad, Retina picking, VoiceOver and external editing. Record measured timing percentiles and any unverified targets.

## M6 | Deliver a reproducible distributable build

**Depends on M5.** Package an arm64 app containing its own helper, required resources, dylibs, attribution and corresponding engine source material.

- [ ] Implement `Scripts/verify` and `Scripts/package-macos` with distinct local and distribution modes. Test a locally signed build on a machine without Homebrew or a system OpenSCAD installation. Implement the existing release workflow’s distribution interface and verify the tag preflight as described in [the build and release guide](../CICD.md).
- [ ] Bundle `Tests/Fixtures/mounting-plate.scad` as a read-only application sample and open an editable untitled copy from Help → Open Example. Copy it from the canonical fixture at build time rather than retyping it, and verify the bundled bytes in the distribution gate.
- [ ] Validate architecture, minimum OS, dependency paths and library/font resolution. Review redistribution licenses for the pinned dependency set and prepare the matching source/build instructions.
- [ ] When the release owner supplies credentials, sign nested code, including the worker with the hardened runtime, and the app, notarize and staple, then run Gatekeeper and quarantine install checks on the final package. Record artifact checksums.

**Exit:** The release checklist in file 06 records both functional verification and distribution state. An ad hoc developer package is a valid local deliverable; mark public distribution pending until those gates pass.

## Later extensions

| Extension | Prerequisite | First acceptance example |
|---|---|---|
| Explicit “only this occurrence” | Binding trace, loop-identity proof, previewable structural diffs | On a recognized integer-range pattern, preview and accept a conditional offset for one occurrence. Other instances, comments and ordinary parameter behavior remain intact; cancel produces no diff. |
| Rotate and scale handles | Robust frame, pivot and handedness tests | Rotate about the displayed pivot under a transformed parent. Re-evaluation produces the previewed pose. |
| Editing dependency files in place | Multi-document coordinated transactions and undo | Changing a library parameter previews all affected open documents and can be undone coherently. |
| Editing imported mesh topology | An explicit asset-editing and export policy with separate undo | In a copy of an imported mesh, split a selected face. Verify the original asset remains byte-identical and the user can review the updated import reference. |
| Arbitrary face push/pull | Handle math generalized beyond axis-aligned primitives | Dragging one cube face moves that face only; the committed evaluation matches the previewed solid. |
| Interactive 2D sketcher | 2D editing under the same verified rewrite rules as the 3D handles | Sketching a rectangle on the plate's top face inserts a verified statement that survives the byte-diff review. |
| Intel or universal distribution | Reproducible x86_64 engine and dependency builds | Verify the native app/helper pairing and the same fixture suite on an actual Intel Mac. |
