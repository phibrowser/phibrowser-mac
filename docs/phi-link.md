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
replacement through removal/re-add, and removal operations. Users can configure their own bot before
unlinking the official bot. The server now issues a ten-minute, single-use **Connect in Telegram** link
for a configured custom bot. Saving a token starts polling; it does not authorize
the first person who happens to message that bot. Settings display **Configured**
until `telegramBinding.userId` is present. The user opens the link, presses Start,
and returns to Phi; the pane refreshes the custom channel when the app becomes
active. The link button ignores repeated requests and accepts only unexpired
HTTPS `t.me` URLs from the authenticated API. An active poller and a linked sender
are separate states.

The authenticated `POST /api/custom-bot/channels/:id/pairing` route belongs to
phi-agent; ownership, capability validation and local/official state isolation
belong to phi-agent and im-server. Those services must be deployed with the new
protocol before enabling the native operation. Existing custom bots without a
binding need this explicit link. Ownerless legacy installations need an explicit
administrator migration; listing settings no longer adopts them automatically.
Official unlink does not clear the custom channel's separate route document.
Verification failures may show the backend's credential-safe explanation, such
as a webhook conflict; the UI does not take over another app's webhook.

## Verification

Run `bash build-scripts/test-im-channels.sh` for the production view model and
API client with controlled authentication and transport. It covers existing
bindings, failed/successful unlink, duplicate requests, stale query responses,
query error recovery, custom-link validation, duplicate link requests, and the sign-in gate. It does not call a live backend.

In the native app, check light and dark appearances with no official binding,
an active binding, and a reconnect-needed binding. The first case must show only
the expanded custom section; both existing-binding cases must show the notice
and only Unlink. Verify pending and failed unlink states, then verify successful
unlink and reopening settings leave the custom bot intact and the official
section absent. See [native testing](testing.md) for full-build verification.
