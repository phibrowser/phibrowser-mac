# Phi Link settings

The native Phi & AI settings pane owns the user-facing Telegram connection UI
in `Sources/UserInterface/Preferences/IMChannels/`. It uses `IMChannelAPIClient`
over the existing `PhiAgentTransport`; phi-agent and im-server own the backend
configuration and delivery. The existing sign-in and AI availability gates apply.

## Official bot retirement

The official bot is being retired. Settings query existing pairings but never
start a new official pairing, generate a QR code, poll a pairing session, or offer
reconnection. Backend pairing APIs and existing bindings remain available for
compatibility until their separate retirement.

Only an existing official Telegram binding makes the official section visible,
including a binding marked `needs_reconnect`. The section shows its Telegram
identity, a retirement notice asking the user to switch to their own bot, and
one **Unlink** button. No retirement date has been announced in the UI.

The binding stays visible and the button is disabled while unlinking. A failed
request preserves the binding and shows its error in that section. A successful
request removes the section without deleting or disabling the custom bot
configuration. In-flight pairing queries cannot restore stale state after an
unlink. Query failures are reported
without being treated as proof that the user has no binding; reloading the pane
retries the query.

## Custom bot

The custom bot section is always present for signed-in users and starts expanded.
It retains the existing BotFather guide, masked token input, verification, save,
replacement through removal/re-add, and removal operations. Users can configure
their own bot before unlinking the official bot. Saving a token starts polling;
settings retain the existing **Linked** status when `isRunning` is true. This is
a service-running indicator, not proof of Telegram sender authorization.

Custom bots use the existing create, update, verify, list and delete APIs. There
is no **Connect in Telegram** action or request to
`POST /api/custom-bot/channels/:id/pairing`: the currently available phi-agent
backend does not implement that endpoint. Users open their bot in Telegram as
before. This restores the existing token-based flow; it does not add sender
binding or change backend routing. Sender authorization and independence from
official pairing state require separate backend work and verification.
Verification failures may show the backend's credential-safe explanation, such
as a webhook conflict; the UI does not take over another app's webhook.

## Verification

Run `bash build-scripts/test-im-channels.sh` for the production view model and
API client with controlled authentication and transport. It covers existing
bindings, failed/successful unlink, duplicate requests, stale query responses,
query error recovery, and the sign-in gate. It does not call a live backend.

In the native app, check light and dark appearances with no official binding,
an active binding, and a reconnect-needed binding. The first case must show only
the expanded custom section; both existing-binding cases must show the notice
and only Unlink. Verify pending and failed unlink states, then verify successful
unlink and reopening settings leave the custom bot intact and the official
section absent. See [native testing](testing.md) for full-build verification.
