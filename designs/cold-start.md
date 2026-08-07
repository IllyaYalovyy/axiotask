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

## Re-measuring

Run `bash tool/measure_cold_start.sh` after any change that could touch startup
cost (new synchronous bootstrap work, heavier first-frame widget tree, added
plugins). MIGRATION-PLAN §5 schedules an explicit cold-start **re-measure** at
T8.x; this script is that tool. Numbers are machine-specific — compare deltas on
the same box, not absolute values across machines.
