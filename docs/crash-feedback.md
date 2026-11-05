# Feedback after an application crash

`SentryService` receives the previous-run result through Sentry's
`onLastRunStatusDetermined` callback. For a crash event, it passes the event ID,
timestamp, and a bounded snapshot of retained Phi log tails
to `CrashFeedbackCoordinator`, which is owned by `AppController`. The snapshot is
taken during the next launch and can include startup messages; it is not an exact
recording of only the crashed session.

`CrashFeedbackCoordinator` owns the pending crash, notification observers, and
bounded retry scheduling. `AppController` creates it at launch and forwards
termination and cancelled-termination lifecycle calls.

The coordinator waits for an authenticated account, an active application, and a
visible normal browser window. It defers while window restoration, Guest
migration, or modal presentation is in progress, and does not present during
termination. It uses the existing application-wide feedback window. An open
feedback window or an unsent description or attachment takes precedence over
the automatic invitation. The last presented crash event ID is saved in
UserDefaults so dismissal does not cause another invitation for that event.

The crash form does not infer a crash-site URL from the tab selected after
relaunch. Users enter their description and may provide a URL or attachments.
Only Send Feedback creates an account-scoped Feedback V2 outbox job. Dismissal
releases the in-memory crash context and log snapshot. A queued job owns its
snapshot file so log rotation and upload retries do not change those bytes.

Crash feedback sets `client_context.category` to `previous_session_crash`;
ordinary feedback keeps `issue-report`. Crash feedback adds `sentry_event_id`
and, when available, `crash_timestamp` to the existing metadata `extra`
dictionary. Every feedback report also adds the sync status keys
`sync_phase` and, when sync problems are tracked, `sync_attention_problems`,
`sync_attention_oldest_age_seconds` and `sync_attention_entered_count`
(enum raw values and counts; see [sync.md](sync.md), "Sync status contract"),
captured when the form is sent. `client_context.trace_id` remains the feedback job ID. The
retained-log snapshot is capped at 1 MiB and included in `logs.zip` as
`PreviousSessionCrash/logs.txt`. Chromium system logs are collected at submission
time from the current session and included as `system_logs.txt`.
Old outbox manifests without a crash snapshot remain readable.

This invitation supplements existing automatic Sentry crash reporting; it does
not change that reporting's delivery or identity configuration. Feedback is
submitted through the existing Feedback V2 API and is not also submitted to
Sentry's User Feedback API. Guest feedback and Chromium child-process crashes
are outside this flow. Live verification requires a configured Sentry DSN and a
crash followed by a relaunch without an attached debugger.
