# CI/CD

Scadretto starts with the [macOS engine spike](plan/05-Milestones.md#m0--prove-the-engine-on-a-mac).
The app requires macOS Tahoe 26 or later on Apple silicon. Build it with
Xcode 26 or later and the Metal Toolchain component. The pinned engine
build has its own deployment target.

## Development

From a fresh checkout on an Apple silicon Mac with Homebrew and full
Xcode installed and selected, build and launch the developer app:

1. `brew install cmake ninja python pkgconf bison flex meson gettext`
2. `xcodebuild -downloadComponent MetalToolchain`
3. `Scripts/build-engine`
4. `xcodebuild -project Scadretto.xcodeproj -scheme Scadretto -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build`
5. `open .build/xcode/Build/Products/Debug/Scadretto.app`

The engine build fetches and checks the pinned sources and stages the
worker in `.build/engine/worker`. Xcode copies the worker and its runtime
into the app. Run `Scripts/verify-engine` to check the pinned engine or
`swift test --package-path Packages/ScadrettoKit` to run the package tests.

`Scripts/build.sh --debug` is also available with
[`lkm-build`](https://github.com/L-K-M/release-tool) installed.

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
