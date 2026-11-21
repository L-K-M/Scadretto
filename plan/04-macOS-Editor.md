# macOS document editor and interaction

Build the application around `NSDocumentController`, one `ScadrettoDocument` subclass, a document window controller and native menus. Use an AppKit split view for the editor, viewport and inspector. Small SwiftUI inspector controls may be hosted in AppKit if they preserve first-responder behavior and the document undo stack. Use an `MTKView` for geometry. [Apple document architecture](https://developer.apple.com/documentation/appkit/nsdocument) · [MetalKit view](https://developer.apple.com/documentation/metalkit/mtkview)

## Window and commands

| Surface | Required behavior |
|---|---|
| Source editor | Plain monospaced text, line numbers, syntax colors, find, diagnostics, jump-to-range, and selection synchronized on explicit navigation. Disable smart quotes, substitutions and rich text. Keep normal typing focus when the preview refreshes. |
| Viewport | Shaded solid, orbit, pan, zoom, frame model and frame selection. Display local or world axes as applicable, selected outline, cutter overlay and editable handles. Preserve camera across reevaluations. |
| Inspector | Selection breadcrumb, source location, authored expression, evaluated value, available edit scopes, affected occurrence count and reason for any disabled edit. Support numeric entry with Enter to commit and Escape to cancel. |
| Instance outline | Display expanded module calls, loops, primitives and boolean operands. Distinguish the selected occurrence from the shared definition. Virtualize large subtrees and let users select enclosed operands. |
| Dependencies | List the files the current evaluation resolved, with logical path, digest, writability and whether each is still current; selecting one reveals its source or opens it in a separate document. Mark unresolved candidates and stale entries. |
| Status area | Report evaluating, ready, valid empty model, preview out of date, cancelled, source diagnostics and worker failures. Make the current failure and source location reachable with the keyboard. |
| File and Edit menus | New, Open, Save, Save As or Duplicate as appropriate for native document mode, Revert, Undo, Redo and Find. Register `.scad` as an editable document type. Keep Finder and drag-to-open working. |
| View and Model menus | Toggle editor/inspector/outline, frame selection, reevaluate, cancel evaluation, reveal source and choose an edit target. Provide accessible alternatives to viewport gestures. |

A second document gets separate selections, worker requests, camera, diagnostics and undo history. Windows belonging to the same `NSDocument` share the one source buffer. Store window presentation preferences separately from the `.scad` bytes.

## Code editing and diagnostics

1. Build `NSTextView` inside a scroll view. Use a delegate or text-storage adapter to convert actual replacements to byte patches. Group typing using native editing conventions. Choose one registration route for typing and one for programmatic transactions, both backed by the document undo manager. Guard against delegate reentry when mirroring a patch.
2. Apply syntax colors as presentation attributes. Isolate highlighting from the undo stack and edited state. Preserve marked text for input methods, selection and scrolling. Resolve diagnostics through the byte/UTF-16 converter. Never reposition the insertion point just because a background render finished.
3. Connect caret or an explicit “Reveal in Model” action to the nearest syntax call and current scene. When one statement generates several instances, highlight the group and allow navigation to an individual instance. On a viewport pick, highlight the corresponding code expression without taking keyboard focus unless “Reveal in Source” was invoked.
4. Keep editing, saving and undo functional while the last-good preview is stale. Disable source-writing handles until the current key has valid geometry and bindings. For an empty valid model, clear the old solid and retain navigation for surviving source diagnostics. If no valid snapshot has ever existed, show a blank viewport with the actionable diagnostic.

## Viewport gesture contract

| Gesture | Feedback during gesture | Commit |
|---|---|---|
| Orbit / pan / zoom | Camera changes, rendered model and overlays track it | Camera state only |
| Click a visible surface | Highlight selected occurrence, code range, scope and related instances | Selection only |
| Click an ambiguous edge | Show a short ordered list of candidate operands plus their source locations | Select exactly the chosen candidate |
| Select an outline operand | Show ghost geometry, including material removed by a difference | Enable equivalent inspector controls |
| Drag a supported handle | Show axis, origin, current dimension or delta, target expression and affected instances | Apply one verified patch on mouse-up |
| Escape, zero delta or change of document revision | Restore the last accepted drawing and label | No source mutation |

Start with click to select, ordinary drag on an explicit handle, background drag to orbit, Shift-drag to pan and scroll/pinch to zoom. Disambiguate a click from a drag with a small movement threshold. Respect backing scale when converting window coordinates to drawable pixels. Convert between AppKit's view coordinates and Metal's viewport convention exactly once. Test on a Retina display and with a resized viewport. A keyboard user must be able to reach the same property by outline and inspector alone.

Give handle hits priority over object hits only while the handle is visible and a compatible operation is selected. Orient drag handles to their advertised frame. Use a projected axis or an axis-aligned drag plane; when ill-conditioned, show numeric entry. Honor a visible snap increment measured in model units. Recalculate the candidate value from mouse-down baseline each frame so snapping and round-trip motion do not accumulate floating-point error.

### Example interaction

Click the inner cylindrical wall of hole three on the fixture. The breadcrumb identifies the third iteration, `mounting_hole` and `cylinder`. The inspector shows `Diameter 4`, the expression chain `d ← hole_d`, and `Shared parameter · 4 cutters`. Selecting that shared target lights up all four cutters. Drag its radius handle outward 0.5 model units or type a diameter of 5. The overlay reports diameter 5. Releasing changes only `hole_d = 4;` to `hole_d = 5;`. The ordinary source editor shows the edited declaration. Undo restores diameter 4 and all four bores.

Use the same feedback for a local offset. A cheap moving outline or operand proxy is sufficient while dragging. Draw unchanged booleans in the existing shaded result and identify the moving overlay as a preview; update the actual boolean solid when the committed evaluation returns.

## Files, libraries and external changes

- Declare an imported type identifier conforming to plain text/source code and the `scad` filename extension. Respect existing type registrations. Support opening read-only files for inspection, with Save As to create a writable copy.
- Use coordinated document reading/writing and native safe-save behavior. Snapshot the bytes for saving. Mark only the saved revision as acknowledged when a newer edit arrived during the write. Integrate with native edited-state and autosave APIs, and test Save As to another directory.
- Track both a disk baseline digest and current unsaved bytes. When a clean main file changes externally, reload and reevaluate. For a dirty file, keep local bytes and present **Compare**, **Keep Editing**, and **Reload from Disk** with an explicit discard decision. After Keep Editing, preserve the conflict and make overwrite versus Save As explicit at save. Do not let autosave overwrite the external version while conflict is pending. Avoid reacting to the app's own coordinated saves as external conflicts.
- Observe resolved dependency files and their parent directories to catch atomic replacements and deleted/recreated files. Debounce duplicate notifications. Track an unresolved include or asset's candidate parent path so creating it can recover the preview. Record resource roots on each evaluation. A changed dependency invalidates current write-back handles immediately.
- Edit one active file per transaction in v1. Navigate to a dependency in a separate editor document when requested. Evaluate referring documents against their saved dependencies; label this behavior in the UI if an included file has unsaved edits elsewhere. Saving the dependency triggers reevaluation of affected parents.
- When the helper fails to launch or load a library, offer logs and Retry Preview. Always preserve the source. Treat the helper as a child process of a non-sandboxed, directly distributed application in this plan. Its process boundary gives crash isolation; any later sandboxed distribution needs its own file-access design.

## Accessibility and native acceptance

Give controls accessible labels that include the property and scope, expose selected/disabled state, and announce render failures concisely. Pair colors with outlines, labels or glyphs. Use dynamic system colors, visible keyboard focus and a tab order through source, outline and inspector. Add accessible identifiers for UI tests, including `sourceEditor`, `sceneOutline`, `targetScope`, `diameterField`, `viewport` and `renderStatus`. Check VoiceOver navigation, dark mode, high contrast, split-view resizing, multiple windows and native Save/Undo menu titles on a real Mac.
