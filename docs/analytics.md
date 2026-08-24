# Analytics

Last updated: 2026-08-24

Phi Browser emits product analytics to both [Countly](https://phi-browser-eaade70cfd902.flex.countly.com) (legacy) and [PostHog](https://us.posthog.com/project/385742) (current). Both pipelines run side-by-side; PostHog is the forward-looking source of truth.

## Initialization

| Pipeline | Init site | Config source |
| --- | --- | --- |
| PostHog | `AppController.applicationWillFinishLaunching` (`Sources/Application/AppController.swift`) | `PostHogEnv` → `PostHogGeneratedConfig` (compiled-in constants from `Sources/Utilities/PostHogConfig.generated.swift`) |
| Countly | `EventTracker.initTracker()` (`Sources/Utilities/EventTrack/EventTracker.swift`) | Hardcoded in source, split by `NIGHTLY_BUILD || DEBUG` |

The `OpenSource` configuration compiles the PostHog initialization block out
and removes its resource bundle from the final app. See
[Open-source build](open-source-build.md) for the complete build boundary.

PostHog SDK config uses `captureApplicationLifecycleEvents = true`, so `$app_installed`, `$app_updated`, `$app_opened`, `$app_backgrounded` are auto-captured — these power DAU and retention.

If the project token or host is empty, `AppController` logs a warning and skips PostHog init; the app runs without analytics rather than crashing.

### PostHog config pipeline

```
build-scripts/posthogConfig                           ← source of truth (checked in)
  ↓  build-scripts/generate-posthog-config.sh
Sources/Utilities/PostHogConfig.generated.swift       ← checked in with empty defaults; overwritten at archive time
  ↓  compiled into the binary
PostHogGeneratedConfig.{projectToken,host}
  ↓  read by
PostHogEnv.{projectToken,host}.value
```

The values are no longer written into `PhiBrowser-Info.plist`, so they can't be extracted with a one-liner `PlistBuddy` against the installed bundle. They do still live in the Mach-O as string literals (PostHog project tokens are public write keys by design), so this is defense-in-depth, not a secret.

Nightly and release builds share the same self-hosted PostHog instance; the bundle identifier (`$app_namespace`) — which contains `.canary.` for nightly — is the way to split the channels in dashboards. Each archive script (`adhoc-build.sh`, `nightly-build.sh`, `public-build.sh`) invokes the generator before `xcodebuild`.

A plain Xcode Run/Debug compiles the empty-value default and runs without PostHog; no setup script is needed. After a local archive, the generated file will show up as locally modified — don't commit that.

## Sentinel telemetry consent contract

Chromium owns the device-level metrics preference. Phi publishes its current
value to the `group.com.phibrowser.shared` App Group so Sentinel and its managed
services can apply the same consent without duplicating the preference.

| Channel | Shared file | Notification |
| --- | --- | --- |
| Stable | `telemetry-consent.plist` | `com.phibrowser.telemetryConsentDidChange` |
| Canary | `telemetry-consent-canary.plist` | `com.phibrowser.canary.telemetryConsentDidChange` |
| Dev | `telemetry-consent-dev.plist` | `com.phibrowser.dev.telemetryConsentDidChange` |

The atomically written plist contains `SchemaVersion` (`1`), `Enabled`, a UUID
`Revision`, and `UpdatedAtMillis`. A revision is retained across browser
restarts while the effective state remains unchanged and replaced whenever the
state changes or an invalid snapshot is repaired.

The Chromium bridge exposes a live getter but no change callback, so Phi polls
it once per second after Chromium finishes launching. A temporarily unavailable
bridge does not overwrite an existing snapshot; consumers fail closed when no
valid snapshot exists. Distributed notifications are wake-up hints only. A
consumer must reread and validate the shared plist instead of trusting a
notification payload.

## Identity

| Boundary | PostHog call | Location |
| --- | --- | --- |
| Active account changed | `identify(auth0.sub, userProperties)` | `AccountController/Account.swift` |
| Logout | `capture("user_logged_out")` then `reset()` | `Onboarding/AuthManager.swift` |
| Effective metrics reporting change | Capture anonymous `metrics_reporting_changed`, then identify only after opt-in | `ChromiumBridge/PhiChromiumCoordinator.swift` |

Distinct ID == Auth0 `sub`. When Chromium metrics reporting is enabled, identify also sets `chromium_metrics_client_id` to Chromium's UMA client ID. A temporarily unavailable client ID does not prevent identification.

Phi explicitly sets `reuseAnonymousId` to `false`. An anonymous identity is
stable across app launches until `reset()` ends that anonymous phase. A
successful `identify()` sends `$anon_distinct_id`, associating events from the
current anonymous phase with the account being identified. After a reset,
events cannot be associated with the account that was active before the reset,
but can be associated with the next account that completes `identify()`.

If a Guest or metrics-disabled launch finds a residual authenticated identity
from an earlier version or abnormal shutdown, Phi drops the synchronous
`Application Installed` or `Application Updated` event that PostHog emits
during setup, then resets before capturing the launch snapshot and later
anonymous events.

## Super properties

We don't register any custom super properties. Everything we need is auto-attached by the SDK: `$app_version` (from `CFBundleShortVersionString`), `$app_build` (from `CFBundleVersion`), `$app_namespace` (the bundle identifier — filter on `contains '.canary.'` to split canary vs. release), `$app_name`, `$os_name`, `$os_version`, `$lib`, `$lib_version`, `$device_*`, `$locale`, `$timezone`.

## Feature flags

Feature flag payloads are resolved through `ExperimentConfigProvider`. The live provider uses `getFeatureFlagResult(_:)` so reading a payload also records the feature flag exposure for experiment attribution.

| Flag key | Payload keys | Defaults | Allowed range | Consumer |
| --- | --- | --- | --- | --- |
| `auth0-refresh-timing` | `refresh_check_interval_seconds`, `refresh_urgent_window_seconds` | `3600`, `3600` | check interval: `300...86400`; urgent window: `300...604800` | `AuthManager` refresh timer and renew preflight |

## Events

All custom events are snake_case. The custom-event rows below inventory names
emitted by shipping Phi source, with duplicate call sites consolidated. Events
prefixed `$` are auto-captured by the SDK; Countly-only and SDK-internal events
are out of scope.

| Event | Trigger | File |
|-------|---------|------|
| `$app_opened` | SDK lifecycle auto-capture; enriched with `layout_mode` (`balanced` / `performance` / `comfortable`), `ai_enabled` (bool), and `is_guest_mode` (bool) via a `beforeSend` hook | `Application/AppController.swift` |
| `$app_installed` / `$app_updated` / `$app_backgrounded` | SDK lifecycle auto-capture | — |
| `user_logged_in` | Auth0 login completed | `Onboarding/Login/LoginViewController.swift` |
| `login_retried` | User tapped "Go back and try again" after failed/timed-out login | `Onboarding/Login/LoginViewController.swift` |
| `user_logged_out` | User logged out; identity reset follows | `Onboarding/AuthManager.swift` |
| `metrics_reporting_changed` | Chromium reports an effective metrics and crash-reporting consent transition. The event contains only `enabled` and is captured under the current anonymous identity. A later metrics-enabled authenticated activation may associate that anonymous phase with the account. Initial-state synchronization does not emit it. | `ChromiumBridge/PhiChromiumCoordinator.swift` |
| `guest_mode_entered` | User successfully crossed the local credential boundary and entered Guest Mode | `Onboarding/LoginController.swift` |
| `guest_mode_exited` | Guest account migration and authenticated account publication completed; `trigger` is `account_setting` or `ai_setting` | `Onboarding/LoginController.swift` |
| `oobe_step_viewed` | OOBE presents a semantic step; includes stable `step`, one-based `step_index`, and `is_guest` | `Onboarding/OOBEAnalyticsSession.swift` |
| `oobe_step_completed` | The current OOBE step accepts its user action; includes the step properties and monotonic `duration_seconds` | `Onboarding/OOBEAnalyticsSession.swift` |
| `oobe_finished` | Authenticated browser access is published or Guest entry succeeds; includes `is_guest`, `steps_completed`, and active `total_duration_seconds` | `Onboarding/OOBEAnalyticsSession.swift` |
| `oobe_interrupted` | The user directly closes the OOBE window before success, or Phi terminates while it is active; includes the last step, active duration, and `reason` (`window_closed` or `app_terminated`) | `Onboarding/OOBEAnalyticsSession.swift` |
| `onboarding_completed` | **Legacy compatibility event:** user tapped Next on the theme welcome screen. Its historical name and trigger remain unchanged; new OOBE events use the `oobe_` prefix | `Onboarding/Welcome/OnboardingWelcomeViewController.swift` |
| `import_viewed` | The browser-data import window is presented or brought forward; `entry_point` is always `menu` | `MainBrowserWindow/MainBrowserWindowController+Actions.swift` |
| `import_types_selected` | The user commits an import; emitted once per selected source with normalized `types`. File imports use an empty array because Chromium detects their contents | `Onboarding/Importer/BrowserDataImporter.swift` |
| `import_started` | The importer accepts a non-reentrant run and locks its target; includes sorted `source_browsers` | `Onboarding/Importer/BrowserDataImporter.swift` |
| `import_finished` | All selected Chromium sources and deferred bookmark persistence finish; includes aggregate success, stable failed sources, duration, and an optional low-cardinality `error_code` | `Onboarding/Importer/BrowserDataImporter.swift` |
| `first_time_action` | An eligible product action first succeeds on this installation; `action` is one of `space_created`, `ai_sidebar_opened`, `import_finished`, `memory_opened`, `agent_task`, or `connector_connected`, with `seconds_since_install` | `Utilities/FirstTimeActionTracker.swift` |
| `space_created` | A user-created Space succeeds; includes `total_spaces` and whether it uses a non-default profile | `Sidebar/Spaces/CreateSpacePanel.swift` |
| `profile_created` | A non-fallback profile is successfully created; includes `total_profiles` | `States/ProfileManager.swift` |
| `space_profile_changed` | A validated Space profile change begins; includes `total_profiles` | `States/Space/SpaceManager.swift` |
| `space_switched` | A user-initiated switch activates a different Space; includes `total_spaces` | `States/Space/SpaceManager.swift` |
| `space_deleted` | The user confirms deletion of a non-default Space from the sidebar or Settings | `Sidebar/Spaces/SpacesStripView.swift`, `Preferences/Spaces/SpacesSettingsView.swift` |
| `ai_features_toggled` | User enabled/disabled AI features in settings | `Preferences/AISettings/AISettingView.swift` |
| `connector_status` | Snapshot of each AI connector's connected/disconnected state, fired on refresh | `Preferences/AISettings/AISettingsConnectorViewModel.swift` |
| `ai_sidebar_opened` | A tab's AI sidebar changed from collapsed to expanded; `trigger` is `button`, `shortcut`, or `restore` | `WebContent/WebContentViewController.swift` |
| `ai_sidebar_closed` | A tab's AI sidebar changed from expanded to collapsed; includes that tab's `duration_seconds` dwell time | `WebContent/WebContentViewController.swift` |
| `kiosk_opened` | A Kiosk window's first tab becomes ready to display; profile-replacement windows do not emit it | `MainBrowserWindow/KioskBrowserWindowController.swift` |
| `kiosk_opened_in_space` | A Kiosk page starts transferring into a Space; includes `total_spaces` without Space identifiers | `States/Space/SpaceManager.swift` |
| `kiosk_profile_changed` | A Kiosk profile replacement is revealed; includes `total_profiles` without profile identifiers | `MainBrowserWindow/KioskBrowserWindowController.swift` |
| `agent_task_started` | An agent task record is created or rebound; includes `origin`, `persistent`, and normalized `agent_name` | `States/AgentSpace/AgentSpaceManager.swift` |
| `agent_task_completed` | An active task ends through the completion path; includes the start properties and `success` | `States/AgentSpace/AgentSpaceManager.swift` |
| `agent_user_space_command` | An agent command passes the user-space browsing-data permission gate; includes `command` and normalized `agent_name` | `Notifications/MessageCard/ExtensionMessageRouter.swift`, `States/AgentSpace/AgentSpaceRouter+Management.swift` |
| `agent_credential_access_requested` | Agent credential access is evaluated; includes `kind`, `approved`, `prompted`, and normalized `agent_name` without credential scope or content | `States/CredentialAccessCoordinator.swift` |
| `agent_credential_access_approved` | Credential access is approved by a prompt or existing grant; includes `kind`, `approval_type`, and normalized `agent_name` | `States/CredentialAccessCoordinator.swift` |
| `scripting_command_invoked` | An allowlisted AppleScript command other than version checking returns; includes command, outcome, success, and bounded client attribution | `Application/Apple Scripts/PhiScriptCommands.swift` |
| `language_changed` | Phi's General settings picker changes from one stored language preference to another; includes only `from` and `to` | `Preferences/General/GeneralSettingView.swift` |
| `feature_entry_tapped` | A visible Chat, Memory, Download, or Organize Tabs entry accepts a tap; `button` is `chat`, `memory`, `download`, or `organize_tabs`, and `surface` is `sidebar` or `web_content_header` | `Sidebar/SidebarViewController.swift`, `Sidebar/TabList/Views/SidebarCellViews.swift`, `WebContent/FloatingSidebar/FloatingSidebarViewController.swift`, `WebContent/Header/WebContentHeader.swift`, `HorizontalBar/TabStrip/TabStripRightButtons.swift` |
| `bookmark_manager_opened` | A native Bookmark Manager page session starts | `WebContent/BookmarkManager/BookmarkManagerViewController.swift` |
| `bookmark_manager_edited` | A Bookmark Manager page session ends after the user performed at least one edit; the event carries no bookmark or edit details | `WebContent/BookmarkManager/BookmarkManagerViewController.swift` |
| `user_defaults_snapshot` | Launch-time snapshot of new-tab behavior, layout mode, active process language (`app_language`), appearance, default browser, proactive suggestions, automatic current-tab context, and Peek/Kiosk preferences | `Application/AppControlle+LaunchInfo.swift` |
| *Chromium-originated events* | Captured in the browser core through `phi_analytics::Capture()`, not by Mac code; inventoried in the Chromium-side registry — see [Chromium-originated events](#chromium-originated-events) below | Chromium repo, `chrome/browser/phinomenon/analytics/README.md` |

Import analytics never include source paths, browser profile names, Arc Space
names, file names, or imported item counts. The current Chromium delegate
reports only source and aggregate success, so per-type counts are unsupported.
Bookmark persistence success uses the completion reported by the existing
LocalStore async API; lower-level model save failures remain local logs rather
than analytics failures.

`language_changed` is emitted only by Phi's picker. A language change made in
macOS System Settings is not observable as a user action inside the running
process; the next launch's `user_defaults_snapshot.app_language` reports the
language actually active for that process.

Naming rule: **don't reuse PostHog-reserved names** (anything starting with `$`, or that collides with SDK-auto events like "app installed"). For features that could be ambiguous with app-level concepts (e.g. downloads), prefix with the feature scope (`file_download_*`, not `download_*`).

## Chromium-originated events

Chromium browser-process code captures events through the `phi_analytics`
component (Chromium repo, `chrome/browser/phinomenon/analytics/`). They cross
the bridge delegate's `captureAnalyticsEvent:module:properties:` into
`ChromiumBridge/ChromiumAnalyticsRelay.swift`, which stamps
`source: "chromium"` and `module` onto every accepted event, drops reserved
`$`-prefixed names, logs each accepted capture (the end-to-end observable on
token-less local builds), and skips the SDK call when PostHog was never
initialized. The relay checks no consent — the metrics-reporting switch gates
identity association, not event flow, same as for Mac events. Delivery is
best-effort: an event racing browser exit may be lost.

Those events are not inventoried in the table above. Their registry lives
beside the component: `chrome/browser/phinomenon/analytics/README.md` in the
Chromium repo, with the naming rules and privacy contract they follow.

## Adding a new event

1. Call `PostHogSDK.shared.capture("snake_case_name", properties: [...])` at the action site. Import `PostHog` in the file.
2. If a matching Countly event already exists, keep both calls side-by-side during migration.
3. Add a row to the Events table above.

For a Chromium-originated event the flow lives on the Chromium side instead:
call `phi_analytics::Capture()` at the action site and add the registry row to
`chrome/browser/phinomenon/analytics/README.md` in the same change — nothing
changes on the Mac side.
