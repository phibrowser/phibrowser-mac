# Companion apps

A companion app is a separate Phi-signed app that ships as part of the
product and talks to Phi only over the agent CDP socket — today Folio.app,
through its bundled helper. Phi admits it without the consent prompt, the way
it admits Sentinel's phi-agent, but holds it to a fixed allowlist on the
private `/phi-agent` channel. The interface it implements is the Folio
repository's `docs/contracts.md`.

## Identity

`AgentPeerIdentity.firstPartyCompanion` recognizes a connection after the
same-user check and the phi-agent pass, before the ancestry walk. All of these
must hold for one channel of an `AgentCompanion` entry:

1. the peer's audit token (`LOCAL_PEERTOKEN`) satisfies
   `anchor apple generic and certificate leaf[subject.OU] = "87DQ3HMK5G" and identifier "<helper id>"`;
2. the process macOS holds responsible for it
   (`responsibility_get_pid_responsible_for_pid`) is an app whose code
   satisfies the same requirement with the channel's app identifier;
3. the peer's executable lies inside that app's bundle;
4. it was started the way its app starts it (`AgentCompanion.launchIsUntampered`):
   argv is the helper alone (a native helper) or exactly the runtime plus the
   bundled script (`Contents/Resources/folio-service/folio-service.mjs`), and
   its exec-time environment has no `NODE_*` variable but `NODE_ENV` and no
   `DYLD_*`. A runtime helper's signature says nothing about the code it
   runs, and anyone can choose the app's environment (`open --env`,
   `launchctl setenv`); a `NODE_OPTIONS=--require …` would otherwise run
   their code as the signed helper.

Folio.app may also connect itself, with its backend in the app rather than a
helper: a peer whose audit token satisfies the requirement with the app
identifier and that runs as that bundle's main executable is admitted, whoever
launched it, as long as its exec-time environment has no `DYLD_*` (Node's
variables mean nothing to native code). So Phi and the Runner accept either
shape of Folio without further change.

| Phi bundle id | App identifier | Helper identifier |
| --- | --- | --- |
| `com.phibrowser.Mac` | `com.phibrowser.folio` | `com.phibrowser.folio.service` |
| `com.phibrowser.canary.Mac` | `com.phibrowser.canary.folio` | `com.phibrowser.canary.folio.service` |

A build accepts the channel paired with its own bundle id; DEBUG builds accept
both. The identity key is per app, not per channel:
`phi:companion:com.phibrowser.folio`. The responsibility lookup is resolved at
runtime and fails closed when unavailable.

A helper that fails (2) or (3) gets no pass and resolves like any other peer.

## What a companion is exempt from

`AgentCDPListener.evaluate` admits a companion before standing denials, grants
and the prompt, and regardless of Developer mode and agent CDP access. Turning
agent CDP access off (`setEnabled(false)`) closes every `/phi-agent` channel
except companions'. Its stock CDP connections are still severed, because
Chromium closes injected connections all at once; the helper reconnects through
its pass. Companion connections are not recorded in `AgentCDPDriverRoster`.

The Settings ▸ Developer "Agent permissions" switch
(`userSpaceOperationsEnabled`) does not gate a companion's allowlisted
`/phi-agent` calls (`AgentSpaceRouter.userSpaceOperationsRefusal`). The
guest-transition block, the per-profile agent permission and Chromium's own
DevTools user-Space gate on stock CDP are unchanged.

## Allowlist

`AgentCompanion.allowedMessageTypes`, enforced in
`AgentDirectConnection.dispatchMessage` before anything is routed:

- `agentSpace.shadow.create|list|openTab|ping|close`
- `agentSpace.listProfiles`
- `agentSpace.spaces.list|listTabs|openTab`
- `notification.show`
- `pageActions.register`

Any other type gets `{"id": N, "error": "type_not_allowed"}` at once. Stock CDP
is not restricted. Adding a companion is one `AgentCompanion` entry in `all`.

## Page actions

Only a verified companion's channel can register menu actions
(`companion_required` otherwise): a consented third-party agent can drive the
browser, but it does not get rows that read as Phi's own. The mechanism is
generic, not Folio-shaped. `PageActionRegistry` owns the rows per channel.

`pageActions.register { actions: [{ id, title, menu, contexts, shortcut,
documentUrlPatterns, incognito }] }` replaces the channel's whole set and
replies `{ "registered": [ids] }`. `menu` defaults to `both`, `contexts` to
`["page"]`, `incognito` to false. Entries without an id or title, with an
unknown menu or context, or with a pattern that does not parse are skipped. A
shortcut needs one printable key and the `command` modifier, otherwise only
the shortcut is dropped. Registrations end when the channel closes. A request
from outside a direct channel gets `direct_channel_required`.

Rendering is File menu only: actions with `menu` `file` or `both` become rows
after Save Page (and Save to Folio when present), tagged
`AppController.filePageActionItemTag` and rebuilt with the menu. The page
context menu is built by Chromium and has no Swift-side hook, so `context`
rows are not shown yet. At validation a row is hidden in off-the-record
windows unless `incognito` is true, and disabled unless the active page
matches `documentUrlPatterns` (`chrome.contextMenus` match patterns; none
means every page). A shortcut becomes the row's key equivalent only when no
menu row or configured command already owns that key.

Choosing a row sends `pageActions.invoked` to the registering channel only:
`{ id, tabId, targetId?, url, title, profileId, windowId, isIncognito }`.
`targetId` is the tab's DevTools page target id, omitted when unavailable.
File-menu invocations carry no `selectionText` or `linkUrl`.

## Built-in Folio while Folio.app is connected

While at least one verified Folio companion channel is open,
`SaveForLaterService.featureEnabled` reads false
(`AgentDirectChannelRegistry.hasCompanionChannel`, thread-safe). The registry
posts `.agentCompanionsDidChange` when the first such channel opens or the last
one closes. On it, `AppController.reapplyFolioAvailability` rebuilds the menus
and re-broadcasts `saveForLater.armedChanged`, the same path a PostHog flag
load takes, and the Library, the General and Profiles settings panes and the
Shortcuts list re-read the flag. With no companion connected the flag and
every surface behave exactly as before.
