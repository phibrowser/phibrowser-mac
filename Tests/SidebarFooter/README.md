# Sidebar footer layout regression

Run `bash build-scripts/test-sidebar-footer.sh` on macOS with Xcode installed.
The test compiles the production footer, feedback, notification entry, and Chat
views. Background-only geometry probes measure their rendered frames. Services,
profile/download/memory controls, theme colors, and image assets are local
stand-ins; their fixed 24-point layout contract is preserved. No browser profile,
network request, download, or notification decision is used.

Coverage includes 193, 217, 218, 260, and 500-point widths, all 16 optional-entry
combinations, horizontal containment with eight-point margins, pairwise frame
separation, title retention at wide widths, and live resizing/notification changes.
The test does not establish native pointer hit targets or full-browser appearance.
Those require a separate unlocked-desktop integration check.

To reuse the compiled fixture and check localization:

```sh
PHI_FOOTER_BUILD_DIR=/tmp/phi-sidebar-footer-fixture bash build-scripts/test-sidebar-footer.sh
/tmp/phi-sidebar-footer-fixture/SidebarFooterFixture.app/Contents/MacOS/SidebarFooterFixture -AppleLanguages '(zh-Hans)'
/tmp/phi-sidebar-footer-fixture/SidebarFooterFixture.app/Contents/MacOS/SidebarFooterFixture -AppleLanguages '(ja)'
```

`--preview` keeps an isolated comparison window open after the assertions. Its
symbols and colors are fixture substitutes, not a full browser screenshot.
