# URL rules

A URL rule sends matching links to a destination: a user Space, the generic
Incognito target, a new Kiosk, or "Ask every time". Users manage every rule in
one editor (Settings, Navigations, "Manage URL Rules…"; also the Spaces menu).

## Ownership

| Concern | Owner |
| --- | --- |
| Storage, normalization | `LocalStore+SpaceURLRule.swift` (SwiftData `SpaceURLRule`) |
| Editor | [SpaceURLRulesEditor.swift](../Sources/UserInterface/Sidebar/Spaces/SpaceURLRulesEditor.swift) |
| Sync | `URLRuleKind` (see [sync](sync.md#url-rules)) |
| Rule cache, push to Chromium, Space opens | `SpaceManager` |
| Host and URL rules at navigation time | Chromium: `PhiSpaceRoutingNavigationThrottle` and `phi::PhiURLRouter`, from the table Swift pushes |
| External opens, App rules, Ask prompt | `AppController.application(_:open:)` |
| Swift matcher (oracle and external opens) | [URLRouter.swift](../Sources/States/Space/URLRouter.swift) |

Host and URL rules are enforced inside Chromium because omnibox entries, in-page
link clicks and server redirects exist only there and must be re-homed before
the navigation commits. `URLRouter` mirrors the C++ semantics; change both
together.

## Rule encodings

The match kind is encoded in the stored `host` string. There is no kind column.

| Editor kind | Stored host | Path prefix | Matches |
| --- | --- | --- | --- |
| Domain | `github.com` | nil | that host only |
| Domain suffix | `*.github.com` | nil | the host and its subdomains |
| Domain contains | `*hub*` | nil | hosts containing the needle |
| URL | `github.com` | `/org` | the host plus a `/`-bounded path prefix |
| App | `app:com.tinyspeck.slackmacgap` | nil | external opens sent by that app |

An App rule host is `SpaceRoutingRule.sourceAppHostPrefix` plus the lowercased
bundle id. It is a normalization fixed point, so it needs no schema or proto
change and syncs as an ordinary host string.

## Where each kind applies

- **Host and URL rules** apply to every navigation, through Chromium.
- **App rules** apply only to external opens that arrive through
  `application(_:open:)`. The URL matcher skips them, and
  `pushRoutingTableToChromium()` never sends them to Chromium. A link clicked
  inside Phi is never matched by an App rule.

## External open evaluation order

1. `application(_:open:)` captures the sender first (`ExternalOpenSender`).
   Each URL keeps its sender's bundle id through the browser-access queue and
   the cold-launch coalescing queue. Links the Phi Chat app opens join the
   same path, handed over by Chromium (`openPhiChatLinks:`, chromium ADR
   0019), with no sender. A Phi Chat link first activates Phi, before the
   login gate, because macOS has already done so for another application's
   link unless it was opened in the background (`open -g`, AppleScript
   `open location` without `activate`, `NSWorkspace.open` with `activates`
   false): Chromium picks the window by the profile that last became main
   while Phi was active. A batch holding one is forwarded only once Phi is
   active: at once on `didBecomeActive` if nothing else holds it, otherwise
   on a later retry, and on the retry timeout if activation never comes. With
   no window and none coming it does not wait for activation.
2. Authentication resume and deep links are handled as before, for opens from
   macOS only: a Phi Chat link is never either (`ExternalOpenSource.steps`).
3. Once rules are loaded, `forwardOpenURLsToChromium` gives every URL whose
   sender matches an App rule to that rule:
   - "Ask every time" is checked first, whatever the target, and shows the
     Space chooser with the rule's target (Kiosk included) as default;
   - otherwise a Space or Incognito target opens through
     `SpaceManager.openExternalURLs(_:inURLRuleTargetSpaceId:)`;
   - otherwise a Kiosk target opens a new Kiosk; if that fails, the URL
     continues to step 4.
4. Every other URL follows the existing path: the external-links-in-Kiosk
   preference with host rules evaluated in Swift
   (`ExternalKioskURLRuleResolver`), or a direct forward to Chromium, which
   routes it by host rules. The Swift resolver also checks "Ask every time"
   before the target, so a Kiosk rule set to ask prompts instead of opening a
   Kiosk silently.

A batch reaches step 3 once rules are loaded, a browser window is registered
(a Kiosk open needs none, but a cold one waits for a regular window to show)
and no windowless session restore is in flight
(`AppController.mayForwardExternalOpenNow`). Forwarded mid-restore, the link's
window request would be dropped and Chromium would pick its window before the
restored ones settle. Until then it waits on 0.5 s retries, at most 8 (30 for
a cold Kiosk open), and then goes out anyway. An open that arrives with
browser access while every window is closed and none is coming back goes out
at once, unless earlier opens are still queued: it then joins them. Otherwise
a batch holding a Phi Chat link also waits for Phi to be active (step 1).

While every window is closed and the restore switch is on, an open that a rule
sends to a Space (an App rule's Space or Incognito target, or, with the Kiosk
preference on, a host or URL rule's Incognito target) and every external ask
first restore the session, as a Dock click does, and go on once it settles
(`SpaceManager.runAfterWindowlessRestore`, chromium ADR 0020). The ask's
chooser then shows on a restored window. With the Kiosk preference off this
changes nothing: the batch already waited for that restore.

When an external ask still has no window to host the chooser, the URL opens in
the rule's default destination: a new Kiosk for a Kiosk default, otherwise that
Space.

Ask prompts queue per source window in the order the URLs arrived and are
shown one at a time; answering or declining one presents the next. This holds
for external opens (a batch of links, or a coalesced cold-launch batch) and for
in-browser navigations asked by Chromium while a chooser is already up. A
queued prompt is never replaced. If the source window closes, its queued
prompts are dropped with a warning log, because nothing is left to host them.
If the Space leaves a hosted shell unanswered, the open prompt and every queued
one resolve as declined (the URL stays in its Space).

Several App rules for one bundle id are ordered by lower sort order, then by the
same account-level tie-break host rules use. A rule whose target Space is
deleted or hidden is ignored, as it is for the Chromium table.

## Precedence and exemption

For an external open, an App rule wins over every host and URL rule and over
the Kiosk preference. Within any rule, "Ask every time" takes precedence over
the rule's target, Kiosk included: the target is only the chooser's default.
Swift (App rules and `ExternalKioskURLRuleResolver` for host rules) matches
Chromium's `PhiURLRouter`, which checks ask before the Kiosk target. The tab it opens is created with
`openTabBypassingSpaceRouting`, a one-shot exemption, so Chromium's host rules
do not re-route it. Later navigations in that tab are routed normally.

## Sender capture

`ExternalOpenSender.captureCurrent()` reads the Apple event AppKit is
dispatching, which is valid only during that call. It tries the sender process
id attribute, then the original address attribute (a process id or a bundle id
string). A result naming Phi itself is discarded. Each capture logs one
`[ExternalLinks] sender …` info line.

Limitation: opens relayed by another process, such as some sandboxed apps,
Shortcuts or the `open` command, may carry no usable sender or name the relay.
App rules then do not apply and the URL follows the existing path. The
frontmost application is never used as a fallback because it is often not the
sender.
