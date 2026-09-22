#!/usr/bin/env python3
"""Extract the production declarations the hostless merge harness needs.

The merge core (SyncableSettings / SyncableSpaces / BookmarkKind / PinKind /
URLRuleKind / SyncableOwnedItems) is pure, but it names a handful of value
types, protocols and constants that live in files whose *other* half drags in
the app (LocalStore, AccountUserDefaults, SwiftData, AppKit, ThemedColor, the
logger). Those files cannot be compiled whole outside the Xcode target.

Rather than copy the declarations into the test tree -- where they would drift
silently -- this script slices them out of the production sources at build
time, exactly the way `build-scripts/test-sync-invalidation.sh` slices
`refreshSpaceSyncGate` out of `PhiChromiumCoordinator.swift`. A renamed or
restructured declaration fails the build loudly instead of testing a stale copy.

Nothing under Sources/ is modified or written to.
"""

import re
import sys
from pathlib import Path

# --- Brace matcher ------------------------------------------------------------
# Swift-aware enough for declaration slicing: skips `//` comments, nestable
# `/* */` comments, and string literals (including escapes, so "\u{0}" and "{"
# never move the depth counter).


def _end_of_declaration(text: str, open_brace: int) -> int:
    depth = 0
    i = open_brace
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    break
                i += 1
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            nl = text.find("\n", i)
            i = n if nl == -1 else nl
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            level = 1
            i += 2
            while i < n and level:
                if text.startswith("/*", i):
                    level += 1
                    i += 2
                elif text.startswith("*/", i):
                    level -= 1
                    i += 2
                else:
                    i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit("unterminated declaration while slicing production source")


def slice_declaration(path: Path, pattern: str, body: bool) -> str:
    """Source text of the first declaration whose head matches `pattern`.

    `body=False` takes the single line (a stored property); `body=True`
    brace-matches, so a multi-line signature is handled too.
    """
    text = path.read_text()
    match = re.search(pattern, text, re.M)
    if not match:
        raise SystemExit(
            f"{path}: no declaration matches /{pattern}/.\n"
            "The hostless convergence harness slices this declaration out of the "
            "production source; it was renamed, moved or restructured. Update "
            "Tests/SyncConvergence/extract_production_slices.py to match."
        )
    if not body:
        line_end = text.find("\n", match.start())
        return text[match.start():len(text) if line_end == -1 else line_end]
    brace = text.find("{", match.start())
    if brace == -1:
        raise SystemExit(f"{path}: /{pattern}/ has no body")
    return text[match.start():_end_of_declaration(text, brace)]


# --- What to slice ------------------------------------------------------------
# (source file, [(pattern, has_body)]) -- emitted verbatim at file scope.

VERBATIM = [
    ("Sources/Sync/Phi/PhiSpaceLocalAccess.swift", [
        (r"^struct PhiLocalSpace\b", True),
        (r"^enum ProfileRefreshOutcome\b", True),
        (r"^@MainActor\nprotocol PhiSpaceLocalAccess\b", True),
    ]),
    ("Sources/Sync/Phi/PhiBookmarkLocalAccess.swift", [
        (r"^struct PhiLocalBookmark\b", True),
    ]),
    ("Sources/Sync/Phi/PhiPinnedTabLocalAccess.swift", [
        (r"^struct PhiLocalPin\b", True),
        (r"^struct PinFieldPatch\b", True),
        (r"^enum PinApplyOp\b", True),
        (r"^struct PinApplyBatch\b", True),
    ]),
    ("Sources/Sync/Phi/PhiURLRuleLocalAccess.swift", [
        (r"^struct PhiLocalURLRule\b", True),
        (r"^struct URLRuleLandingValues\b", True),
        (r"^enum URLRuleSyncOp\b", True),
        (r"^enum URLRuleSignatureQueries\b", True),
    ]),
    ("Sources/Sync/Phi/PhiSpaceSyncState.swift", [
        (r"^struct PhiSpaceCursor\b", True),
        (r"^struct PhiSpaceSyncTable\b", True),
        (r"^extension PhiSpaceSyncTable \{", True),
    ]),
    ("Sources/Sync/Phi/PhiOwnedItemState.swift", [
        (r"^struct PhiOwnedItemTable\b", True),
        (r"^extension PhiOwnedItemTable \{", True),
        (r"^struct PhiOwnedItemCursor\b", True),
    ]),
    ("Sources/LocalStorage/LocalStore+PinnedTabScope.swift", [
        (r"^enum PinnedTabScope\b", True),
    ]),
    ("Sources/Sync/Phi/PhiSyncProtocolClient.swift", [
        (r"^enum PhiSyncEntity\b", True),
    ]),
    ("Sources/UserInterface/Preferences/PhiPreferences.swift", [
        (r"^extension UserDefaults \{", True),
        (r"^enum LayoutMode\b", True),
        (r"^enum AutoPictureInPictureMode\b", True),
    ]),
]

# (synthesized head, source file, [(member pattern, has_body)]).
#
# These namespaces are app objects in production -- `final class`es carrying
# @Published state and ObservableObject conformance, or an enum whose other
# members reference the theme/agent/reader layers. Only the members below reach
# the merge core, so the harness re-hosts exactly those members under the same
# name. Every member is production text.
NAMESPACED = [
    ("enum SpaceManager", "Sources/States/Space/SpaceManager.swift", [
        (r"^    static let incognitoSpaceIdPrefix\b", False),
        (r"^    static func isIncognitoSpaceId\b", True),
        (r"^    static let incognitoRuleTargetId\b", False),
        (r"^    static let kioskRuleTargetId\b", False),
        (r"^    static func isRoutableRuleTarget\b", True),
    ]),
    ("enum AgentSpaceManager", "Sources/States/AgentSpace/AgentSpaceManager.swift", [
        (r"^    static let spaceNamePrefix\b", False),
        (r"^    static let spaceIconName\b", False),
        (r"^    static let spaceColorHex\b", False),
        (r"^    static let persistentSpaceColorHex\b", False),
        (r"^    nonisolated static func isAgentSpaceName\b", True),
        (r"^    nonisolated static func isAgentSpaceModel\b", True),
        (r"^    nonisolated static func isPersistentAgentSpaceModel\b", True),
    ]),
    ("enum LocalStore", "Sources/LocalStorage/LocalStore+SpaceURLRule.swift", [
        (r"^    static let kioskURLRuleTargetId\b", False),
        (r"^    static func normalizedRule\b", True),
        (r"^    static func normalizedHost\b", True),
        (r"^    static func normalizedPathPrefix\b", True),
    ]),
    ("enum PhiSpaceSyncState", "Sources/Sync/Phi/PhiSpaceSyncState.swift", [
        (r"^    nonisolated static let retentionMs\b", False),
    ]),
    # `enum PhiPreferences: String` itself carries ThemedColor/DefaultColors
    # constants, and its production extension also nests the Reader / AI /
    # AgentSpaces preference trees. Only these two nested enums are named by
    # SyncableSettings, so the namespace is re-declared empty and the two
    # production enums are re-hosted in it.
    ("enum PhiPreferences", "Sources/UserInterface/Preferences/PhiPreferences.swift", []),
    ("extension PhiPreferences", "Sources/UserInterface/Preferences/PhiPreferences.swift", [
        (r"^    enum GeneralSettings\b", True),
        (r"^    enum ThemeSettings\b", True),
    ]),
]

HEADER = """// GENERATED -- do not edit, do not commit.
//
// Produced by Tests/SyncConvergence/extract_production_slices.py from this
// repository's own Sources/. Every declaration below is production text; the
// script only re-hosts members of app objects under same-named namespaces so
// the merge core compiles without the app target.

import CryptoKit
import Foundation
"""


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2])
    chunks = [HEADER]

    for relative, members in VERBATIM:
        path = root / relative
        chunks.append(f"\n// MARK: - {relative}\n")
        for pattern, body in members:
            chunks.append(slice_declaration(path, pattern, body) + "\n")

    for head, relative, members in NAMESPACED:
        path = root / relative
        chunks.append(f"\n// MARK: - {relative} -> {head}\n")
        chunks.append(head + " {\n")
        for pattern, body in members:
            chunks.append(slice_declaration(path, pattern, body) + "\n")
        chunks.append("}\n")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(chunks))


if __name__ == "__main__":
    main()
