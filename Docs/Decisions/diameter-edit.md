# Bidirectional cylinder diameter edits

The pinned OpenSCAD worker reports the rendered solid, executed occurrences,
local operand meshes and the argument chain for uniform cylinder diameter.
Scadretto builds a triangle index off the main actor for the final mesh and
one index per distinct local operand. The mounting plate has no face-owner
table. The application picks the first final surface and checks which operand
covers that same world point. It checks the plane and triangle boundaries
within `clamp(sceneDiagonal × 1e-8, 1e-9, 1e-5)` and requires normal alignment.
Reflection and subtraction change the operand normal convention. Multiple
matches lead to an explicit choice, and the outline is available for surfaces
without a matched operand.

A pick uses the scene identity and projection of a frame confirmed by
Metal's presented callback. Size and backing changes invalidate that mapping.
One native run reported presentation time zero for the first frame containing
the diameter grip. The viewport resubmitted the same current scene and mapping,
and the next callback confirmed presentation before the grip accepted a press.

The client resolves the worker's request-local file ID against the result
file table and verifies the main snapshot's identity, digest and byte length.
The final literal must occupy the exact initializer or supplied argument span.
The editor checks that range against a numeric token in the current Tree-sitter
snapshot. In the plate, the third cutter leads through `cylinder` and
`mounting_hole` to `hole_d`. The affected set includes four executed cutters
with that same authored span. Scope counts describe traced cutters in the
current evaluation. Expressions and dependency-file targets remain inspectable.

The grip moves along the cylinder's local radial axis using a world-space ray.
The overlay shows the proposed diameter and the traced cutters during the drag.
Release checks the scene, selected occurrence, syntax token and expected bytes
before applying a document transaction. The inspector's numeric field uses the
same transaction. A click without motion and Escape both leave the buffer and
undo stack intact. One edit of the diameter creates one named undo action.

## Verification

Local checks used a Mac16,9 with Apple M4 Max and 36 GiB RAM, macOS 27.0.1
(26A434), Xcode 27.2 (27B52), SDK 27.2 and Metal Toolchain 27B47. The
native tests used a 608 × 638 point viewport at backing scale 1. The OpenSCAD
revision was `1c9c8441586eeade3f73a4cd5db575659a9acb5f` with Manifold
`ce50d78021d64507f89e8c9fc2c2e51018117857`.

```sh
swift test --package-path Packages/ScadrettoKit
Scripts/build.sh --debug
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath "$PWD/.build/m3/DerivedData" \
  -resultBundlePath "$PWD/.build/m3/native-suite-02.xcresult" \
  CODE_SIGN_IDENTITY='Apple Development' test
Scripts/verify-engine --saved-plate '.build/m3/Native Saved Mounting Plate.scad'
```

The 48 package tests also passed from outside the checkout. The plate test
decoded the pinned golden and cast the horizontal ray
from inside the third bore, and matched instance 13 at iteration 2. The
binding produced bytes `[74,75)`, and the syntax tree confirmed the numeric
token there. An independent projection test moved the grip 0.5 along its
local radius and produced diameter 5 with snapping off.

The native tests selected the bore by a projected point on the actual
shaded wall. The keyboard test preserved an equal `d = 4` in an unrelated
call. The mouse test used native mouse-down, motion and release with a
0.5-unit snap increment to reproduce the exact value on a display with
finite input precision. It checked the single source edit, undo, redo,
typing the fifth occurrence, save and reopen. The inspector showed five
traced cutters after reevaluation and after selecting the reopened bore.

On a fresh test copy, a native drag with snapping off displayed a draft
diameter of `5.00032103122`. Escape while the button was held removed the
draft before mouse-up. The source stayed byte-identical and native Undo
was disabled. Deleting the closing brace made the preview stale and the
diameter field unavailable. Typing the brace restored the field and the
original buffer. The event and accessibility records are in
`.build/m3/escape/`.

The saved attachment extracted from the native mouse test is
`.build/m3/Native Saved Mounting Plate.scad`. It differs from the canonical
fixture at byte offsets 74 and 85 and has SHA-256
`a637b502f40665240a7b74747bbf434e23095c3cc7766d9a247f97d7526fcfeb`.
The verifier measured five centers at X = 15, 35, 55, 75 and 95, worker
volume `28211.89715802264`, reference volume `28211.897132616563` and
symmetric difference `0.0002453918871208015`. The unmodified reference STL
and comparison record are under
`.build/engine/verification.kNkphkGn/v1/app-saved-plate/`.
