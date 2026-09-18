# Native Folio library

`SaveForLaterService.openLibrary()` opens a native window owned by the originating
`MainBrowserWindowController`. Each browser window retains its own library
controller; closing the browser window closes that library. Opening an original
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
is visible; unchanged file heads are reused. File IO and Markdown parsing run off
the main actor. Selection-driven reads discard stale or cancelled results.

The native reader uses Foundation's Markdown presentation intents for paragraphs,
headings, lists, code, quotes, and tables. The leading document title is shown in
the reader header. Mirage's structural `## Highlights` section is presented in a
separate reading mode. A heading inside a code block does not split the document.
The reader does not fetch remote images or execute embedded HTML; the saved MHTML
copy opens in a browser tab when requested. Only HTTP(S) links are actionable in
the native document.

Native file actions share the broker's basename validation and reject symlink
entries. Removing an item requires confirmation and moves its Markdown and MHTML
files to Trash. If only part of that operation succeeds, the error remains visible
and the next refresh reconciles the list with disk.

Validation lives in `FolioLibraryTests` and `SaveForLaterPathJailTests`.
