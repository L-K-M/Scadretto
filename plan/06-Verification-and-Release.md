# Verification and release

## Canonical fixture

Create `Tests/Fixtures/mounting-plate.scad` with UTF-8, LF line endings and a final newline. Keep this exact file as the baseline for byte-diff tests. OpenSCAD lengths are model units; the walkthrough uses the common millimetre convention.

```openscad
// Scadretto acceptance fixture — keep this comment.
$fn = 64;
hole_d = 4;
count = 4;
pitch = 20;
x0 = 15;
plate_h = 6;

module mounting_hole(d) {
    cylinder(h = plate_h + 2, d = d);
}

difference() {
    cube([120, 40, plate_h]);
    for (i = [0 : count - 1])
        translate([x0 + i * pitch, 20, -1])
            mounting_hole(d = hole_d);
}
```

Initial bounds are `[0,0,0]` to `[120,40,6]`. Bore centers at Y = 20 are X = 15, 35, 55 and 75. The cutter extends below and above the solid. An acceptance test must distinguish those four *through-holes* from four separate cylinders drawn on a solid plate.

## Mounting-plate walkthrough

| Step | Action | Required result |
|---|---|---|
| 1 | Open the fixture through File → Open. | One plate with four through-holes. The outline shows the repeated cutter operation. Saving untouched is byte-identical. |
| 2 | Click the inner wall of the third hole in the shaded view. | Selection resolves to iteration `i=2` and the cylinder in `mounting_hole`. Its argument chain reaches the active file's `hole_d`. |
| 3 | Select the shared diameter. Drag radially outward by 0.5 model units and release. | The displayed diameter goes from 4 to 5, all four bores enlarge, and the only source difference is `hole_d = 4;` → `hole_d = 5;`. One Undo restores every original byte. Redo reapplies it. |
| 4 | In the source editor change `count = 4;` to `count = 5;`. | Five through-holes, with the fifth at X = 95. Inspector and affected count reflect five cutters. There are exactly two changed numeric tokens relative to the baseline. |
| 5 | Save, close, reopen in Scadretto and render the saved file with the upstream reference CLI. | The same five holes and physical geometry appear. The saved file is valid standalone OpenSCAD and retains the authored module, loop and comment. |
| 6 | Independently reopen the baseline. Pick iteration 2's pitch handle and drag it +4 along local X. | The selected hole moves from X = 55 to 59; `pitch = 20;` becomes `pitch = 22;`. The four centers are 15, 37, 59, 81. At iteration zero numeric pitch entry remains available. |
| 7 | Drag again but press Escape. Then remove a closing brace in the text editor. | Escape leaves identical bytes and undo depth. The syntax error shows a stale preview with disabled write-back. Fixing the brace restores current handles. |

For deterministic hit tests, cast a local horizontal ray from inside the third empty bore at `(55,20,3)` toward its wall at an angle away from polygon vertices. Also send a camera ray through the normal mouse event path in a pitched view; use a projected known wall point and assert the first visible hit. Drive one XCUITest with mouse-down, motion and mouse-up on the real handle at a known camera pose and backing scale. Use the inspector's numeric field for a second, independent path.

## Geometry oracle

Render fixtures with the unmodified reference CLI built from `Engine/upstream.lock`. Run both implementations with the same resources, working directory, tessellation settings, backend and render mode. In v1 use final-render semantics for the authoritative scene and reference, including matching `$preview`; “live preview” in the UI describes scheduling. Add a fixture that explicitly branches on `$preview`. Time-dependent or random programs require a fixed input for equality tests, or an explicitly documented test exclusion.

For a closed solid, compute world bounds, absolute signed volume after consistent triangle orientation, and occupancy probes with a tolerance. Triangle count and STL byte order are unreliable cross-build oracles. For the plate, the expected volume is `120 × 40 × 6 − count × 6 × (64/2) × (hole_d/2)² × sin(2π/64)`. This accounts for the 64-sided hole rather than assuming a perfect circle. Probe each center at Z = 3 as empty, points between neighboring bores as solid, and points beyond the plate as empty. Suggested starting tolerances for this fixture are `1e-4` model units on bounds and `1e-5` relative on volume. Record adjustments with an explanation and never loosen tolerances to hide a missing bore. Verify watertight edges after tolerance-aware vertex welding when using STL.

Use a dependency fixture with `use <lib/part.scad>` and another with `include`. Give one included file a relative asset import in a nested directory. Add whitespace and non-ASCII characters to a parent path. Test in-memory main overlays and saved reference files in matching directory structures.

### Fixture preflight

The plan's fixture and its three edits were rendered with stock OpenSCAD 2021.01 on Linux. The following measurements came from the exported binary STL. Every run had the expected bounds, two incident triangles per undirected edge, and 64 vertices per bore on each of the top and bottom faces. These numbers establish the example geometry; the macOS engine/build and interaction gates still require implementation.

| File state | Measured solid volume in cubic model units | Bore centers on X |
|---|---:|---|
| Original | 28498.8913 | 15, 35, 55, 75 |
| Diameter 5 | 28329.5177 | 15, 35, 55, 75 |
| Diameter 5, count 5 | 28211.8972 | 15, 35, 55, 75, 95 |
| Original with pitch 22 | 28498.8913 | 15, 37, 59, 81 |

## Regression matrix

| Area | Case | Assertion |
|---|---|---|
| Fidelity | BOM, CRLF, mixed line endings, no trailing newline, emoji, comments, tabs, scientific notation | No-op save matches raw bytes. One supported edit touches only its gold span; undo restores original bytes. |
| Syntax drift | Worker source span differs from concrete syntax or target token | No write occurs. Highlight the diagnostic or allow code navigation only. |
| Scope | Module-local `d` shadows a top-level `d`; two equal literal values; numeric positional and named arguments | Correct resolved formal/declaration and instance impact; unrelated code and shapes remain unchanged. |
| Expressions | `wall/2`, nested arithmetic, inline/block comments, decimal comma UI locale, second drag after save/reopen | Formula remains evaluable; explicit offset retains future changes to `wall`. Golden diff covers accepted cases; unsupported ambiguous comments disable the action. |
| Primitive properties | Uniform cube, centered cube, vector cube, sphere diameter expressed as radius, tapered cylinder | Correct authored argument changes; centered resize remains symmetric; radius-to-diameter conversion and top/bottom picking are correct. |
| Transforms | Rotation under a parent, nonuniform scale, mirrored parent, singular matrix, first `translate` insertion | Committed object follows the displayed handle in the chosen frame. Unrepresentable moves are disabled. |
| Procedural picking | Nested differences, identical cached cutters, shared call, coincident surfaces, rim pick | Inner wall resolves to a cutter; ambiguities present choices. Enclosed shapes are reachable through the outline. |
| Source entry points | Typing, inspector, actual mouse drag, undo/redo, Save As and open from Finder | All paths converge on the same buffer, model and file. One visual gesture produces one undo item. |
| Scheduling | Render A finishes after B, dependency changes during drag, cancel, close while rendering | Stale results do not replace scene or accept edits; child processes and job files are reclaimed. |
| Result validation | Missing or non-executable helper, worker from another build, unsupported protocol version, triangle owner naming a missing instance, operand range outside `operands.bin`, span past the end of its file, unknown winding value | Each result is rejected with a packaging or protocol error before any scene, handle or highlight uses it. Recovery follows the Failure recovery row. |
| Failure recovery | Invalid code, valid empty `difference`, missing asset later created, child exits mid-write, corrupt mesh or protocol mismatch | Source stays editable and saveable. Valid empty clears prior geometry; errors preserve last-good geometry and show the reason. |
| Files | External replacement while clean and dirty, autosave conflict, read-only dependency, sibling library in two documents | Dirty bytes survive. No silent overwrite. Dependency changes invalidate previews even when source is unchanged. |
| Native UX | IME composition, Retina pick, document windows, dark mode, keyboard-only inspector, VoiceOver | Selection and ranges survive refresh, controls are discoverable and the active window owns Undo. |

## Build and verification entry points

The agent creates these project scripts in M0–M6. The commands below are acceptance interfaces for the future repository. They have not been executed against a Scadretto application.

```sh
./Scripts/bootstrap-macos
./Scripts/build-engine
./Scripts/verify-engine
swift test --package-path Packages/ScadrettoKit
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto -destination 'platform=macOS,arch=arm64' test
./Scripts/verify
./Scripts/package-macos --local
```

`verify-engine` runs worker contract, source trace and reference comparisons. `verify` runs the deterministic package, integration and application test suites and reports machine/toolchain metadata. For XCTest UI automation use a logged-in macOS runner that permits UI tests. A headless CI host can run core and worker suites; mark GUI coverage pending until the UI suite runs. Make all failures nonzero and preserve relevant source diffs, diagnostics and fixture names in CI artifacts. Successful local CI must not require release credentials.

## Performance targets

Treat these as initial engineering budgets. Report observed p50/p95, sample count, hardware, OS, revision, backend and cold/warm state. Use release builds on a declared baseline such as an M1 with 16 GB RAM or equivalent. Re-run after pin changes.

| Workload | Measurement | Target |
|---|---|---|
| Canonical plate | Warm, commit to accepted shaded frame over 30 edits, excluding typing debounce | p95 under 1 second |
| Active drag and orbit | Twenty seconds of interaction with the plate; then repeat with 100 valid repeated cutters on a larger plate | p95 frame time at or below 33 ms; a cut can update on commit |
| Typing while worker is busy | 100 paced edits while running the larger pattern | p95 main-thread edit handling under 16 ms; zero stale scene commits |
| Cancellation and cleanup | Alternate 50 distinct jobs, supersede or close repeatedly, inspect children and private job storage after settling | Zero orphaned workers and zero abandoned completed jobs; record peak memory and termination latency |

## Distribution gate

1. Build an arm64 Release app for the declared deployment target. Put the child executable in the app's helpers location, dynamic libraries in Frameworks, and engine resources, fonts as licensed, and shader resources in bundle resources. Resolve paths relative to the executable or bundle. Run `file`, `otool -L` and deployment-target inspection recursively and flag developer-machine or Homebrew paths.
2. Inventory the exact licenses of the pinned OpenSCAD sources, patches, grammar, runtime and redistributed dependencies. Include attribution and license texts, and prepare the corresponding worker source and reproducible build scripts for distributed binaries. Make the application licensing and publication decision explicitly before public release. Process separation alone does not settle licensing. [OpenSCAD COPYING](https://github.com/openscad/openscad/blob/master/COPYING)
3. Keep `--local` ad hoc signed and usable without an Apple developer account. For external distribution use the owner's real bundle ID and Developer ID Application identity, hardened runtime, timestamp, and inside-out signing of nested code. Verify the app, package it, submit through `notarytool`, check acceptance, staple to a supported artifact and verify the final distributed bytes. Keep signing credentials outside source control. [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
4. On a clean supported Mac, launch the quarantined distribution artifact, open the fixture offline, drag and save a change, then reopen it. Check the helper starts and finds fonts, imports, libraries and shader resources with developer paths absent. A signed app that starts but cannot launch its child fails this gate.
5. Record the package hash, macOS versions tested, hardware, app/worker SHAs, test results, attribution/source location and notarization status. Claims for minimum OS support require a run on that OS. Label a build “local development” while credentialed distribution is pending.

## Implementation references

- [OpenSCAD CLI](https://en.wikibooks.org/wiki/OpenSCAD_User_Manual/Using_OpenSCAD_in_a_command_line_environment) and [upstream build instructions](https://github.com/openscad/openscad). Use the reference build's own `--help` output for the exact export/backend flags in the pinned revision.
- [Gonzalez and colleagues' OpenSCAD prototype](https://cil.csit.carleton.ca/bidirectional-programming-csg-cad/). The descriptions of affected elements and ghost cutters are especially relevant to the selection tests.
- [BelfrySCAD source-rewrite notes](https://github.com/BelfrySCAD/BelfrySCAD/blob/main/docs/wysiwyg.md). Compare the documented expression-delta behavior with Scadretto's explicit edit scopes.
