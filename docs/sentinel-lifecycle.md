# Sentinel lifecycle supervision

The browser supervises the configured Sentinel application while Phi AI is
enabled. `SentinelWatchdog` owns liveness monitoring and relaunch scheduling; it
does not supervise each service inside Sentinel or present recovery UI.

## Detection and recovery

Workspace termination notifications provide the primary signal, filtered by the
Sentinel bundle identifier. A 60-second poll is the backstop. A recovery first
waits two seconds and checks liveness again so an intentional Sentinel self-restart
does not cause a redundant launch.

Overlapping signals share one recovery task. After debounce, the first attempt
has no additional delay. Rapid repeated deaths back off by 1, 2, 4 seconds and so
on, capped at five minutes. Ten minutes of stability since the last watchdog
relaunch resets the attempt counter. Recovery remains log-only and does not give
up permanently after a fixed number of attempts.

## Intentional shutdown

`start()` and `stop()` are idempotent. `stop()` removes the observer and cancels
poll/recovery work. Every intentional shutdown path must stop supervision before
asking Sentinel to terminate, including AI disable, update installation,
uninstall and credential-boundary cleanup failure. These paths use the
browser-update termination request, because Sentinel refuses a plain quit while
the browser is running. Otherwise the watchdog can resurrect a process being
deliberately stopped. Account and build capability gates remain owned by their existing
lifecycle callers; the watchdog is not a second authentication policy.

The [Phi Chat hotkey](sentinel-phi-chat-hotkey.md) and
[telemetry consent](analytics.md#sentinel-telemetry-consent-contract) are separate
cross-process contracts. A running Sentinel process alone does not prove its
managed services are ready.

## Source and verification

- [Watchdog](../Sources/Application/SentinelWatchdog.swift)
- [Application startup](../Sources/Application/AppController.swift)
- [AI enablement](../Sources/States/BrowserState+ToggleAI.swift)
- [Update lifecycle](../Sources/Application/AppController+Sparkle.swift)
- [Focused tests](../Tests/PhiBrowserTests/SentinelWatchdogTests.swift)

The focused suite injects liveness, launcher, time and sleep. Verify single
recovery, debounce self-recovery, stability reset, increasing delay and suppression
after stop. Live acceptance should separately cover the actual channel's process
and intentional shutdown sequence with a compatible Sentinel artifact.
