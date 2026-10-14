# Agent app info

`agentSpace.app.info` tells an agent connected to the `/phi-agent` WebSocket
which Phi build is answering. CDP's `/json/version` cannot: its `Browser` field
names the Chromium underneath (`Chrome/152.0.7977.76`), not Phi.

The request uses the existing direct-channel envelope and takes no payload:

```js
{ id: 1, type: 'agentSpace.app.info', payloadJson: '{}' }
```

The reply is synchronous:

```json
{"ok":true,"name":"Phi Browser","version":"2.12.0","channel":"stable","buildNumber":"…"}
```

`version` is `CFBundleShortVersionString` (`SystemUtils.appVersion`), what the
About window shows; `channel` is `FeedbackOutbox.channelName`, the release
channel the build was compiled with (`canary`, `debug` or `stable`);
`buildNumber` is `CFBundleVersion`. These are the values the browser's own
feedback reports carry, so a report an agent files describes the same build the
user's own report would. A local build carries placeholders: the open-source
scheme answers `version` `debug` and `channel` `canary`.

The method is read-only and about the app, not the user's data, so it needs no
task id and the Agent permissions switch does not gate it. Connecting at all
still goes through the consent prompt.

A browser older than this method does not answer it: an unknown type falls
through `CommonMessageRouter` and the direct channel fails it only after its
60-second timeout. Agents must bound the call themselves.
