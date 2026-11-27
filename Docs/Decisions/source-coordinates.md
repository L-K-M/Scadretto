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
`ch.lkmc.scadretto.scad`, conforming to `public.source-code`, with the
Editor role and Alternate handler rank. The native document controller
owns opening, safe save, Save As and Revert. The M1 shell saved only on
request; M5 turns on autosave in place once the disk checks below exist.

The document does not follow a file that another program moves.
`NSDocument` adopts the new location by default once the old path has
stayed empty for a moment, then offers to save there, which overwrote a
backup in a native regression test. The URL changes only through Save
As. Measured on macOS 27.0.1, a plain delete sends no presenter notice,
and a coordinated replacement sends a deletion notice before its change
notice. Handlers must check the path's contents rather than trust the
kind of notice.

`DiskBaseline` in `ScadrettoCore` holds the bytes the document last
read or wrote and classifies each read of the path. The document reads
the path, under coordination and off the main thread, after a presenter
notice, when the app becomes active (a plain delete sends no notice)
and before Save. A document without edits reloads a changed file. With
unsaved edits it offers Compare, Keep Editing and Reload from Disk, and
Save asks before overwriting. The approval covers only the reviewed
version, so a later change needs a new decision. A missing file keeps
the text and offers Save As. A moved file is followed only through Use
New Location. A conflict marks the document edited until resolved.
Checks wait for a running save or text composition. Once the path is
checked, Save calls `save(to:ofType:for:completionHandler:)` directly,
because AppKit's Save asks again about a move the user has accepted.
`writeSafely` rechecks the bytes inside the coordinated write.

Documents autosave in place, about 15 seconds after an edit on macOS
27.0.1. An autosave writes the committed bytes and moves the disk
baseline. The window stays edited until Save, and Revert to Saved
restores the last opened or saved version on disk as well as in the
editor. An autosave waits while text is being composed, while another
program's coordinated write is under way and while an external change
is pending. It resumes when that clears. Closing and quitting finish a
composition and autosave the text. With a pending change, closing or
quitting asks Save As, Cancel or Don't Save instead of closing with the
text unsaved. Opening the menu bar during a dead-key composition
cancels it; that is the input system's behavior.

Several AppKit defaults had to give way, each found by a native test:

- `presentedItemDidChange` reverted an autosaving document AppKit
  thought was clean, discarding text typed while another writer held
  the file. The document no longer calls it and reloads only through
  `DiskBaseline`.
- NSDocument observes its undo manager. When a group closes it waits on
  the main thread for any running save or close, and Scadretto's typing
  groups close on a timer, so closing right after typing hung on the
  document activity semaphore (sampled), and an autosave finished later
  from AppKit's close crashed it. The source's undo history is now
  private to the document, which reports each edit, undo and redo
  through `updateChangeCount`. AppKit's check before the first edit of
  an old file or one in Downloads ran from those notifications and no
  longer does; its check when a document opens still runs.
- AppKit decides from `hasUnautosavedChanges` whether closing or
  quitting needs an autosave. It also counts marked text and compares
  the committed bytes with the baseline.
- AppKit's close and quit sequences expect an autosave to hand over to
  `super` before it returns. The path check is therefore synchronous
  and uncoordinated; `writeSafely` checks again inside the coordinated
  write.
- AppKit's own autosave compares modification dates and offers a Revert
  that discards the local text. Each autosave first reads the path and
  applies it through `DiskBaseline`, so a change already on disk raises
  Scadretto's question instead. A plain write that lands between that
  check and AppKit's write is not covered and would bring up AppKit's
  alert; no test produces that timing. `writeSafely` still refuses a
  write over bytes the document has not agreed with.
- AppKit's Revert restores a version it records from undo
  notifications, which the private history no longer sends, and with
  autosave in place it removes a menu item whose action is that revert.
  Revert to Saved therefore puts back the bytes last opened or saved,
  clears the undo history and writes them through the checked Save, so
  a pending external change still gets its question. Browsing earlier
  versions is not offered yet.

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
