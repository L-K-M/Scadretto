# Scadretto

A native macOS editor for handwritten OpenSCAD: a code editor and a visual
CAD editor driven by one source document. Click a feature in the model,
edit its controlling expression, and review the minimal diff in the
original `.scad` file. Editing the same expression with the keyboard
updates the inspector and the model.

The developer app opens, edits and saves OpenSCAD source and displays live
previews from the pinned worker. See [CI/CD](CICD.md) for build and test
commands. Start with
[`plan/00-Start-Here.md`](plan/00-Start-Here.md) — the numbered files
under [`plan/`](plan/) are parts of a single document covering
architecture, source-edit rules, the OpenSCAD worker protocol, the macOS
editor, milestones and verification.

Targets: macOS 14+, arm64, Swift/AppKit + MetalKit, with an
out-of-process pinned OpenSCAD build as the geometry engine.
