# Agent notification cards

`notification.show` presents an existing MessageCard through the authenticated
`/phi-agent` WebSocket on Phi's agent Unix socket. It is an app-level command,
independent of an agent Space or page target. It does not add a Chromium CDP
domain. Page automation continues to use the normal DevTools connection.

The request uses the existing direct-channel envelope:

```js
{
  id: 1,
  type: 'notification.show',
  payloadJson: JSON.stringify({
    title: 'Review ready',
    message: 'The results are ready to review.',
    buttonTitle: 'Review',
    expiresInSeconds: 300,
  }),
}
```

`title` and `message` must be nonblank strings. `buttonTitle` is optional and
defaults to `Run` (including an empty string). `expiresInSeconds` is an optional
integer from 1 to 86400, defaulting to 300. Phi generates a unique notification
ID for each call; callers cannot replace another caller's card by supplying an ID.

The immediate reply is `{id: 1, responseJson: '{"notificationId":"..."}'}`.
It acknowledges queue insertion, not visibility or user acceptance. Invalid
input returns `{"ok":false,"error":"invalid_params"}` inside `responseJson`. Connections
without an authenticated direct-agent principal, including extension senders
and the legacy Chromium message tunnel, receive
`{"ok":false,"error":"agent_session_required"}`. This matches phi-agent's
`callPrivate()` failure contract; successful replies do not require an `ok` field.

Decisions arrive separately on every live direct connection belonging to the
same authenticated agent session, never through the global extension broadcast:

```js
{
  event: 'notification.response',
  payloadJson: JSON.stringify({
    notificationId: '...',
    decision: 'accept', // 'reject' or 'timeout'
  }),
}
```

The primary button sends `accept`; the close button sends `reject`. The hide
button hides the stack without deciding. Expiry or eviction from the shared
five-card queue sends `timeout`. Results are live events, with no offline replay;
keep a connection open to receive them and subscribe before sending the request.

Cards retain existing presentation: Balanced and Performance use the sidebar,
Comfortable uses the overlay. Automatic display respects the account's popup
preference; the API neither forces focus nor opens a browser window.

Using the bundled client's `connectBrowser()` result:

```js
const stop = client.phi.onEvent('notification.response', result => {
  console.log(result.notificationId, result.decision)
})
const reply = await client.phi.send('notification.show', {
  title: 'Review ready',
  message: 'The results are ready to review.',
  buttonTitle: 'Review',
})
if (reply.ok === false) throw new Error(reply.error)
console.log(reply.notificationId)
// Keep the client connected until the decision arrives, then call stop().
```

The Swift path is `AgentDirectConnection.route` → `ExtensionMessageRouter` →
`NotificationCardManager.handleAgentRequest` → the existing card queue and views.
Decisions use `ExtensionMessaging.broadcastToAgent` and the principal-scoped
`AgentDirectChannelRegistry.broadcast` overload. The legacy extension
`notification` request and response envelope are unchanged.
