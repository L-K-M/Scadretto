# Packaging and distribution

`Scripts/package-macos` builds the arm64 Release app, copies in the license
files, signs it inside out, checks it and puts it in a disk image with the
corresponding worker source. `Scripts/verify` runs the deterministic suites
first. Both follow the [distribution gate](../../plan/06-Verification-and-Release.md#distribution-gate).

## Bundle layout

| Location | Content |
|---|---|
| `Contents/MacOS/Scadretto` | The document app, with Tree-sitter and its OpenSCAD grammar linked in |
| `Contents/Helpers/scadretto-engine` | The patched OpenSCAD worker |
| `Contents/Frameworks` | GLib, libintl, GMP, GMP C++, MPFR, Fontconfig and libzip, with `@rpath` install names |
| `Contents/Resources/OpenSCAD` | The worker's Liberation fonts with their `fonts.conf`, color schemes and the empty bundled `libraries` root |
| `Contents/Resources/default.metallib` | The viewport's compiled Metal shaders |
| `Contents/Resources/mounting-plate.scad` | The example, copied from `Tests/Fixtures/mounting-plate.scad` at build time |
| `Contents/Resources/Licenses` | One folder of license and notice files per component, listed in `Engine/licenses.lock` |

The disk image adds `Source/scadretto-worker-source-X.Y.Z.tar` and
`Third-Party Notices.txt` beside the app and an Applications link.

## Two modes

`--local` signs ad hoc, without the hardened runtime, and needs no Apple
developer account. It produces a local development build and says so in its
report.

`--distribution` signs every dylib, the worker and the app with a Developer
ID Application identity, the hardened runtime and a secure timestamp. Neither
the app nor the worker has entitlements, so the worker's library validation
accepts only libraries signed by the same team. The script then submits the
app to the notary service and staples it, so a copy installed from the image
passes Gatekeeper offline, builds the image, signs, submits and staples it,
and assesses both with `spctl`. Notarization inputs come from the environment
(`NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID`); the identity comes
from the keychain, or `SCADRETTO_DEVELOPER_ID` when there are several. The
release workflow imports the identity into a temporary keychain from the
`distribution` environment, as [CI/CD](../../CICD.md#distribution) describes.

## Checks in both modes

- Every Mach-O file is arm64 only, reports a minimum macOS no newer than
  `ENGINE_MACOS_TARGET` (14.0) with `vtool -show-build`, links only system
  libraries or `@rpath`, `@executable_path` and `@loader_path` paths, and has
  only relative run paths or the system Swift runtime's `/usr/lib/swift`.
- `codesign --verify --strict` passes for each file and for the whole app.
- The bundled example is byte-identical to the canonical fixture.
- The packaged worker passes the worker contract checks
  (`Tests/Engine/verify_v1.py`) against the pinned reference, with
  `/opt/homebrew` and `/usr/local` unreadable through a `sandbox-exec`
  profile, so it finds its fonts, libraries and resources inside the bundle.

Any failure stops packaging. The report beside the image records the
revision, machine, identity, entitlements, Mach-O count, check results,
notarization state and the SHA-256 of the app executable, worker and image.

## Licenses of the bundled components

Versions are the pins in `Engine/upstream.lock`, `Engine/dependencies.lock`
and `Packages/ScadrettoKit/Package.resolved`. The license column names the
texts the package carries; it summarizes them and is not legal advice.

| Component | Version | License texts | How it ships |
|---|---|---|---|
| OpenSCAD | `1c9c844`, with `Engine/patches` | GPL 2.0 or later, with a CGAL linking exception in `COPYING` | Worker |
| Clipper2 | OpenSCAD submodule `c7f820f` | Boost Software License 1.0 | Static in the worker |
| Manifold | OpenSCAD submodule `ce50d78` | Apache 2.0 | Static in the worker |
| CGAL | 6.2.1 | GPL 3.0 or later and LGPL 3.0 or later by package; BSL for some files | Compiled into the worker |
| Boost | 1.92.0 | Boost Software License 1.0 | Static in the worker |
| Eigen | 5.0.1 | MPL 2.0, with Apache, BSD and MINPACK notices for some files | Compiled into the worker |
| double-conversion | 3.4.0 | BSD 3-clause | Static in the worker |
| FreeType | 2.15.0 | FreeType License or GPL 2.0 | Static in the worker |
| HarfBuzz | 15.2.0 | Old MIT | Static in the worker |
| OpenSSL | 3.5.9 | Apache 2.0 | Static in the worker |
| GLib | 2.90.1 | LGPL 2.1 or later | Dynamic library |
| PCRE2 | 10.49 | PCRE2 licence (BSD) | Linked into GLib |
| libffi | 3.5.2 | MIT | Linked into GLib |
| libintl (gettext) | 1.0 | LGPL 2.1 or later (`gettext-runtime/intl/COPYING.LIB`) | Dynamic library |
| GMP | 6.3.0 | LGPL 3.0 or later, or GPL 2.0 or later | Dynamic libraries |
| MPFR | 4.2.2 | LGPL 3.0 or later | Dynamic library |
| Fontconfig | 2.18.4 | Fontconfig license (MIT style) | Dynamic library |
| libzip | 1.12.1 | BSD 3-clause | Dynamic library |
| Liberation fonts | 2.00.1 | SIL Open Font License 1.1 | Worker resources |
| Tree-sitter | 0.26.9 (`7f53486`) | MIT | Static in the app |
| tree-sitter-openscad | 0.7.1 (`4c36a4f`) | MIT | Static in the app |

The worker as distributed combines GPL-licensed OpenSCAD and CGAL code, so it
ships under the GPL with its complete corresponding source. The LGPL
libraries stay dynamic and replaceable, as the
[engine record](engine-spike.md) explains.

## Corresponding source

The image's `Source` archive holds the OpenSCAD tree and the submodules the
build initializes at the pinned revisions, every pinned library archive, and
the patches, build scripts, checks and fixtures that produced the worker,
with a README naming the Scadretto revision. Rebuilding means checking out
that revision, placing the archives in `.build/engine/downloads` under their
SHA-256 names and running `Scripts/build-engine`.

## Decisions that stay with the owner

- **Application licensing and publication.** The document app runs the
  worker as a separate process, but process separation alone does not settle
  how the combined product is licensed. The owner decides the app's license
  and whether and where to publish before any public release. The packaging
  makes either choice possible; it does not make it.
- **Release credentials and publication.** Developer ID signing and
  notarization need the owner's certificate and notary account in the
  `distribution` environment. The release workflow stages a draft; the owner
  publishes it after the clean-Mac checks.

## Local results

These come from one development Mac: Mac16,9 (Apple M4 Max, 36 GiB),
macOS 27.0.1 (26A434), Xcode 27.2, one 1920 × 1080 display at backing scale 1,
Swiss German keyboard layout, Homebrew installed, no system OpenSCAD.

`Scripts/package-macos --local` on revision `d30efc9`, 2026-11-23:

| Item | Result |
|---|---|
| Image | `Scadretto-local.dmg`, 258 MB, SHA-256 `7073876cbe082aafb072817595ccfff62d72a3fabb85160633d85a0d78c7c4cf` |
| App executable | SHA-256 `ba6c380a916a511194fd762ff63c079859e9f229da8ac82741f529dcbf6b9721` |
| Worker | SHA-256 `60a9b08a19a8c3326286d84c6f3f525adf63fc4d369fbfa4f771928bd7f4332e` |
| Signing | Ad hoc, no hardened runtime; no entitlements on the app or the worker |
| Mach-O checks | 9 files (app, worker, 7 libraries): arm64 only, minimum macOS 14.0 or older, no problems |
| Packaged worker contract checks | Pass with `/opt/homebrew` and `/usr/local` unreadable |
| Notarization | None; this is a local development build |

The image's bytes change with every build (timestamps), so the hashes above
identify this build only.

### Install check

The app was copied out of the mounted image with `ditto` and run under a
`sandbox-exec` profile that denies reading `/opt/homebrew` and `/usr/local`
and all outgoing IP connections. A desktop automation tool drove it with
synthesized mouse and keyboard events.

1. The installed app's signature verifies, and its example is
   byte-identical to `Tests/Fixtures/mounting-plate.scad`.
2. Help > Open Example opens an untitled "Mounting Plate" that evaluates
   offline: "Preview ready · 1052 triangles". The editor shows the start
   of every line.
3. A click on the third bore's wall selects "i = 2 · mounting_hole ·
   cylinder", a shared parameter of 4 cutters. Dragging the diameter handle
   changes `hole_d = 4;` to `hole_d = 4.9753561478;` (the synthesized drag
   path is not pixel-exact). Undo restores `hole_d = 4;` and Redo reapplies
   it, from the Edit menu and from the keyboard.
4. After typing `// copy ` at the top, Save asks where to save the untitled copy.
   The saved file outside the bundle equals the fixture with only those two
   changes.
5. The app quits without a prompt. Launched again with the saved file, it shows
   the same text and "Preview ready · 1052 triangles", again from the start
   of each line.
6. The bundled example is unchanged and the app's signature still verifies.
7. The unmodified reference CLI renders the saved copy to 1052 facets with
   all four bores at radius 2.4877 (the fixture's are 2.0).

The packaged worker contract checks cover the worker's fonts, includes and
`use` from library roots, imports and `surface()` data from inside the
bundle; the install check covers the app's Metal shaders and the worker it
starts.

### Remaining gates

| Gate | Needs |
|---|---|
| Developer ID signing, notarization, stapling and `spctl` | The owner's Developer ID Application certificate and notary account in the `distribution` environment, then a version tag |
| Clean-Mac install of the quarantined, notarized image | A supported Mac without Homebrew or developer tools, and the image downloaded from the draft release |
| macOS 14 | A Mac or virtual machine running macOS 14 |
| Application license and publication | The owner's decision |
