# Verification and release

## Canonical fixture

The checked-in [mounting plate](../Tests/Fixtures/mounting-plate.scad) is the byte-exact baseline, encoded in UTF-8 with LF and a final newline. Git disables text normalization for SCAD fixtures. The walkthrough uses model units.

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

### Fixture invariants

In M0, test the exact 350-byte length and SHA-256 `136c95090096979a91024b7f1e6325f4f09fdca421880d6ffee447ac6c095235` of `Tests/Fixtures/mounting-plate.scad`, the byte ranges and values of the `hole_d`, `count` and `pitch` literals (`[74,75)`, `[85,86)`, `[96,98)`), the initial world bounds, and the expected volume for the original and the three edited states using the formula below. The test fails on any whitespace, line-ending, BOM or trailing-byte change, so a normalized checkout or an accidental edit cannot silently invalidate the byte-offset assertions in file 02 or the walkthrough.

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

Render fixtures with the unmodified reference CLI built from `Engine/upstream.lock`. Run both implementations with the same resources, working directory, tessellation settings, backend and render mode. In v1 use final-render semantics for the authoritative scene and reference, including matching `$preview`; “live preview” in the UI describes scheduling. Add a fixture that explicitly branches on `$preview`. Time-dependent or random programs require a fixed input for equality tests, or an explicitly documented test exclusion. The patched worker and the unmodified reference must produce equivalent solids for every fixture, including trace-instrumented runs; the trace patch is observation-only and a geometry difference is a failed gate.

For a closed solid, compute world bounds, absolute signed volume after consistent triangle orientation, and occupancy probes with a tolerance. These are fast diagnostics, but equal bounds and volume plus a finite set of probes do not prove equivalent geometry: an extra cavity and an equal-volume protrusion away from the probes could pass. For the reference comparison, compute the volume of the symmetric difference between the worker and reference solids with a pinned verification backend capable of robust solid comparison, or use a separately validated equivalent surface/solid comparison. Require that mismatch to be below a recorded absolute and relative tolerance; retain the bounds, volume and probe assertions to explain failures. The comparison itself must fail or report inconclusive for open, nonmanifold or invalid solids rather than treating them as equal. Add a negative control that preserves bounds and volume while moving or replacing geometry away from the fixed probes, and assert the comparison rejects it. Triangle count and STL byte order are unreliable cross-build oracles. For the plate, the expected volume is `120 × 40 × plate_h − count × plate_h × ($fn/2) × (hole_d/2)² × sin(2π/$fn)`. With the baseline values (`plate_h = 6`, `$fn = 64`, `hole_d = 4`, `count = 4`) this is `28800 − 4 × 6 × 32 × 4 × sin(2π/64)`. The polygon term accounts for the `$fn`-sided hole rather than assuming a perfect circle. Keep the formula in terms of the fixture variables so edits to `plate_h`, `$fn`, `hole_d` or `count` keep the oracle valid without recomputation. Probe each center at Z = 3 as empty, points between neighboring bores as solid, and points beyond the plate as empty. Suggested starting tolerances for this fixture are `1e-4` model units on bounds and `1e-5` relative on volume. Record adjustments with an explanation and never loosen tolerances to hide a missing bore. Verify watertight edges after tolerance-aware vertex welding when using STL.

Use a dependency fixture with `use <lib/part.scad>` and another with `include`. Give one included file a relative asset import in a nested directory. Add whitespace and non-ASCII characters to a parent path. Test in-memory main overlays and saved reference files in matching directory structures.

### Fixture preflight

The plan's fixture and its three edits were rendered with stock OpenSCAD 2021.01 on Linux. The following measurements came from the exported binary STL. Every run had the expected bounds, two incident triangles per undirected edge, and 64 vertices per bore on each of the top and bottom faces. These numbers are provenance from that 2021.01 run, not the acceptance oracle: M0 selects a reproducible macOS 14 arm64 pin. Preserve these historical results and record new measurements against that pin in the spike report. The macOS engine/build and interaction gates still require implementation.

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
| Encoding | Invalid or truncated UTF-8, a UTF-16 BOM, Latin-1 bytes invalid as UTF-8 | Open fails with the first bad byte offset; no replacement characters and no silent transcoding |
| Typed line endings | Return, Control-Return (`insertLineBreak:`) and `insertParagraphSeparator:` in a CRLF file; paste of LF, CR, CRLF, U+2028 and U+2029 text; drag-and-drop of LF, CR and mixed text; Return in a mixed file and on a final line without a newline | Every inserted separator matches the convention at the insertion point; a pasted CRLF pair converts as one unit, never two. No typed, pasted or dropped U+2028 or U+2029 reaches the source. Untouched bytes, including existing separators, stay as they are. Undo removes the inserted separator and restores the original bytes. |
| Syntax drift | Worker source span differs from concrete syntax or target token | No write occurs. Highlight the diagnostic or allow code navigation only. |
| Scope | Module-local `d` shadows a top-level `d`; two equal literal values; numeric positional and named arguments | Correct resolved formal/declaration and instance impact; unrelated code and shapes remain unchanged. |
| Overwritten assignments | `hole_d` assigned twice in the main file; a main-file default overwritten by a later `include`; an included default overwritten by the main file; `mounting_hole(d = hole_d, $fn = 32)` against a top-level `$fn` | The patch targets the overwriting expression and the geometry changes. A dependency-file overwrite makes the edit inspect-only with its location. The `$fn` impact set excludes occurrences that receive a closer value. |
| Module scopes | `use <lib.scad>` where `module m(d = lib_size)` and `lib_size` exist only in the library, a main-file `lib_size` with the same name, a wrapper module that places `children()` inside `translate`, `children(i)` inside the wrapper's loop | The library default is read-only and names its file; the main-file `lib_size` is never offered. Picking a child passed through `children()` selects the caller's child statement. A move edits that statement's own `translate` or inserts a prefix there under the prefix rule; the wrapper's inner `translate` applies to every call of the wrapper and is offered only as a shared edit, inspect-only in a dependency file. The `i` in `children(i)` resolves in the module's scope. |
| Expressions | `wall/2`, nested arithmetic, inline/block comments, decimal comma UI locale, second drag after save/reopen | Formula remains evaluable; explicit offset retains future changes to `wall`. Golden diff covers accepted cases; unsupported ambiguous comments disable the action. |
| Argument binding | `cylinder(8, 2)`, `cylinder(h = 8, 2)`, `cylinder(8, 2, 3, false, 5)`, `cylinder(d = 8, r = 1)`, `cylinder(r = 2, r2 = 4)`, a named argument repeating a positional one, a ninth positional argument, `translate(5)`, `translate([10, 0])`, centered cylinder, a user module named `cylinder` | Each handle edits only the literal that bound its value, and a cone is labeled bottom or top radius. Dead and unbound literals are read-only with upstream's warning as the reason, and any end supplied only by a default is read-only. |
| Primitive properties | Uniform cube, centered cube, vector cube, sphere diameter expressed as radius, tapered cylinder | Correct authored argument changes; centered resize remains symmetric; radius-to-diameter conversion and top/bottom picking are correct. |
| Transforms | Rotation under a parent, nonuniform scale, mirrored parent, singular matrix, first `translate` insertion | Committed object follows the displayed handle in the chosen frame. Unrepresentable moves are disabled. |
| Prefix insertion | Explicit move of `!cube(8);`, `#cube(8);` and a background-only `%cube(8);` | For an executed, writable target, the prefix follows its modifiers and the part moves by the requested amount. A background-only statement with no current binding offers no handle. |
| Procedural picking | Nested differences, identical cached cutters, shared call, coincident surfaces, rim pick | Inner wall resolves to a cutter; ambiguities present choices. Enclosed shapes are reachable through the outline. |
| Geometry oracle | Worker and reference solids with equal bounds and volume but different local geometry away from fixed probes | Symmetric-difference or validated equivalent comparison rejects the mismatch; invalid solids fail or are marked inconclusive. |
| Find and Replace | Replace one occurrence, Replace All of a parameter name in a CRLF file containing an emoji, case-sensitive match, then Undo | Only the matched spans change and every other byte stays identical. Replace All makes one undo entry, and one Undo restores the original bytes. |
| Source entry points | Typing, inspector, actual mouse drag, undo/redo, Save As and open from Finder | All paths converge on the same buffer, model and file. One visual gesture produces one undo item. |
| Selection reconciliation | Edit or undo around two identical cutters, dependency change, reopen | Selection follows the recorded anchor and call path, falls back to the nearest matching ancestor, or clears; it never jumps to an equal sibling |
| Scheduling | Render A finishes after B, dependency changes during drag, cancel, close while rendering, Save As or library-root change during evaluation | Stale results do not replace scene or accept edits, including when unchanged source resolves against a new directory; child processes and job files are reclaimed. |
| Console | `echo()` of numbers, strings and vectors; `assert` failure with a message; warning raised in an included file; 10,000 echoes from a loop | Instantiation messages match the reference CLI's `.echo` output for the same bytes up to the truncation bound. Spans jump to the correct file. Truncation is reported and typing stays responsive. |
| Worker environment | `text()` with the default and a bundled named font, first text evaluation with an empty cache, two concurrent text jobs, app started with `DYLD_*` and `OPENSCADPATH` set | `text()` geometry matches the reference run with the same font set. The cache is built once and reused by later jobs; no child builds the cache concurrently with another. A font in the user's `~/.fonts` does not change the result. Variables outside the allowlist, including `DYLD_*` and `OPENSCADPATH`, never reach the child. |
| Memory ceiling | An evaluation that allocates past the ceiling; critical memory pressure delivered through a test hook that calls the production handler; two documents evaluating at once | The parent terminates the child on detecting excess footprint or critical pressure and reaped. Status reports a memory limit with the peak footprint and the termination cause (ceiling or critical pressure). The source, undo history and last-good scene survive, and Retry Preview with a higher limit works after ceiling terminations. |
| Result validation | Missing or non-executable helper, worker from another build, unsupported protocol version, triangle owner naming a missing instance, operand range outside `operands.bin`, span past the end of its file, unknown winding value | Each result is rejected with a packaging or protocol error before any scene, handle or highlight uses it. Recovery follows the Failure recovery row. |
| Failure recovery | Invalid code, valid empty `difference`, missing asset later created, child exits mid-write, corrupt mesh or protocol mismatch | Source stays editable and saveable. Valid empty clears prior geometry; errors preserve last-good geometry visibly stale, show the current reason and disable old bindings. Creating the missing asset triggers reevaluation without touching the main file. |
| Resource bounds | Huge loop count, extreme `$fn`, oversized asset, diagnostic flood, truncated or oversized payload | Job fails within its configured limits; the child is reaped, job files are reclaimed, no partial scene commits and the document stays editable. |
| Diagnostics | Error, warning-only, deprecated and repeated messages | Severity is mapped, spans attach when available, repeats collapse with a count, and warnings leave independently verified bindings available |
| Library roots | Library in `~/Documents/OpenSCAD/libraries`, `OPENSCADPATH` set with `launchctl setenv`, a root added in Preferences, Documents access denied, same `use <...>` name in a Preferences root and in the user library folder | Resolution order and geometry match the reference CLI given the same explicit roots; the reference CLI also searches its own user library and bundled folders, so any divergence caused by differing bundled folders is recorded as a documented difference. No library access happens at launch. Denial names the root in a diagnostic and leaves the document editable. |
| Data dependencies | `surface(file = "terrain.png")` and a `.dat` heightmap, `text()` with a bundled font, the heightmap replaced on disk, a DXF lookup supported by the pin and a resolved font replaced in a controlled test resource root | Each file appears in the file table with its kind. Replacing it invalidates the scene and reevaluates without a source edit. |
| Files | External replacement while clean and dirty, autosave conflict, read-only dependency, sibling library in two documents | Dirty bytes survive. No silent overwrite. Dependency changes invalidate previews even when source is unchanged. |
| Document registration | Finder Open With, double-click when selected as default, drag-to-open, `open -a` and File → Open for a SCAD file | The app receives the file and opens it as an editable document; a read-only file opens for inspection and Save As creates a writable copy. |
| Main file removal | Clean and dirty documents whose file is deleted, renamed or moved on disk | In-memory bytes survive; the app does not silently recreate the old path; Save As chooses a new location; the logical URL changes only after the user accepts it. |
| Text system | Line-number ruler, diagnostic markers, find bar, IME composition and a generated 20,000-line file | The text view stays on the recorded TextKit version for the whole session. Typing meets the main-thread latency budget recorded with the M1 TextKit decision, and scripted scrolling of the generated file shows no dropped frames. |
| Navigation | Mouse wheel, trackpad scroll with momentum, Shift+trackpad scroll, pinch, right-drag, motionless right-click, each standard view, orthographic projection, orbit/pan swap preference | Each input produces its documented camera change; wheel and pinch zoom about the cursor; momentum after a handle drag is ignored; the context menu opens without panning, in both swap modes. Picking and handle drags hit the point under the cursor through the same projection used for rendering, in both perspective and orthographic views. |
| Autosave | Autosave during IME composition, during a drag and with a pending external conflict; Undo back to the saved bytes; Revert; restoring an earlier version | Autosave never writes uncommitted composition text or a tentative value and never overwrites a pending conflict. Undo to the saved bytes shows the document unedited. A restored version gets a new baseline and cancels gestures. |
| Cloud and partial files | Open a main file that is still an iCloud placeholder; an included file evicted while open; a dependency rewritten in place while a job reads it | Opening never blocks the main thread and shows progress. The job waits for the dependency or reports a diagnostic. A digest mismatch, including a same-size rewrite with a restored timestamp, invalidates the job and triggers reevaluation. |
| Native UX | IME composition, including Undo from the Edit menu, Revert, an external reload, a conflict resolution, a pending graphical patch and a background highlight pass while text is marked, Retina pick, pick after moving the window between displays of different scale, document windows, dark mode, keyboard-only inspector, VoiceOver | Selection and ranges survive refresh. Held mutations run only after the composition is committed or cancelled, against re-verified preconditions, no evaluation is scheduled from marked text, and highlighting never changes attributes inside the marked range. Controls are discoverable and the active window owns Undo. |
| Accessible model | VoiceOver from outline to inspector; selection change, committed edit and scene failure | The selection summary, scope, evaluated value and scene state are announced without sight; the same property is reachable from the outline and inspector alone. |
| Multi-window document | Two windows of one `NSDocument`; edit or undo from either while the other holds a selection or gesture | One buffer and one undo stack; no duplicate undo entries; both selections re-anchor or clear safely |

## Build and verification entry points

The agent creates the engine and verification scripts in M0–M6. The commands below are acceptance interfaces for the future repository. They have not been executed against a Scadretto application. The repository already provides `Scripts/build.sh` and `Scripts/release.sh` as the supported app-build and release-tag wrappers; the raw `xcodebuild` invocations remain the underlying commands.

```sh
./Scripts/bootstrap-macos
./Scripts/build-engine
./Scripts/verify-engine
Scripts/build.sh --debug
swift test --package-path Packages/ScadrettoKit
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto -destination 'platform=macOS,arch=arm64' test
./Scripts/verify
./Scripts/package-macos --local
Scripts/release.sh --preflight 1.2.3
```

`verify-engine` runs worker contract, source trace and reference comparisons. It also replays `Engine/patches/` onto a clean checkout of the pinned revision and fails on any divergence, so the documented patch series is always the one the worker was built from. `verify` runs the deterministic package, integration and application test suites and reports machine/toolchain metadata. GitHub Actions runs repository script checks on every pull request and push to `main`; wire the pinned engine checks into CI in M0 and the package tests and app build in M1, as described in [the build and release guide](../CICD.md). For XCTest UI automation use a logged-in macOS runner that permits UI tests. A headless CI host can run core and worker suites; mark GUI coverage pending until the UI suite runs. Make all failures nonzero and preserve relevant source diffs, diagnostics and fixture names in CI artifacts. Successful local CI must not require release credentials.

## Performance targets

Treat these as initial engineering budgets. Report observed p50/p95, sample count, hardware, OS, revision, backend and cold/warm state. Use release builds on a declared baseline such as an M1 with 16 GB RAM or equivalent. Re-run after pin changes.

Define each interval precisely and log it per commit. For “commit to accepted shaded frame,” start when the committed transaction mutates the buffer and end when a frame built from the matching `EvaluationKey` is presented; report queue wait, worker wall time, decode/BVH time and presentation separately. For the warm commit latency budget, initialize the app and GPU pipeline, discard five warm-up commits, then measure at least 30. Include the per-evaluation child launch in each sample. Measure cold app launch and resource initialization separately, retaining first samples. Record dropped frames and main-thread hitches alongside worker latency so slow decoding cannot hide behind an average.

| Workload | Measurement | Target |
|---|---|---|
| Canonical plate | Warm, commit to accepted shaded frame over 30 edits, excluding typing debounce | p95 under 1 second |
| Active drag and orbit | Twenty seconds of interaction with the plate; then repeat with 100 valid repeated cutters on a larger plate | p95 frame time at or below 33 ms; a cut can update on commit |
| Typing while worker is busy | 100 paced edits while running the larger pattern | p95 main-thread edit handling under 16 ms; zero stale scene commits |
| Cancellation and cleanup | Alternate 50 distinct jobs, supersede or close repeatedly, then quit normally, force quit and `kill -9` the app during a long evaluation; inspect children and private job storage after settling and after the next launch | Zero orphaned workers and zero abandoned completed jobs; record peak memory and termination latency |

### Stress workload

`Tests/Fixtures/stress-100-cutters.scad` is the larger pattern named in the table above. It is a `2010 × 40 × 6` plate with 100 through-holes of diameter 4 on a 20-unit pitch starting at X = 15, cut with `$fn = 32`. Its bounds are `[0,0,0]` to `[2010,40,6]`; the bore centers are X = 15 + 20i for i = 0…99 at Y = 20. The expected solid volume is `2010 × 40 × 6 − 100 × 6 × (32/2) × (4/2)² × sin(2π/32)`, following the same regular-polygon convention as the canonical fixture.

Use this fixture for the drag/orbit and typing workloads and for the cancellation series. Derive variants from its module and loop shape rather than hand-editing a second copy. Record the fixture's SHA-256 with every benchmark result; changing the fixture invalidates stored percentiles.

## Distribution gate

1. Build an arm64 Release app for the declared deployment target. Put the child executable in the app's helpers location, dynamic libraries in Frameworks, and engine resources, licensed fonts and the compiled Metal shader library in bundle resources. Resolve paths relative to the executable or bundle. Run `file`, `otool -L` and deployment-target inspection recursively and flag developer-machine or Homebrew paths. Check every Mach-O file's minimum OS with `vtool -show-build`, which reports `LC_BUILD_VERSION` or the older `LC_VERSION_MIN_MACOSX`, and flag any minimum newer than the declared deployment target. Inspect `otool -l` `LC_RPATH` entries with the same recursion and flag absolute or Homebrew paths, which `otool -L` does not show.
2. Inventory the exact licenses of the pinned OpenSCAD sources, patches, grammar, runtime and redistributed dependencies. Include attribution and license texts, and prepare the corresponding worker source and reproducible build scripts for distributed binaries. Make the application licensing and publication decision explicitly before public release. Process separation alone does not settle licensing. [OpenSCAD COPYING](https://github.com/openscad/openscad/blob/master/COPYING)
3. Keep `--local` ad hoc signed and usable without an Apple developer account. For external distribution use the owner's real bundle ID and Developer ID Application identity, hardened runtime, timestamp, and inside-out signing of nested code. Notarization requires the hardened runtime on every executable, so sign the worker itself with it and the same identity, not only the app. Sign every bundled dylib with that identity so the worker's library validation accepts it. Start the worker with no entitlements and add one only with a recorded reason. Verify each nested item with `codesign --verify --strict`, and record the identities and entitlements in the release report. Test the packaged ad hoc worker locally. For Developer ID distribution, package the signed app, submit through `notarytool`, check acceptance, staple to a supported artifact, then verify the final distributed bytes and assess the notarized, stapled app with `spctl --assess`. Keep signing credentials outside source control. [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
4. On a clean supported Mac, launch the quarantined distribution artifact, use Help → Open Example offline, drag in the untitled copy, save it outside the bundle and reopen the saved file. Check the helper starts and finds fonts, imports, libraries and shader resources with developer paths absent. A signed app that starts but cannot launch its child fails this gate. The bundled example is present, is byte-identical to the canonical fixture, and opens offline from a clean install.
5. Record the package hash, macOS versions tested, hardware, app/worker SHAs, test results, attribution/source location and notarization status. Claims for minimum OS support require a run on that OS. Label a build “local development” while credentialed distribution is pending.

## Implementation references

- [OpenSCAD CLI](https://en.wikibooks.org/wiki/OpenSCAD_User_Manual/Using_OpenSCAD_in_a_command_line_environment) and [upstream build instructions](https://github.com/openscad/openscad). Use the reference build's own `--help` output for the exact export/backend flags in the pinned revision.
- [Gonzalez and colleagues' OpenSCAD prototype](https://cil.csit.carleton.ca/bidirectional-programming-csg-cad/). The descriptions of affected elements and ghost cutters are especially relevant to the selection tests.
- [BelfrySCAD source-rewrite notes](https://github.com/BelfrySCAD/BelfrySCAD/blob/main/docs/wysiwyg.md). Compare the documented expression-delta behavior with Scadretto's explicit edit scopes.
