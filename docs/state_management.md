# State Management

Last updated: 2026-03-29

## Overview

State is primarily managed with Combine publishers (`@Published`) and window-scoped objects. The architecture favors explicit state objects over global singletons, with the exception of a small `AppState` shared container.

## App-scoped state

| Component | Responsibility |
| --- | --- |
| `AppState.shared` | Small global UI flags (e.g., layout toggles) |

## Window-scoped state

| Component | Responsibility |
| --- | --- |
| `BrowserState` | Tabs, sidebar, fullscreen, layout mode for a single main window |
| `BrowserImagePreviewState` | Image preview session, current item index, load state, and zoom bounds for one window |
| `BookmarkBar` | Shared bookmark bar view instance for one window; owned by `WebContentContainerViewController` and reparented into the active tab controller |

### Key patterns

- `BrowserState` uses `@Published` to notify UI of tab and layout changes.
- Chrome controllers that are hidden by layout mode or sidebar visibility should cancel their Combine subscriptions and clear rendered data, then rebuild from the current `BrowserState` / `BookmarkManager` values when reactivated.
- `BrowserState.imagePreviewState` keeps preview state window-scoped instead of introducing a process-global preview singleton.
- `BrowserState` owns cleanup of Chromium's auto-created placeholder NTP tab during window restore so replay logic can stay focused on snapshot restoration.
- `WebContentContainerViewController` owns one shared `BookmarkBar` per window and hands it to the active `WebContentViewController`.
- `WebContentViewController.updateBookmarkBarVisibility(bookmarkCount:)` owns the tab-scoped slot visibility policy, using explicit count input rather than direct bookmark collection access.
- Chromium events are routed to the appropriate `BrowserState` instance via `EventBus`.
- Window controllers retain their own `BrowserState` instance for isolation.

## Local persistence integration

`BrowserState` subscribes to `LocalStore` publishers (for example, pinned tabs) to keep UI state in sync with the SwiftData store.

## Login and onboarding state

- `LoginController.shared.phase` is split by scope: `.login` remains app-scoped in `UserDefaults.standard`, while post-login onboarding phases are persisted per account in `Account.userDefaults`.
- Account onboarding progress now uses `loginPhase` as the single source of truth.

## Recommended extensions

- Add new UI state to `BrowserState` if it is per-window.
- Use `AppState` only for truly global toggles.
- Prefer Combine publishers instead of custom notification patterns.

## Preferences state

- General Preferences SwiftUI views bind persisted toggles with `@AppStorage` on top of `PhiPreferences.GeneralSettings`.
- `alwaysShowURLPath` is surfaced in General settings and remains backed by `PhiPreferences.GeneralSettings.alwaysShowURLPath` in `UserDefaults`.
