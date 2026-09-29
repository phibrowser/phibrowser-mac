# Developer documentation

These documents explain the macOS client's current ownership, integration
contracts, failure modes and verification entry points. Start with the repository
[README](../README.md) and [engineering rules](../AGENTS.md).

## Build and contribution

- [Open-source build](open-source-build.md): capabilities, compile flags and
  artifact checks.
- [Testing](testing.md): hostless checks, hosted XCTest and manual acceptance.
- [Localization](i18n/localization-guidelines.md): string IDs, English source and
  translation ownership.
- [Analytics](analytics.md): native event semantics, identity and consent.

## Native architecture

- [Space and store lifetime](architecture/space-store-lifetime.md)
- [Hosted shell and window verification](hosted-shell-window-fixes-and-testing.md)
- [Sidebar selection and refresh](architecture/sidebar-selection-and-refresh.md)
- [Group overview](architecture/group-overview.md)
- [Split chat ownership](architecture/split-chat-ownership.md)
- [Guest mode and migration](architecture/guest-mode.md)
- [Download profile scope](architecture/download-profile-scope.md)
- [Tab search](tab-search.md)

## Features and integration boundaries

- [Reader integration and extraction](reader-view.md)
- [Folio capture](folio-capture.md) and [native Folio library](folio-native-library.md)
- [Content blocking](content-blocking.md)
- [Site memory management](site-memory-management.md)
- [Profile-scoped connectors](profile-scoped-connectors.md)
- [Service broker extension boundary](service-broker-extension-boundary.md)
- [Sidecar scene restoration](sidecar-travel-back.md)
- [Sentinel lifecycle](sentinel-lifecycle.md) and [Phi Chat hotkey](sentinel-phi-chat-hotkey.md)
- [Bitwarden integration](bitwarden-password-manager.md)
- [Native sync contracts](sync.md) and [Sync E2E cases](sync-e2e-test-cases.md)
- [Crash feedback](crash-feedback.md) and [feedback attachments](feedback-attachments.md)
- [Time Machine](time-machine.md) and [uninstall](phi-uninstall.md)

## Applicability and maintenance

The custom Chromium framework, extensions, helper binaries, Sentinel and hosted
services are companion components. This repository documents the boundaries its
native code consumes, not the private implementation of those components.
Source references into this repository are relative links. Companion behavior
requires validation against an identified compatible artifact.

The open-source configuration disables account authentication, Phi AI and official
service integrations as described in the build guide. A feature document can
still help someone contribute to the published client even when that feature
cannot be exercised in a self-built open-source app.

Document durable decisions, contracts and known limitations. Keep execution
plans, agent-specific prompts, workstation paths, incident transcripts and
individual run results in task or review records. A test's presence or successful
compilation is not proof that it ran or that a paired integration works.

When changing behavior, update the owning reference and its verification
scenarios. Avoid adding a competing description of the same responsibility.
