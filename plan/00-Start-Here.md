# Scadretto | macOS implementation plan

Scadretto is a native editor for handwritten OpenSCAD. A designer can click a mounting hole, see which expression controls its diameter, drag the diameter, and review the small change in the original `.scad` file. Editing the same expression with the keyboard updates the inspector and the model. One source document owns both operations.

## Start here

Give an implementation agent this whole directory. The numbered files are parts of one plan. Read the contracts before coding, then work one milestone at a time. Paths and commands referring to the future application repository are proposed deliverables. Run the bootstrap milestone before using those commands.

| File | Use it for |
|---|---|
| [01 Architecture](01-Architecture.md) | Target platform, repository layout, ownership of state, process and document boundaries |
| [02 Source and edits](02-Source-and-Edits.md) | Source coordinates, property binding, rewrite rules, undo and drag behavior |
| [03 OpenSCAD worker](03-OpenSCAD-Worker.md) | Geometry evaluation, trace collection, protocol, picking and cancellation |
| [04 macOS editor](04-macOS-Editor.md) | AppKit document lifecycle, text editor, Metal viewport, selection and inspector |
| [05 Milestones](05-Milestones.md) | Ordered work packages with targets, dependencies and exit conditions |
| [06 Verification and release](06-Verification-and-Release.md) | Canonical test fixture, behavioral oracles, performance targets and packaging |

See the [build and release guide](../CICD.md) for repository checks and the macOS release process.

**First assignment for an agent.** Complete M0 on a Mac. Produce a reproducible upstream reference build, a patched headless worker spike, and a report of which source ranges and geometry identities survived the mounting-plate example. Then complete M1–M3 to put one real viewport edit through the application. A mock scene is useful in tests. The M3 demonstration must open an ordinary file and use the real worker.

## Release scope

| Capability | First release |
|---|---|
| Documents | Open, edit, save and reopen UTF-8 `.scad` files. Use ordinary files with relative imports. Preserve comments, identifiers, line endings and untouched bytes. |
| Code → UI | An accepted evaluation replaces the model, instance outline, values and diagnostics together. Syntax errors leave a visibly stale last-good preview. |
| UI → code | Edit literal dimensions on cubes, spheres and cylinders, direct numeric arguments to user modules, named numeric parameters and supported translations. Offer formula offsets or a shared parameter edit under the rules in file 02. |
| Booleans and repetition | Inspect positive operands and cutters. Select one occurrence inside a module or loop and show the full impact of editing its source. Offer a pitch handle for the documented simple pattern. |
| Arbitrary OpenSCAD | Let the pinned engine evaluate valid 3D programs within its supported features and file inputs. Code navigation and inspection remain available for constructs without an editable handle. Report diagnostics for unsupported inputs. |
| macOS delivery | Native Apple silicon application, working offline after installation. Deliver a Developer ID distribution build when release credentials are available. |

**Platform assumption.** “Mac OS X” means modern macOS. Use macOS 14 or later on arm64 for the first release. Record the exact Xcode, SDK, deployment target and engine revision at M0. Intel support can follow once the dependency stack and helper pass the same fixture on an Intel Mac. The document format is independent of the CPU.

**Editing boundary.** In the first release the visual CAD editor means direct manipulation of authored parameters: viewport handles, inspector fields and the instance outline acting on the source the user wrote. It is not a freeform modeler. The first release operates on authored values and operations. Explicitly breaking one instance out of a procedural pattern, editing imported mesh topology, arbitrary face push/pull, simultaneous multi-file rewrites, and an interactive 2D sketcher are follow-on work. An included module remains useful in v1 because an explicit argument in the current file can still be edited. The proposed later milestones describe where the first two procedural extensions fit.

## User-visible contract

1. Saving an untouched supported file reproduces its bytes. A visual edit changes only the documented source range, or inserts the selected transform.
2. A handle identifies its target and affected instances before it moves. A shared edit updates the shared model. One completed gesture makes one undo entry.
3. Dragging never destroys a formula silently. If an edit cannot be expressed under the selected rule, the inspector explains why and reveals the expression.
4. Opening a file in Scadretto, editing it, then opening it in the pinned upstream OpenSCAD produces equivalent geometry for the supported fixtures.
5. Saving code is always available, including while it is incomplete or the geometry worker is restarting. Scadretto does not require a sidecar for model data.

## Decisions to carry forward

Use Swift and AppKit for the document application, MetalKit for the viewport, and an out-of-process C++ worker based on a pinned OpenSCAD revision for evaluation. Use the OpenSCAD Tree-sitter grammar for fast editing feedback. Geometry, runtime bindings and execution paths come from the worker. These are implementation choices for this plan. Record deviations with their effect on a fixture, compatibility or release requirement. Build and publication credentials are independent; local development and tests work with ad hoc signing.

## Definition of done

A fresh checkout builds on the declared Mac toolchain. A fresh install opens the example with no separately installed OpenSCAD or Homebrew libraries. The sequence in [the acceptance walkthrough](06-Verification-and-Release.md#mounting-plate-walkthrough) passes, including exact source diffs, scope, malformed code, undo, save, reopen and an upstream geometry comparison. The release report identifies the tested hardware, engine SHA and any unverified distribution step. A green renderer test by itself does not complete the editor.
