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
| `com.phibrowser.Mac` | `com.phibrowser.athena` | `com.phibrowser.athena.service` |
| `com.phibrowser.canary.Mac` | `com.phibrowser.canary.athena` | `com.phibrowser.canary.athena.service` |
| `com.phibrowser.Mac` | `com.phibrowser.folio` | `com.phibrowser.folio.service` |
| `com.phibrowser.canary.Mac` | `com.phibrowser.canary.folio` | `com.phibrowser.canary.folio.service` |

The app is Athena; it was called Folio until 2026-10-30 and signed with the
`folio` identifiers until 2026-11-11. Both sets are admitted, so a build from
before the rename keeps working.

A build accepts the channels paired with its own bundle id; DEBUG builds accept
all of them. The identity key is per app, not per channel:
`phi:companion:com.phibrowser.folio`. Its display name, used wherever Phi
names the driving peer, is "Athena". The responsibility lookup is resolved at
runtime and fails closed when unavailable.

A third shape is a process the app spawned that is signed as nothing of the
companion's: Folio drives Spaces through the phi-browser skill by running the
user's own `node` on the skill's runner, straight from the app. It is admitted
on the app's account when the process macOS holds responsible for it is an app
that passes the app shape above (the channel's app requirement, its bundle's
main executable, no `DYLD_*`), and its own exec-time environment has no
`DYLD_*` and no `NODE_*` but `NODE_ENV`. It is an agent the companion vouches
for, not the companion: its identity carries `companionLauncher` rather than
`companion`, so `evaluate` admits it without a prompt but it gets the agent
surface instead of the allowlist, is named in the driver roster, and is
severed with the other agents when agent CDP access is turned off. Its pid
is the app's, so every round the app runs shares one driver session, and its
key is the app's agent key (`phi:companion:com.phibrowser.folio:agent`), so
that session is never the app's own scoped one. Left to the
ancestry walk, the same connection would read as Phi's own code started
outside the browser and be refused without a prompt.

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

Actions with `menu` `file` or `both` become File menu rows after Save Page
(and Save to Folio when present), tagged `AppController.filePageActionItemTag`
and rebuilt with the menu. At validation a row is hidden in off-the-record
windows unless `incognito` is true, and disabled unless the active page
matches `documentUrlPatterns` (`chrome.contextMenus` match patterns; none
means every page). A shortcut becomes the row's key equivalent only when no
menu row or configured command already owns that key.

Actions with `menu` `context` or `both` also show in the web-content
right-click menu, after the extensions' items. That menu is Chromium's, so
the registry pushes those rows down on every change
(`setPageActionContextMenu:`, kept in `phi::PhiPageActionMenuRegistry`), and
Chromium shows a row when the menu was opened on one of its `contexts`
(`selection` for selected text, `link` on a link, `page` on the page itself),
the page matches its `documentUrlPatterns`, and the window is not off the
record unless `incognito` is true.

Choosing a row sends `pageActions.invoked` to the registering channel only:
`{ id, tabId, targetId?, url, title, profileId, windowId, isIncognito }`.
`targetId` is the tab's DevTools page target id, omitted when unavailable.
A right-click invocation also carries `selectionText` and `linkUrl` when the
menu was opened on them; File-menu invocations carry neither.

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

## Athena Canary internal trial

Build the native client with the Release-Canary configuration and add
`ATHENA_CANARY_TRIAL` to its existing Swift compilation conditions. Package
the signed browser and the signed `Athena Canary.app` together in one folder.
Omit the Sentinel login item. Both apps keep their Canary identifiers so that
the shared sign-in and the browser companion signature check work. Testers
quit their regular Canary apps before opening the trial and keep both trial
apps together when moving the folder.

Build the trial extensions in a fresh staging directory.

```sh
python3 build-scripts/build-athena-canary-extensions.py \
    "$ATHENA_CHECKOUT" "$ATHENA_REVISION" "$EXTENSION_VERSION" "$STAGING/Default Apps"
```

Keep the Canary launch switch `--phi-no-embed-extensions`. Both choices use
the same Canary user-data root and extension IDs. On every trial launch the
native bootstrap registers the four signed CRXs with Chromium's per-user
`External Extensions` provider before loading profiles. Chromium checks the
signature, ID and version and performs the install or upgrade as each profile
opens. Chromium can defer an in-use extension update until the next browser
launch. The default-app provider alone only seeds new profiles. Use an extension
version newer than the versions in the Canary profiles being upgraded.

The build script produces Sidecar, Lexington, Kensington and
Mirage from that Athena revision using its locked dependencies and staging
signing keys. The external install descriptors retain the existing Canary IDs.
The Athena staging builds append ` Athena` to their extension names. Hold
Option and open Help → Extension Info to see which builds the profile loaded.
The trial CRXs omit the regular staging update feed. Ship updates in a newer
trial bundle. Replace the staged framework's `Versions/Current/Default Apps`
directory with the output and sign the framework before the enclosing app.

In Settings → Athena, enabling Athena opens the signed sibling app for a
signed-in user and enables Sidecar, Lexington and Kensington. Browser AI
surfaces (chat sidebar, site memory and tab organization) and the extensions'
native settings follow the effective Athena switch. The browser publishes the
signed-in value under the existing AI preference in its process-local defaults
domain, preserving the saved ordinary Canary setting. Disabling Athena closes
open browser AI panels, quits the companion and disables those extensions. Mirage
remains enabled as the browser's web store customizer. A separate preference
controls automatic opening of Athena at browser startup or sign-in. Both
preferences default to on. Athena owns its Runner, service updates and chat UI.
Guest sessions only open the browser. For a signed-in user with Athena enabled,
the existing authenticated Service Broker client resolves the current account's
Athena engine data socket. The storage root is
`~/Library/Application Support/com.phibrowser.canary.athena/engine/<sanitized subject>`
and the short socket directory is `/tmp/phi-athena-<storage path hash>/sockets`.
Athena owns its private Runner control connection. Sentinel supervision and
AI-data export stay disabled. Browser data can still be exported.
The trial browser does not start its nightly updater. It shares Canary's user
data and credentials. Distribute `build-scripts/switch-to-regular-canary.command`
as `Switch to Regular Canary.command` beside the trial apps. To switch back,
quit the trial apps, install a signed regular Canary with newer extensions,
then run that command. It points the four shared registrations at the regular
CRXs and opens the browser. The regular extensions carry their regular OTA URLs.
