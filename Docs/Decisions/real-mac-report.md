# M5 real-Mac report

M5 closes with a report from a real Mac on trackpad input, Retina picking,
VoiceOver and external editing. This one comes from an automated agent on a
shared development Mac. It records what ran there and names each check that
still needs a person or other hardware.

## Machine

Mac16,9 (Apple M4 Max, 36 GiB), macOS 27.0.1 (26A434), Xcode 27.2 (27B52).
One 1920 × 1080 display at 60 Hz and backing scale 1. The Swiss German
keyboard layout. Input came from XCUITest, which synthesizes mouse and
keyboard events; nobody touched a trackpad. Other agents shared the Mac and
its screen, under a lease that gave one agent the desktop at a time.

## Ran on this Mac

The UI test plan runs the real application bundle with its bundled worker.
On the M5 branches it passed in full: 29 of 29 tests with the three
benchmark tests skipped (`m5-stack-full-01`), plus the settings, exercise and
import tests added alongside (each passed in repeated runs). Failures seen
along the way came from other agents' windows taking focus or from
"Timed out while synthesizing event" under load, and passed on rerun; the
pull requests list them.

- **External editing.** A clean document reloads a change made by another
  program; a document with unsaved edits asks first, and asks again after a
  second change; a moved file is followed only when accepted; a file moved
  away or removed is not recreated and offers Save As; a backup rename does
  not redirect Save; a coordinated writer holding the file wins over
  autosave; autosave writes committed text in place, never over a pending
  conflict, and Revert restores the saved version.
- **Dependencies.** Unsaved edits in an open dependency are labeled in the
  parent until saved; a missing include and a relative STL import recover
  when their files return; library folders from Settings re-evaluate open
  documents, including a renamed folder.
- **Text input.** Dead-key composition on the Swiss German layout holds
  autosave until the composed character is committed; typing, closing and
  quitting right after typing keep the text; undo and redo work from the
  menus in each document and across two windows of one document.
- **Viewport.** Mouse orbit, pan and menu navigation change the rendered
  frame; diameter and pitch handles drag, cancel with Escape and survive save,
  undo and reopen; coincident surfaces offer every matching instance.
- **Resilience.** A worker stopped at its memory budget recovers on the next
  edit.
- **Accessibility.** The announcements for scene state, selection and
  committed edits, and the inspector's accessibility summary, as described in
  [the live preview record](live-preview.md).
- **Performance.** See [the performance record](performance.md).

## Not verified here

| Check | Why not | What it needs |
|---|---|---|
| Trackpad: scroll with momentum, Shift-scroll, pinch | XCUITest sends mouse events only, and no person used the trackpad | A person on a Mac with a trackpad, following the Navigation row of the regression matrix |
| Retina picking, and picking after moving a window between displays of different scale | The only display runs at backing scale 1 | A Retina display, or two displays of different scale |
| VoiceOver speech and navigation from outline to inspector | The tests read the announcement log and the accessibility tree; running VoiceOver under automation would change a system security setting on a shared Mac | A person with VoiceOver on, following the Accessible model row |
| macOS 14 | Only macOS 27.0.1 was available | A Mac or virtual machine running macOS 14 |
| Comma-decimal system locale | Not changed on a shared Mac | A run with a comma-decimal region setting |

XCTest also reported a priority-inversion warning ("Thread running at
User-interactive quality-of-service class waiting on a lower QoS thread")
during three UI tests, marked `[Internal]`. It has not been traced to app
code.
