# Feedback attachment collection

Feedback V2 permits ten uploaded attachments, each at most 20 MiB. A selected
file remains limited to 10 MiB. Automatic logs use at most five upload slots:
one Phi/Chromium/crash archive and up to four Sentinel archives. Unused log slots
are available to user images and files. After logs, images use the remaining
slots with a preferred reservation for ordinary files. If packaging cannot fit
all attachments, keep the archives that fit and skip the rest without blocking
submission or showing an additional warning. Kept images and ordinary files
remain required uploads. The uploader receives only fully prepared jobs.

## Sentinel sources and bounds

Collect only the current channel's main logs and the submitting Auth0 subject's
`state/logs` directory. Match Sentinel's bundle/channel and sanitized-subject
path convention. Do not collect credentials, configuration, other accounts,
rotated files, or files reached through symlinks.

- `main/`: current `boot.log`, `runner.log`, `ai-gateway.log`, and
  `ai-gateway-process.log`.
- `services/<component_id>/`: current `stdout.log` and `stderr.log`, including
  Service Broker, Gateway, and Privacy Guard. Missing streams are reported.
- `services/llm/`: each model's current `.log` (Sentinel combines stdout/stderr
  for a model in this file).
- `audit/runner/`: current `ipc-audit.log`.

Each stream contributes at most its last 5 MiB. Files shorter than this are
collected as-is; `.1`, `.2`, and `.3` never supplement them. The Sentinel raw
content budget is 64 MiB. Allocate it fairly across streams, redistribute unused
small-file quotas, and prefer a line boundary at the beginning of a truncated
tail. Reads remain byte-bounded even for non-rotating LLM and Privacy Guard logs.

Channel-level main logs may span account changes. Component and Gateway process
output is not guaranteed to be redacted and can contain payload fragments.
Gateway process and stderr streams are retained separately because they overlap
but are not interchangeable.

## Durable outbox and account ownership

The feedback form owns the draft. Send first prepares a complete, account-scoped
job under `Account.userDataStorage/feedbackOutbox/<job-id>/`, including copies of
selected files and captured logs. The user must not have to keep the form open
while the network upload runs. Only a complete, validated job is published by
an atomic manifest write; a preparation failure leaves the draft available and
removes the partial job directory.

`FeedbackOutboxUploader` scans the authenticated account's directory at launch
and on account/access changes. It persists preparation, per-attachment upload,
retry and submit state in the manifest so a later scan can resume from saved
sources rather than collect newer logs. Before processing a job or making network
requests, it checks that the same account is still active. A different signed-in
user must never upload the previous account's feedback.

Required attachments must finish uploading before submit; the network calls go
through `APIClient`. Successful submit marks the job and removes its directory.
Failures receive bounded retry and backoff, then the job is discarded after the
configured retry limit. Do not promise indefinite retention or exactly-once
server submission if a response is lost. The form does not expose background
retry state as if it were a synchronous send result.

## Snapshot and packaging

Preparation runs off the main actor before publishing the outbox manifest.
Snapshot sources into the job directory and store their provenance in the
manifest. Multi-file collection is not an atomic cross-process snapshot. A
missing or unreadable Sentinel stream is reported without dropping other streams.

Each log ZIP includes `collection-manifest.json`: relative source names,
capture time, original and collected sizes, byte offset, truncation and failure
status. No account identifier or absolute source path is added to this manifest.
Phi/Chromium current logs are also bounded to 5 MiB per source; the existing
immutable previous-session crash snapshot is preserved in full.

Try one Sentinel ZIP first. If its actual size exceeds 20 MiB, balance streams
across two through four independent ZIPs, checking actual sizes each time.
If necessary, reduce packaged tails and report the resulting offsets and lengths.
Do not assume a compression ratio. Skip any archive still oversized after
bounded repacking attempts, while retaining the archives that fit.

Retries and archive rebuilds use saved snapshots only. Missing snapshot files
fail the job rather than substituting a newer session. Old jobs retain existing
prepared attachments; if rebuilding is necessary, use only their saved sources,
without acquiring new live logs. Uploads still use APIClient's presign, PUT, and
submit flow, with account checks before network work.

## Source and verification

- [Feedback view model, outbox preparation, manifest and uploader](../Sources/UserInterface/Feedback/FeedbackOutbox.swift)

Verify queued delivery across form closure and app restart, account switching
before and during upload, partial preparation cleanup, retry exhaustion and a
missing saved snapshot. Check the manifest's saved-source provenance without
including attachment contents or user identifiers in test output.
