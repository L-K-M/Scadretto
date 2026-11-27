# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Native macOS OpenSCAD editor direction and architecture: one source document
  driving keyboard and graphical edits, with undo-safe transactions and
  source-byte preservation.
- Pinned, independently verified OpenSCAD engine and worker toolchain, CMake
  dependency build, editor/protocol separation, and mounting-plate fixture
  checks.
- Swift package and document-app implementation covering source editing,
  syntax feedback, worker evaluation, model inspection, shared-source
  relationships, comparison and viewport interaction.
- Distribution packaging design and workflows for verified, notarized macOS
  DMGs, plus CI, engine verification, Dependabot, the GLM/StepFun review
  workflow, and agent instructions.
