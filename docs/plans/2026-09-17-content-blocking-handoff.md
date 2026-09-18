# Phi Content Blocking Handoff

Date: 2026-09-17
Stage: research and planning only; no feature implementation.
Purpose: preserve discussion, decisions, reference projects, and next steps.

## User intent and decision history

The user wants content blocking for Phi Browser, a Chromium-based browser with
a native macOS shell. The central constraint is minimal Chromium coupling:
isolate functionality and maintain small patches so milestone upgrades remain
manageable. Zero upgrade impact was explicitly not promised.

We compared an embedded extension, a native engine with thin Chromium adapters,
and a wholesale Brave Shields transplant. The user selected option 2: native
adblock-rust plus Phi-owned adapters, not a Brave fork within Phi.

The user then required at least three independently controlled features, based
on a screenshot: Block ads, Block cookie banners, Block trackers. These are all
MVP requirements. Earlier statements deferring tracker/cookie support are stale.
Cookie-banner hiding is not consent acceptance or rejection, nor does it imply
cookies themselves are blocked.

The user described YouTube video ad blocking as important, requested research,
then explicitly deferred it. Preserve it as future work; do not add YouTube
scriptlets, player-data rewriting, media manipulation, or anti-adblock bypasses
to this MVP. Do not promise reliable pre-roll or mid-roll blocking.

The user has approved the architectural direction and requested planning
artifacts. They have not asked to begin implementation. The latest request is
this handoff, not permission to write browser code.

## Existing artifacts: read instead of duplicating

- Requirements (latest product scope):
  `/Users/corot2a/phi/phibrowser-mac/docs/plans/2026-09-16-adblock-requirements.md`
- Development plan (proposed patch sequence and tests):
  `/Users/corot2a/phi/phibrowser-mac/docs/plans/2026-09-16-adblock-development-plan.md`
- Feasibility report (source evidence, limitations, alternatives):
  `/Users/corot2a/phi/phibrowser-mac/docs/plans/2026-09-16-adblock-rust-feasibility.md`

The feasibility report predates the expanded three-toggle requirement. Use it
for technical evidence, not to override subsequent scope decisions. These plans
are drafts despite their "approved direction" headings; some details below
still need resolution before an implementation handoff is decision-complete.

## Workspace and observed state

| Repository | Role | Investigated baseline |
| --- | --- | --- |
| `/Users/corot2a/phi/chromium/src` | Phi engine and native bridge | phi-r152, 152.0.7977.76, a493fbcf57fb529071cce26d41af066d34bc4d32 |
| `/Users/corot2a/phi/phibrowser-mac` | Swift/AppKit shell | 61caa362d0c69311433f180b8a38e59979e9cd28 |
| `/Users/corot2a/phi/adblock-rust` | Upstream engine checkout | 1c0740d27d531a2389c808212a8702592bb74138; Cargo version 0.13.3 |

Recheck all revisions before implementing. The three planning documents were
still untracked in phibrowser-mac on 2026-09-17. No commits were made. No feature
code, rule package, FFI, or build target was created. No build, browser test,
performance measurement, or live YouTube effectiveness test was run.

Earlier `git diff --check` calls succeeded, but untracked documents are not
covered by that command; this is not proof of comprehensive document validation.

## Rules to load before continuing

- `/Users/corot2a/.agents/company-knowledge/10-team/agents/shared-agent-rules.md`
- `/Users/corot2a/phi/phibrowser-mac/AGENTS.md`
- `/Users/corot2a/.agents/company-knowledge/30-projects/phinomenon/chromium-phibrowser/README.md`
- `/Users/corot2a/.agents/company-knowledge/30-projects/phinomenon/phibrowser-mac/README.md`

The knowledge-base pull fetched but failed to fast-forward because histories
diverged. Do not reset or merge it silently; local implementation source was
used as authority. Repository documentation must be English. The macOS repo
requires explicit instruction before committing. Preserve unrelated changes.

## Reference projects, in priority order

| Project | What to inspect | Caution |
| --- | --- | --- |
| https://github.com/brave/adblock-rust | Rule parser, matcher, cosmetic resource API, cache | Engine, not a complete browser blocker; MPL-2.0 |
| https://github.com/brave/brave-core | Current FFI, browser integration, renderer lifecycle, updates/tests | Reference selected components; do not transplant Shields wholesale |
| https://github.com/brave/adblock-lists | List selection, Brave compatibility rules, category sources | Audit individual list licenses and supported syntax |
| https://github.com/brave/adblock-resources | Scriptlet and replacement-resource infrastructure | Future execution scope; individual asset provenance matters |
| https://github.com/brave/uBlock | Rule semantics and compatibility behavior | A uBlock Origin fork, not a Brave-original engine; GPL-3.0, not blanket permission to copy |
| https://github.com/brave/cookiecrumbler | Cookie-consent detection research/tooling | Not established as a drop-in runtime for Phi; inspect before adopting |
| https://github.com/brave/brave-core-crx-packager | Component packaging and distribution patterns | No requirement to adopt CRX or Brave's hosted service |
| https://github.com/brave/go-update | Component update server reference | Not an approved new Phi backend dependency |

Most useful brave-core paths:

- `components/brave_shields/core/common/adblock/rs/src/lib.rs`: cxx contract.
- `components/brave_shields/core/common/adblock/rs/BUILD.gn`: Rust GN integration.
- `components/brave_shields/core/browser/ad_block_*`: filters/resources/update ownership.
- `components/brave_shields/content/`: Chromium integration.
- `components/cosmetic_filters/renderer/`: document lifecycle and script application.
- `components/cosmetic_filters/resources/data/`: cosmetic/procedural runtime reference.

The old https://github.com/brave/adblock-rust-ffi is archived; do not start from
it. Other projects discussed (slim-list-lambda, WebKit validator, variations,
kuchikiki) are lower-priority references, not necessary MVP dependencies.
Recheck upstream state and pin revisions before reuse; previous reads used
moving master branches. Consult https://www.mozilla.org/en-US/MPL/2.0/FAQ/ for
MPL distribution obligations and separately review rules/resources licenses.

## Technical findings that affect the design

- Use GN Rust integration and a narrow cxx facade. Keep matching out of Swift,
  Sentinel, localhost services, and native messaging.
- Candidate network registration: ChromeContentBrowserClient's
  `WillCreateURLLoaderFactory`. Preserve existing proxy composition, terminal
  interceptor ordering, CORS and redirect validation.
- Browser-side `CreateURLLoaderThrottles` alone misses ordinary renderer
  subresources. Factory proxies still do not prove full coverage: service-worker
  generated/CacheStorage responses and WebSocket need separate treatment.
- Candidate renderer registration: `RenderFrameCreated`, with reviewed Mojo
  bindings and document-scoped lifecycle handling, not Blink DOM modifications.
- Default adblock-rust `single-thread` makes Engine non-Send/non-Sync. A
  sequenced task runner is not necessarily a fixed physical thread. Engine
  creation, matching, generation replacement and destruction must agree on
  ownership. This was inspected, not benchmarked or implemented.
- Request type/source mapping matters: the local engine does not map literal
  "fetch" to XHR automatically. Use should_block(), preserve exception and
  important semantics, and do not interpret redirect presence alone as a block.
- Serialized data is a cache, not a stable interchange format. Resources are
  loaded separately; pin revisions/features and retain source lists.
- Reduce upstream file touchpoints and replay small feature-gated quilt patches.
  Compilation and patch application do not replace behavioral uplift tests.

## Gaps to resolve before implementation

1. Three-toggle composition: define how active category lists combine and how
   exceptions/badfilter/important interact across overlapping lists. Disabling
   ads cannot guarantee an overlapping tracker URL is allowed when tracker
   blocking remains on. Test all eight toggle combinations.
2. Cookie banners: CSS-only hiding must not leave a locked page, backdrop or
   broken scrolling. Define a tested coverage tier; do not silently expand to
   consent clicking or privileged scriptlets to pass tests.
3. Policy defaults: the user approved three controls, not all default states,
   guest/PhiChat policy, or exact domain-exception semantics. The screenshot's
   enabled toggles are not sufficient to assume shipping defaults.
4. Rules/update contract: exact list URLs, licenses, limits, signing algorithm,
   key ownership/rotation, hosting, update schedule, expiration and anti-rollback
   behavior remain unspecified. No service or signing credentials were set up.
5. Threading: reconcile the plan's fixed-thread engine with background builds
   and atomic publication. Non-Send objects cannot simply be moved from a pool
   worker to a matching thread. Select and prove a concrete model.
6. FFI failures: the plan's "panics become status values" is not guaranteed with
   panic=abort or Chromium's exception-disabled build. Specify recoverable errors
   and avoid panic paths rather than promising crash recovery via catch_unwind.
7. Tests/build: `phinomenon_adblock_unittests` and `PhiAdblock*` in the plan are
   proposed names, not existing targets. Knowledge-base notes warn that PhiDebug
   component builds cannot link browser_tests; inspect/use a suitable
   non-component configuration such as PhiTest instead of blindly running the
   listed commands.
8. Performance: no numeric budgets or effort estimates were validated. Establish
   baseline and pass/fail thresholds; the earlier YouTube "2-3 weeks" estimate
   was speculative and is not an MVP commitment.

These are planning follow-ups, not a request to reopen the selected architecture.
Avoid unrelated repairs while only preparing this handoff.

## YouTube research to retain for later

Official list inspection found player-data scriptlets (`json-prune`, `set`)
alongside network/cosmetic rules in:
https://github.com/brave/adblock-lists/blob/master/brave-lists/filters-mirror.txt

Brave-specific navigation/theater/playback fixes appear in:
https://github.com/brave/adblock-lists/blob/master/brave-lists/brave-specific.txt

These support a multi-layer approach, not a claim that copying a few rules
reproduces current Brave effectiveness. Some listed fixes are commented out.
Android's YouTube script injector inspected here mainly handles playback/PiP;
it is not evidence of a standalone desktop video-ad blocker. No live comparison
was performed. Keep this work deferred unless the user explicitly resumes it.

## Suggested next session and skills

First read the requirements, plan and the gaps above. Resolve the implementation
contracts without expanding the three-capability MVP. If the user subsequently
requests implementation, start with a pinned-engine/GN/cxx build spike, then the
network coverage prototype before adding native UI.

- `think`: close concrete design gaps while preserving approved direction.
- `research`: verify exact upstream APIs, list/resource provenance, and licenses.
- `codebase-design`: keep the engine facade and browser/renderer boundary small.
- `implement`: execute only after an implementation request.
- `tdd`: if test-first implementation is requested.
- `design`: when building the actual native controls.
- `check`: review implementation and test results before delivery.

Do not create tasks, publish tickets, commit, or start recurring monitoring
merely because this handoff mentions future work.
