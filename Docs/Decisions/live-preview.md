# Live preview and worker protocol

The application sends each evaluation to a separate process. The desktop
app gives all documents one scheduler with two active slots, at most one
running job per document, and one pending replacement per document. A
closed or superseded request is terminated and reaped. Each worker also
has a lifetime pipe so parent exit stops native evaluation. The scheduler
passes an explicit environment and uses a private, locked session directory.
The versioned font cache lives outside individual jobs. The worker acquires
its cache lock on first font use.

The protocol and three portable example jobs are under
[Engine/protocol](../../Engine/protocol/README.md). The worker checks the
executable digest, the original source digest and the resolution and option
digests. It writes binary geometry before publishing the result manifest.
Swift checks identity, exit status, file spans, instance and operand links,
transforms, and every decoded payload range. A failed model retains the
previous mesh with stale styling. An accepted empty model clears it.

The worker records the search candidates actually tested by OpenSCAD.
The application watches consumed paths and the nearest existing directories
for missing candidates. It checks observed digests and the winning path
before accepting a scene. The new watch can deliver events to the document
before that last check begins. A recheck follows newly created directories
and replaces watches when a path now names a different inode. A `use` file
has the digest of the buffer passed to the parser. Stream-based readers
record the file at the read boundary and the parent checks its digest again.
M5 covers coordinated replacements, provider hydration and concurrent file
changes.

Settings (Command-comma) lists the ordered library folders searched before
`OPENSCADPATH` and `~/Documents/OpenSCAD/libraries`, and the preview time
limit: 1 to 3,600 seconds, 20 by default. Both live in the app's defaults.
A change re-evaluates every open document under a new dependency
generation, because a different folder order can choose a different file
while the source stays the same. A change written elsewhere, such as with
`defaults write`, also refreshes an open Settings window, so its next edit
does not write an older list back. UI tests clear both settings with the
hidden launch default `ScadrettoResetPreviewSettings`. In
`testLibraryFoldersReevaluateOpenDocuments` an unresolved `use` resolves
when its folder is added, a folder moved ahead with the same file name
wins, and removing it brings back the first file. The test file stays
unchanged. `testPreviewTimeLimitComesFromSettings` stops a long evaluation
at a one-second limit.

The Metal renderer receives decoded double-precision positions. CPU mesh
preparation subtracts a double-precision render origin before converting
vertices to float. The renderer uses a precompiled app metallib. The engine
process, payload decoder and mesh preparation run off the main actor. The
document window updates the console, outline and viewport from one accepted
request. It preserves the camera when a newer mesh or an empty model arrives.
A window covered by another one presents no frame. Its viewport draws again
when the window shows, so a scene that arrived while it was covered is
presented then.

An included or used file opens as its own document. The worker reads such
files from disk, so a parent's preview shows the saved state of a
dependency open in another window. The parent's status row names those
files until their text is written, and saving one re-evaluates the parent
through the dependency watch. `testUnsavedDependencyEditsAreLabeledUntilSaved`
checks the label, the unchanged parent preview while the part is unsaved,
and the new geometry after Save.

VoiceOver hears scene changes, the selection and committed edits as
announcements. A failure is announced at high priority with the status text,
and the next successful evaluation is announced once. Evaluations that end
the way the last one did stay quiet, so typing does not repeat "Preview
ready". An evaluation that runs longer than 1.5 seconds is announced as
evaluating at low priority. The inspector exposes its breadcrumb, property,
value and scope as one summary, which is announced when the selection or
property changes. A committed edit is announced with its old and new values
and its scope, which carries the affected count. The hidden launch default
`ScadrettoAnnouncementLog` writes each announcement to a file, and
`testVoiceOverHearsSceneSelectionAndEditChanges` checks that sequence. Speech
itself and VoiceOver navigation still need the manual check on a real Mac.

File > New Window opens another window on the same document. The windows
share the source buffer, the transaction path, the undo history and the
preview; each keeps its own camera and text selection. An edit made in one
window moves the other window's text selection with the text around the
change. The feature selection, inspector and handles live in one window at a
time: selecting in another window clears them in the first, so no handle
outlives a change it did not see. Composed text in one window is committed
before another window's edit, and that edit's keystroke is dropped with a
beep because its ranges predate the composed text. A property edit waits
while any window of the document composes. Later windows of a
document carry a number in their title, which also tells them apart in the
Window menu. `testTwoWindowsOfOneDocumentShareTextUndoAndSelectionSafely`
types in both windows, undoes both steps from either window until Undo is
disabled, moves the selection, edits a diameter and closes one window.

## Verification

The local run used a Mac16,9 with Apple M4 Max and 36 GiB RAM, macOS
27.0.1 (26A434), Xcode 27.2 (27B52), SDK 27.2 and Metal Toolchain 27B47.
The signed target deploys to arm64 macOS 14. The minimum-OS launch and
physical trackpad, Retina and VoiceOver checks are later release gates.

```sh
SCADRETTO_ENGINE_JOBS=10 Scripts/build-engine
Scripts/verify-engine
swift test --package-path Packages/ScadrettoKit
Scripts/build.sh --debug
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath "$PWD/.build/m2/DerivedData" \
  -resultBundlePath "$PWD/.build/m2/native-10.xcresult" \
  CODE_SIGN_IDENTITY='Apple Development' test
```

The worker comparison measured a symmetric difference volume of
`0.000176826853` for the plate against the pinned reference CLI. The
third cutter has iteration `2` and its diameter binding ends at raw
bytes `[74,75)`. Binary operands share the four identical local cutter
meshes. The portable golden omits ownership because this backend uses the
M0 surface-matching fallback. The verifier also checks the BOM warning span,
the selected search root before and after creating and deleting a preferred
copy, nested relative STL import, a DAT surface, and the bundled font.
The worker follow-up checks malformed root arrays, incomplete dependency
searches, and an occurrence limit exceeded after rendering started. The
three portable goldens matched from a logical directory containing Unicode
and quotes in `.build/engine/verification.xa93cKQV`. GitHub's upload step
rejected the quote in an evidence path after engine verification passed.
`.build/engine/verification.8YmtoamP` retains the run with an uploadable
Unicode path.

The package suite exercises the three on-disk examples, decoder bounds and
links, a cube at X = 100,000,000, child signal and timeout handling,
bounded process logs, and replacement of an active request. All 36 package
tests and seven native UI tests passed. The native tests open the plate
from a path containing spaces. Editing `count` raises the
preview from 1,052 to 1,312 triangles, and the outline shows `i = 4`. A
captured frame records the five-bore result. The suite checks parser
failure and recovery, the empty model, diagnostic navigation to
`missing_parameter`, include deletion and recreation, and explicit preview
cancel and retry. The include test creates a library directory before adding
its source file. The suite reruns the M1 source fidelity, encoding, undo and
reopen tests. The viewport navigation test checks a Top view command, a
mouse orbit, and the contextual menu from a motionless right click. The
test display was 1,920 × 1,080 points at backing scale 1.

A native MetalKit probe in `.build/m2/ViewportLayoutCheck.swift` handed a
triangle to a zero-sized viewport. After a 640 × 480 layout the camera
distance was `2902854.277` before the fix and `3.005` after it. A second
resize preserved the distance. The probe linked the viewport sources with
`swiftc -swift-version 6` and loaded the developer app's `default.metallib`.

A Launch Services run on the developer app used the View menu's native
accessibility checkmark. The menu reflected the saved Show Edges setting
on launch. Turning Show Edges off from the viewport context menu cleared
the checkmark in View. The copied plate remained byte-for-byte identical.

A separate Launch Services run opened a temporary copy of the plate with
`open -a` against the developer build. Cancelling the unsaved-quit dialog
retained the document and its preview. A subsequent disjoint cube edit
raised the visible count from 1,052 to 1,064 triangles. Quitting and
discarding that edit left the original fixture bytes on disk.
