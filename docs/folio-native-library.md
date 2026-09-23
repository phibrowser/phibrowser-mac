# Native Folio library

File > Open Folio calls `SaveForLaterService.openLibrary()` to open Mirage's
`library.html` extension page in the active browser Profile.

`SpaceSessionController.openFolioLibrary()` opens a native window owned by the originating
`SpaceSessionController`. Each browser session retains its own library
controller; closing the session closes that library. Opening an original
page or a saved webpage creates a tab in the originating browser window, not the
currently active Profile.

The in-window Library also embeds `FolioLibraryView` in its Folio section, with a
separate model bound to the browser window's Profile. Opening an original page or
archive dismisses the overlay and creates a tab in that browser window. Leaving
the Folio section clears its loaded content; refresh runs only while it is shown.
The Folio navigation entry follows the feature flag and Guest Mode restrictions.

`FolioLibraryModel` owns only its library presentation state. It resolves
the originating Profile's existing `PhiPreferences.SaveForLater` folder rules on
refresh. A folder change clears the previous selection and document. The Folio
feature flag and Guest Mode restrictions apply to opening, reading, and actions.

The library reads Mirage's existing Markdown/MHTML pairs without importing,
migrating, or creating a database. Directory metadata is refreshed while the window
is visible; unchanged file heads are reused. File IO and Markdown sanitization run off
the main actor. MarkdownReader caches the sanitized text's render parse.
Selection-driven reads discard stale or cancelled results.

The native reader uses MarkdownView's `MarkdownText` in a single native text view
for continuous selection across wrapped lines, paragraphs, and headings. Its
component fonts use `NSFont` so text-size controls also work before macOS 26.
Markdown links use a custom SwiftUI link renderer to preserve the originating
window's navigation action instead of RichText's default AppKit link handling.
The leading document title is shown in
the reader header. Mirage's structural `## Highlights` section is presented in a
separate reading mode. A heading inside a code block does not split the document.
A swift-markdown rewriter removes HTML nodes, replaces images with their alternative
text, and resolves and validates links before rendering. The reader does not fetch
remote images or execute embedded HTML; the saved MHTML copy opens in a browser
tab when requested. Only HTTP(S) links are actionable in the native document.

Native file actions share the broker's basename validation and reject symlink
entries. Removing an item requires confirmation and moves its Markdown and MHTML
files to Trash. If only part of that operation succeeds, the error remains visible
and the next refresh reconciles the list with disk.

Validation lives in `FolioLibraryTests` and `SaveForLaterPathJailTests`.
