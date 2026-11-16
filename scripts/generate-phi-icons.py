#!/usr/bin/env python3
"""Generate the Phi picture icons from Heroicons v2 mini (20px solid).

Each icon becomes an image set in Resources/Assets.xcassets/icons with a
black (light appearance) and a white (dark appearance) SVG, inset by the
same `translate(2 2) scale(0.8)` group the picker has always used. Character
icons (letters, numbers, punctuation) are drawn by hand and are not touched.
"""

from __future__ import annotations

import argparse
import io
import re
import sys
import tarfile
import urllib.request
from pathlib import Path


HEROICONS_VERSION = "2.2.0"
DEFAULT_SOURCE_URL = f"https://registry.npmjs.org/heroicons/-/heroicons-{HEROICONS_VERSION}.tgz"
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "Resources/Assets.xcassets/icons"
TARBALL_ICON_DIR = "package/20/solid/"

# (asset slug, Heroicons v2 name). The slug is the stored identity
# (`phi-icon-<slug>`), so existing slugs keep their v1 names even where
# Heroicons renamed the icon. Keep in step with PhiIconCatalog.all.
ICONS: list[tuple[str, str]] = [
    # Icons that shipped with Heroicons v1 artwork.
    ("mail", "envelope"),
    ("color-swatch", "swatch"),
    ("camera", "camera"),
    ("chat", "chat-bubble-oval-left-ellipsis"),
    ("bell", "bell"),
    ("user", "user"),
    ("globe-alt", "globe-alt"),
    ("sun", "sun"),
    ("sparkles", "sparkles"),
    ("credit-card", "credit-card"),
    ("ticket", "ticket"),
    ("moon", "moon"),
    ("briefcase", "briefcase"),
    ("archive", "archive-box"),
    ("lock-closed", "lock-closed"),
    ("office-building", "building-office"),
    ("chart-pie", "chart-pie"),
    ("shield-exclamation", "shield-exclamation"),
    ("photograph", "photo"),
    ("cog", "cog-6-tooth"),
    ("filter", "funnel"),
    ("qrcode", "qr-code"),
    ("clipboard-list", "clipboard-document-list"),
    ("lightning-bolt", "bolt"),
    ("light-bulb", "light-bulb"),
    ("view-grid-add", "squares-plus"),
    ("md-library", "building-library"),
    ("play", "play-circle"),
    ("presentation-chart-line", "presentation-chart-line"),
    ("chip", "cpu-chip"),
    ("cube-transparent", "cube-transparent"),
    ("search-circle", "magnifying-glass-circle"),
    ("cloud", "cloud"),
    ("academic-cap", "academic-cap"),
    ("gift", "gift"),
    ("truck", "truck"),
    ("cake", "cake"),
    ("beaker", "beaker"),
    ("table", "table-cells"),
    ("paper-airplane", "paper-airplane"),
    ("device-mobile", "device-phone-mobile"),
    ("music-note", "musical-note"),
    ("film", "film"),
    ("database", "circle-stack"),
    ("server", "server"),
    ("identification", "identification"),
    ("rss", "rss"),
    ("map", "map"),
]

# Icons added with the v2 artwork. Slug and Heroicons name are the same.
ICONS += [(name, name) for name in [
    # General
    "home", "star", "flag", "heart", "fire", "bookmark", "tag", "squares-2x2",
    "check-badge", "hand-thumb-up", "face-smile", "trophy", "rocket-launch",
    # Work and productivity
    "calendar-days", "clock", "document-text", "folder", "pencil-square",
    "clipboard-document-check", "inbox", "rectangle-stack", "calculator",
    "paper-clip", "chart-bar",
    # People and chat
    "chat-bubble-left-right", "users", "user-group", "at-symbol", "phone",
    "video-camera", "megaphone", "microphone",
    # Reading and help
    "newspaper", "book-open", "language", "lifebuoy",
    # Money and shopping
    "shopping-cart", "shopping-bag", "building-storefront", "banknotes", "wallet",
    "currency-dollar", "currency-euro", "receipt-percent", "arrow-trending-up",
    "scale",
    # Tech and dev
    "code-bracket", "command-line", "cube", "computer-desktop", "device-tablet",
    "wifi", "signal", "finger-print", "key", "shield-check", "bug-ant",
    "wrench-screwdriver", "puzzle-piece",
    # Media and creative
    "tv", "radio", "speaker-wave", "paint-brush", "scissors", "eye",
    "cursor-arrow-rays",
    # Places
    "map-pin", "globe-americas", "globe-europe-africa", "globe-asia-australia",
]]

CONTENTS_JSON = """{{
  "images" : [
    {{
      "filename" : "{light}",
      "idiom" : "universal"
    }},
    {{
      "appearances" : [
        {{
          "appearance" : "luminosity",
          "value" : "dark"
        }}
      ],
      "filename" : "{dark}",
      "idiom" : "universal"
    }}
  ],
  "info" : {{
    "author" : "xcode",
    "version" : 1
  }},
  "properties" : {{
    "preserves-vector-representation" : true
  }}
}}
"""


def load_heroicons(source: str | None) -> dict[str, str]:
    """Map Heroicons name to its 20/solid SVG text."""
    if source and Path(source).is_dir():
        return {path.stem: path.read_text() for path in Path(source).glob("*.svg")}

    if source:
        data = Path(source).read_bytes()
    else:
        with urllib.request.urlopen(DEFAULT_SOURCE_URL) as response:
            data = response.read()

    icons: dict[str, str] = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            if member.isfile() and member.name.startswith(TARBALL_ICON_DIR) and member.name.endswith(".svg"):
                name = member.name[len(TARBALL_ICON_DIR):-len(".svg")]
                if "/" not in name:
                    icons[name] = archive.extractfile(member).read().decode()
    return icons


def phi_svg(heroicon_svg: str, fill: str) -> str:
    paths = re.findall(r"<path\b[^>]*/>", heroicon_svg)
    if not paths:
        raise ValueError("no <path> elements found")
    lines = [path.replace("<path ", f'<path fill="{fill}" ', 1) for path in paths]
    return (
        '<svg width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">\n'
        '<g transform="translate(2 2) scale(0.8)">\n'
        + "\n".join(lines)
        + "\n</g>\n</svg>\n"
    )


def write_image_set(output: Path, slug: str, heroicon_svg: str) -> None:
    asset = f"phi-icon-{slug}"
    image_set = output / f"{asset}.imageset"
    image_set.mkdir(parents=True, exist_ok=True)
    for stale in image_set.glob("*.svg"):
        stale.unlink()
    (image_set / f"{asset}.svg").write_text(phi_svg(heroicon_svg, "black"))
    (image_set / f"{asset}-dark.svg").write_text(phi_svg(heroicon_svg, "white"))
    (image_set / "Contents.json").write_text(
        CONTENTS_JSON.format(light=f"{asset}.svg", dark=f"{asset}-dark.svg")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--source",
        help="Heroicons npm tarball (.tgz) or a folder of 20/solid SVGs. "
        f"Defaults to downloading heroicons {HEROICONS_VERSION} from npm.",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    heroicons = load_heroicons(args.source)
    missing = sorted({name for _, name in ICONS} - heroicons.keys())
    if missing:
        print(f"Missing from source: {', '.join(missing)}", file=sys.stderr)
        return 1
    slugs = [slug for slug, _ in ICONS]
    if len(slugs) != len(set(slugs)):
        print("Duplicate asset slugs in ICONS", file=sys.stderr)
        return 1

    for slug, name in ICONS:
        write_image_set(args.output, slug, heroicons[name])
    print(f"Wrote {len(ICONS)} image sets to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
