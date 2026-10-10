# Native sidebar media controls

The sidebar player reads media state and sends commands through Chromium's
native MediaSession integration. Each `WebContentWrapper` exposes a
`PhiMediaControls` instance scoped to its own WebContents.

## Implementation and ownership

`NativeMediaAdapter.Subscription` manages observation on the main actor,
converts native dictionary snapshots into typed playback state, and maps UI
actions to native commands. `SidebarMediaController` owns source selection,
visibility and interaction state for one physical browser window. Its
`SpaceWindowSlot` owns one controller shared by the docked and floating sidebars
of all its Space sessions. Standalone sessions use the same controller with a
single state. Sidebar views render the shared selection using the currently
presented Space's theme and forward actions with a session-qualified surface.

While the player is enabled, the controller observes opened tabs across the
slot's registered live BrowserStates, including silent native sessions. It does
not load dormant Spaces or include another window's tabs. Native callbacks
deliver state changes even when the source Space is hidden. A one-second timer
refreshes the selected card's extrapolated position only while a sidebar surface
is presented.

The adapter checks for `mediaControls` before accessing it. A Framework without
that interface supplies no sidebar media source. State and actions use the
native interface throughout; there is no CDP or injected-script fallback.

## Observation lifecycle

Subscriptions stop when the player is disabled, its session or tab is removed,
its wrapper is replaced, or the controller is destroyed. Sidebar hiding and
Space switching preserve observation.
Stopping observation does not pause playback or close PiP.

The published wrapper property on `Tab` lets the controller detach from the old
WebContents and subscribe to its replacement. Initial callbacks are buffered
until the controller owns the subscription, allowing synchronous teardown to
close it safely. Activation and subscription generations, session and tab
identity, window membership and wrapper identity reject late callbacks and
stale commands. Session replacement or eviction reconciles subscriptions
immediately, independently of delayed window-close notifications.

Same-document URL changes trigger a state refresh because they may not produce
a MediaSession notification. Re-enabling the player revalidates the retained
selection using fresh native snapshots.

## Source selection and PiP priority

Source selection follows real tab visits in the presented session, with a
stable per-session history fallback, and supports cycling across Spaces.
Ordinary Space switches preserve an eligible selected source. Visiting a playing
media tab can reset manual selection under the usual visit-order policy.

Only the presented Space's focused tab and visible split panes are excluded as
visible page content. A hidden Space's remembered focused tab is a background
source. The floating sidebar takes precedence over the docked surface within
the presented Space. Outgoing views cannot deactivate or control an incoming
Space's player. Space changes reset transient hover, volume and gesture state
without dismissing the media source.

Cycling and playback controls act on the originating session without switching
Spaces. Clicking the source button first activates its Space in the owning
slot, then activates the original tab after the switch completes. Source and
session identity are validated again on completion. Failed or superseded
switches and removed/replaced sources cancel the action; missing tabs are not
reopened. Navigation never routes through a different, globally focused window.

A video in PiP is already visible, so it is excluded from the sidebar player and
source cycling. Observation continues, and other background media can occupy
the card. Leaving PiP restores normal source eligibility. A previously selected
paused source remains eligible through this temporary replacement, provided
its source identity still matches and it was not explicitly dismissed.

PiP entry and exit are separate capabilities. Exit requires the current session
to own the PiP window. Entering PiP follows Chromium's policy and may replace
another tab's existing PiP window.

Dismissing a card hides that source without stopping playback. Dismissal is
bound to source identity so that a new source can become eligible again.

## Playback state and actions

The adapter validates capability fields and optional position and duration.
An unavailable position remains absent. The timeline is shown only when both
position and duration are finite, and seeking also requires the native seek
capability.

`sourceToken` identifies a source for selection and dismissal. `token` identifies
the observed state used by rendered controls and drag gestures. Stopping and
restarting observation invalidates request tokens while retaining source
identity when no source change was observed.

Play/pause and PiP actions preserve the intent shown by the rendered state.
Before dispatch, the adapter rechecks the current token, source and capability.
Seeking requires a finite target and clamps it to the native duration. A
successful dispatch does not guarantee completion; subsequent native state is
authoritative, and site handlers retain Chromium's normal precedence.

Previous and next buttons send explicit track actions. Each follows its own
capability, independently of duration or seek support. Page-owned queues work
when the site supplies MediaSession handlers. Standalone files without handlers
have disabled track buttons. Missing track capability fields also disable the
buttons. The timeline continues to support pointer, keyboard and accessibility
seeking.

## Volume

Clicking the volume button toggles a slider below the transport controls.
Leaving the player hides the slider immediately in every presentation mode,
while its row height animates closed.
Option-click toggles tab mute without changing slider visibility. Muting and
unmuting preserve the gain, and adjusting gain does not unmute the tab.

Gain is a per-WebContents multiplier in [0, 1], combined with page volume and
Chromium audio-focus ducking. It survives track changes and observation
stop/start. A replacement WebContents starts at full gain. It does not modify
the page's DOM volume or the system volume.

Slider gestures remain bound to their original source identity; source
replacement rejects stale updates. Missing native gain capabilities disable
the slider.

## Track-change continuity

An accepted previous/next request retains the current card through temporary
native session gaps while blocking stale controls. Fresh track state updates
metadata without resetting expansion.

A 250 ms settling window accommodates metadata and player teardown arriving
on separate channels. A five-second timeout releases the retained card if no
replacement appears. Navigation, tab removal, surface changes, dismissal and
explicit source cycling cancel the hold. Ordinary media loss and PiP visibility
continue to follow their own policies.

## Native session limits

A native session can represent multiple players or media in cross-origin frames.
Its tokens do not identify individual DOM elements or provide a renderer
transaction. A same-element source change with unchanged metadata, or an
undelivered A-to-B-to-A transition, can be invisible to the native API. Renderer
state can also change after browser-side validation.

The adapter does not reconstruct arbitrary preloaded or silent DOM elements,
disjoint seekable ranges, per-element volume, or playlist contents. Available
controls reflect the capabilities reported by the native session.
