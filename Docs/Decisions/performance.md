# Performance measurements

`Scripts/benchmark-macos` measures the workloads in
[the verification guide](../../plan/06-Verification-and-Release.md#performance-targets)
on a Release build. Benchmark UI tests drive the app while the hidden launch
default `ScadrettoTimingLog` makes it write JSON lines: a `commit` when a
transaction mutates the buffer, with its main-thread handling time; an
`accepted` result with queue wait, worker wall time, decode time, mesh and BVH
preparation and peak worker memory; and a `frame` for every Metal drawable
that reaches the screen, with its presentation time. All timestamps use the
`CACurrentMediaTime` clock that Metal reports presentation times in.
`Scripts/benchmark-report` turns the logs into percentiles (nearest rank).
The UI tests skip unless `SCADRETTO_BENCHMARK_DIR` is set, so the ordinary
suite does not run them.

The script then opens a long evaluation three times and ends the app with
Quit, `SIGTERM` and `SIGKILL`. It counts worker processes and job directories
five seconds later, and again while a new launch runs.

## Results, 2026-11-23

Raw logs, environment and report:
[Docs/Benchmarks/2026-11-23-m4-max](../Benchmarks/2026-11-23-m4-max).
Mac16,9 (Apple M4 Max, 36 GiB), macOS 27.0.1 (26A434), Xcode 27.2, Release
arm64 build of 91034fc, one 1920 × 1080 display at 60 Hz and backing scale 1.
Other agents shared the Mac: the load average was about 9 throughout.

| Workload | Measured | Target | Met |
|---|---|---|---|
| Canonical plate, commit to presented frame, 30 warm diameter commits after 5 discarded | p50 78 ms, p95 244 ms | p95 under 1 s | yes |
| Orbit and handle drag, plate, 20 s | 961 frame intervals, p50 and p95 16.7 ms | p95 at or below 33 ms | yes |
| Orbit, hundred-cutter plate, 20 s | 954 frame intervals, p50 and p95 16.7 ms | p95 at or below 33 ms | yes |
| Typing while the worker is busy, hundred-cutter plate, 100 keystrokes 120 ms apart | 103 commits, main-thread handling p95 0.7 ms, 0 stale results | p95 under 16 ms, no stale scene | yes |
| Quit, `SIGTERM`, `SIGKILL` during a long evaluation | no worker left 5 s after each; the job directory left by a signal is removed by the next launch | no orphaned workers or abandoned jobs | yes |

The plate's commit interval splits into queue wait p95 0.0 ms, worker wall
time p95 119 ms, decode p95 0.8 ms, preparation p95 0.7 ms and presentation
after acceptance p95 44 ms. Quit took 232 ms from the request to the app's
exit, `SIGTERM` 20 ms and `SIGKILL` 24 ms.

No workload missed its target, so this milestone adds no caching or instancing.

## Limits of these numbers

- The display refreshes at 60 Hz, so a frame interval cannot fall below
  16.7 ms. Five or six intervals per orbit run exceeded 33 ms; the largest
  values are pauses between scripted drags, not frames, because bursts split
  only at gaps over 250 ms.
- Peak worker memory is sampled every 50 ms. An evaluation that ends sooner
  reports only its first sample, which is why the plate's p50 is 0.1 MB while
  its p95 is 22.8 MB.
- All runs are warm. Cold launch and resource initialization were not
  measured separately.
- The cancellation series uses a recursive `fib(40)` evaluation rather than a
  variant of the stress fixture, because the stress plate evaluates too quickly
  to end the app during it. The typing workload supersedes most of its 103
  requests, which covers repeated superseding, but the series does not
  alternate fifty distinct jobs with document closes.
- Earlier runs the same day failed for reasons outside the app: other agents'
  windows took focus during UI tests, and the first versions of the script and
  orbit test measured nothing (fixed before this run). Only the run above is
  reported.

Rerun with `Scripts/benchmark-macos [OUTPUT_DIRECTORY]` in a logged-in session
that permits UI automation. It needs about ten minutes.
