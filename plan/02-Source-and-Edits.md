# Source transactions and editing rules

Implement the planning logic as pure code in `ScadrettoCore`. Given immutable source, an evaluated binding, an intent and a selection, it returns either a checked patch, a choice of explicit targets, or an inspect-only reason. Unit tests must be able to exercise this interface without opening a window.

## Coordinates and document format

- Support UTF-8 input, including an optional UTF-8 BOM. Retain the original bytes and newline sequences, including mixed endings and missing final newlines. For unsupported encodings show an open error with a reason. Never silently transcode a file on open.
- Define a source span as `(fileID, contentDigest, startByte, endByte)` with zero-based half-open offsets into the exact original bytes, including any BOM. Pass a BOM-stripped view to a parser if required and add its offset at the adapter boundary. Two file-ID domains exist and must not be conflated. Worker-produced spans carry *request-scoped* file IDs that resolve through that result's file table; the engine client translates them into *document-scoped* file identity by logical path and content digest before publishing a scene. `ScadrettoCore` and the edit planner operate on document-scoped identity, which has no worker request behind it. In v1 a span is writable only when it resolves to the document's main file; dependency-file ranges are inspect-only.
- AppKit selection and replacement use UTF-16 `NSRange`. Maintain a line-start index and convert at character boundaries. Treat an emoji, combining character, CRLF pair and tab correctly. When the text view normalizes a separator for display, maintain its mapping to original source bytes. Inserted lines use the surrounding line-ending convention. Do not rebuild all bytes from `NSTextView.string` on save.
- The worker must normalize its parser coordinates into those same byte ranges. Verify column origin and whether columns count bytes or characters on the pinned engine. If a range cannot be verified against the syntax tree and expected token, disable that edit and keep source navigation if possible.

## Patch contract

A patch contains `key`, `label` and one or more disjoint edits. Each edit holds `span`, `expectedBytes` and `replacementBytes`. For insertions verify a syntax anchor and adjacent context in addition to the key. At commit, confirm document identity, revision, dependency generation, file identity, span bounds and expected slices. Apply all replacements, highest offset first, in one transaction. Register an inverse against newly captured positions for undo, update the selection, then schedule evaluation. Any failed precondition changes nothing; refresh the inspector.

Keyboard edits modify the same buffer even with syntax errors. Graphical edits require a matching valid evaluation and verified bounds and binding. Undo and redo use document transactions and advance revision. During text input composition, defer conflicting graphical actions. Never register undo once in the text view and again in the document. Use a test that alternates typing, a radius edit, typing and three undos to exercise this.

### Undo and redo across revisions

Once a transaction commits, store its document-local before/after byte edits and logical selections in undo history. Keep inverse offsets in the post-edit buffer and forward offsets in the pre-edit buffer. Replay the top undo or redo group on the serial mutation path, checking the current source slices and history position. Each replay creates a fresh source revision and schedules evaluation. The original evaluation key guards the initial graphical commit only. Clear redo on a divergent edit and reset the history when an external reload replaces the document contents.

Test a width change from `9` to `10`, followed by typing before that literal. Invalidate a dependency and take the worker offline. Two Undos must restore the intermediate and original byte buffers in order. Two Redos must restore the edited buffers, including the shifted literal. Verify the native Undo and Redo commands throughout.

## Resolve the target before editing

Give each editable property its display name, model value, unit, defining expression, source span, resolved declaration when available, operation, impact set and available scopes. Derive bindings from the worker's executed parameter and argument links. Looking up a declaration solely by identifier text breaks shadowed variables, module defaults and calls with positional arguments.

| Source at the selected target | UI action | Permitted patch |
|---|---|---|
| `cube([10, 20, 30])`, Y dimension | Set Y to 24 | Replace only `20` with `24`. For `cube(10)` label the handle “uniform size”; changing it affects all axes. |
| `cylinder(d=4, h=8)`, diameter | Set diameter to 5 | `d=5`. If the authored parameter is `r=2`, the diameter handle writes `r=2.5`. Preserve positional versus named syntax. |
| `hole(d=hole_d)` where `hole_d = 4;` | Choose shared `hole_d` and set 5 | Patch the numeric initializer `4`. Highlight all currently executed dependents, including operations other than holes where known. |
| `hole(d=4)` used at a distinct call site | Set that call's argument to 5 | Patch the call's `4`. Other source calls remain byte-identical. A call site inside a loop may affect several occurrences. |
| `translate([wall/2, 0, 0])` | Explicit “Offset X here” of +3 in its local frame | Change the first component to `(wall/2) + 3`. The shared declaration and the other components retain their bytes. |
| `translate([10,0,0]) cube(8);` | Translate +2 on its local X axis | Replace just `10` with `12`. On a standalone untransformed supported call, an explicit move may insert a `translate([...]) ` prefix at its verified child-statement boundary. |
| `for (i=...) hole(...);` | Select an occurrence and attempt “only this one” | Explain that this statement generates multiple instances, highlight those affected and offer source navigation or the shared edit. No automatic loop rewrite in v1. |
| Imported mesh, computed list, unknown primitive signature, dependency-file declaration | Inspect | Show evaluated dimensions if available, read-only reason and source link where meaningful. Offer an explicitly supplied local call argument when its binding is proved. |

For tapered cylinders with independent radii/diameters, identify bottom and top separately. If a signature, implicit default or mixture of parameters cannot be mapped uniquely, display it read-only. Make the initial allowlist explicit in code: cube uniform size and vector elements, sphere `r/d`, cylinder `h/r/d/r1/r2/d1/d2` in unambiguous signatures, numeric named or positional module arguments with a resolved formal, top-level numeric literals, and `translate` vector elements. Generic `rotate` and `scale` remain inspectable in v1.

## Scopes, expressions and precision

1. Offer **This call site**, **Shared parameter** or **Offset here** only when the corresponding write target exists in the active document. Show the expression, file/line and number of affected evaluated instances. A call site in a loop is shared. Active branch counts describe the current evaluation only.
2. For a variable reference, follow runtime bindings through module arguments to the active declaration. Offer a declaration edit only for a verified writable numeric initializer. Local offset is a separately labeled action. Never replace a derived formula with its current numeric value.
3. Preserve the exact expression text when adding a local offset. Only fold or remove an existing offset if the application knows it created that exact syntax, verified by span and base expression fingerprint; an expression that merely resembles a generated offset is user-authored. After reopening, a fresh outer offset is acceptable. Preserve grouping around operators and comments, and ensure a closing parenthesis cannot be swallowed by a line comment. Otherwise disable the offset.
4. Produce finite decimal values with a dot separator, independent of the macOS locale. Locale-aware entry may parse `2,5` as user input; generated SCAD uses `2.5`. Preserve untouched literals byte for byte. Format touched values at the selected snap precision or enough significant digits to reproduce the requested value within the fixture tolerance. A click without motion and a value equal to the original produce an empty patch.
5. Enforce property constraints per operation. For direct size handles, accept positive finite dimensions; show a validation message on invalid entry. A model that the text author made degenerate still opens. Typing remains the full OpenSCAD editing path.

## Motion and transform math

Use Double precision for interaction math and the engine coordinate system, with Z up and lengths in model units. Label millimetres as a display convention where enabled. Rotation values are degrees in OpenSCAD. Matrix storage, handedness and vector convention are specified in [the worker contract](03-OpenSCAD-Worker.md#snapshot-and-geometry-conventions). Transform stack order affects which literal a drag should update.

For a translation nested under parent transform `P`, convert a world displacement to the writable vector's coordinate frame using the inverse linear part of `P`. For a scalar dimension handle, project the drag onto the transformed local axis and convert according to the anchored face or radius. Define diameter handles from the axis to the rim: one unit of local radial travel increases diameter by two. For a centered cube, enlarging with the opposite face fixed would require a translation as well. Use a symmetric resize about its center and label it accordingly. Use the original lower face for a non-centered cube. Disable a handle if the transform is singular, the active axis is edge-on and drag projection is unstable, or outward movement has ambiguous meaning. Keep numeric entry available for valid bindings.

For the initial pitch handle, recognize the exact semantic family `x0 + i * pitch` in an executed range loop whose `i` is a known scalar, with one explicitly selected literal-backed `pitch`. Verify bindings, local axis and downstream instances. Offer a spatial drag only when the binding trace proves that changing the pitch leaves the base offset, loop domain, selected occurrence and transform into the drag frame fixed. Keep explicit shared numeric entry when that independence is unknown. For selected occurrence `i ≠ 0`, `newPitch = oldPitch + localDx / i`. At `i = 0` choose numeric pitch entry or another occurrence. Resolve reversed or algebraically different expressions only after adding separate fixtures. Treat general expression inversion as future work.

## Acceptance examples

For the exact LF fixture in file 06, the initial diameter token occupies UTF-8 bytes `[74,75)`. Source evaluation starts at the selected cutter in iteration 2, follows the cylinder's `d` through the module's formal and the caller's `hole_d` expression, then identifies that initializer. The plan for setting diameter to 5 expects the single byte `0x34` and replaces it with `0x35`. In the same baseline, count is `[85,86)` and pitch is `[96,98)`. Use these offsets only as fixture assertions. Insert a non-ASCII character in the first comment and verify that rediscovery of the range still edits the intended literal.

- With the plate fixture, diameter 4 → 5 changes just the `4` in `hole_d = 4;`. An immediately following undo restores the entire original file byte for byte.
- In `rotate([0,0,90]) translate([10,0,0]) cube(2);`, dragging along world +Y by 2 updates local X to 12. An attempted drag mapped through a zero-scale parent is unavailable.
- Repeat the pitch example with `pitch = 20; x0 = pitch;`. At `i = 2`, changing pitch to 22 moves X from 60 to 66. Suppress the +4 drag and leave its source and undo depth intact. An explicit numeric pitch edit to 22 still moves the occurrence to 66.
- A module-local `d` shadows a top-level `d`. Changing the instance's explicit argument updates that call; selecting the shared root initializer is available only where the runtime path actually reaches it.
- With an emoji before a literal, CRLFs and an inline comment after the literal, the single changed byte range exactly matches the number. An external change arriving between mouse-down and mouse-up aborts the patch.
