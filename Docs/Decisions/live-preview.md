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
before accepting a scene. Use-file dependencies have the digest of the
buffer passed to the parser. The stream-based readers record the file at
the read boundary and the parent checks that digest again. M5 covers
coordinated replacements, provider hydration and concurrent file changes.

The Metal renderer receives decoded double-precision positions. CPU mesh
preparation subtracts a double-precision render origin before converting
vertices to float. The renderer uses a precompiled app metallib. The engine
process, payload decoder and mesh preparation run off the main actor. The
document window updates the console, outline and viewport from one accepted
request. It preserves the camera when a newer mesh or an empty model arrives.

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
  -resultBundlePath "$PWD/.build/m2/native-07.xcresult" \
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
three portable goldens also matched from a logical directory containing
Unicode and quotes. The raw engine run is under
`.build/engine/verification.xa93cKQV`.

The package suite exercises the three on-disk examples, decoder bounds and
links, a cube at X = 100,000,000, child signal and timeout handling,
bounded process logs, and replacement of an active request. All 35 package
tests and seven native UI tests passed. The native tests open the plate
from a path containing spaces. Editing `count` raises the
preview from 1,052 to 1,312 triangles, and the outline shows `i = 4`. A
captured frame records the five-bore result. The suite checks parser
failure and recovery, the empty model, diagnostic navigation to
`missing_parameter`, include deletion and recreation, and explicit preview
cancel and retry. It also reruns the M1 source fidelity, encoding, undo and
reopen tests. The viewport navigation test checks a Top view command, a
mouse orbit, and the contextual menu from a motionless right click. The
test display was 1,920 × 1,080 points at backing scale 1.

A separate Launch Services run opened a temporary copy of the plate with
`open -a` against the developer build. Cancelling the unsaved-quit dialog
retained the document and its preview. A subsequent disjoint cube edit
raised the visible count from 1,052 to 1,064 triangles. Quitting and
discarding that edit left the original fixture bytes on disk.
