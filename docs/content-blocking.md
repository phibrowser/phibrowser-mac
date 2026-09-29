# Content blocking

The native client owns settings and presentation. The supplied framework owns
filtering, list storage and request matching. This document describes the native
contract; it does not include the framework's engine implementation.

## User-visible contract

- Ads, trackers and cookie banners have separate per-Profile switches, initially
  off. Turning on a category without usable rules opens the rule chooser.
- Downloads are user initiated through the chooser, individual download actions,
  update actions or custom URL lists. Do not silently add background downloads.
- Catalog files are shared across Profiles, while each Profile chooses which
  lists it uses. Custom rules and site exceptions are Profile-scoped.
- Removing a Profile's selection is different from deleting a shared catalog
  file. The native UI does not offer deletion that would disable other Profiles.
- The site toggle uses the framework's registrable-domain result. The current
  bridge addresses regular Profiles, so private windows do not expose that row.
- Unsupported framework versions show unavailable state rather than inventing
  successful settings changes.

## Native ownership and bridge

`ContentBlockingSettings` is the native accessor. Views consume its state instead
of calling the bridge directly. Optimistic changes revert when the framework
refuses them. `contentBlockingStatusChanged:` refreshes state for rule generation,
status and downloads, including lists not currently selected by a category.

The bridge includes settings reads, category/list/site-exception writes, custom
list creation/removal, catalog download and refresh methods. Declarations and
availability guards in the accessor are the source of truth. Payloads use
protocol types; calls are checked with `responds(to:)` for older frameworks.

| Status | Meaning |
| --- | --- |
| `active` | A usable configuration is active |
| `building` | Rules are being prepared |
| `degraded` | A new build failed while previous usable rules remain |
| `disabled` | Categories are off |
| `no_lists` | A selected category has no usable downloaded rules |

Do not treat download completion as proof that a page was filtered. Request
blocking and page cosmetics require the compatible framework and an actual page
reload. The integration does not promise scriptlet execution, redirect filters,
cookie-consent clicking or interception of responses served from Cache Storage.

## Analytics and verification

Native launch analytics include only the three category booleans, from the
Profile settings mirror. No rule, URL or site is added to that snapshot. A Profile
whose settings have not been observed can still have the mirror's default value;
see [analytics](analytics.md).

Source entry points:

- [Settings accessor](../Sources/ChromiumBridge/ContentBlockingSettings.swift)
- [Settings UI](../Sources/UserInterface/Preferences/Profiles/ContentBlockingSettingsSection.swift)
- [Rule chooser](../Sources/UserInterface/Preferences/Profiles/ContentBlockingRuleSetSheet.swift)
- [Site toggle](../Sources/UserInterface/WebContent/Header/SiteContentBlockingToggle.swift)
- [Analytics mirror](../Sources/States/ContentBlockingAnalytics.swift)

Focused `ContentBlockingSettingsTests`, rule-sheet/custom-filter tests and
`SiteContentBlockingToggleTests` cover native behavior. Follow [testing](testing.md)
for execution. Manual checks should cover unavailable framework support, a failed
download, enabling/disabling rules, a custom rule and two Profiles sharing a list.
