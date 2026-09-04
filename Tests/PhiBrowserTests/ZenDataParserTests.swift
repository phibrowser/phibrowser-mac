// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Compression
import XCTest
@testable import Phi

/// Zen's on-disk data read from fixtures: three `profiles.ini` shapes, the
/// Mozilla LZ4 container, a session file captured from a real install, and
/// the Zen source-model builder over the two.
final class ZenDataParserTests: XCTestCase {

    // MARK: - profiles.ini fixtures

    /// One usable profile, which the install section names.
    private let oneProfileINI = """
    [General]
    StartWithLastProfile=1
    Version=2

    [Profile0]
    Name=Default (release)
    IsRelative=1
    Path=Profiles/abcd1234.Default (release)
    Default=1

    [Install6ED35B3CA1B5D3AF]
    Default=Profiles/abcd1234.Default (release)
    Locked=1
    """

    /// Two usable profiles; the second is the install's default.
    private let twoProfilesINI = """
    [General]
    StartWithLastProfile=1
    Version=2

    [Profile0]
    Name=Work
    IsRelative=1
    Path=Profiles/aaaa0000.Work

    [Profile1]
    Name=Personal
    IsRelative=1
    Path=Profiles/bbbb1111.Personal

    [Install6ED35B3CA1B5D3AF]
    Default=Profiles/bbbb1111.Personal
    Locked=1
    """

    /// This machine's file (Zen 1.21.15b, 2026-08-30): a never-launched ghost
    /// carrying `Default=1` beside the profile the install section names.
    private let ghostINI = """
    [General]
    StartWithLastProfile=1
    Version=2

    [Profile0]
    Name=Default (release)
    IsRelative=1
    Path=Profiles/fgpkjy7r.Default (release)

    [Profile1]
    Name=Default Profile
    IsRelative=1
    Path=Profiles/gxnlgs9z.Default Profile
    Default=1

    [Install6ED35B3CA1B5D3AF]
    Default=Profiles/fgpkjy7r.Default (release)
    Locked=1

    [6ED35B3CA1B5D3AF]
    Default=Profiles/fgpkjy7r.Default (release)
    Locked=1
    """

    private let realKey = "fgpkjy7r.Default (release)"
    private let ghostKey = "gxnlgs9z.Default Profile"

    private func ini(_ text: String) -> ZenDataParserTool.ProfilesINI {
        ZenDataParserTool.parseProfilesINI(text)
    }

    // MARK: - profiles.ini

    func testProfilesComeOutInSectionOrderWithTheirNamesAndBasenames() {
        let profiles = ini(twoProfilesINI).profiles

        XCTAssertEqual(profiles.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(profiles.map(\.key), ["aaaa0000.Work", "bbbb1111.Personal"])
    }

    func testTheInstallSectionNamesTheDefaultProfile() {
        XCTAssertEqual(ini(twoProfilesINI).defaultProfileKey, "bbbb1111.Personal")
        XCTAssertEqual(ini(oneProfileINI).defaultProfileKey, "abcd1234.Default (release)")
    }

    /// The flag sits on the ghost; the install section is what counts.
    func testTheDefaultFlagDoesNotMakeAProfileTheDefault() {
        let parsed = ini(ghostINI)

        XCTAssertEqual(parsed.profiles.map(\.key), [realKey, ghostKey])
        XCTAssertEqual(parsed.defaultProfileKey, realKey)
    }

    /// Not even as a fallback: without an install section nothing is the
    /// default, whatever a profile section flags.
    func testWithoutAnInstallSectionThereIsNoDefault() {
        let parsed = ini("""
        [Profile0]
        Name=First
        IsRelative=1
        Path=Profiles/a.First

        [Profile1]
        Name=Second
        IsRelative=1
        Path=Profiles/b.Second
        Default=1
        """)

        XCTAssertEqual(parsed.profiles.map(\.name), ["First", "Second"])
        XCTAssertNil(parsed.defaultProfileKey)
    }

    func testAProfileWithoutANameHasAnEmptyOne() {
        let parsed = ini("""
        [Profile0]
        IsRelative=1
        Path=Profiles/abcd.nameless
        """)

        XCTAssertEqual(parsed.profiles.map(\.name), [""])
        XCTAssertEqual(parsed.profiles.map(\.key), ["abcd.nameless"])
    }

    /// Only a profile under Zen's own `Profiles` directory is listed: that
    /// is the one place the Chromium-side import resolves a profile key, so
    /// a profile the user put elsewhere would preview and then fail to
    /// import. An install section naming such a profile names no default.
    func testAProfileWithoutAPathOrOutsideZensProfilesDirectoryIsNotListed() {
        let parsed = ini("""
        [Profile0]
        Name=Broken

        [Profile1]
        Name=Elsewhere
        IsRelative=0
        Path=/Volumes/Elsewhere/Whole

        [Profile2]
        Name=Nested
        IsRelative=1
        Path=Backups/Profiles/x.Nested

        [Profile3]
        Name=Fine
        IsRelative=1
        Path=Profiles/ok.Fine

        [InstallABCD]
        Default=/Volumes/Elsewhere/Whole
        """)

        XCTAssertEqual(parsed.profiles, [ZenDataParserTool.Profile(name: "Fine", key: "ok.Fine")])
        XCTAssertNil(parsed.defaultProfileKey)
    }

    func testAnEmptyFileHasNoProfilesAndNoDefault() {
        let parsed = ini("")

        XCTAssertTrue(parsed.profiles.isEmpty)
        XCTAssertNil(parsed.defaultProfileKey)
    }

    // MARK: - The Mozilla LZ4 container

    /// `zen-live-folders.jsonlz4` as Zen wrote it on this machine, all fifteen
    /// bytes: the magic, a decoded size of two, and the block for `[]`.
    private let containerZenWrote = Data([
        0x6d, 0x6f, 0x7a, 0x4c, 0x7a, 0x34, 0x30, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x20, 0x5b, 0x5d,
    ])

    /// Wraps JSON the way Zen writes its session file — the mozlz4 header
    /// over one raw LZ4 block — with the block from the platform's own
    /// encoder.
    private func container(_ json: String) -> Data {
        let source = [UInt8](json.utf8)
        var block = [UInt8](repeating: 0, count: source.count + source.count / 255 + 64)
        let size = compression_encode_buffer(
            &block, block.count, source, source.count, nil, COMPRESSION_LZ4_RAW)
        XCTAssertGreaterThan(size, 0)
        var bytes = [UInt8]("mozLz40\0".utf8)
        bytes += withUnsafeBytes(of: UInt32(source.count).littleEndian, Array.init)
        bytes += block[..<size]
        return Data(bytes)
    }

    func testAContainerZenWroteDecodesWithThePlatformDecoder() throws {
        XCTAssertEqual(try ZenDataParserTool.decodeMozillaLZ4(containerZenWrote), Data("[]".utf8))
    }

    func testAFileWithoutTheMagicIsRejected() {
        XCTAssertThrowsError(try ZenDataParserTool.decodeMozillaLZ4(Data("{\"spaces\": []}".utf8))) {
            XCTAssertEqual($0 as? ZenDataParserTool.SessionFileError, .notAMozillaLZ4Container)
        }
    }

    func testAHeaderWithNothingAfterItIsRejected() {
        XCTAssertThrowsError(try ZenDataParserTool.decodeMozillaLZ4(containerZenWrote.prefix(12))) {
            XCTAssertEqual($0 as? ZenDataParserTool.SessionFileError, .notAMozillaLZ4Container)
        }
    }

    func testATruncatedContainerIsRejected() {
        let whole = container(capturedSession)
        let truncated = whole.prefix(whole.count / 2)

        XCTAssertThrowsError(try ZenDataParserTool.decodeMozillaLZ4(truncated)) {
            guard case .truncatedOrCorrupt(let decoded, let declared)? = $0 as? ZenDataParserTool.SessionFileError else {
                return XCTFail("unexpected error \($0)")
            }
            XCTAssertLessThan(decoded, declared)
            XCTAssertEqual(declared, capturedSession.utf8.count)
        }
    }

    /// A header claiming four gigabytes is a malformed file, not a large one,
    /// and must not be allocated for.
    func testAnAbsurdDeclaredSizeIsRejectedWithoutAllocating() {
        var bytes = [UInt8](containerZenWrote)
        bytes.replaceSubrange(8..<12, with: [0xff, 0xff, 0xff, 0xff])

        XCTAssertThrowsError(try ZenDataParserTool.decodeMozillaLZ4(Data(bytes))) {
            XCTAssertEqual($0 as? ZenDataParserTool.SessionFileError, .declaredSizeOutOfRange(0xffff_ffff))
        }
    }

    // MARK: - The session file

    /// `zen-sessions.jsonlz4` from this machine's Zen 1.21.15b profile
    /// (2026-08-30, re-read after the user set the spaces' containers),
    /// decoded, with the two-stop space's stops swapped so that the primary
    /// is second — Zen had written the primary first. As Zen writes it,
    /// `icon` is absent from a space with none, `lightness` is sometimes a
    /// string, and `containerTabId` is the container's id — 6 the custom one,
    /// 3 Banking, 0 none, 1 Personal.
    ///
    /// The pinned tabs and folders are this machine's too, every URL and
    /// title scrubbed and each tab cut down to the keys Zen's own shape
    /// carries for them, in Zen's order: two Essentials (one in no
    /// container, one in Personal), an empty placeholder and a pin in the
    /// "zen basics" folder, four loose pins, and — under "qqq" — a loose pin,
    /// a placeholder and a pin in "New Folder", a loose pin; then the pins of
    /// "abc"; and an open, unpinned tab, which Zen writes beside the pins
    /// while it runs. Added by hand for the cases the real file did not hold
    /// at once: an Essential in Work (a container no Space is set to), a
    /// pin whose pinned-at entry differs from its current one ("OS"), a
    /// "Reading" folder nested in "New Folder" with a pin, an "Empty" folder
    /// holding only a placeholder, a Glance tab, a pin with no pinned-at
    /// entry ("Current"), and a pin naming a workspace that is not in
    /// `spaces[]` ("Orphan"); and, for the split views, with example hosts:
    /// two pins split inside "zen basics" — with the `folders[]` record Zen
    /// writes for a split placed in a folder, flagged `splitViewGroup` —
    /// two pins split stacked at the root of "Space", whose layout names
    /// them the other way round from the file ("Docs" first), and a grid
    /// of three under "qqq". `groups[]` — copies of the folders as Firefox
    /// tab groups — is emptied, being ignored.
    private let capturedSession = """
    {
      "lastCollected": 1788092851102,
      "tabs": [
        {
          "entries": [
            { "url": "https://search.example/policy/", "title": "Policy" },
            { "url": "https://search.example/", "title": "Search" }
          ],
          "pinned": true, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1787729867468-64", "zenEssential": true, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://search.example/", "title": "Search" }, "image": null },
          "userContextId": 0, "index": 2
        },
        {
          "entries": [ { "url": "https://social.example/", "title": "Social" } ],
          "pinned": true, "zenWorkspace": "{ddae1ff1-c30a-45dc-b8ac-b5f70db8fed4}",
          "zenSyncId": "1788087466541-13", "zenEssential": true, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://social.example/", "title": "Social" }, "image": null },
          "userContextId": 1, "index": 1
        },
        {
          "entries": [ { "url": "https://mail.example/", "title": "Mail" } ],
          "pinned": true, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788099000000-01", "zenEssential": true, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://mail.example/", "title": "Mail" }, "image": null },
          "userContextId": 2, "index": 1
        },
        {
          "entries": [ { "url": "about:blank" } ],
          "pinned": true, "groupId": "1787729895449-23", "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1787729895454-87", "zenEssential": false, "zenIsEmpty": true, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "about:blank" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://zen.example/welcome/", "title": "Welcome" } ],
          "pinned": true, "groupId": "1787729895449-23", "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1787729867469-83", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://zen.example/welcome/", "title": "Welcome" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://notes.example/", "title": "Notes" } ],
          "pinned": true, "groupId": "1788100000000-11", "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788100000000-12", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://notes.example/", "title": "Notes" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://tasks.example/", "title": "Tasks" } ],
          "pinned": true, "groupId": "1788100000000-11", "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788100000000-13", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://tasks.example/", "title": "Tasks" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://zen.example/welcome/", "title": "Welcome" } ],
          "pinned": true, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1787729956461-80", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://zen.example/welcome/", "title": "Welcome" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://video.example/", "title": "Video" } ],
          "pinned": true, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1787729956441-24", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://video.example/", "title": "Video" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://chat.example/", "title": "Chat" } ],
          "pinned": true, "groupId": "1788100000000-21", "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788100000000-22", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://chat.example/", "title": "Chat" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://docs.example/", "title": "Docs" } ],
          "pinned": true, "groupId": "1788100000000-21", "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788100000000-23", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://docs.example/", "title": "Docs" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://wiki.example/", "title": "Wiki" } ],
          "pinned": true, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1787729930022-20", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://wiki.example/", "title": "Wiki" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://os.example/changed/", "title": "OS, changed" } ],
          "pinned": true, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788086996175-64", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://os.example/", "title": "OS" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://forum.example/topic/1/", "title": "Topic" } ],
          "pinned": true, "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788098557189-59", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://forum.example/topic/1/", "title": "Topic" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "about:blank" } ],
          "pinned": true, "groupId": "1788098553873-3", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788098553880-31", "zenEssential": false, "zenIsEmpty": true, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "about:blank" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://forum.example/", "title": "Forum" } ],
          "pinned": true, "groupId": "1788098553873-3", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788098544470-70", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://forum.example/", "title": "Forum" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://forum.example/reading/", "title": "Reading list" } ],
          "pinned": true, "groupId": "1788098553873-4", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788099000000-02", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://forum.example/reading/", "title": "Reading list" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "about:blank" } ],
          "pinned": true, "groupId": "1788098553873-5", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788099000000-03", "zenEssential": false, "zenIsEmpty": true, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "about:blank" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://glance.example/", "title": "Glance" } ],
          "pinned": true, "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788099000000-04", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": true,
          "_zenPinnedInitialState": { "entry": { "url": "https://glance.example/", "title": "Glance" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [
            { "url": "https://engine.example/start/", "title": "Start" },
            { "url": "https://engine.example/", "title": "Engine" }
          ],
          "pinned": true, "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788098572307-51", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://engine.example/", "title": "Engine" }, "image": null },
          "userContextId": 0, "index": 2
        },
        {
          "entries": [ { "url": "https://alpha.example/", "title": "Alpha" } ],
          "pinned": true, "groupId": "1788100000000-31", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788100000000-32", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://alpha.example/", "title": "Alpha" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://beta.example/", "title": "Beta" } ],
          "pinned": true, "groupId": "1788100000000-31", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788100000000-33", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://beta.example/", "title": "Beta" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://gamma.example/", "title": "Gamma" } ],
          "pinned": true, "groupId": "1788100000000-31", "zenWorkspace": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
          "zenSyncId": "1788100000000-34", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://gamma.example/", "title": "Gamma" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "https://os.example/io/", "title": "OS (io)" } ],
          "pinned": true, "zenWorkspace": "{ddae1ff1-c30a-45dc-b8ac-b5f70db8fed4}",
          "zenSyncId": "1788087438888-39", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://os.example/io/", "title": "OS (io)" }, "image": null },
          "userContextId": 1, "index": 1
        },
        {
          "entries": [
            { "url": "https://fallback.example/first/", "title": "First" },
            { "url": "https://fallback.example/current/", "title": "Current" }
          ],
          "pinned": true, "zenWorkspace": "{ddae1ff1-c30a-45dc-b8ac-b5f70db8fed4}",
          "zenSyncId": "1788099000000-05", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "userContextId": 1, "index": 2
        },
        {
          "entries": [ { "url": "https://orphan.example/", "title": "Orphan" } ],
          "pinned": true, "zenWorkspace": "{00000000-0000-0000-0000-000000000000}",
          "zenSyncId": "1788099000000-06", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": { "entry": { "url": "https://orphan.example/", "title": "Orphan" }, "image": null },
          "userContextId": 0, "index": 1
        },
        {
          "entries": [ { "url": "about:preferences#containers", "title": "Settings" } ],
          "pinned": false, "zenWorkspace": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
          "zenSyncId": "1788095333100-4", "zenEssential": false, "zenIsEmpty": false, "zenIsGlance": false,
          "_zenPinnedInitialState": {},
          "userContextId": 0, "index": 1
        }
      ],
      "spaces": [
        {
          "containerTabId": 6,
          "hasCollapsedPinnedTabs": false,
          "icon": "chrome://browser/skin/zen-icons/selectable/airplane.svg",
          "name": "Space",
          "theme": { "gradientColors": [], "opacity": 0.5, "texture": 0, "type": "gradient" },
          "uuid": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}"
        },
        {
          "containerTabId": 3,
          "hasCollapsedPinnedTabs": false,
          "icon": "chrome://browser/skin/zen-icons/selectable/american-football.svg",
          "name": "TTT",
          "theme": {
            "gradientColors": [
              { "algorithm": "complementary", "c": [45, 113, 251], "isCustom": false, "isPrimary": false,
                "lightness": 58, "position": { "x": 94, "y": 107 }, "type": "undefined" },
              { "algorithm": "complementary", "c": [250, 181, 40], "isCustom": false, "isPrimary": true,
                "lightness": 58, "position": { "x": 264, "y": 251 }, "type": "undefined" }
            ],
            "opacity": 0.5, "texture": 0, "type": "gradient"
          },
          "uuid": "{9438b3f9-b6e7-41d9-8c70-61e1fedea9e9}"
        },
        {
          "containerTabId": 0,
          "hasCollapsedPinnedTabs": false,
          "name": "qqq",
          "theme": {
            "gradientColors": [
              { "algorithm": "", "c": [168, 6, 58], "isCustom": false, "isPrimary": true,
                "lightness": 34, "position": { "x": 243, "y": 158 }, "type": "undefined" }
            ],
            "opacity": 0.5, "texture": 0, "type": "gradient"
          },
          "uuid": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}"
        },
        {
          "containerTabId": 1,
          "hasCollapsedPinnedTabs": false,
          "icon": "🤡",
          "name": "abc",
          "theme": {
            "gradientColors": [
              { "algorithm": "floating", "c": [70, 236, 168], "isCustom": false, "isPrimary": true,
                "lightness": "60", "position": { "x": 147, "y": 195 }, "type": "explicit-lightness" }
            ],
            "opacity": 0.695, "texture": 0, "type": "gradient"
          },
          "uuid": "{ddae1ff1-c30a-45dc-b8ac-b5f70db8fed4}"
        }
      ],
      "folders": [
        { "pinned": true, "splitViewGroup": false, "id": "1787729895449-23", "name": "zen basics", "collapsed": true,
          "saveOnWindowClose": true, "parentId": null, "prevSiblingInfo": null, "userIcon": "",
          "workspaceId": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}" },
        { "pinned": true, "splitViewGroup": true, "id": "1788100000000-11", "name": "", "collapsed": false,
          "saveOnWindowClose": true, "parentId": "1787729895449-23", "prevSiblingInfo": { "type": "tab", "id": "1787729867469-83" },
          "userIcon": "", "essential": false, "emptyTabIds": [],
          "workspaceId": "{c406b463-0db9-48a4-90a8-317bd1bd9d12}" },
        { "pinned": true, "splitViewGroup": false, "id": "1788098553873-3", "name": "New Folder", "collapsed": true,
          "saveOnWindowClose": true, "parentId": null, "prevSiblingInfo": { "type": "tab", "id": "1788098557189-59" },
          "userIcon": "", "workspaceId": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}" },
        { "pinned": true, "splitViewGroup": false, "id": "1788098553873-4", "name": "Reading", "collapsed": false,
          "saveOnWindowClose": true, "parentId": "1788098553873-3", "prevSiblingInfo": { "type": "tab", "id": "1788098544470-70" },
          "userIcon": "", "workspaceId": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}" },
        { "pinned": true, "splitViewGroup": false, "id": "1788098553873-5", "name": "Empty", "collapsed": false,
          "saveOnWindowClose": true, "parentId": null, "prevSiblingInfo": { "type": "tab", "id": "1788099000000-02" },
          "userIcon": "", "workspaceId": "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}" }
      ],
      "groups": [],
      "splitViewData": [
        { "groupId": "1788100000000-11", "gridType": "vsep",
          "layoutTree": { "type": "splitter", "direction": "row", "sizeInParent": 100, "children": [
            { "type": "leaf", "tabId": "1788100000000-12", "sizeInParent": 50 },
            { "type": "leaf", "tabId": "1788100000000-13", "sizeInParent": 50 } ] },
          "tabs": [ "1788100000000-12", "1788100000000-13" ] },
        { "groupId": "1788100000000-21", "gridType": "hsep",
          "layoutTree": { "type": "splitter", "direction": "column", "sizeInParent": 100, "children": [
            { "type": "leaf", "tabId": "1788100000000-23", "sizeInParent": 50 },
            { "type": "leaf", "tabId": "1788100000000-22", "sizeInParent": 50 } ] },
          "tabs": [ "1788100000000-22", "1788100000000-23" ] },
        { "groupId": "1788100000000-31", "gridType": "grid",
          "layoutTree": { "type": "splitter", "direction": "row", "sizeInParent": 100, "children": [
            { "type": "splitter", "direction": "column", "sizeInParent": 50, "children": [
              { "type": "leaf", "tabId": "1788100000000-32", "sizeInParent": 50 },
              { "type": "leaf", "tabId": "1788100000000-33", "sizeInParent": 50 } ] },
            { "type": "leaf", "tabId": "1788100000000-34", "sizeInParent": 50 } ] },
          "tabs": [ "1788100000000-32", "1788100000000-33", "1788100000000-34" ] }
      ]
    }
    """

    private func spaces(_ json: String) throws -> [ZenDataParserTool.Space] {
        try ZenDataParserTool.parseSession(json: Data(json.utf8)).spaces
    }

    func testSpacesComeOutInArrayOrder() throws {
        let spaces = try spaces(capturedSession)

        XCTAssertEqual(spaces.map(\.name), ["Space", "TTT", "qqq", "abc"])
        XCTAssertEqual(spaces.map(\.id), [
            "{c406b463-0db9-48a4-90a8-317bd1bd9d12}",
            "{9438b3f9-b6e7-41d9-8c70-61e1fedea9e9}",
            "{d84b71ba-bc19-41e0-a6a0-28a93aa9d024}",
            "{ddae1ff1-c30a-45dc-b8ac-b5f70db8fed4}",
        ])
    }

    /// The stop flagged primary, which here is the second one.
    func testTheColourIsThePrimaryStopNotTheFirst() throws {
        XCTAssertEqual(try spaces(capturedSession)[1].colorHex, "#fab528")
    }

    func testAOneStopThemeYieldsThatStopWhateverItsLightnessLooksLike() throws {
        let spaces = try spaces(capturedSession)

        XCTAssertEqual(spaces[2].colorHex, "#a8063a")
        XCTAssertEqual(spaces[3].colorHex, "#46eca8")
    }

    func testNoStopsYieldsNoColour() throws {
        XCTAssertNil(try spaces(capturedSession)[0].colorHex)
    }

    func testTheIconIsCarriedAsWritten() throws {
        let spaces = try spaces(capturedSession)

        XCTAssertEqual(spaces[0].icon, "chrome://browser/skin/zen-icons/selectable/airplane.svg")
        XCTAssertEqual(spaces[1].icon, "chrome://browser/skin/zen-icons/selectable/american-football.svg")
        XCTAssertNil(spaces[2].icon)
        XCTAssertEqual(spaces[3].icon, "🤡")
    }

    func testTheCapturedFileParsesFromItsContainer() throws {
        let session = try ZenDataParserTool.parseSession(container: container(capturedSession))

        XCTAssertEqual(session.spaces.map(\.name), ["Space", "TTT", "qqq", "abc"])
    }

    func testWhenNoStopIsFlaggedPrimaryTheFirstStands() throws {
        let spaces = try spaces("""
        { "spaces": [ { "uuid": "{1}", "name": "A", "theme": { "gradientColors": [
            { "c": [0, 0, 255] }, { "c": [255, 0, 0] } ] } } ] }
        """)

        XCTAssertEqual(spaces[0].colorHex, "#0000ff")
    }

    func testAnOutOfRangeChannelIsClamped() throws {
        let spaces = try spaces("""
        { "spaces": [ { "uuid": "{1}", "name": "A", "theme": { "gradientColors": [
            { "c": [300, -20, 127.6], "isPrimary": true } ] } } ] }
        """)

        XCTAssertEqual(spaces[0].colorHex, "#ff0080")
    }

    func testANullIconAndAMissingThemeAreNoIconAndNoColour() throws {
        let spaces = try spaces("""
        { "spaces": [ { "uuid": "{1}", "name": "A", "icon": null }, { "uuid": "{2}", "name": "B", "icon": "" } ] }
        """)

        XCTAssertEqual(spaces.map(\.icon), [nil, nil])
        XCTAssertEqual(spaces.map(\.colorHex), [nil, nil])
    }

    func testAnEmptyNameTakesTheExistingPlaceholder() throws {
        let spaces = try spaces("""
        { "spaces": [ { "uuid": "{1}", "name": "  " }, { "uuid": "{2}" } ] }
        """)

        let placeholder = NSLocalizedString("app.browserMigration.zen.untitledSpaceName",
            value: "Untitled Space", comment: "Browser migration wizard - fallback name for a Zen workspace that has no name")
        XCTAssertEqual(spaces.map(\.name), [placeholder, placeholder])
    }

    /// A theme this parser cannot read costs the colour, never the space.
    func testAMalformedThemeCostsTheColourNotTheSpace() throws {
        let spaces = try spaces("""
        { "spaces": [ { "uuid": "{1}", "name": "A", "theme": { "gradientColors": [ { "c": "red" } ] } },
                      { "uuid": "{2}", "name": "B", "theme": "none" } ] }
        """)

        XCTAssertEqual(spaces.map(\.name), ["A", "B"])
        XCTAssertEqual(spaces.map(\.colorHex), [nil, nil])
    }

    /// A profile predating workspaces has no `spaces` at all: no Spaces, not
    /// an unreadable file.
    func testAFileWithoutASpacesArrayHasNoSpaces() throws {
        XCTAssertEqual(try spaces("{ \"tabs\": [] }"), [])
    }

    func testASpaceWithoutAnIdentifierMakesTheFileUnreadable() {
        XCTAssertThrowsError(try spaces("{ \"spaces\": [ { \"name\": \"A\" } ] }"))
    }

    func testAFileThatIsNotJSONIsUnreadable() {
        let prose = String(repeating: "This is not a session file. ", count: 8)

        XCTAssertThrowsError(try ZenDataParserTool.parseSession(container: container(prose)))
    }

    func testASpaceCarriesTheContainerItIsSetToAndNoneIsZero() throws {
        XCTAssertEqual(try spaces(capturedSession).map(\.containerTabId), [6, 3, 0, 1])
        XCTAssertEqual(try spaces("{ \"spaces\": [ { \"uuid\": \"{1}\", \"name\": \"A\" } ] }").map(\.containerTabId), [0])
    }

    // MARK: - Pinned tabs and folders

    private func session(_ json: String) throws -> ZenDataParserTool.Session {
        try ZenDataParserTool.parseSession(json: Data(json.utf8))
    }

    /// In file order, Essentials and workspace pins alike. The two empty
    /// placeholders, the Glance tab and the open tab are not pins.
    func testPinnedTabsComeOutInFileOrderWithoutPlaceholdersGlanceTabsOrOpenTabs() throws {
        let tabs = try session(capturedSession).pinnedTabs

        XCTAssertEqual(tabs.map(\.title), [
            "Search", "Social", "Mail",
            "Welcome", "Notes", "Tasks", "Welcome", "Video", "Chat", "Docs", "Wiki", "OS",
            "Topic", "Forum", "Reading list", "Engine", "Alpha", "Beta", "Gamma",
            "OS (io)", "Current", "Orphan",
        ])
    }

    func testAnEssentialIsMarkedAndCarriesItsContainer() throws {
        let tabs = try session(capturedSession).pinnedTabs

        XCTAssertEqual(tabs.prefix(3).map(\.isEssential), [true, true, true])
        XCTAssertEqual(tabs.prefix(3).map(\.userContextId), [0, 1, 2])
        XCTAssertFalse(tabs.dropFirst(3).contains(where: \.isEssential))
    }

    /// "Welcome" is pinned twice: once in the "zen basics" folder, once loose.
    func testAWorkspacePinNamesItsWorkspaceAndTheFolderItSitsIn() throws {
        let tabs = try session(capturedSession).pinnedTabs
        func pin(_ title: String) -> ZenDataParserTool.PinnedTab? { tabs.first { $0.title == title } }

        XCTAssertEqual(pin("Welcome")?.workspaceID, "{c406b463-0db9-48a4-90a8-317bd1bd9d12}")
        XCTAssertEqual(pin("Welcome")?.groupID, "1787729895449-23")
        XCTAssertNil(tabs.last { $0.title == "Welcome" }?.groupID)
        XCTAssertNil(pin("Video")?.groupID)
        XCTAssertEqual(pin("Reading list")?.groupID, "1788098553873-4")
        XCTAssertEqual(pin("Orphan")?.workspaceID, "{00000000-0000-0000-0000-000000000000}")
    }

    /// The pinned-at entry is what Zen's own "reset pinned tab" returns to;
    /// a pin without one reads its current entry.
    func testTheURLAndTitleAreThePinnedAtEntryFallingBackToTheCurrentOne() throws {
        let tabs = try session(capturedSession).pinnedTabs
        func pin(_ title: String) -> ZenDataParserTool.PinnedTab? { tabs.first { $0.title == title } }

        XCTAssertEqual(pin("OS")?.url, "https://os.example/")
        XCTAssertNil(pin("OS, changed"))
        XCTAssertEqual(pin("Current")?.url, "https://fallback.example/current/")
        XCTAssertNil(pin("First"))
    }

    /// The record flagged `splitViewGroup` — the split view placed in "zen
    /// basics" — is not a folder and is not among them.
    func testFoldersComeOutWithTheirNesting() throws {
        let folders = try session(capturedSession).folders

        XCTAssertEqual(folders.map(\.id),
                       ["1787729895449-23", "1788098553873-3", "1788098553873-4", "1788098553873-5"])
        XCTAssertEqual(folders.map(\.name), ["zen basics", "New Folder", "Reading", "Empty"])
        XCTAssertEqual(folders.map(\.parentID), [nil, nil, "1788098553873-3", nil])
    }

    /// A split view is a Firefox tab group of its own — its pins carry its
    /// id in `groupId` — and `splitViewData[]` says which groups are splits
    /// and how they are laid out. The one placed in "zen basics" has the
    /// `folders[]` record too, which names that folder; the one at the root
    /// has none; the grid of three nests a splitter in a pane, so its top
    /// level is not all leaves and it has no panes to pair.
    func testSplitViewsComeOutWithTheirPanesDirectionAndParentFolder() throws {
        let splitViews = try session(capturedSession).splitViews

        XCTAssertEqual(splitViews, [
            ZenDataParserTool.SplitView(
                id: "1788100000000-11", parentFolderID: "1787729895449-23",
                direction: "row", paneTabIDs: ["1788100000000-12", "1788100000000-13"]),
            ZenDataParserTool.SplitView(
                id: "1788100000000-21", parentFolderID: nil,
                direction: "column", paneTabIDs: ["1788100000000-23", "1788100000000-22"]),
            ZenDataParserTool.SplitView(
                id: "1788100000000-31", parentFolderID: nil, direction: "row", paneTabIDs: nil),
        ])
    }

    /// A split's layout names its panes by the tabs' `zenSyncId`; a pin in a
    /// split carries the split's id where a folder's pins carry the folder's.
    func testAPinCarriesItsSyncIdAndTheSplitViewItSitsIn() throws {
        let tabs = try session(capturedSession).pinnedTabs
        func pin(_ title: String) -> ZenDataParserTool.PinnedTab? { tabs.first { $0.title == title } }

        XCTAssertEqual(pin("Docs")?.syncID, "1788100000000-23")
        XCTAssertEqual(pin("Docs")?.groupID, "1788100000000-21")
        XCTAssertEqual(pin("Notes")?.groupID, "1788100000000-11")
        XCTAssertEqual(pin("Welcome")?.syncID, "1787729867469-83")
    }

    /// A `splitViewGroup` record with no `splitViewData[]` entry — a shape
    /// Zen does not write — is still not a folder: it is a split with no
    /// layout, and so no panes, placed in the folder the record names.
    func testASplitViewGroupRecordWithoutAnEntryIsASplitWithNoPanes() throws {
        let session = try session("""
        { "spaces": [], "folders": [
            { "id": "f1", "name": "Folder" },
            { "id": "s1", "name": "", "parentId": "f1", "splitViewGroup": true } ] }
        """)

        XCTAssertEqual(session.folders.map(\.id), ["f1"])
        XCTAssertEqual(session.splitViews, [ZenDataParserTool.SplitView(
            id: "s1", parentFolderID: "f1", direction: nil, paneTabIDs: nil)])
    }

    /// A tab with no entry to read a URL from is not a pin; without an
    /// `index` the current entry is the last one; a missing title is empty.
    func testATabWithoutAURLIsNotAPinAndWithoutAnIndexTheLastEntryIsCurrent() throws {
        let tabs = try session("""
        { "spaces": [], "tabs": [
            { "pinned": true, "zenWorkspace": "{1}", "entries": [] },
            { "pinned": true, "zenWorkspace": "{1}",
              "entries": [ { "url": "https://a.example/" }, { "url": "https://b.example/" } ] } ] }
        """).pinnedTabs

        XCTAssertEqual(tabs, [ZenDataParserTool.PinnedTab(
            workspaceID: "{1}", isEssential: false, userContextId: 0, groupID: nil,
            title: "", url: "https://b.example/", syncID: nil)])
    }

    // MARK: - containers.json

    /// This machine's `containers.json` (2026-08-30): the four Firefox
    /// defaults, Firefox's two internal identities, the custom container the
    /// user made ("AAAAAAAAA", which the captured session's first space is
    /// set to), and — appended by hand from a later read of the same file,
    /// its icon and colour not captured — the custom "NOT USED" the user made
    /// next and set no space to.
    private let capturedContainers = """
    {"version":6,"lastUserContextId":7,"identities":[{"icon":"fingerprint","color":"blue","l10nId":"user-context-personal","public":true,"userContextId":1},{"icon":"briefcase","color":"orange","l10nId":"user-context-work","public":true,"userContextId":2},{"icon":"dollar","color":"green","l10nId":"user-context-banking","public":true,"userContextId":3},{"icon":"cart","color":"pink","l10nId":"user-context-shopping","public":true,"userContextId":4},{"public":false,"icon":"","color":"","name":"userContextIdInternal.thumbnail","accessKey":"","userContextId":5},{"userContextId":4294967295,"public":false,"icon":"","color":"","name":"userContextIdInternal.webextStorageLocal","accessKey":""},{"userContextId":6,"public":true,"icon":"briefcase","color":"blue","name":"AAAAAAAAA"},{"userContextId":7,"public":true,"name":"NOT USED"}]}
    """

    private func containers(_ json: String) throws -> [ZenDataParserTool.Container] {
        try ZenDataParserTool.parseContainers(json: Data(json.utf8))
    }

    func testContainersComeOutInFileOrderWithoutTheInternalOnes() throws {
        let containers = try containers(capturedContainers)

        XCTAssertEqual(containers.map(\.userContextId), [1, 2, 3, 4, 6, 7])
        XCTAssertEqual(containers.map(\.l10nId), [
            "user-context-personal", "user-context-work", "user-context-banking",
            "user-context-shopping", nil, nil,
        ])
        XCTAssertEqual(containers.map(\.name), [nil, nil, nil, nil, "AAAAAAAAA", "NOT USED"])
    }

    func testAContainersFileWithNoIdentitiesHasNone() throws {
        XCTAssertEqual(try containers("{ \"version\": 6 }"), [])
    }

    /// Firefox reads a missing `public` as not public; and an identity with
    /// the id of no container would double the no-container Profile.
    func testAnIdentityWithoutThePublicFlagOrWithTheNoContainerIdIsLeftOut() throws {
        let containers = try containers("""
        { "identities": [
            { "userContextId": 9, "name": "Unflagged" },
            { "userContextId": 0, "public": true, "name": "Zero" },
            { "userContextId": 8, "public": true, "name": "Kept" } ] }
        """)

        XCTAssertEqual(containers.map(\.userContextId), [8])
    }

    func testAMalformedContainersFileIsUnreadable() {
        XCTAssertThrowsError(try containers("[]"))
        XCTAssertThrowsError(try containers("{ \"identities\": [ { \"name\": \"no id\" } ] }"))
    }

    // MARK: - Source model

    private typealias Zen = BrowserDataImporter.ZenMigrationSource

    private func zenSpace(
        _ id: String, _ name: String, colorHex: String? = nil, container: Int = 0, icon: String? = nil
    ) -> ZenDataParserTool.Space {
        ZenDataParserTool.Space(
            id: id, name: name, colorHex: colorHex, containerTabId: container, icon: icon)
    }

    private func source(
        _ text: String,
        sessions: [String: [ZenDataParserTool.Space]],
        containers: [String: [ZenDataParserTool.Container]] = [:]
    ) -> BrowserMigrationSource {
        Zen(
            profilesINI: ini(text),
            sessions: sessions.mapValues { ZenDataParserTool.Session(spaces: $0) },
            containers: containers
        ).migrationSource
    }

    private func source(
        _ text: String,
        session: ZenDataParserTool.Session,
        under key: String,
        containers: [ZenDataParserTool.Container] = []
    ) -> BrowserMigrationSource {
        Zen(profilesINI: ini(text), sessions: [key: session], containers: [key: containers])
            .migrationSource
    }

    /// A Space's tree: a folder bracketing what it holds, a split showing
    /// its second page after its first.
    private func outline(_ node: ArcDataParserTool.Bookmark) -> [String] {
        node.children.map { child in
            if child.isFolder { return "\(child.title ?? "")[\(outline(child).joined(separator: ", "))]" }
            if let split = child.split { return "\(child.title ?? "") ⫽ \(split.secondaryTitle)" }
            return child.title ?? ""
        }
    }

    private func plan(_ source: BrowserMigrationSource) -> BrowserMigrationPlan {
        BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!)
    }

    private func rows(_ source: BrowserMigrationSource) -> [BrowserMigrationPreviewProfileRow] {
        BrowserMigrationPreview.rows(source: source, plan: plan(source))
    }

    private func essential(container: Int, _ title: String, _ url: String) -> ZenDataParserTool.PinnedTab {
        ZenDataParserTool.PinnedTab(
            workspaceID: "{1}", isEssential: true, userContextId: container, groupID: nil,
            title: title, url: url, syncID: nil)
    }

    /// The design machine as it stands: the captured spaces over the captured
    /// containers under the profile the install names, beside the
    /// never-launched ghost. One for the Space set to none, then the
    /// containers in use — the custom one, Banking, Personal — in first
    /// appearance order rather than the containers' own, then Work, Shopping
    /// and the custom NOT USED, which no Space uses, greyed as having none;
    /// every Profile reads the Firefox profile's directory; the ghost, which
    /// the user never chose anything in, gets no row at all.
    func testProfilesAreDerivedFromTheContainersSpacesAreSetTo() throws {
        let source = source(
            ghostINI,
            sessions: [realKey: try spaces(capturedSession)],
            containers: [realKey: try containers(capturedContainers)])

        XCTAssertEqual(source.profiles.map(\.key), [
            "\(realKey)#0", "\(realKey)#6", "\(realKey)#3", "\(realKey)#1",
            "\(realKey)#2", "\(realKey)#4", "\(realKey)#7",
        ])
        XCTAssertEqual(source.profiles.map(\.displayName),
                       ["Zen", "AAAAAAAAA", "Banking", "Personal", "Work", "Shopping", "NOT USED"])
        XCTAssertEqual(Set(source.profiles.map(\.sourceDirectory)), [realKey])
        XCTAssertEqual(source.spaces.map(\.profileKey),
                       ["\(realKey)#6", "\(realKey)#3", "\(realKey)#0", "\(realKey)#1"])
        XCTAssertEqual(source.defaultProfileKey, "\(realKey)#0")

        let rows = rows(source)
        XCTAssertEqual(rows.map(\.displayName),
                       ["Zen", "AAAAAAAAA", "Banking", "Personal", "Work", "Shopping", "NOT USED"])
        XCTAssertEqual(rows.map { $0.spaces.map(\.name) },
                       [["qqq"], ["Space"], ["TTT"], ["abc"], [], [], []])
        XCTAssertEqual(rows.map(\.skipReason), [nil, nil, nil, nil, .noSpaces, .noSpaces, .noSpaces])
    }

    func testSpacesAllSetToContainersLeaveNoNoContainerProfile() throws {
        let source = source(
            oneProfileINI,
            sessions: ["abcd1234.Default (release)": [
                zenSpace("{1}", "Desk", container: 2), zenSpace("{2}", "Lab", container: 2),
            ]],
            containers: ["abcd1234.Default (release)": try containers(capturedContainers)])

        XCTAssertEqual(source.profiles.map(\.displayName),
                       ["Work", "Personal", "Banking", "Shopping", "AAAAAAAAA", "NOT USED"])
        XCTAssertEqual(rows(source).map { $0.spaces.map(\.name) },
                       [["Desk", "Lab"], [], [], [], [], []])
        XCTAssertEqual(rows(source).map(\.skipReason),
                       [nil, .noSpaces, .noSpaces, .noSpaces, .noSpaces, .noSpaces])
    }

    /// A Space set to a container the list no longer holds binds to the
    /// install default's no-container Profile and says so — and that Profile
    /// is listed for it even though no Space is set to none.
    func testASpaceSetToAMissingContainerBindsToTheInstallDefaultsNoContainerProfile() throws {
        let source = source(
            ghostINI,
            sessions: [realKey: [
                zenSpace("{1}", "Home", container: 1), zenSpace("{2}", "Gone", container: 9),
            ]],
            containers: [realKey: try containers(capturedContainers)])

        XCTAssertEqual(source.profiles.prefix(2).map(\.key), ["\(realKey)#0", "\(realKey)#1"])
        XCTAssertEqual(source.profiles.prefix(2).map(\.displayName), ["Zen", "Personal"])
        XCTAssertEqual(source.spaces.map(\.profileKey), ["\(realKey)#1", nil])
        XCTAssertEqual(source.defaultProfileKey, "\(realKey)#0")

        let rows = rows(source)
        XCTAssertEqual(rows[0].spaces.map(\.name), ["Gone"])
        XCTAssertEqual(rows[0].spaces.map(\.boundToDefaultProfile), [true])
        XCTAssertEqual(rows[1].spaces.map(\.name), ["Home"])
    }

    /// When the install's default profile is not usable, the binding host
    /// is the first usable one — so the bound Space still lands on a listed
    /// Profile rather than one the planner would have to invent.
    func testWhenTheInstallDefaultIsNotUsableAMissingContainerBindsToTheFirstUsableProfile() throws {
        let source = source("""
        [Profile0]
        Name=Ghost
        IsRelative=1
        Path=Profiles/gg.Ghost

        [Profile1]
        Name=Live
        IsRelative=1
        Path=Profiles/ll.Live

        [InstallABCD]
        Default=Profiles/gg.Ghost
        """, sessions: ["ll.Live": [zenSpace("{1}", "Gone", container: 9)]],
           containers: ["ll.Live": try containers(capturedContainers)])

        XCTAssertEqual(source.defaultProfileKey, "ll.Live#0")
        XCTAssertEqual(source.profiles.first?.key, "ll.Live#0")
        XCTAssertEqual(source.profiles.first?.displayName, "Zen")
        XCTAssertEqual(rows(source)[0].spaces.map(\.boundToDefaultProfile), [true])
    }

    /// A profile with no `containers.json` at all knows no container, so a
    /// Space set to one is the same missing-container case.
    func testWithoutAContainersFileEverySetContainerIsMissing() {
        let source = source(oneProfileINI, sessions: ["abcd1234.Default (release)": [
            zenSpace("{1}", "Home", container: 1),
        ]])

        XCTAssertEqual(source.profiles.map(\.key), ["abcd1234.Default (release)#0"])
        XCTAssertEqual(source.spaces.map(\.profileKey), [nil])
    }

    func testContainerNamesFollowTheirIdentities() throws {
        let defaults = try containers(capturedContainers).prefix(4).map(Zen.displayName(of:))

        XCTAssertEqual(defaults, ["Personal", "Work", "Banking", "Shopping"])
        XCTAssertEqual(Zen.displayName(of: .init(userContextId: 6, l10nId: nil, name: "AAAAAAAAA")), "AAAAAAAAA")
        XCTAssertEqual(Zen.displayName(of: .init(userContextId: 7, l10nId: "user-context-later", name: nil)), "Container 7")
        XCTAssertEqual(Zen.displayName(of: .init(userContextId: 8, l10nId: nil, name: "  ")), "Container 8")
    }

    /// Two usable Firefox profiles each derive their own container Profiles
    /// under their own names, with no prefixing: the "Personal" Profiles
    /// collide, and the planner's suffix tells the planned ones apart — an
    /// unused container's greyed row is not in the plan and keeps its plain
    /// name.
    func testTwoUsableFirefoxProfilesDeriveTheirOwnContainerProfiles() throws {
        let containers = Array(try containers(capturedContainers).prefix(2))
        let source = source(
            twoProfilesINI,
            sessions: [
                "aaaa0000.Work": [zenSpace("{1}", "Desk", container: 1)],
                "bbbb1111.Personal": [zenSpace("{2}", "Sofa", container: 1), zenSpace("{3}", "Loose")],
            ],
            containers: ["aaaa0000.Work": containers, "bbbb1111.Personal": containers])

        XCTAssertEqual(source.profiles.map(\.key), [
            "aaaa0000.Work#1", "aaaa0000.Work#2",
            "bbbb1111.Personal#0", "bbbb1111.Personal#1", "bbbb1111.Personal#2",
        ])
        XCTAssertEqual(source.profiles.map(\.displayName),
                       ["Personal", "Work", "Personal", "Personal", "Work"])
        XCTAssertEqual(rows(source).map(\.displayName),
                       ["Personal", "Work", "Personal 2", "Personal 3", "Work"])
    }

    /// The design machine's ghost — no session file, so no Spaces — is not
    /// listed: a Firefox profile is nothing the user chose in Zen. The sole
    /// usable profile's no-container Profile is named "Zen".
    func testASoleUsableProfileIsNamedZenAndTheGhostIsNotListed() {
        let source = source(ghostINI, sessions: [realKey: [zenSpace("{1}", "Home")]])

        XCTAssertEqual(source.profiles.map(\.key), ["\(realKey)#0"])
        XCTAssertEqual(source.profiles.map(\.displayName), ["Zen"])

        let rows = rows(source)
        XCTAssertEqual(rows.map(\.displayName), ["Zen"])
        XCTAssertEqual(rows.map(\.skipReason), [nil])
        XCTAssertEqual(rows[0].spaces.map(\.name), ["Home"])
    }

    /// An install whose profiles are all unusable offers nothing — the
    /// wizard's nothing-to-migrate state, not a list of greyed profiles.
    func testAnInstallWhoseProfilesAreAllUnusableHasNothingToMigrate() {
        let source = source(ghostINI, sessions: [:])

        XCTAssertTrue(source.profiles.isEmpty)
        XCTAssertTrue(BrowserMigrationPreview.hasNothingToMigrate(rows: rows(source)))
    }

    func testSeveralUsableProfilesKeepTheirProfilesININamesForTheNoContainerProfile() {
        let source = source(twoProfilesINI, sessions: [
            "aaaa0000.Work": [zenSpace("{1}", "Desk")],
            "bbbb1111.Personal": [zenSpace("{2}", "Sofa")],
        ])

        XCTAssertEqual(source.profiles.map(\.displayName), ["Work", "Personal"])
        XCTAssertEqual(source.profiles.map(\.sourceDirectory), ["aaaa0000.Work", "bbbb1111.Personal"])
    }

    /// A session file with no spaces in it is as unusable as none, so the
    /// other profile is still the sole usable one.
    func testAProfileWhoseSessionFileYieldsNoSpaceIsNotUsable() {
        let source = source(twoProfilesINI, sessions: [
            "aaaa0000.Work": [],
            "bbbb1111.Personal": [zenSpace("{2}", "Sofa")],
        ])

        XCTAssertEqual(source.profiles.map(\.key), ["bbbb1111.Personal#0"])
        XCTAssertEqual(source.profiles.map(\.displayName), ["Zen"])
    }

    /// An empty `profiles.ini` name falls back to the directory basename —
    /// here, in the builder, since the key no longer is the basename.
    func testAUsableProfileWithNoNamePreviewsAsItsBasename() {
        let source = source("""
        [Profile0]
        IsRelative=1
        Path=Profiles/abcd.nameless

        [Profile1]
        Name=Named
        IsRelative=1
        Path=Profiles/efgh.named
        """, sessions: [
            "abcd.nameless": [zenSpace("{1}", "A")],
            "efgh.named": [zenSpace("{2}", "B")],
        ])

        XCTAssertEqual(rows(source).map(\.displayName), ["abcd.nameless", "Named"])
    }

    func testSpacesFollowTheirProfileInFileOrderWithTheirColourAndIcon() {
        let source = source(twoProfilesINI, sessions: [
            "aaaa0000.Work": [
                zenSpace("{1}", "Desk", colorHex: "#fab528", icon: "chrome://browser/skin/zen-icons/selectable/airplane.svg"),
                zenSpace("{2}", "Lab"),
            ],
            "bbbb1111.Personal": [zenSpace("{3}", "Sofa", icon: "🤡")],
        ])

        XCTAssertEqual(source.spaces.map(\.id), ["{1}", "{2}", "{3}"])
        XCTAssertEqual(source.spaces.map(\.profileKey),
                       ["aaaa0000.Work#0", "aaaa0000.Work#0", "bbbb1111.Personal#0"])
        XCTAssertEqual(source.spaces.map(\.name), ["Desk", "Lab", "Sofa"])
        XCTAssertEqual(source.spaces.map(\.colorHex), ["#fab528", nil, nil])
        XCTAssertEqual(source.spaces.map(\.icon), [.zenNamed("airplane"), nil, .emoji("🤡")])
        XCTAssertEqual(source.spaces.map { $0.bookmarkRoot?.children.isEmpty }, [true, true, true])
        XCTAssertTrue(source.pinnedGroups.isEmpty)
    }

    // MARK: - Space Bookmarks from workspace pins

    /// Each Space's tree is its workspace's pins in file order — a folder
    /// sitting where its first pin does, nested as `folders[]` nests it —
    /// directly at the root, whatever container the pins carry. A folder
    /// holding only a placeholder is not written, nor is the pin naming a
    /// workspace that is not in the file; Essentials are not in any tree.
    /// A split view of two pins is one entry where the first of its pins
    /// sits — inside the folder the split is placed in, or at the root —
    /// never a folder; the grid of three falls back to its pins, in place.
    func testEachSpacesBookmarksAreItsWorkspacePinsWithTheirFolders() throws {
        let source = source(
            ghostINI, session: try session(capturedSession), under: realKey,
            containers: try containers(capturedContainers))

        XCTAssertEqual(source.spaces.map(\.name), ["Space", "TTT", "qqq", "abc"])
        XCTAssertEqual(source.spaces.map { $0.bookmarkRoot.map(outline) }, [
            ["zen basics[Welcome, Notes ⫽ Tasks]", "Welcome", "Video", "Docs ⫽ Chat", "Wiki", "OS"],
            [],
            ["Topic", "New Folder[Forum, Reading[Reading list]]", "Engine", "Alpha", "Beta", "Gamma"],
            ["OS (io)", "Current"],
        ])
    }

    func testABookmarkCarriesItsPinsURLAndAFolderNone() throws {
        let source = source(
            ghostINI, session: try session(capturedSession), under: realKey,
            containers: try containers(capturedContainers))
        let qqq = try XCTUnwrap(source.spaces[2].bookmarkRoot)

        XCTAssertEqual(qqq.title, "qqq")
        XCTAssertEqual(qqq.children.map(\.url), [
            "https://forum.example/topic/1/", nil, "https://engine.example/",
            "https://alpha.example/", "https://beta.example/", "https://gamma.example/",
        ])
        XCTAssertEqual(qqq.children[1].children[1].children.map(\.url),
                       ["https://forum.example/reading/"])
    }

    /// A chain of folders that loops — a shape Zen never writes — is cut
    /// where it comes back round rather than followed forever; the pin
    /// still sits inside its folders.
    func testAChainOfFoldersThatLoopsIsCutWhereItComesBackRound() throws {
        let session = try session("""
        { "spaces": [ { "uuid": "{1}", "name": "A" } ],
          "folders": [ { "id": "f1", "name": "Outer", "parentId": "f2" },
                       { "id": "f2", "name": "Inner", "parentId": "f1" } ],
          "tabs": [ { "pinned": true, "zenWorkspace": "{1}", "groupId": "f1",
                      "_zenPinnedInitialState": { "entry": { "url": "https://a.example/", "title": "A" } } } ] }
        """)
        let source = source(oneProfileINI, session: session, under: "abcd1234.Default (release)")

        XCTAssertEqual(source.spaces[0].bookmarkRoot.map(outline), ["Inner[Outer[A]]"])
    }

    /// A split view of two workspace pins is one Split Bookmark: the first
    /// pane's page on the row, the second riding on it, the divider read
    /// from the axis Zen names — `column` (stacked) is Phi's horizontal
    /// bar, `row` its vertical one. It sits where the first of the split's
    /// pins is in the file, which at the root of "Space" is the second
    /// pane's place ("Chat" is written before "Docs").
    func testATwoPaneSplitViewIsOneSplitBookmarkWhereItsFirstPinSits() throws {
        let source = source(
            ghostINI, session: try session(capturedSession), under: realKey,
            containers: try containers(capturedContainers))
        let space = try XCTUnwrap(source.spaces[0].bookmarkRoot)

        let atRoot = space.children[3]
        XCTAssertEqual(atRoot.title, "Docs")
        XCTAssertEqual(atRoot.url, "https://docs.example/")
        XCTAssertEqual(atRoot.split, ArcSplit(
            secondaryTitle: "Chat", secondaryURL: "https://chat.example/",
            layout: SplitLayout.horizontal.rawValue))
        XCTAssertFalse(atRoot.isFolder)
        XCTAssertTrue(atRoot.children.isEmpty)

        let inFolder = try XCTUnwrap(space.children[0].children.last)
        XCTAssertEqual(inFolder.url, "https://notes.example/")
        XCTAssertEqual(inFolder.split, ArcSplit(
            secondaryTitle: "Tasks", secondaryURL: "https://tasks.example/",
            layout: SplitLayout.vertical.rawValue))
    }

    /// One space with two pins, "A" then "B", in a split view at its root,
    /// laid out as given.
    private func splitSession(layoutTree: String) throws -> ZenDataParserTool.Session {
        try session("""
        { "spaces": [ { "uuid": "{1}", "name": "S" } ],
          "tabs": [
            { "pinned": true, "zenWorkspace": "{1}", "groupId": "s1", "zenSyncId": "t1",
              "_zenPinnedInitialState": { "entry": { "url": "https://a.example/", "title": "A" } } },
            { "pinned": true, "zenWorkspace": "{1}", "groupId": "s1", "zenSyncId": "t2",
              "_zenPinnedInitialState": { "entry": { "url": "https://b.example/", "title": "B" } } } ],
          "splitViewData": [ { "groupId": "s1", "layoutTree": \(layoutTree) } ] }
        """)
    }

    private func twoLeaves(_ direction: String, _ first: String = "t1", _ second: String = "t2") -> String {
        #"""
        { "type": "splitter", "direction": "\#(direction)", "children": [
            { "type": "leaf", "tabId": "\#(first)" }, { "type": "leaf", "tabId": "\#(second)" } ] }
        """#
    }

    private func spaceOutline(_ session: ZenDataParserTool.Session) -> [String] {
        source(oneProfileINI, session: session, under: "abcd1234.Default (release)")
            .spaces[0].bookmarkRoot.map(outline) ?? []
    }

    /// Zen's `direction` names the axis the panes run along; Phi names the
    /// divider. `row` (side by side) is Phi's vertical bar, `column`
    /// (stacked) its horizontal one, and a direction Phi does not know
    /// leaves the default.
    func testAZenDirectionBecomesPhisDividerLayout() throws {
        func split(_ direction: String) throws -> ArcSplit? {
            source(oneProfileINI, session: try splitSession(layoutTree: twoLeaves(direction)),
                   under: "abcd1234.Default (release)")
                .spaces[0].bookmarkRoot?.children.first?.split
        }

        XCTAssertEqual(try split("row")?.layout, SplitLayout.vertical.rawValue)
        XCTAssertEqual(try split("column")?.layout, SplitLayout.horizontal.rawValue)
        XCTAssertEqual(try split("diagonal"), ArcSplit(
            secondaryTitle: "B", secondaryURL: "https://b.example/", layout: nil))
    }

    /// A pane whose tab is not a pin of the Space — here one the file does
    /// not hold — leaves nothing to pair, and so does a layout naming one
    /// of the pins twice: the split's pins land plain, in place.
    func testASplitWhosePanesAreNotItsTwoPinsFallsBackToItsPins() throws {
        XCTAssertEqual(spaceOutline(try splitSession(layoutTree: twoLeaves("row", "t1", "t9"))), ["A", "B"])
        XCTAssertEqual(spaceOutline(try splitSession(layoutTree: twoLeaves("row", "t1", "t1"))), ["A", "B"])
    }

    /// A `splitViewGroup` record with no `splitViewData[]` entry is a split
    /// with no panes: its pins land plain, in the folder the record names —
    /// never in a folder of the split's own.
    func testASplitViewGroupRecordWithoutALayoutLandsItsPinsPlainInItsFolder() throws {
        let session = try session("""
        { "spaces": [ { "uuid": "{1}", "name": "S" } ],
          "folders": [ { "id": "f1", "name": "Folder" },
                       { "id": "s1", "name": "", "parentId": "f1", "splitViewGroup": true } ],
          "tabs": [
            { "pinned": true, "zenWorkspace": "{1}", "groupId": "f1", "zenSyncId": "t0",
              "_zenPinnedInitialState": { "entry": { "url": "https://x.example/", "title": "X" } } },
            { "pinned": true, "zenWorkspace": "{1}", "groupId": "s1", "zenSyncId": "t1",
              "_zenPinnedInitialState": { "entry": { "url": "https://a.example/", "title": "A" } } },
            { "pinned": true, "zenWorkspace": "{1}", "groupId": "s1", "zenSyncId": "t2",
              "_zenPinnedInitialState": { "entry": { "url": "https://b.example/", "title": "B" } } } ] }
        """)

        XCTAssertEqual(spaceOutline(session), ["Folder[X, A, B]"])
    }

    /// Zen never puts an Essential in a split view; should a layout name
    /// one, the Essential is not a pin of the Space, so the workspace pin
    /// beside it lands plain and the Essential stays its container
    /// Profile's pinned entry.
    func testAnEssentialNamedByASplitsLayoutStaysAPinnedEntry() throws {
        let session = try session("""
        { "spaces": [ { "uuid": "{1}", "name": "S" } ],
          "tabs": [
            { "pinned": true, "zenWorkspace": "{1}", "groupId": "s1", "zenSyncId": "t1",
              "_zenPinnedInitialState": { "entry": { "url": "https://a.example/", "title": "A" } } },
            { "pinned": true, "zenEssential": true, "zenWorkspace": "{1}", "groupId": "s1", "zenSyncId": "t2",
              "_zenPinnedInitialState": { "entry": { "url": "https://e.example/", "title": "E" } } } ],
          "splitViewData": [ { "groupId": "s1", "layoutTree": \(twoLeaves("row")) } ] }
        """)
        let source = source(oneProfileINI, session: session, under: "abcd1234.Default (release)")

        XCTAssertEqual(source.spaces[0].bookmarkRoot.map(outline), ["A"])
        XCTAssertEqual(source.pinnedGroups.map { $0.entries.map(\.title) }, [["E"]])
    }

    // MARK: - Pinned tabs from Essentials

    /// An Essential is a pinned entry of the Profile of its own container,
    /// in file order: the one in no container goes to "Zen", the one in
    /// Personal to "Personal", and the one in Work — a container no Space is
    /// set to — to Work's greyed row, which the planner creates nothing for.
    func testEssentialsBecomeTheirContainersProfilesPinnedEntries() throws {
        let source = source(
            ghostINI, session: try session(capturedSession), under: realKey,
            containers: try containers(capturedContainers))

        XCTAssertEqual(source.pinnedGroups.map(\.profileKey),
                       ["\(realKey)#0", "\(realKey)#1", "\(realKey)#2"])
        XCTAssertEqual(source.pinnedGroups.map { $0.entries.map(\.title) },
                       [["Search"], ["Social"], ["Mail"]])
        XCTAssertEqual(source.pinnedGroups[0].entries.map(\.url), ["https://search.example/"])

        let plan = plan(source)
        XCTAssertEqual(plan.profiles.map(\.displayName), ["Zen", "AAAAAAAAA", "Banking", "Personal"])
        XCTAssertEqual(plan.profiles.map { $0.pinnedTabs.map(\.title) },
                       [["Search"], [], [], ["Social"]])
        XCTAssertEqual(plan.skippedProfiles.map(\.displayName), ["Work", "Shopping", "NOT USED"])
        XCTAssertEqual(plan.skippedProfiles.map(\.droppedPinnedEntries), [1, 0, 0])
    }

    /// With every Space set to a container, the no-container Profile is
    /// still listed when there are Essentials in no container — greyed,
    /// having no Spaces, and after the containers in use like the other
    /// greyed rows — so that they are dropped where the plan counts them
    /// rather than lost in silence.
    func testEssentialsInNoContainerListTheNoContainerProfileWhenNoSpaceIsSetToNone() throws {
        let key = "abcd1234.Default (release)"
        let source = source(
            oneProfileINI,
            session: ZenDataParserTool.Session(
                spaces: [zenSpace("{1}", "Desk", container: 2)],
                pinnedTabs: [essential(container: 0, "Search", "https://search.example/")]),
            under: key,
            containers: try containers(capturedContainers))

        XCTAssertEqual(source.profiles.map(\.displayName),
                       ["Work", "Zen", "Personal", "Banking", "Shopping", "AAAAAAAAA", "NOT USED"])
        XCTAssertEqual(source.pinnedGroups.map(\.profileKey), ["\(key)#0"])
        XCTAssertEqual(rows(source).map(\.skipReason).prefix(2), [nil, .noSpaces])
        XCTAssertEqual(plan(source).skippedProfiles.first?.droppedPinnedEntries, 1)
    }

    /// An Essential in a container the list does not hold has no resolvable
    /// profile record and, like a Space set to one, follows the default
    /// Profile: it lands there when that Profile has Spaces, and is counted
    /// on its greyed row when it has none.
    func testAnEssentialInAContainerTheListDoesNotHoldFollowsTheDefaultProfile() throws {
        let key = "abcd1234.Default (release)"
        let gone = essential(container: 9, "Gone", "https://gone.example/")
        let landed = source(
            oneProfileINI,
            session: ZenDataParserTool.Session(spaces: [zenSpace("{1}", "Home")], pinnedTabs: [gone]),
            under: key, containers: try containers(capturedContainers))
        let counted = source(
            oneProfileINI,
            session: ZenDataParserTool.Session(spaces: [zenSpace("{1}", "Desk", container: 1)], pinnedTabs: [gone]),
            under: key, containers: try containers(capturedContainers))

        XCTAssertEqual(landed.pinnedGroups.map(\.profileKey), [nil])
        XCTAssertEqual(plan(landed).profiles.map { $0.pinnedTabs.map(\.title) }, [["Gone"]])

        XCTAssertEqual(counted.profiles.prefix(2).map(\.displayName), ["Personal", "Zen"])
        XCTAssertEqual(plan(counted).skippedProfiles.first?.displayName, "Zen")
        XCTAssertEqual(plan(counted).skippedProfiles.first?.droppedPinnedEntries, 1)
        XCTAssertFalse(landed.profiles.contains { $0.key == "\(key)#9" })
    }

    func testTheIconAdapterNamesABuiltInByItsFileAndKeepsAnEmojiAsItself() {
        let adapt = Zen.sourceIcon

        XCTAssertEqual(adapt("chrome://browser/skin/zen-icons/selectable/american-football.svg"),
                       .zenNamed("american-football"))
        XCTAssertEqual(adapt("🤡"), .emoji("🤡"))
        XCTAssertNil(adapt(nil))
        XCTAssertNil(adapt(""))
    }

    func testAnInstallWithNoProfilesHasNothingToMigrate() {
        let source = source("", sessions: [:])

        XCTAssertTrue(source.profiles.isEmpty)
        XCTAssertTrue(source.spaces.isEmpty)
        XCTAssertTrue(BrowserMigrationPreview.hasNothingToMigrate(rows: rows(source)))
    }
}
