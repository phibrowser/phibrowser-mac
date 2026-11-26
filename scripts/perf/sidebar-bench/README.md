# Sidebar performance bench

Measures the main-thread cost of two sidebar interactions in a real Phi Canary
build, so two builds can be compared and regressions traced over time:

- **toggle**: View > Toggle Sidebar, 24 times, 0.6s apart.
- **scroll**: the sidebar tab list scrolled top → bottom → top, twice, in
  100 steps per leg.

Both run in the Performance layout (`BENCH_LAYOUT` picks another) on a
profile shaped like real use:

- Default Space: 150 tabs, with 6 tab groups of 5, 6 split views, 6 pinned
  tabs and 12 bookmarks.
- Spaces "Bench B" and "Bench C": 30 tabs each, with 2 tab groups of 4,
  2 split views and 2 pinned tabs.

Both are driven through Accessibility, with the Time Profiler attached for
20s. Nothing in the app is changed to run them, so any two builds compare on
equal terms.

## Requirements

- macOS with Xcode command line tools (`xcrun xctrace`), Python 3.
- Accessibility permission for the terminal running the scripts (System
  Events drives the app).
- No other Phi Canary running. The app runs on screen; don't touch the mouse
  or keyboard during a run.
- Disk: each recording leaves several GB of temporary kernel trace, which
  `bench.sh` deletes; if Xcode's `DTServiceHub` still holds it, the space comes
  back when Xcode quits.

## Builds under test

Use plain Debug builds (not `build-for-testing` products), launched directly,
not under the Xcode debugger. Copy the `.app` out of the build folder: a quit
build-folder app can be replaced by Sparkle with a release, which `bench.sh`
refuses (it checks the version is `debug`).

```sh
xcodebuild build -project Phi.xcodeproj -scheme PhiBrowser-canary \
  -destination platform=macOS -derivedDataPath build/DerivedData-Bench
cp -c -R "build/DerivedData-Bench/Build/Products/Debug-Canary/Phi Canary.app" /tmp/candidate.app
```

To compare against another branch, build it in its own worktree the same way.
A new worktree needs `Frameworks/Phi Framework.framework` copied in
(`cp -c -R` clones it).

## Running

```sh
# Once per machine: the fixture profile in $BENCH_DIR (default
# ~/Library/Application Support/PhiSidebarBench). Complete onboarding and
# sign-in by hand when asked; the rest takes ~40 minutes of UI automation
# (make_fixture.py), hands off. Later runs reuse the saved snapshot.
sh scripts/perf/sidebar-bench/seed.sh /tmp/baseline.app

# Both builds, both scenarios, 2 rounds each (~8 minutes), then the summary.
sh scripts/perf/sidebar-bench/run.sh base /tmp/baseline.app cand /tmp/candidate.app

# Or one round, and the summary on its own.
sh scripts/perf/sidebar-bench/bench.sh cand /tmp/candidate.app toggle 1
python3 -I scripts/perf/sidebar-bench/analyze.py base cand
```

Seed with the older build when the two differ in stored data. Every round
starts from a fresh clone of the same snapshot, in the Default Space, at the
same window frame (1311 × 812), sidebar expanded and scrolled to the top.
Layout mode is an app-wide preference shared with your own Canary: each round
sets it and puts your value back when it ends. Other app preferences come
from the same standard defaults; keep them unchanged between runs.

## What the numbers mean

Each Time Profiler sample is 1ms of the main thread; the window is 2.5s–19.5s
of the recording. Per op means per toggle, or per scroll step.

| Metric | Meaning |
|---|---|
| main ms / op | All main-thread work. |
| app ms / op (excl. AX) | Without the driver's Accessibility requests, which the app answers on its main thread. Compare this one. |
| component lines | Samples whose stack contains `_layoutViewTree`, `CA::Transaction::commit`, `NSHostingView`, `ContentSurfaceHosting.update`, outline row views; they overlap. |
| stretches > 16.7ms / op | Main-thread busy runs (gaps ≤ 3ms) longer than one 60Hz frame: frames the main thread could not commit. |
| over-budget ms / op | How far those runs exceeded the frame. |

Limits: Debug builds; the scroll driver sets the scroll bar's value, which is
not trackpad momentum scrolling, and steps about every 32ms, so per-step cost
matters more than dropped frames there. Animation Hitches need a physical
display and are not part of this bench.

## Results

| Date | Baseline | Candidate | Toggle app ms/toggle | Toggle stretches/toggle | Scroll app ms/step |
|---|---|---|---|---|---|
| 2026-11-21 | `dev` 609caf37 | `improve/sidebar-appkit-tab-row` 78ade5b3 | 215 → 127 (−41%) | 3.54 → 0.98 (−72%) | 13.9 → 11.0 (−21%) |

2026-11-21 detail (fixture above, Performance layout, 2 rounds each, remote
virtual 60Hz display): toggle `_layoutViewTree` 65.3 → 10.1ms,
`NSHostingView` 48.1 → 10.3ms, `ContentSurfaceHosting.update` 76.0 → 52.0ms,
longest stretch 159 → 110ms; scroll `NSHostingView` 2.77 → 0.80ms per step,
`ContentSurfaceHosting.update` 6.64 → 4.77ms, stretches > 16.7ms per step
0.45 → 0.13.

Earlier, on 150 plain tabs in the Balanced layout (2026-11-21, same builds):
toggle 147 → 84ms (−43%), 1.73 → 0.92 stretches per toggle; scroll 10.0 →
7.5ms per step (−26%). Detail: toggle
`_layoutViewTree` 41 → 6.7ms, `NSHostingView` 33.5 → 10.6ms,
`ContentSurfaceHosting.update` 49 → 27.6ms, longest stretch 96 → 73ms; scroll
`NSHostingView` 2.6 → 0.32ms per step (tab rows moved to AppKit),
`ContentSurfaceHosting.update` 3.7 → 2.3ms.
