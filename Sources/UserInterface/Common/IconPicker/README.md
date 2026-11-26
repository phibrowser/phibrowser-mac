# IconPicker

`IconPicker` is a reusable SwiftUI picker for two icon sources:

- Phi icons from `Resources/Assets.xcassets/icons`
- System emoji from the bundled emoji catalog at `Resources/Emoji/emoji-catalog.json`

The picker does not parse Unicode metadata at runtime. Runtime code only decodes
the bundled JSON catalog through `EmojiCatalog`.

## Phi Icon Identity

Phi icon assets use semantic image-set names such as `phi-icon-mail` and
`phi-icon-view-grid-add`. `PhiIconCatalog` is the single mapping between the
trailing Figma component name, the asset name, and the numbered asset name used
by older releases.

The numbered compatibility mapping is based on matching the artwork, not the
current Figma order. `IconPickerSelection.fromStorageValue` converts stored
values such as `phi:phi-icon-1` into the current semantic ID before rendering,
so existing Space records keep the same visible icon.

Character component names use file-safe asset slugs to avoid colliding with
legacy numbered IDs. For example, Figma names `1`, `A`, and `?` map to
`phi-icon-number-1`, `phi-icon-letter-a`, and
`phi-icon-question-mark`.

## Phi Icon Artwork

Picture icons use Heroicons v2 mini (20px solid, MIT, credited in
`Resources/credits.html`). Letters, numbers and punctuation are drawn by hand
and are not generated.

`scripts/generate-phi-icons.py` writes each picture icon's image set: a black
SVG for the light appearance and a white SVG for the dark one, both inset with
`translate(2 2) scale(0.8)`. The script's `ICONS` list maps each asset slug to
its Heroicons name. Original icons keep their v1 slugs (`phi-icon-mail` draws
Heroicons `envelope`), so stored selections never change.

To add an icon, add it to `ICONS` in the script and to `PhiIconCatalog.all`,
then run:

```sh
python3 scripts/generate-phi-icons.py
```

The script downloads the pinned Heroicons release from npm. Pass
`--source /path/to/heroicons.tgz` to use a local copy.

## Emoji Metadata Source

Emoji metadata is generated from Unicode's official `emoji-test.txt` file:

```text
https://unicode.org/Public/emoji/latest/emoji-test.txt
```

The generation script is:

```text
scripts/generate-emoji-catalog.py
```

The script reads `emoji-test.txt`, keeps only `fully-qualified` emoji records,
and preserves the Unicode file order. It also preserves Unicode group and
subgroup names so the picker can display emoji with or without grouped sections.

Skin tone variants are detected from the Fitzpatrick modifier code points:

```text
1F3FB, 1F3FC, 1F3FD, 1F3FE, 1F3FF
```

Base emoji are stored as picker items. Skin tone emoji are stored under their
base emoji as `skinVariants`, which lets the picker show a secondary popover
when a selectable emoji has skin tone variants.

## Generating the Catalog

Generate from the default Unicode URL:

```sh
python3 scripts/generate-emoji-catalog.py
```

Generate from a local `emoji-test.txt` file:

```sh
python3 scripts/generate-emoji-catalog.py \
  --source /path/to/emoji-test.txt \
  --output Resources/Emoji/emoji-catalog.json
```

The output JSON is committed as a project resource:

```text
Resources/Emoji/emoji-catalog.json
```

The Xcode project includes this JSON in the app bundle resources. If the file is
missing or malformed, `EmojiCatalog` logs an error and returns an empty catalog.

## Catalog Shape

The generated JSON contains:

- `version`: Unicode emoji version parsed from the source file
- `date`: Unicode source file date
- `source`: URL or local path used by the generator
- `groups`: ordered Unicode groups
- `items`: ordered base emoji records inside each group
- `skinVariants`: ordered skin tone variants attached to a base emoji

Each emoji ID is the uppercase Unicode code point sequence joined with `-`.
For example, a single-code-point emoji uses an ID like `1F600`, while a composed
emoji uses an ID like `1F469-200D-1F4BB`.

## Maintenance Notes

Regenerate `emoji-catalog.json` when Unicode publishes a new emoji version or
when product requirements need the catalog refreshed.

After regeneration:

- Review the JSON diff for `version`, `date`, item order, group changes, and
  skin variant changes.
- Build the app to verify the resource is copied into the bundle.
- Check the picker preview to confirm grouped and ungrouped emoji still render.
- Avoid hand-editing `emoji-catalog.json`; update the generator instead when
  the catalog shape or filtering behavior needs to change.

For release-stable updates, prefer generating from a downloaded or versioned
`emoji-test.txt` file instead of the moving `latest` URL, then commit the updated
catalog with the script change if needed.
