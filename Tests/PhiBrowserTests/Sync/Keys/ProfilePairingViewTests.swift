import XCTest
@testable import Phi

/// Devices pane（`ProfilePairingView` 的 `.settings` 上下文）的回归网（§10.7 第 5 条）。
/// M3-2b 对这条路只做了两处结构性改动，两处都声称「结果等价」——这里把那句声称变成
/// 断言。
///
/// `@MainActor`：`ProfilePairingSelectionStore` 是 `@MainActor`，`ProfilePairingView` /
/// `RowChrome` 是 SwiftUI 类型（与 `ProfilePairingGateTests` 同款标注）。
@MainActor
final class ProfilePairingViewTests: XCTestCase {

    private let home = RemoteProfile(uuid: "R1", name: "Home")
    private let work = RemoteProfile(uuid: "R2", name: "Work")

    /// 1. 状态上提之后，`.settings` 那条路喂给 `ProfilePairingModel` 的输入与它算出的
    ///    `decisions()` **逐字不变**。种子仍然是 `initialSelections`——Task 7 只是把它
    ///    从 `init` 里的 `State(initialValue:)` 搬到了 `ProfilePairingSelectionStore.seed`。
    func testTheSettingsPathStillSeedsAndDecidesExactlyAsBefore() {
        let locals = [PairingLocal(profileId: "Default", displayName: "Home"),
                      PairingLocal(profileId: "P2", displayName: "Nothing matches")]
        let remotes = [home, work]

        let store = ProfilePairingSelectionStore()
        store.seed(locals: locals, remotes: remotes)
        XCTAssertEqual(store.selections,
                       ProfilePairingModel.initialSelections(locals: locals, remotes: remotes),
                       "壳的种子必须与今天 init 里那一句是同一句")
        XCTAssertEqual(store.remoteChoices, [:])

        let model = ProfilePairingModel(locals: locals, remotes: remotes,
                                        selections: store.selections,
                                        remoteChoices: store.remoteChoices)
        XCTAssertEqual(model.decisions(),
                       [.adopt(localProfileId: "Default", remoteUuid: "R1"),
                        .registerNew(localProfileId: "P2", displayName: "Nothing matches")])
    }

    /// 2. Devices pane 的三条**按上下文分叉过**的文案（§6.8 把它们钉成「一字不动」）。
    ///    §6.8 那张表里另外三条（`Register as new` / `Unclaimed account profiles` /
    ///    `Unnamed profile (%@)`）两个上下文共用、本里程碑一个字节没碰，也没有第二个
    ///    分支可走岔，所以不在这里重复断言。
    func testTheDevicesPaneCopyIsUnchanged() {
        XCTAssertEqual(ProfilePairingView.settingsTitle, "Match your profiles")
        XCTAssertEqual(ProfilePairingView.settingsPrimaryTitle, "Confirm")
        XCTAssertEqual(ProfilePairingView.settingsBody,
                       "We found profiles on this Mac and on your account that we couldn’t "
                       + "match automatically. Pick which account profile each local profile "
                       + "belongs to.")
        // `.gate` 的三条对应文案在 Step 5(a) 里整支消失，所以这三条**没有**第二个分支
        // 可以走岔——这一条同时是「`.gate` 分支真的被删干净了」的回归。
    }

    /// 3. `RowChrome(context: .settings)` 与今天那两句等价（§10.7 第 5 条要求「用一条
    ///    显式断言钉住，而不是靠肉眼看 diff」）。`.legacyTextBackground` 这个 case 的
    ///    文档注释里写着它的两句是什么，改掉哪一句都要先改这条断言。
    func testTheSettingsRowChromeIsStillTodaysTwoModifiers() {
        XCTAssertEqual(RowChrome.kind(for: .settings), .legacyTextBackground)
        XCTAssertEqual(RowChrome.kind(for: .gate), .wizardCard,
                       "分叉必须真的分叉——两支同值就是白改一场")
    }
}
