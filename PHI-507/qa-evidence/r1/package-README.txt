Phi Tab Close QA — Internal Test Build
=====================================

Build: 0.0.0 (1030.1) / TC-QA-20261030.1
Architecture: Apple Silicon (arm64)
Minimum macOS declared by the app: 14.0
Framework: 156.0.8078.52
Source branch: feature/tab-close-improvements
Base commit: d390230615c172c3a3f94132e0b36ce081dac0be
Source working-diff SHA-256: 6865cc137ce00f136bbf6ce303a7bbd2380a659dfb460b06b7e238948fc16d92
This build includes the uncommitted tab-closing changes in that worktree.

Install
-------
1. Open the DMG.
2. Drag Phi Tab Close QA.app to Applications.
3. If another Phi OpenSource build is running, quit it first: it has the same
   com.phibrowser.opensource.Mac bundle identity and storage.
4. Open /Applications/Phi Tab Close QA.app.
5. Open Settings (Command-comma), then Advanced. The second card has no title
   and contains Double-click to close tabs and Close tabs by position.
6. Use TC-QA-20261030.1 as the handbook build identifier and record a unique run ID.

The app uses a separate bundle identity and data directory from official Phi
and Phi Canary. Its filename is distinct, so do not replace the official app.
It DOES share preferences and browser data with other OpenSource builds.
Do not make it the default browser for this QA run.

Scope
-----
This is the OpenSource native QA build. It includes the tab closing changes,
the matching embedded Chromium framework and the generated localizations.
It does not provide Phi account login, cloud sync, AI, Sentinel or automatic
updates. Official-only integration cases in the handbook remain blocked.
This is an unoptimized QA build, not a release performance benchmark.

Defaults are Double-click to close tabs OFF and Close tabs by position ON.
Existing OpenSource preferences may retain their previous values.
Use disposable tabs, groups, pins and bookmarks for closing tests.

Manual QA handbook
------------------
https://woodnotfound.github.io/phi-qa-handbooks/tab-closing/
The embedded Resources/TabCloseQA-Build-Info.json identifies this exact build.
The adjacent Build-Info.json contains the same build provenance.
