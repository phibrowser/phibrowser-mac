# Feedback V2 Refactor Design

Date: 2026-06-02

## Context

The current native feedback window is a small SwiftUI form backed by
`FeedbackViewModel` and `FeedbackViewController`. It submits immediately through
Chromium's legacy `submitFeedbackWithParams` bridge, which builds Chromium
`FeedbackData` and calls `RedactThenSendFeedback`.

Feedback V2 changes the submission contract:

- The client must call `POST /api/auth/feedback/v2/attachments/presign` before
  uploading attachments.
- Each presign request accepts at most five attachments.
- Each uploaded object must be no larger than 20 MB. The implementation should
  use one shared `20 * 1024 * 1024` byte constant for planning and verification.
- Attachment bytes are uploaded directly to R2/S3 with `PUT`.
- The client must call `POST /api/auth/feedback/v2/submit` once after required
  attachments have uploaded successfully.
- Submit has no attachment-count limit.

The refactor should keep the native UI responsive. Sending feedback should feel
like handing off a report locally, not waiting for a network workflow to finish.

## Goals

- Remove the single-attachment limit from the native feedback UI.
- Stop requesting screenshots from the system.
- Add image attachments when the user presses `Cmd+V` in the feedback window and
  the pasteboard contains image data.
- Upload image attachments directly as image objects.
- Include Phi logs and Sentinel logs as required log attachments.
- Package user-selected non-image files into one or more zip attachments.
- Respect the five-attachment presign request limit by batching presign calls.
- Respect the 20 MB object limit for every image, log zip, and file zip.
- Submit exactly once after required images and logs have uploaded successfully.
- Persist pending feedback jobs under `Account.userDataStorage` so uploads resume
  after app restart or account switching.
- Keep all Feedback V2 network calls in the native networking layer.

## Non-Goals

- Do not keep using Chromium's legacy feedback submission path for V2.
- Do not create a second networking abstraction outside `APIClient.swift`.
- Do not move account-scoped persistence outside `Account.userDataStorage`.
- Do not block the user while uploading attachments.
- Do not surface background retry state in the feedback window.
- Do not implement unauthenticated feedback behavior; the feedback entry point is
  disabled before this flow can run.

## Recommended Approach

Use a persistent native outbox. The Send button writes a complete local snapshot
of the feedback request into the current account's feedback outbox, then closes
the window immediately. A background uploader prepares attachments, performs
presign and R2 uploads, retries silently, and eventually calls submit once.

This keeps UI ownership native, upload ownership in the native networking layer,
and Chromium involvement limited to launching the feedback window and providing
optional context.

## Architecture

### FeedbackViewModel

`FeedbackViewModel` should become the single owner of feedback form state:

- Description text.
- Page URL.
- Selected attachments.
- Pasted image attachments.
- Basic local validation.
- The command to enqueue a feedback job.

The SwiftUI view should bind to this model instead of building a raw
`[String: AnyHashable]` payload.

### FeedbackView

The view remains presentation-only:

- Show description and URL fields.
- Show selected image and file attachments.
- Allow multi-select file import.
- Add a local key handler for `Cmd+V`.
- Let text paste continue normally when the pasteboard does not contain an image.
- Call the view model's enqueue command on Send.

The view should not perform network calls, zip files, or read log directories.

### FeedbackViewController

The controller keeps the existing responsibility of wiring the feedback window to
the active browser window:

- Open privacy and terms links.
- Pre-fill the current tab URL.
- Close the window after the outbox job is created.

It should not call `submitFeedbackWithParams` for Feedback V2.

### FeedbackOutbox

Add an account-scoped outbox rooted at:

```text
AccountController.shared.account.userDataStorage/feedbackOutbox/
```

Each job gets its own directory:

```text
feedbackOutbox/<job-id>/
  manifest.json
  images/
  files/
  prepared/
```

`manifest.json` should contain:

- Job id.
- Description.
- Page URL.
- Contact email, if used.
- Metadata snapshot.
- User-selected image and file entries.
- Required or optional attachment classification.
- Per-attachment upload state.
- Retry metadata.
- Submit state.

The enqueue step must copy user-selected files into the outbox directory while
security-scoped access is still available. It must not store only file URLs for
background upload.

### FeedbackOutboxUploader

Add one background coordinator responsible for upload jobs:

- Scan the current account's outbox on app launch and account changes.
- Pick queued or retryable jobs.
- Prepare images, logs, and file zips.
- Batch presign requests in groups of five.
- PUT each object to R2 with returned headers.
- Retry silently with backoff.
- Re-presign when a signed URL expires or upload retries are exhausted.
- Submit once when required attachments have uploaded successfully.
- Delete the job directory after submit succeeds.

The uploader should update `manifest.json` after meaningful state transitions so
restarts resume without repeating completed uploads.

## Attachment Tracks

### Images

Image attachments are required.

Sources:

- Image data pasted with `Cmd+V`.
- User-selected files whose content type is image.

Behavior:

- Store each image as an independent attachment under `images/`.
- Name generated pasteboard images as `image-1.png`, `image-2.png`, and so on.
- Preserve user-selected image filenames when safe and unique.
- Use `attachment_type = screenshot` so Slack can preview them as image feedback.
- Presign and upload images in batches of five.

Size handling:

- If an image is larger than 20 MB, normalize it to a smaller image attachment
  before upload. Prefer preserving PNG for smaller images; for oversized images,
  re-encode as JPEG with bounded quality/scale steps until the result is below
  20 MB.
- If normalization cannot bring the image under 20 MB, keep the job retryable and
  log the failure. Required images must not be silently dropped.

### Logs

Log attachments are required.

Sources:

- Phi logs from `FileSystemUtils.phiBrowserDataDirectory()/PhiLogs`.
- Sentinel logs from `SentinelHelper.sentinelLogsDirectoryURL()`.

Behavior:

- Preserve two top-level directories in the zip content: `PhiLogs/` and
  `SentinelLogs/`.
- Estimate zip buckets from original file sizes before creating zips.
- Generate `logs.zip` when the combined log bucket fits under 20 MB.
- Generate `logs-1.zip`, `logs-2.zip`, and so on when logs need multiple
  buckets.
- Use `attachment_type = log`.

Size handling:

- Each log zip must be no larger than 20 MB.
- If a single log file is larger than 20 MB, split that file by byte range into
  multiple entries before zipping, preserving names such as
  `large.log.part-1`.
- After zip creation, verify the actual zip size. If compression overhead or
  archive metadata pushes a zip over 20 MB, split the bucket more aggressively
  and regenerate.

### User Non-Image Files

User-selected non-image files are optional.

Behavior:

- Copy selected files into `files/` on enqueue.
- Estimate buckets from original file sizes.
- Generate `feedback-files-1.zip`, `feedback-files-2.zip`, and so on.
- Use `attachment_type = other`.

Size handling:

- Each generated file zip must be no larger than 20 MB.
- A single original non-image file larger than 20 MB should be skipped for this
  feedback job and logged, because optional files should not block required image
  and log submission.
- If a generated zip exceeds 20 MB, split the bucket and regenerate.

## Upload State Machine

Each job should move through these states:

- `queued`
- `preparing`
- `uploading`
- `readyToSubmit`
- `submitting`
- `submitted`
- `failedWaitingRetry`

Each uploadable attachment should track:

- Local file path inside the outbox.
- Filename.
- MIME type.
- Size.
- Attachment type.
- Required flag.
- Presign object key.
- Upload URL expiration, if available.
- Upload status.
- Retry count.

The job becomes `readyToSubmit` only when every required image and log attachment
has uploaded successfully. Optional file zips that succeed are included. Optional
file zips that remain failed after the retry policy can be excluded from submit.

## Network Flow

All Feedback V2 account API calls should be implemented in `APIClient.swift` or
a focused extension of it.

1. Prepare uploadable attachment metadata.
2. Order upload work so required images and logs are uploaded before optional
   file zips.
3. Split metadata into chunks of at most five attachments.
4. Call `POST /api/auth/feedback/v2/attachments/presign` for each chunk.
5. For each presigned attachment, `PUT` bytes to the returned `upload_url` with
   the returned headers.
6. Retry failed PUTs silently.
7. If a PUT cannot succeed with the current signed URL, call presign again for
   that attachment and retry.
8. Once required attachments are uploaded, call
   `POST /api/auth/feedback/v2/submit` exactly once.

Submit should include only attachments that have uploaded successfully and have
an object key.

## Metadata

The submit metadata should include a native snapshot:

- Browser name.
- App version and build.
- Channel derived from the bundle identifier or build configuration.
- Page URL.
- Locale.
- Selected input source ID and localized name in `extra.input_source_id` and
  `extra.input_source_name`, captured when Send is clicked and retained on retries.
- OS version.
- Device model.
- Trace id or job id.
- Phi built-in extension versions from the existing extension manager state when
  available.

Chromium can remain a source for opening the feedback window and refreshing
extension state, but the V2 submit payload should be assembled natively.

## Error Handling

User-facing behavior:

- Send returns after the local outbox job is written.
- The feedback window closes immediately after enqueue succeeds.
- Background upload errors do not reopen the window and do not prompt the user.

Background behavior:

- Required image and log failures keep the job pending with backoff.
- Optional file zip failures are retried, then may be excluded from submit.
- API, presign, upload, zip, and file-copy errors are written to `AppLog`.
- Successful submit removes the job directory.

The enqueue step is the only part that may need a visible error. If local outbox
creation or file copying fails before the job exists, the window should stay open
and show a concise local-save failure message.

## Recovery and Cleanup

- On app launch, scan the current account's outbox and resume incomplete jobs.
- On account change, stop processing the previous account and scan the new
  account's outbox.
- Never process another user's outbox while a different account is active.
- Keep incomplete jobs until submitted.
- Delete submitted jobs promptly.
- Ignore malformed job directories after logging an error; do not delete them
  automatically unless a later cleanup policy is explicitly added.

## Testing

Focused tests should cover:

- Attachment classification for images and non-images.
- Presign batching in groups of five.
- Log bucket planning from original file sizes.
- File zip bucket planning from original file sizes.
- Required versus optional upload semantics.
- Manifest resume behavior after partial upload.
- Submit payload assembly with only uploaded attachments.

Manual verification should cover:

- `Cmd+V` image paste adds an attachment.
- `Cmd+V` text paste still works in the description field.
- Sending closes the window after local enqueue.
- Pending jobs resume after app restart.
- Background upload logs retry failures without blocking the user.

Use the `PhiBrowser-canary` scheme for build verification in this repository.

## Alternatives Considered

### Keep Legacy Chromium Submission

This would reuse `submitFeedbackWithParams` and Chromium `FeedbackData`, but it
does not match Feedback V2's presign, R2 upload, and submit contract. It also
keeps attachment handling inside Chromium when the new API belongs to the native
account networking layer.

### Upload Every File Individually

This is simpler for the client, but it produces scattered Slack attachments and
does not match the agreed behavior that images upload directly while logs and
ordinary files are packaged as zip files.

### Zip All Images

This minimizes attachment count but removes direct image preview in Slack. The
agreed design keeps images as direct attachments because they carry high-value
debugging context.
