## Canonical plate: commit to accepted shaded frame

35 commits with a presented frame; the first 5 are discarded as warm-up. Target: p95 under 1000 ms.

| Interval | Samples | p50 | p95 | Max |
|---|---|---|---|---|
| Commit to presented frame | 30 | 78.0 ms | 244.1 ms | 244.5 ms |
| Queue wait | 30 | 0.0 ms | 0.0 ms | 0.0 ms |
| Worker wall time | 30 | 28.9 ms | 119.0 ms | 120.9 ms |
| Decode | 30 | 0.7 ms | 0.8 ms | 0.8 ms |
| Mesh and BVH preparation | 30 | 0.6 ms | 0.7 ms | 1.3 ms |
| Acceptance to presentation | 30 | 34.8 ms | 44.3 ms | 44.6 ms |
| Peak worker memory | 30 | 0.1 MB | 22.8 MB | 22.9 MB |

Peak worker memory is the largest footprint sampled every 50 ms while the worker runs; an evaluation that ends sooner reports only its first sample.

Stale accepted results: 0

## Orbit and handle drag, plate: presented frame intervals

Bursts split at gaps over 250 ms. Target: p95 at or below 33 ms.

| Interval | Samples | p50 | p95 | Max |
|---|---|---|---|---|
| Frame interval | 961 | 16.7 ms | 16.7 ms | 250.0 ms |

Intervals over 33 ms: 6

## Orbit, hundred-cutter plate: presented frame intervals

Bursts split at gaps over 250 ms. Target: p95 at or below 33 ms.

| Interval | Samples | p50 | p95 | Max |
|---|---|---|---|---|
| Frame interval | 954 | 16.7 ms | 16.7 ms | 83.3 ms |

Intervals over 33 ms: 5

## Typing while the worker is busy, hundred-cutter plate

Main-thread handling of each committed keystroke. Target: p95 under 16 ms and no stale scene.

| Interval | Samples | p50 | p95 | Max |
|---|---|---|---|---|
| Edit handling | 103 | 0.6 ms | 0.7 ms | 4.3 ms |

Stale accepted results: 0
