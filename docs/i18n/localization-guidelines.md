# Localization Guidelines

All production user-facing strings must use an explicit localization key,
English value, and translator comment:

```swift
NSLocalizedString(
    "profile.nameEditor.promptForTooLong",
    value: "Name is too long (maximum 100 characters)",
    comment: "Profile name editor - Error shown when the name exceeds 100 characters"
)
```

## Key

- Use a stable, dot-separated, lower-camel-case semantic key in the form
  `productArea.surface.purpose`, adapting the levels when needed.
- Describe public product concepts and user-visible scenarios. Do not derive
  keys from method, type, file, framework, dependency, or other internal names.
- Do not use the English copy as the key, and do not add mechanical
  disambiguators such as `variant1`.
- Give identical English text separate keys when its context or meaning differs.
  Reuse a key only when the semantic meaning is identical and all usages should
  change together.

## Value

- Set `value` to the exact current English user-facing copy.
- Treat the key as stable identity: update `value`, not the key, when English
  wording changes without changing the semantic purpose.
- Preserve placeholders, formatting, punctuation, and capitalization exactly.

## Comment

- Write a concise English translator comment that identifies the user-visible
  surface, the string's role, and the condition or action that presents it.
- Explain the meaning of each placeholder when it is not self-evident.
- Do not merely repeat the English value or expose internal implementation
  details.

## Extraction and Catalog

- This repository owns localization IDs, English source values, and translator
  comments. Add only the `en` localization for new catalog entries.
- Do not proactively author or update non-English localizations in
  `Resources/Localizable.xcstrings`. Multilingual translations are maintained
  by the dedicated translation repository and should enter this repository only
  through that repository's synchronization workflow.
- Preserve existing non-English localizations unless a translation-repository
  synchronization explicitly updates them or the entire stale entry is removed.
- Delete entries marked as stale (`extractionState: "stale"`) from
  `Resources/Localizable.xcstrings`, including all of their localizations.
- Developer-only strings under `#if DEBUG`, and strings used only by examples,
  samples, previews, or debug tools, must remain direct string literals instead
  of using `NSLocalizedString`.
- Use `Text(verbatim:)` for non-localized SwiftUI literals when necessary to
  prevent automatic string-catalog extraction.
- Keep source calls and `Resources/Localizable.xcstrings` synchronized.
