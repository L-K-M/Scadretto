# Scadretto

A native macOS editor for handwritten OpenSCAD: a code editor and a visual
CAD editor driven by one source document. Click a feature in the model,
edit its controlling expression, and review the minimal diff in the
original `.scad` file. Editing the same expression with the keyboard
updates the inspector and the model.

Open **Help → Open Example** for the mounting plate. Select the third bore
and choose **Pitch** in the inspector. The viewport grip shows the caliper
as you drag. Hold Option over the source or model socket to see the shared
instances, or open **Model → Shared-Source Constellation** to inspect them
with the pointer or arrow keys. After the edit renders, use **Compare**
or hold Space with the viewport focused to scrub between both revisions.

The developer app opens, edits and saves OpenSCAD source and displays live
previews from the pinned worker. See [CI/CD](CICD.md) for build and test
commands. Start with
[`plan/00-Start-Here.md`](plan/00-Start-Here.md) — the numbered files
under [`plan/`](plan/) are parts of a single document covering
architecture, source-edit rules, the OpenSCAD worker protocol, the macOS
editor, milestones and verification.

Targets: macOS 14+, arm64, Swift/AppKit + MetalKit, with an
out-of-process pinned OpenSCAD build as the geometry engine.
