# CI/CD

Scadretto starts with the [macOS engine spike](plan/05-Milestones.md#m0--prove-the-engine-on-a-mac).
The supported target is macOS 14 or later on Apple silicon. Record the exact
Xcode, SDK, CMake and engine revisions in M0.

## Development

On an Apple silicon development Mac, select a full Xcode installation and
install the [shared release tool](https://github.com/L-K-M/release-tool)
for `lkm-build` and `lkm-release`. With Homebrew, install the worker's build
tools and build the app:

```sh
brew install cmake ninja python pkgconf bison flex meson gettext
Scripts/build.sh --debug
```

The wrapper fetches and builds the pinned OpenSCAD worker on demand, then
bundles it using the shared `Scadretto` Xcode scheme. It reuses the runtime
in `.build/engine/` when the pinned inputs and toolchain match. The first
build can take several minutes. `--check`
prints the app build configuration without preparing the engine. `--clean`
resets the default app build directory and keeps the engine cache.
To use a prebuilt runtime, set `SCADRETTO_WORKER_PRODUCT` to its path.
This also works for a CI runtime restored to `.build/engine/worker`.
If Xcode reports that its Metal toolchain is missing, install it with
`xcodebuild -downloadComponent MetalToolchain`.

To build both the worker and the reference CLI for geometry verification:

```sh
Scripts/build-engine
Scripts/verify-engine
swift test --package-path Packages/ScadrettoKit
```

To run the shared scheme directly in Xcode, prepare the worker first with
`Scripts/build-engine --worker-only`. It publishes the local worker at
`.build/engine/worker` when that path is available. See the
[engine decision record](Docs/Decisions/engine-spike.md) for build flags,
trace examples, and geometry checks.

The [verification guide](plan/06-Verification-and-Release.md#build-and-verification-entry-points)
lists the test and release entry points.

GitHub Actions runs repository script checks, pinned engine verification and
Swift package tests on PRs and pushes to `main`. The package tests and the
document app build use the checked runtime from the engine job. Without a
built worker, the planner's live-worker tests report themselves skipped.
Run the UI test plan on a logged-in Mac:

```sh
xcodebuild -project Scadretto.xcodeproj -scheme Scadretto \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test
```

Native UI and minimum-OS checks follow the verification guide.

`Scripts/verify` runs the deterministic checks in one pass: the pinned engine
build and its verification, the package tests and the app build. It records
the machine and toolchain in `summary.txt` under `.build/verify/` and exits
nonzero if any step fails. `Scripts/verify --ui` adds the UI test plan;
without it the summary marks GUI coverage pending. The release workflow runs
`Scripts/verify` before signing.

`Scripts/package-macos --local` builds an ad hoc signed local development
image at `.build/package/Scadretto-local.dmg` with a report beside it. It
needs no Apple developer account. [The distribution record](Docs/Decisions/distribution.md)
describes its checks, the bundled licenses and the corresponding source.

## Pull requests

The pinned GLM workflow reviews ready PRs from branches in this repository and
cancels obsolete runs when new commits arrive. It reads `ZAI_API_KEY` from
repository secrets. `STEPFUN_API_KEY` enables optional review
providers. The workflow runs from the base branch. Follow the review rules in
[AGENTS.md](AGENTS.md).

## Distribution

Once the M6 verification and packaging entry points exist, cut a version tag
from a clean `main` checkout at `origin/main`:

```sh
Scripts/release.sh 1.0.0        # create local tag v1.0.0
Scripts/release.sh 1.0.0 --push # create and push the tag to stage a draft
```

The workflow verifies the app and engine before importing a Developer ID
Application identity into a temporary keychain. Put signing and notarization
inputs in the GitHub Actions `distribution` environment:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded PKCS#12 with the Developer ID Application certificate and private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for that PKCS#12 |
| `NOTARY_APPLE_ID` | Apple Account for notarization |
| `NOTARY_PASSWORD` | App-specific password for notarization |
| `NOTARY_TEAM_ID` | Apple developer team ID |

The workflow hands off to the M6 packaging script through
`Scripts/package-macos --distribution --version X.Y.Z --build N --output /path/to/Scadretto.dmg`.
That mode builds for arm64, signs nested code and the DMG with Developer ID,
includes the required notices and corresponding worker source, and notarizes
and staples the DMG. The script accepts the notarization inputs as environment
variables. Its `--local` mode uses ad hoc signing.

The workflow verifies the image signature, staple and Gatekeeper assessment
and puts the DMG and its SHA-256 checksum in a draft GitHub release. Publish
the draft after the [distribution gate](plan/06-Verification-and-Release.md#distribution-gate)
passes on the exact downloaded image, including the clean-Mac offline fixture
test and the minimum OS verification.
