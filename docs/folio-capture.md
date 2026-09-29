# Folio capture and storage

Folio is the product name; native identifiers retain `SaveForLater` and
`saveForLater`. The companion extension, Mirage, owns the save end to end:
extraction, document construction, file requests and completion presentation.
The native client owns preferences, eligibility and authorization gates, jailed
file operations and the native presentation endpoints used by the extension.
The [native library](folio-native-library.md) reads the same saved files.

## Capture ownership

`SaveForLaterService` delegates a save using the originating tab, window and
Profile. It prevents duplicate in-flight triggers for the same tab. Eligibility
requires an enabled feature and an HTTP(S) page, not a native new-tab or extension
page. Feature availability and library visibility are separate from capture
eligibility; the current `canSave` path does not exclude Guest mode.

`saveForLater.save` and `saveForLater.saveResult` correlate requests by ID. The
reply acknowledges acceptance, not a completed archive. The current acceptance
budget is 12 seconds; a video job may take much longer to finish. Waiting for
completion at this boundary could turn accepted work into a timeout and a
duplicate retry. Completion feedback uses the extension's later presentation
request. A missing extension or unanswered request reports failure: there is
deliberately no second native save implementation or automatic native fallback.
This keeps one save pipeline instead of two implementations that can diverge.

Both capture legs start from the requested page. Once their payloads have been
captured, later work need not keep the tab alive. Do not describe closing the tab
before capture finishes as guaranteed lossless.

The webpage copy is MHTML; article Markdown is best-effort. A failed article
extraction can produce a link-bearing stub alongside the webpage copy. Failures
of the archive or disk write are still failures and must not be presented as a
fully saved pair. Video summaries and site-action saves are companion-dependent;
this document does not specify service prompts or generation internals.

## Automatic site-action saves

Automatic saves require all three gates: Folio availability, the independent
auto-trigger feature flag and the user's opt-in. The separate flag can stop
unwanted writes if a site's changed markup makes its trigger rules misfire;
manual saves do not depend on that auto-trigger flag.

The extension's cached armed state is an optimization, not authorization. For
every trigger, native code verifies the expected sender, rechecks all gates,
resolves the originating tab and requires its current URL to equal the trigger
URL. A late event must not save the page navigated to afterwards. The native
handler also deduplicates automatic saves by URL within its current ten-minute
window. Keep these checks even when the extension has already filtered the event.

## Folder and file boundary

Markdown and MHTML use one shared basename in a flat folder. Native preferences
resolve the destination from the originating Profile's override or the global
folder. The default product folder is `~/Documents/PhiFolio`.

The job pins its folder before asynchronous work. Resolving again from the
frontmost Profile during a later callback could put the two files in different
folders. Bridge file operations use the captured job/tab context, validated
basenames and the existing path-jail rules; callers do not receive authority to
write arbitrary filesystem paths.

Frontmatter carries source/title/save metadata and the trigger. Native readers
must tolerate the companion's supported format without inventing a parallel
database or silently rewriting archived content. Highlights are structured saved
content; a heading inside a fenced code block is not a Highlights section.

## Source and verification

- [Capture and folder routing](../Sources/States/SaveForLaterService.swift)
- [Library model and file handling](../Sources/States/FolioLibrary.swift)
- [Library presentation](../Sources/UserInterface/Folio/FolioLibraryView.swift)
- [Path-jail tests](../Tests/PhiBrowserTests/SaveForLaterPathJailTests.swift)

Test Profile switches while a save is active, missing extraction, failed writes,
duplicate triggers, invalid basenames and symlink entries. Real paired-file and
video/site-action acceptance requires the matching extension/services; native
path validation tests do not establish their implementation.

Verify that an accepted slow save is not retried as a timeout, and that no
extension response produces a failure rather than a native fallback. For
automatic saves, exercise opt-out with a stale extension cache, a disabled
auto-trigger flag, an unexpected sender, navigation before delivery and duplicate
events. These checks cover native authorization separately from site-rule quality.
