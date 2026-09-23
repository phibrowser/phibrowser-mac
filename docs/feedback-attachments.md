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
