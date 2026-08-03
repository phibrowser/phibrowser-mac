# Analytics

Last updated: 2026-08-03

Phi Browser uses PostHog for product analytics and Sentry for crash/error reporting. Both
pipelines are controlled by Chromium's **Help improve Phi's features and performance**
setting. When that setting is off, outbound events are rejected and persisted analytics
identity is reset. Sentry is stopped, its transport is cancelled, and its queued cache is
deleted so previously accepted offline envelopes cannot upload after opt-out.

## Initialization

| Pipeline | Init site | Config source |
| --- | --- | --- |
| PostHog | `AppController.applicationWillFinishLaunching` (`Sources/Application/AppController.swift`) | `PostHogEnv` → `PostHogGeneratedConfig` (compiled-in constants from `Sources/Utilities/PostHogConfig.generated.swift`) |
| Sentry | `SentryService.setup()` (`Sources/Utilities/Sentry/Sentry.swift`) | Native Sentry configuration |

PostHog SDK config uses `captureApplicationLifecycleEvents = true`, so `$app_installed`, `$app_updated`, `$app_opened`, `$app_backgrounded` are auto-captured — these power DAU and retention.

If the project token or host is empty, `AppController` logs a warning and skips PostHog init; the app runs without analytics rather than crashing.

`PhiChromiumCoordinator.currentNativeSettings()` publishes the same live measurement state,
account presence, Phi AI master switch, and Browser Memories switch to preinstalled
extensions. `AppController` observes the Chromium-owned measurement setting and republishes
changes; account and AI-setting changes publish through the same snapshot. The main-thread
observer caches measurement consent and Chromium's metrics client ID in
`PhiChromiumCoordinator`; account and telemetry SDK worker callbacks read that locked snapshot
rather than calling Chromium off-thread. Missing bridge state fails closed.

Sentry starts only while measurement consent is enabled. Opt-out cancels its URL session, closes
the SDK with a zero-second shutdown window, and removes both cached envelopes and its persisted
installation identifier. Opt-in starts a fresh SDK transport. Automatic session tracking remains
enabled for opted-in periods so release-health metrics remain complete without crossing an
opted-out period.

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

## Identity

| Boundary | PostHog call | Location |
| --- | --- | --- |
| Active account changed | `identify(auth0.sub, userProperties)` | `AccountController/Account.swift` |
| Logout | `capture("user_logged_out")` then `reset()` | `Onboarding/AuthManager.swift` |

Distinct ID == Auth0 `sub`. When Chromium metrics reporting is enabled, identify also sets `chromium_metrics_client_id` to Chromium's UMA client ID. A temporarily unavailable client ID does not prevent identification. Turning measurement off resets PostHog identity and clears the Sentry user.

## Super properties

We don't register any custom super properties. Everything we need is auto-attached by the SDK: `$app_version` (from `CFBundleShortVersionString`), `$app_build` (from `CFBundleVersion`), `$app_namespace` (the bundle identifier — filter on `contains '.canary.'` to split canary vs. release), `$app_name`, `$os_name`, `$os_version`, `$lib`, `$lib_version`, `$device_*`, `$locale`, `$timezone`.

## Feature flags

Feature flag payloads are resolved through `ExperimentConfigProvider`. The live provider uses `getFeatureFlagResult(_:)` so reading a payload also records the feature flag exposure for experiment attribution.

| Flag key | Payload keys | Defaults | Allowed range | Consumer |
| --- | --- | --- | --- | --- |
| `auth0-refresh-timing` | `refresh_check_interval_seconds`, `refresh_urgent_window_seconds` | `3600`, `3600` | check interval: `300...86400`; urgent window: `300...604800` | `AuthManager` refresh timer and renew preflight |

## Events

All custom events are snake_case. Events prefixed `$` are auto-captured by the SDK.

| Event | Trigger | File |
|-------|---------|------|
| `$app_opened` | SDK lifecycle auto-capture; enriched with `layout_mode` (`balanced` / `performance` / `comfortable`) and `ai_enabled` (bool) via a `beforeSend` hook | `Application/AppController.swift` |
| `$app_installed` / `$app_updated` / `$app_backgrounded` | SDK lifecycle auto-capture | — |
| `user_logged_in` | Auth0 login completed | `Onboarding/Login/LoginViewController.swift` |
| `login_retried` | User tapped "Go back and try again" after failed/timed-out login | `Onboarding/Login/LoginViewController.swift` |
| `user_logged_out` | User logged out; identity reset follows | `Onboarding/AuthManager.swift` |
| `onboarding_completed` | User tapped Next on welcome screen | `Onboarding/Welcome/OnboardingWelcomeViewController.swift` |
| `ai_features_toggled` | User enabled/disabled AI features in settings | `Preferences/AISettings/AISettingView.swift` |
| `connector_status` | Snapshot of each AI connector's connected/disconnected state, fired on refresh | `Preferences/AISettings/AISettingsConnectorViewModel.swift` |
| `ai_chat_page_opened` | AI Chat page became visible | `Chat/AIChatViewController.swift` |
| `ai_chat_page_viewed` | Fires on AI Chat page close, with `duration_seconds` dwell time | `Chat/AIChatViewController.swift` |
| `user_defaults_snapshot` | Launch-time snapshot of selected preferences (NTP, AI toggles, default browser, appearance) | `Application/AppControlle+LaunchInfo.swift` |

Naming rule: **don't reuse PostHog-reserved names** (anything starting with `$`, or that collides with SDK-auto events like "app installed"). For features that could be ambiguous with app-level concepts (e.g. downloads), prefix with the feature scope (`file_download_*`, not `download_*`).

## Adding a new event

1. Call `PostHogSDK.shared.capture("snake_case_name", properties: [...])` at the action site. Import `PostHog` in the file.
2. Do not add a second telemetry transport; the global PostHog consent hook is the required
   enforcement boundary.
3. Add a row to the Events table above.
