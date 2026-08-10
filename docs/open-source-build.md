# Open-source build

Last updated: 2026-08-10

The `PhiBrowser-OpenSource` scheme builds the existing `PhiBrowser` target with
the `OpenSource` build configuration. It is not a separate application target.
This keeps target membership shared while applying the open-source capability
boundary at compile time and validating the final app bundle after linking.

## `PHI_OSS_BUILD`

`Configs/OpenSource.xcconfig` defines the build setting and forwards it to the
Swift compiler:

```xcconfig
PHI_OSS_BUILD = YES
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PHI_OSS_BUILD
GCC_PREPROCESSOR_DEFINITIONS = $(inherited) PHI_OSS_BUILD=1
```

The setting has two purposes:

- Swift and Objective-C code use `#if PHI_OSS_BUILD` and
  `#if !PHI_OSS_BUILD` to include or exclude behavior at compile time.
- Xcode exposes the build setting to build phases as the
  `PHI_OSS_BUILD` environment variable. The `Prune OpenSource Build` phase
  runs only when its value is `YES`.

`PHI_OSS_BUILD` is not a runtime preference and must not be added to
`PhiBrowser-Info.plist`. Code should not attempt to read it from the app bundle.
Official configurations do not define the condition, so their existing
behavior follows the `#else` or `#if !PHI_OSS_BUILD` branches.

The configuration also adds `Sparkle.framework` to
`EXCLUDED_SOURCE_FILE_NAMES`. This is an input-level exclusion; the compile
guards and final-product checks below remain the authoritative Sparkle
boundary.

## Capability changes

The flag currently changes these parts of the application:

| Area | Open-source behavior |
| --- | --- |
| Application identity | The product uses `com.phibrowser.opensource.Mac`, giving it separate preferences, Application Support, and Chromium user-data storage from Canary and public builds. |
| Updates | Sparkle imports, updater state, initialization, update windows, update reminders, and the **Check for Update** menu item are compiled out. |
| Authentication | `PhiBuildCapabilities.supportsAuthentication` is `false`. The application remains in Guest mode, Chromium may open without a login, Dock reopen does not show the login window, account information is unavailable, and token requests return an empty value. |
| AI | `PhiBuildCapabilities.supportsAI` is `false`. The AI preference always reads as disabled, the master switch and dependent settings are disabled, and Chromium is instructed not to enable Phi AI extensions. |
| Account settings | Only the default-browser section is added to the Account settings pane. Profile, sign-in, guest sign-in notice, sharing, and account controls are omitted. |
| Sentinel | The authenticated Sentinel lifecycle and telemetry publisher are not started, and any bundled Sentinel login item is removed from the final product. |
| Chromium telemetry | Metrics reporting is set to off by default after Chromium initializes. |
| Native crash reporting | `SentryService.setup()` is compiled out, and the Sentry framework is removed from the final app bundle. |
| Product analytics | PostHog setup and its launch-time snapshot are compiled out, and the PostHog resource bundle is removed from the final app bundle. |

The flag defines startup and capability behavior; it does not promise that
every source reference to an unavailable SDK is absent. Artifact requirements
are enforced separately by the pruning phase. It is also not a general network
kill switch. Any new feature that reaches a Phinomenon-hosted service must add
an explicit open-source build boundary and corresponding verification.

## `scripts/prune_open_source_build.sh`

The `Prune OpenSource Build` Xcode phase invokes this script after the app has
been linked and its frameworks and resources have been copied. The phase exits
immediately for any build where `PHI_OSS_BUILD` is not `YES`, including Canary
and public builds.

The script accepts one argument: the path to the built `.app`. It then:

1. Validates that the app, its `Contents/MacOS` directory, and its
   `Info.plist` exist, and that the bundle identifier is
   `com.phibrowser.opensource.Mac`.
2. Removes these non-open-source runtime components:
   - `Contents/Frameworks/Sparkle.framework`
   - `Contents/Frameworks/Sentry.framework`
   - `Contents/Resources/PostHog_PostHog.bundle`
   - any bundled Phi Sentinel login item
3. Verifies that the required `Phi Framework.framework` still exists and that
   an app executable has a load command for it.
4. Fails the build if Sparkle content, Sparkle load commands, Sparkle symbols,
   a Sentry load command, or a bundled Sentinel component remains.
5. Deletes and verifies the absence of the Sparkle `Info.plist` keys
   `SUAutomaticallyUpdate`, `SUEnableAutomaticChecks`, `SUFeedURL`,
   `SUPublicEDKey`, and `SUScheduledCheckInterval`.

The script is intentionally both a pruning step and a build-time regression
check. When another component must be excluded from the open-source product,
add its exact bundle path and an appropriate artifact assertion to this script.

Because the open-source scheme shares a target and Swift package graph with
official builds, package resolution may still fetch or build packages that the
open-source product does not use. The contract is about the produced app: it
must not contain or link the excluded runtime components. For Sparkle, the
script enforces this with bundle, `otool`, and `nm` checks.

## Verification

Build the `PhiBrowser-OpenSource` scheme and inspect the product, not only the
source or package graph:

```sh
xcodebuild build \
  -project Phi.xcodeproj \
  -scheme PhiBrowser-OpenSource \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-OpenSource

oss_app=build/DerivedData-OpenSource/Build/Products/OpenSource/Phi.app

find "$oss_app" \( -iname '*sparkle*' -o -iname '*sentry*' -o -iname '*posthog*' \)
otool -L "$oss_app/Contents/MacOS/Phi"
nm -g "$oss_app/Contents/MacOS/Phi" | rg 'SPU|SUAppcast|Sparkle'
plutil -p "$oss_app/Contents/Info.plist" | rg 'SU(AutomaticallyUpdate|EnableAutomaticChecks|FeedURL|PublicEDKey|ScheduledCheckInterval)'
```

The `find`, Sparkle `nm`, and Sparkle plist searches should produce no output,
and `otool -L` should not contain Sparkle or Sentry. The build phase performs
the same critical checks and fails the build if those invariants are broken.

The release acceptance check must also launch a clean open-source build and
confirm through network capture that the default application state makes no
requests to `*.phibrowser.com`. Build Canary or the relevant official scheme
separately to confirm that its updater and other official-only components are
unchanged.
