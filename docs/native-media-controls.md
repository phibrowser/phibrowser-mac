# Native sidebar media controls

The sidebar player reads media state and sends commands through Chromium's
native MediaSession integration. Each `WebContentWrapper` exposes a
`PhiMediaControls` instance scoped to its own WebContents.

## Implementation and ownership

`NativeMediaAdapter.Subscription` manages observation on the main actor,
converts native dictionary snapshots into typed playback state, and maps UI
actions to native commands. `SidebarMediaController` owns source selection,
visibility and interaction state for one browser window. The sidebar views
render that state and forward user actions.

While the player is enabled and a sidebar surface is active, the controller
observes opened tabs in its own `BrowserState`, including silent native
sessions. Native callbacks deliver state changes. A one-second timer refreshes
the selected card's extrapolated playback position through `snapshot`.

The adapter checks for `mediaControls` before accessing it. A Framework without
that interface supplies no sidebar media source. State and actions use the
native interface throughout; there is no CDP or injected-script fallback.

## Observation lifecycle

Subscriptions stop when the sidebar becomes inactive, the player is disabled,
a tab is removed, its wrapper is replaced, or the controller is destroyed.
Stopping observation does not pause playback or close PiP.

The published wrapper property on `Tab` lets the controller detach from the old
WebContents and subscribe to its replacement. Initial callbacks are buffered
until the controller owns the subscription, allowing synchronous teardown to
close it safely. Activation and subscription generations, tab identity, window
membership and wrapper identity reject late callbacks and stale commands.

Same-document URL changes trigger a state refresh because they may not produce
a MediaSession notification. A selection retained while hidden is revalidated
before it becomes visible again.

## Source selection and PiP priority

Source selection uses the window's tab visit history and supports manual cycling.
Focused and visible split-view sources are excluded from the background player.
The floating sidebar takes precedence over the docked surface. Cycling checks
the destination's current state without changing playback or focusing its tab.

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
Command-click toggles tab mute without changing slider visibility. Muting and
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
