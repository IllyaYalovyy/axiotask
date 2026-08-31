# Cold-start budget & measurement (T2.5)

**Budget: a release-build cold start under 2 seconds** (VISION.md §Success
Criteria — "Launch the app and see all their Google Tasks in under 2 seconds";
RESEARCH-flutter-stack.md §"Startup" makes it an *early* gate, not a
Step-8 afterthought). This document records the measurement method and the
baseline taken when the walking skeleton was complete.

## How it is measured

`tool/measure_cold_start.sh [iterations]` times, for the **release** Linux
build, wall-clock from **process spawn → first rendered frame** — the honest
cold start: process creation + Flutter engine init + Dart bootstrap + first
frame. The app signals the frame by printing an `AXIOTASK_FIRST_FRAME` marker
(`lib/src/app/startup_trace.dart`) on its first post-frame callback, but only
when launched with `AXIOTASK_STARTUP_TRACE=1` — a normal launch stays silent.

The script runs the binary against an **already-running** Xvfb display (started
once, up front) so the display server's own boot is excluded from every sample,
and gives each run a throwaway `XDG_DATA_HOME`/`XDG_CONFIG_HOME` +
`AXIOTASK_PREFIX` so it never touches production data. The first iteration is
the true cold start (cold OS file cache); later ones are warm. It **fails** if
the cold start reaches 2000 ms.

The marker's exact shape is pinned by `test/app/startup_trace_test.dart`, so the
script can never silently mis-parse or miss it.

## Baseline (this developer machine, walking skeleton at T2.5)

Fedora 43, `Xvfb -screen 0 1280x800x24`, `flutter build linux --release`,
5 iterations:

- **cold start: 488 ms** — 24% of the 2000 ms budget.
- warm median: 325 ms.
- Dart-side `main()` → first frame: ~250 ms cold, ~175 ms warm (the rest is
  process + engine init before `main`).

Verdict: **within budget with large headroom.** No startup work is deferred or
skipped to hit this; the detached post-first-frame path (auth restore / sync,
which do not exist yet) is what must keep it there as Steps 3/5/6 land.

## First snapshot (#260)

Cold start is process → first *frame*; the list on that frame also depends on
how long the STORE takes to answer. #260 needed that number, because "show
skeleton rows if the first snapshot is slow" is only honest if someone measured
what "slow" is.

Measured on this developer machine (Fedora 43, `flutter test` on the Dart VM,
drift over a **file-backed** DB seeded and then reopened exactly as a launch
reopens it — timed from `watchAllTasks()` subscription to its first emission):

- **50 tasks** — open 3.2 ms, subscribe → first snapshot **9.8 ms**
- **200 tasks** — open 1.4 ms, subscribe → first snapshot **7.2 ms**
- **1000 tasks** — open 0.9 ms, subscribe → first snapshot **12.1 ms**
- **5000 tasks** — open 0.9 ms, subscribe → first snapshot **31.8 ms**

So at the sizes VISION.md targets ("dozens to hundreds of tasks") the first
snapshot lands inside one to two frames, and even a 5000-task account lands in
under 32 ms. `MotionDurations.firstSnapshotGrace` is 300 ms — an order of
magnitude of headroom — which is why the list shows *nothing* for that long
instead of a spinner, and why the skeleton rows behind that threshold are a
safety net (a cold spinning disk, a phone thrashing) rather than a state the app
expects to render.

Caveats: the numbers are warm-file-cache reopens on an NVMe machine, and the VM
is JIT rather than AOT. They bound the QUERY cost, not a first-ever read off
cold storage on a slow phone — which is exactly the case the skeleton exists
for.

## Re-measuring

Run `bash tool/measure_cold_start.sh` after any change that could touch startup
cost (new synchronous bootstrap work, heavier first-frame widget tree, added
plugins). MIGRATION-PLAN §5 schedules an explicit cold-start **re-measure** at
T8.x; this script is that tool. Numbers are machine-specific — compare deltas on
the same box, not absolute values across machines.
