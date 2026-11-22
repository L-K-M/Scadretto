# Source coordinates and the document shell

The app uses TextKit 1 explicitly through `NSTextView(usingTextLayoutManager:
false)`. Its line-number ruler enumerates the visible layout fragments.
Syntax highlighting uses temporary layout attributes, so applying a
highlight leaves source bytes and undo history alone. A future move to
TextKit 2 needs a ruler based on `NSTextLayoutManager` fragments.

`SourceBuffer` stores the original UTF-8 bytes. It exposes a display string
with LF line breaks and hides the leading BOM from AppKit's UTF-16
coordinate space. A table of scalar boundaries maps half-open byte ranges
to UTF-16 ranges and back. A graphical or programmatic patch must verify
its original source slices. A native text edit uses the surrounding line
ending for new separators. Save serializes the byte buffer instead of the
display string.

OpenSCAD's pinned macOS bundle declares the `.scad` extension and gives
no exported type identifier. Scadretto imports
`com.lkm.scadretto.scad`, conforming to `public.source-code`, with the
Editor role and Alternate handler rank. The native document controller
owns opening, safe save, Save As and Revert. Autosaving is disabled in
the M1 shell while explicit saves verify the bytes last read or written
at the document URL.

## Text system measurements

On a Mac16,9 with M4 Max and 36 GiB RAM, macOS 27.0.1 (26A434), Xcode
27.2 (27B52) and SDK 27.2, compare the two TextKit initializers with the
same 20,000 generated comment lines plus one edited line.

```sh
mkdir -p .build/m1
swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
  Packages/ScadrettoKit/Sources/ScadrettoCore/SourceBuffer.swift \
  Tests/Benchmarks/TextKitBenchmark.swift -o .build/m1/benchmark
.build/m1/benchmark
```

The generated input has 388,896 bytes and SHA-256
`7b564f03a1e0a8c122cbcc5cf8044f5d37b4f99a815bb4d0f26435cc5df43969`.
Timing starts before the checked source transaction and ends after the
matching text-storage edit and `didChangeText`. The scroll samples measure
clip-view movement and layout in an unhosted AppKit view. Timing excludes
syntax work, the event queue and display presentation.

| Text system | Typing p50 and p95 | Scroll layout p50 and p95 |
| --- | --- | --- |
| TextKit 1 | 4.702 ms and 4.864 ms | 0.004 ms and 0.006 ms |
| TextKit 2 | 2.438 ms and 2.598 ms | 1.386 ms and 1.605 ms |

Typing has 30 samples after five warmup edits. Scroll layout has 120
samples. The initial main-thread typing budget is p95 under 16 ms. The
TextKit 1 result is within that budget for this test and gives the ruler
a single layout API for the whole session. Frame pacing and typing while
a geometry worker is busy will be measured in M5.

## Native document verification

On the same M4 Max Mac and toolchain, the native `Scadretto` scheme ran
three UI tests on a logged-in desktop. The system Open panel opened
`editor-bom-crlf.scad`. Saving immediately preserved the original bytes.
After keyboard replacement of `9` with `10`, File → Save wrote exactly
the bytes of `editor-bom-crlf-edited.scad`. File → Close and a second Open
displayed `10`, and the byte comparison still passed. File → Revert to
Saved discarded a subsequent unsaved edit and restored the saved text.

Another test used Edit → Undo and Redo on separate Alpha and Beta
documents, then confirmed each document retained its original disk
contents. The invalid UTF-8 test verified that the system error panel
names the first bad byte and that no editor opens for the invalid file.
Opening a file exercises AppKit's concurrent document creation and read
callbacks. A small Objective-C base initializer preserves that AppKit
entry point on Swift 6 toolchains. The editable model is created and
updated on main.

```sh
swift test --package-path Packages/ScadrettoKit
Scripts/build.sh --debug
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath "$PWD/.build/m1/DerivedData" \
  -resultBundlePath "$PWD/.build/m1/native-12.xcresult" \
  CODE_SIGN_IDENTITY='Apple Development' test
```

The UI run completed with zero failures. The package's nine tests cover
raw encoding errors, checked patches and inverses, separate source models,
and actor-isolated syntax parsing against the mounting plate's worker byte
ranges. Minimum-OS, input-method and native coordination checks remain in
M5 and M6.
