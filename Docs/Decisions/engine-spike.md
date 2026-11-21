# Engine feasibility on arm64 macOS

## Build and resource choices

The reference and worker use OpenSCAD
`1c9c8441586eeade3f73a4cd5db575659a9acb5f`. [The upstream lock](../../Engine/upstream.lock)
pins the evaluator, its Flex/Bison grammar, Clipper2 and Manifold together.
[The dependency lock](../../Engine/dependencies.lock) pins the downloaded
archives by SHA-256. The build records the actual Flex and Bison versions
along with the SDK, compiler and CMake inputs in each product's toolchain
record. For the editor parser, the OpenSCAD Tree-sitter grammar
`4c36a4fb569688c97cfa28090031e039a6079244` (v0.7.1) and Tree-sitter runtime
`7f534862c3ec939c3a6ee147f7600ef5c1bf900f` (v0.26.9) agree on ABI 15.
A native C build of this pair parsed the mounting plate and a CRLF input
with an emoji comment, an include and a cylinder without error nodes.

The spike uses the headless `NULLGL` build with the serial Manifold backend
and the CGAL compatibility code. A trial with `ENABLE_CGAL=OFF` failed in
`manifoldutils.h`, which includes a CGAL header on this revision. Keeping
CGAL enabled also keeps upstream geometry support that uses it. The M0
configuration disables GUI, Cairo, 3MF, TBB and mimalloc. Resource lookup
starts from the executable's sibling `Resources` directory. The bundled
`libraries` directory is empty. The only bundled fonts are the upstream
Liberation 2.00.1 files under the SIL Open Font License 1.1, with their
upstream license text included. FreeType disables the SDK's optional HVF
backend and the GLib recipe uses its portable pipe fallback. The macOS 27
SDK otherwise enables pipe2 even at a macOS 14 deployment target.

Clipper2, Manifold, Boost, double-conversion, FreeType, HarfBuzz and OpenSSL
are static in the source-built engine. GLib, libintl, GMP and MPFR retain
separately replaceable libraries. Fontconfig also stays shared with the
development `fc-cache` tool. libzip uses the shared-library target to
resolve its system zlib and crypto dependencies when linked. The build
collects this closure from the pinned prefix, rewrites it to `@rpath`
under the staged `Frameworks` folder, and ad hoc signs the binaries.

The reference CLI resolves explicit `OPENSCADPATH` entries in order before
its user library and bundled roots. The spike job uses the logical main
path for sibling inputs and takes explicit additional roots in its request.
The recorded include and use cases each resolve an STL relative to its
authoring file, with spaces and an accented character in the main folder
name. Native preference roots and file observation belong to the editor
integration.

## Runtime source chain and hit

The worker loads `main.scad` from the job directory and passes the bytes to
the stock parser at the request's logical URL. The on-disk file at that URL
contains only `cube(1);` in the verification case. The fixture is 350 bytes
and has SHA-256
`136c95090096979a91024b7f1e6325f4f09fdca421880d6ffee447ac6c095235`.

- `Literal::evaluate` marks the real token's location on its numeric value.
  `ScopeContext::init` records the assignment that stores that value.
  `Lookup::evaluate` extends the provenance on the value the stock context
  resolves. Arithmetic that computes a fresh number ends the inherited chain.
- `Arguments` records the expression evaluated in the caller's context.
  `Parameters` records the formal chosen by upstream named or positional
  binding. `builtin_cylinder` reads the value after radius alias resolution.
- `builtin_for` records bindings from the executed iteration context on the
  appended children. The scene walk combines the evaluated `TransformNode`
  matrices. The geometry key used by `GeometryEvaluator` lets four distinct
  occurrences reference one local cutter mesh.

In the observed baseline, the first final-surface hit of the ray from
`(55, 20, 3)` in direction `(cos(0.041), sin(0.041), 0)` was triangle 343,
at `(56.9959774463, 20.0818809611, 3)`. Its inward normal was
`(-0.9987954562, -0.0490676743, 0)`. Instance 13, with iteration `i = 2`
and world translation `(55, 20, -1)`, was the only matching operand.
The local cylinder transform was identity. The chain starts at the cylinder
call `[153,185)` and follows its `d` expression `[183,184)`, the
`mounting_hole` formal supplied by `hole_d` at `[339,345)`, the resolved
`hole_d` assignment, and the literal `[74,75)` containing byte `0x34`.
An unrelated cylinder of diameter 4 resolves to its own literal.

Manifold tracks run IDs for geometry and OpenSCAD uses them for color and
boolean face shading. The final PolySet conversion does not provide an
association from those IDs to executed AST instances. The verifier therefore
matches transformed operand triangles at the world hit. It uses face
containment, normal alignment in either direction for subtracting surfaces,
and a distance tolerance of the model diagonal multiplied by `1e-8`,
clamped to `[1e-9, 1e-5]` units. At the exact top rim the candidate IDs
were 3 and 13, the plate and the third cutter. A small parallel-wall control
distinguishes planes separated by `4e-9` units.

Flex locations are one-based byte columns with exclusive ends. The pinned
lexer consumes a UTF-8 BOM as whitespace and counts its three bytes, so the
worker can feed it the original byte stream. The BOM fixture resolves
`[77,78)`, and a declaration on the BOM's own line resolves `[10,11)`.
The worker's digest and length refer to raw bytes in both cases. The stock
CLI also rendered the BOM fixture successfully.

## Geometry evidence

The stock CLI exports binary STL in final-render mode with the same backend
and font inputs. The verification code welds repeated STL vertex coordinates,
checks oriented edge incidence and passes both closed meshes to a verifier
linked against the same pinned Manifold. It sums the two directional
difference volumes. The plate comparison requires a symmetric difference
under both 0.01 cubic units and `1e-6` of the worker volume. For diagnostics,
the expected bounds are `[0,0,0]` to `[120,40,6]`, each vertical bore probe
must pass through, and the volume must agree with the fixture's polygon
formula.

| Fixture | Worker volume | Reference volume | Difference volume |
| --- | ---: | ---: | ---: |
| Baseline | 28498.89134491 | 28498.89133527 | 0.00017683 |
| Diameter 5 | 28329.51772642 | 28329.51770331 | 0.00019575 |
| Diameter 5 and count 5 | 28211.89715802 | 28211.89713262 | 0.00024539 |
| Pitch 22 | 28498.89134491 | 28498.89133527 | 0.00017683 |

A 0.75-unit lateral offset of only the third bore retains the bounds,
volume and fixed occupancy probes and produces a difference of
35.75806542 cubic units. The verifier rejects a mesh with one triangle
removed. An ordinary export through the patched CLI also matches the
baseline.

## Reproduction and environment

```sh
Scripts/bootstrap-macos
Scripts/build-engine
Scripts/verify-engine
```

The build stages separate reference and worker products under
`.build/engine/reference` and `.build/engine/worker`. Verification replays
the patch from the pin and writes the trace, meshes, reference STL,
geometry checks and raw timing samples to a fresh
`.build/engine/verification.*` directory.

The initial feasibility measurements used a Mac16,9 with an M4 Max and
36 GiB RAM, macOS 27.0.1 (26A434), Xcode 27.2 (27B52), SDK 27.2, Apple
Clang 21.0.0 (2100.4.1.1), CMake 4.4.5, Flex 2.7.3 and Bison 3.8.2.
The executable targeted arm64 macOS 14.0. This first probe used Homebrew
libraries on the development Mac while the source-built runtime was under
development. Its geometry and source evidence above are separate from
runtime deployment verification.

The initial Homebrew-linked plate worker launch and evaluation
took 403 ms. In the same probe the 30 warm process-plus-evaluation samples
had p50 25 ms and p95 65 ms. Those intervals include job execution and
serialization through child exit. They exclude scheduling, decode, GPU
presentation and UI interaction. On an empty cache the first default
`text()` evaluation took 1,235 ms and the warm evaluation took 31 ms.
The named Liberation Sans case took 398 ms on its own empty cache and
29 ms warm. M2 must serialize initialization and share the warmed cache
across jobs. These observations support retaining one child per evaluation
for this spike.

A second run used binaries linked against the source-built dependency
prefix and staged with the runtime closure. All geometry checks, including
the table above, passed again. The timing series had warm p50 19 ms and
p95 126 ms. The default and named font first/warm pairs were 36/19 ms
and 178/20 ms. A cold run of staged `fc-cache` took 164 ms. The worker ran
with an isolated environment, and `otool -L` showed only staging-relative
third-party libraries and Apple system paths. The binary and bundled
libraries passed arm64 and Mach-O deployment checks.

The source-built probe artifacts and hashes from this Mac were:

| Path under `.build/m0/` | SHA-256 |
| --- | --- |
| `source-reference/bin/openscad` | `d8459551972e86847c0532fac1ebe95a11fe48d04863f58e83b5b43253aefdde` |
| `source-worker/bin/scadretto-engine` | `3d7d0b59365ebf2d97bbf8e57064fd9a3e17f7379113220fbc0d94b35171f5e5` |

The probe evidence is in `.build/m0/source-verification-2/`. The
format-patch replay and CI job provide the clean source-tree checks.

The M0 tests exercise CPU rays and the evaluator through its spike job
interface. The real application mouse path, versioned production protocol,
minimum-OS runtime and clean installation are separate acceptance checks.
