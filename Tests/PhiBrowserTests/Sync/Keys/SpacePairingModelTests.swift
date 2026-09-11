import XCTest
@testable import Phi

/// 第 2 步的决定核与 D7 的覆盖差异。对照 `ProfilePairingModelTests`：每一条都是
/// 安全性质，不是渲染细节——一个账户 Space 被两行认领会在账户里焊死两个本机 Space，
/// 而一条假差异会让确认页对用户说一件不会发生的事。
final class SpacePairingModelTests: XCTestCase {

    private func local(_ id: String, name: String = "Work", profile: String = "Default",
                       icon: String = "phi:a", color: String = "#3AA4D5",
                       themeId: String? = nil,
                       light: Double? = nil, dark: Double? = nil) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: profile, name: name, colorHex: color,
                      iconName: icon, sortOrder: 0,
                      createdDate: Date(timeIntervalSince1970: 1),
                      themeId: themeId, opacityLight: light, opacityDark: dark)
    }

    private func account(_ uuid: String, name: String = "Work", icon: String = "phi:a",
                         color: String = "#3AA4D5", profileUuid: String = "uuid-a",
                         themeId: String = "", light: Int64 = -1,
                         dark: Int64 = -1) -> PhiAccountSpaceSummary {
        PhiAccountSpaceSummary(syncUuid: uuid, name: name, iconName: icon, colorHex: color,
                               profileUuid: profileUuid, isDefault: false, themeId: themeId,
                               overlayOpacityLightMilli: light, overlayOpacityDarkMilli: dark)
    }

    private func model(locals: [PhiLocalSpace], accounts: [PhiAccountSpaceSummary],
                       selections: [String: SpacePairingModel.Assignment] = [:])
        -> SpacePairingModel {
        SpacePairingModel(
            input: .init(locals: locals, accountSpaces: accounts,
                         localProfileNames: ["Default": "Personal"],
                         accountProfileNames: ["uuid-a": "Home"]),
            selections: selections)
    }

    // MARK: - 1. 一个账户 Space 至多被一行认领

    func testAnAccountSpaceLeavesTheOtherRowsListsButStaysInItsOwn() {
        let a = local("A"), b = local("B", name: "Reading")
        let m = model(locals: [a, b], accounts: [account("acct-1"), account("acct-2", name: "R")],
                      selections: ["A": .existing(syncUuid: "acct-1")])
        XCTAssertEqual(m.assignableAccountSpaces(for: b).map(\.syncUuid), ["acct-2"])
        XCTAssertEqual(m.assignableAccountSpaces(for: a).map(\.syncUuid), ["acct-1", "acct-2"],
                       "自己那条永远留在自己的列表里，否则 Picker 的 selected tag 缺失会渲染成空白")
    }

    // MARK: - 2. 过期的选择读回「未决定」

    func testAStaleSelectionReadsBackAsUndecided() {
        let a = local("A")
        let m = model(locals: [a], accounts: [],   // 账户列表变了，acct-1 没了
                      selections: ["A": .existing(syncUuid: "acct-1")])
        XCTAssertNil(m.assignment(for: a))
        XCTAssertFalse(m.allRowsDecided)
        XCTAssertTrue(m.decisions().isEmpty, "显示为空白的行不产出决定")
    }

    // MARK: - 3. 「Add all as new」是快捷方式，不是重置

    func testAddAllAsNewOnlyFillsTheUndecidedRows() {
        let a = local("A"), b = local("B", name: "Reading"), c = local("C", name: "Notes")
        let m = model(locals: [a, b, c], accounts: [account("acct-1")],
                      selections: ["A": .existing(syncUuid: "acct-1")])
        let after = m.addAllAsNew()
        XCTAssertEqual(after["A"], .existing(syncUuid: "acct-1"), "已决定的行不动")
        XCTAssertEqual(after["B"], .addAsNew)
        XCTAssertEqual(after["C"], .addAsNew)
    }

    // MARK: - 4/5. 默认 Space 与 decisions()

    func testTheDefaultSpaceIsNeitherARowNorADecision() {
        let def = local(LocalStore.defaultSpaceId, name: "Default")
        let a = local("A")
        let m = model(locals: [def, a], accounts: [account("acct-1")],
                      selections: ["A": .addAsNew,
                                   LocalStore.defaultSpaceId: .existing(syncUuid: "acct-1")])
        XCTAssertEqual(m.rows.map(\.spaceId), ["A"])
        XCTAssertEqual(m.defaultRow?.spaceId, LocalStore.defaultSpaceId)
        XCTAssertTrue(m.allRowsDecided, "默认 Space 不计入")
        XCTAssertEqual(m.decisions().map(\.localSpaceId), ["A"])
    }

    func testDecisionsNeverPointTwoRowsAtOneAccountSpace() {
        let a = local("A"), b = local("B", name: "Reading")
        let m = model(locals: [a, b], accounts: [account("acct-1")],
                      selections: ["A": .existing(syncUuid: "acct-1"),
                                   "B": .existing(syncUuid: "acct-1")])
        let claimed = m.decisions().compactMap { decision -> String? in
            if case .existing(let uuid) = decision.assignment { return uuid }
            return nil
        }
        XCTAssertEqual(Set(claimed).count, claimed.count,
                       "第二行的选择已经不在它的可选列表里，读回未决定")
    }

    // MARK: - 6. 空账户

    func testAnEmptyAccountIsDecidableInOneClick() {
        let a = local("A"), b = local("B", name: "Reading")
        let m = model(locals: [a, b], accounts: [])
        XCTAssertTrue(m.assignableAccountSpaces(for: a).isEmpty)
        XCTAssertFalse(m.allRowsDecided)
        let after = m.addAllAsNew()
        XCTAssertTrue(model(locals: [a, b], accounts: [], selections: after).allRowsDecided)
    }

    // MARK: - 7. 左列的口径（§5.4 那条注释的可执行版本）

    /// fixture 里放一个 profile **没有映射**的本地 Space（`pairableSpaces()` 会给出、
    /// `currentSpaces()` 不会）。把左列接到 `currentSpaces()` 上就会让这条用例红。
    func testARowSurvivesEvenWhenItsProfileHasNoMappingYet() {
        let unmapped = local("A", name: "Work", profile: "Profile 7")
        let m = model(locals: [unmapped], accounts: [])
        XCTAssertEqual(m.rows.map(\.spaceId), ["A"])
        XCTAssertNil(m.profileName(for: unmapped), "名字解析不出来不影响它是一行")
    }

    // MARK: - D7：SpaceOverwriteDiff（§5.7）

    private func diffs(_ selections: [String: SpacePairingModel.Assignment],
                       locals: [PhiLocalSpace],
                       accounts: [PhiAccountSpaceSummary],
                       themes: [String: String] = ["pure": "Pure", "coral": "Coral"])
        -> [SpaceOverwriteDiff] {
        let m = model(locals: locals, accounts: accounts, selections: selections)
        return SpaceOverwriteDiff.diffs(decisions: m.decisions(), locals: locals,
                                        accountSpaces: accounts,
                                        themeDisplayName: { themes[$0] })
    }

    // 8
    func testSixEqualFieldsProduceNoDiff() {
        let out = diffs(["A": .existing(syncUuid: "acct-1")],
                        locals: [local("A", themeId: nil, light: nil, dark: nil)],
                        accounts: [account("acct-1", themeId: "", light: -1, dark: -1)])
        XCTAssertTrue(out.isEmpty)
    }

    // 9
    func testOneDifferingFieldListsOnlyThatField() throws {
        let out = diffs(["A": .existing(syncUuid: "acct-1")],
                        locals: [local("A", name: "Job")],
                        accounts: [account("acct-1", name: "Work")])
        let diff = try XCTUnwrap(out.first)
        XCTAssertEqual(diff.spaceName, "Job", "节标题是**本机**这一行的名称")
        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.changes[0].field, .name)
        XCTAssertEqual(diff.changes[0].local, .text("Job"))
        XCTAssertEqual(diff.changes[0].account, .text("Work"))
    }

    // 10
    func testThemeDefaultsAreNormalizedAndNamedThroughTheResolver() throws {
        let pinned = diffs(["A": .existing(syncUuid: "acct-1")],
                           locals: [local("A", themeId: nil)],
                           accounts: [account("acct-1", themeId: "pure")])
        XCTAssertEqual(pinned.first?.changes.first?.local, .defaultValue)
        XCTAssertEqual(pinned.first?.changes.first?.account, .text("Pure"))

        let unknown = diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", themeId: nil)],
                            accounts: [account("acct-1", themeId: "moss")])
        XCTAssertEqual(unknown.first?.changes.first?.account, .text("moss"),
                       "解析不出显示名就用 id 本身")

        // `""` 与 `"default"` 都是「无 pin」：这条同时钉住「界面上不可能出现
        // `Theme: No custom value → No custom value`」。
        let sentinel = diffs(["A": .existing(syncUuid: "acct-1")],
                             locals: [local("A", themeId: nil)],
                             accounts: [account("acct-1", themeId: "default")])
        XCTAssertTrue(sentinel.isEmpty)
    }

    // 11
    func testOpacityIsComparedInMilliUnitsAndNegativesAreAllCleared() throws {
        // 浮点往返不造假差异。
        XCTAssertTrue(diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", light: 0.85)],
                            accounts: [account("acct-1", light: 850)]).isEmpty)

        let cleared = diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", light: 0.85)],
                            accounts: [account("acct-1", light: -1)])
        XCTAssertEqual(cleared.first?.changes.first?.local, .percent(milliUnits: 850))
        XCTAssertEqual(cleared.first?.changes.first?.account, .defaultValue)

        let gained = diffs(["A": .existing(syncUuid: "acct-1")],
                           locals: [local("A", dark: nil)],
                           accounts: [account("acct-1", dark: 700)])
        XCTAssertEqual(gained.first?.changes.first?.field, .opacityDark)
        XCTAssertEqual(gained.first?.changes.first?.local, .defaultValue)
        XCTAssertEqual(gained.first?.changes.first?.account, .percent(milliUnits: 700))

        // 连续滑杆造出的一对：`Int(milli / 10)` 会把它压成 `45% → 45%`。
        let slider = diffs(["A": .existing(syncUuid: "acct-1")],
                           locals: [local("A", light: 0.4489)],
                           accounts: [account("acct-1", light: 451)])
        XCTAssertEqual(slider.first?.changes.first?.local, .percent(milliUnits: 449))
        XCTAssertEqual(slider.first?.changes.first?.account, .percent(milliUnits: 451))

        // 负数哨兵不止 -1：落地那侧 `opacity(_:)` 判的是 `< 0`。
        XCTAssertTrue(diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", light: nil)],
                            accounts: [account("acct-1", light: -5)]).isEmpty)
    }

    // 12（D7 的「顺序除外」，不是 §7）
    func testRankAndSortOrderAreNotPartOfTheOverwriteDiffPerD7() {
        var localRow = local("A")
        localRow.sortOrder = 9
        XCTAssertTrue(diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [localRow], accounts: [account("acct-1")]).isEmpty)
    }

    // 13
    func testOnlyExistingDecisionsProduceDiffs() {
        let out = diffs(["A": .addAsNew],
                        locals: [local("A", name: "Totally different", color: "#000000")],
                        accounts: [account("acct-1")])
        XCTAssertTrue(out.isEmpty, "`.addAsNew` 不覆盖任何东西")
    }

    // 14
    func testFieldOrderIsDeclarationOrderAndSectionOrderFollowsTheDecisions() throws {
        let locals = [local("A", name: "n", icon: "phi:z", color: "#AAAAAA",
                            themeId: "coral", light: 0.5, dark: 0.5),
                      local("B", name: "m")]
        let accounts = [account("acct-2", name: "N", icon: "phi:y", color: "#BBBBBB",
                                themeId: "pure", light: 600, dark: 600),
                        account("acct-1", name: "M")]
        let out = diffs(["A": .existing(syncUuid: "acct-2"), "B": .existing(syncUuid: "acct-1")],
                        locals: locals, accounts: accounts)
        XCTAssertEqual(out.map(\.localSpaceId), ["A", "B"], "节的顺序 = decisions() 的顺序")
        XCTAssertEqual(out[0].changes.map(\.field),
                       [.name, .icon, .color, .theme, .opacityLight, .opacityDark])
    }

    // 15（不是笔误：Swift 的 `String ==` 区分大小写，而 `land` 用的就是这个运算符）
    func testColorHexCaseIsARealDifferenceBecauseLandUsesTheSameOperator() {
        let out = diffs(["A": .existing(syncUuid: "acct-1")],
                        locals: [local("A", color: "#AABBCC")],
                        accounts: [account("acct-1", color: "#aabbcc")])
        XCTAssertEqual(out.first?.changes.map(\.field), [.color])
    }

    // 16
    func testUnresolvableRowsAreSkippedRatherThanTrapping() {
        let out = SpaceOverwriteDiff.diffs(
            decisions: [(localSpaceId: "A", assignment: .existing(syncUuid: "ghost")),
                        (localSpaceId: "GONE", assignment: .existing(syncUuid: "acct-1")),
                        (localSpaceId: "B", assignment: .existing(syncUuid: "acct-1"))],
            locals: [local("A"), local("B", name: "Renamed")],
            accountSpaces: [account("acct-1")],
            themeDisplayName: { _ in nil })
        XCTAssertEqual(out.map(\.localSpaceId), ["B"],
                       "解析不到的行跳过、不 trap、不影响其余行")
    }
}
