# Challenges and consent banners — detail

Deep semantics behind SKILL.md's two page-gate rules: Cloudflare challenges
(two bounded passive checks, then handoff) and cookie-consent banners
(auto-dismissed by `goto`/`openTab`). Read this when a challenge appears or a
banner survives the automatic pass.

## Cloudflare challenges

A `goto`/`openTab` that lands on "Just a moment…", or an `observe()` that
returns a near-empty page whose one iframe is `crossOrigin: true` from
`challenges.cloudflare.com`, is a Cloudflare challenge. Confirm with
`detectChallenge()` → `null` or `{vendor, kind, url, title}` where `kind` is
`interstitial` (full-page gate), `turnstile` (widget embedded in a normal
page, e.g. a login form), or `blocked` (a hard block/error page). A stale
"Just a moment..." title alone is not enough: detection also requires a
Cloudflare DOM/asset marker or characteristic verification copy.

A managed Cloudflare browser check can sometimes finish by itself. Before
handoff, call `waitForChallengeClearance()` once. It makes at most two timed,
observation-only rechecks shared across the whole encounter. It does not click,
reload, re-navigate, access the cross-origin iframe, or mutate the page. A
high-level input that discovers Cloudflare uses this same shared budget, so
calling input again cannot multiply the attempts. The budget is persisted by
tab across separate heredoc rounds and is cleared only after the page is
confirmed challenge-free, an explicit navigation starts, the tab closes, or
the task completes.

```js
const cf = await waitForChallengeClearance()
if (!cf.cleared && cf.challenge?.kind !== 'blocked') {
  await handOff('Cloudflare wants a human check on example.com — ' +
                'complete the verification, then click "Hand back".')
  cliLog({ handedOff: true, challenge: cf.challenge,
           passiveChecks: cf.totalAttempts })
  return
}
```

Return shape:

- `{cleared: true, attempts, totalAttempts, challenge: null}` — the managed
  check resolved without input; re-observe because the real page may have
  loaded and every challenge-page ref is stale.
- `{cleared: false, challenge, exhausted: true, ...}` — the two-check budget
  is spent and the challenge remains; hand off now. Do not call the helper or
  an input helper again to create another loop.
- `challenge.kind === 'blocked'` — no checks are attempted because a hard
  block cannot self-resolve; report it instead of handing off.

`attempts` may be set to `1` or `2` (default `2`); the helper caps larger
values at two. `interval` is seconds (default `2.5`, bounded to `0.25–5`).
These are settling observations, not attempts to solve the challenge. NEVER
click a Turnstile checkbox or challenge surface, synthesize pointer/keyboard
input, or inject `js()` into the iframe.

Then end the round, start the hand-back watcher (see SKILL.md ▸ "Hand-back
watcher"), and tell the user in chat. When the watcher fires, re-check
`detectChallenge()` and re-observe before continuing — passing the challenge
reloads onto the real page, so refs from before it are gone. Expect repeats:
clearance can be per-path, so a later navigation on the same site may
challenge again — each genuinely new encounter gets its own two passive
checks, then the same handoff if it remains.

`kind: 'blocked'` has nothing for the user to click either: report it and
ask how to proceed instead of handing off; do not wait, click, or retry the
navigation.

## Cookie-consent banners

`goto()` and `openTab()` automatically run a **static rule set** that dismisses
the common cookie/GDPR banners before returning — a per-CMP accept-all selector
table (OneTrust, Didomi, Cookiebot, Quantcast, Usercentrics, TrustArc, Osano,
Iubenda, …), then per-CMP **close** controls for notice-only banners that ship
no accept control at all (the CCPA OneTrust variant: "Cookie Settings" + ✕
only), matched against the top document and same-origin frames. It is
deterministic: no observe, no screenshot, no model turn. Because banners are
usually injected a beat after load on a first visit, the pass polls briefly for
one to surface — activating the instant a matching control appears, waiting ~1.2s
when nothing consent-like is present yet, and extending (to ~3s) once a banner
is spotted still rendering — so most of the time it is already gone by the time
you look. Opt out per call with `{acceptCookies: false}` (e.g. to test the
banner yourself); tune the wait with `{acceptCookies: {waitMs: 8000}}`.

Every matched control must pass the same topmost-element hit test as an
ordinary human click and is activated with trusted CDP move/press/release
events. The rules never use `element.click()`, so they cannot accept a hidden
or covered control that a person could not reach.

There is a second timing guard: the first high-level input on a document waits
through the remaining part of a short late-banner window and reruns the static
selector pass. Later inputs probe once immediately. If a consent-looking modal
is visibly blocking but no safe accept/close rule matches, Phi refuses the
input instead of sending it through the overlay. Opting out of navigation's
pass with `{acceptCookies: false}` does not disable this input-safety gate.

When a banner is still up — an unlisted CMP, a late injection, or one that needs
the text pass — call `acceptCookies()` yourself. It re-runs the selector tiers
**plus** guarded text heuristics: a visible control whose exact label is an
accept phrase (several languages) inside a consent-looking container — never a
Reject/Manage/Settings control — and, failing that, an explicit Close/✕-labeled
control in the same kind of container. It returns:

- `{clicked: true, rule, text}` — done; re-observe and continue.
- `{clicked: false, reason: 'cross-origin-frame', frameSrc}` — the CMP is in a
  cross-origin iframe page JS can't reach (e.g. Sourcepoint). Fall back to
  `annotatedScreenshot()` + `click(x, y)` on the accept button.
- `{clicked: false, reason: 'none', pending}` — nothing clicked; `pending: true`
  means a consent-looking box is present but no accept control matched, so
  observe and click it yourself.

Why accept rather than dismiss: the banner usually intercepts pointer events for
the whole page; dismissing without choosing tends to re-prompt on every
navigation; and accepting persists consent + session cookies into the shared
profile, so later navigations and rounds start warm instead of cold — fewer
repeated gates. Close controls are therefore tried only AFTER both accept tiers
found nothing — the case of notice-only banners, where closing IS the intended
dismissal (and the vendor persists it, e.g. OneTrust's OptanonAlertBoxClosed).

Distinguish a routine cookie notice (let the rules accept it and move on) from a
genuinely consequential choice — a login, a paywall, a purchase, or an
account-level privacy setting. Don't click those through on the user's behalf;
hand off or ask. A plain "we use cookies" notice is not one of them.
