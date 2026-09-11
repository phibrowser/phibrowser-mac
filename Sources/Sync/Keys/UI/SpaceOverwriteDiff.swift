// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// D7 / R-D7-1：「把本机 Space X 对应到账户 Space Y」这一行，首次同步会把哪些本地
/// 字段换成账户的值（§5.7）。**无 SwiftUI、无网络、无单例**——`themeDisplayName` 是
/// 注入的 resolver，所以这整个类型可以在测试里当纯函数跑。
///
/// **比较用的值 vs 显示用的值是两件事。** 比较一律在**线上编码**上做，因为首次同步
/// 真正会被换掉的就是那一份线上编码的值：只要 snapshot / land 那条路上会覆盖，确认页
/// 就必须列出来；只要不会，就不能列——一条「显示上不同、实际不会变」的假差异比不列
/// 出更糟。三个串字段用 **Swift `String ==`**，与 `land` 里那三句朴素比较是同一个
/// 运算符（SyncableSpaces.swift 的 update 分支），所以 NFC/NFD 两种写法不会造出假
/// 差异，而大小写与空格敏感这两条一个都不丢。
///
/// **字段集是产品裁定的，封闭在六个**：`rank`（顺序是两台机器上同一次重排的两个投影，
/// 不是一次字段覆盖）、`profile_uuid`（在**选择的时刻**就摆在用户眼前——第 2 步 Picker
/// 的每个账户选项括号里正是它的 Profile）与 `created_at_ms`（用户无从判断，它唯一的
/// 投影是 `getAllSpaces()` 排序的最后一级 tiebreak）都不比。加第七个字段要用户另行裁定。
struct SpaceOverwriteDiff: Equatable, Identifiable {
    enum Field: Equatable, CaseIterable {
        case name, icon, color, theme, opacityLight, opacityDark
    }

    /// 一侧的值，**语义而不是字符串**：本地化模板留在视图里（§6.9），所以测试断言的是
    /// `.defaultValue` / `.percent(milliUnits: 850)`，不是一句会被翻译改掉的 `"85%"`。
    enum Value: Equatable {
        /// 原样上屏的串：名称、颜色 hex、主题的显示名。空串由视图渲染成 `—`。
        case text(String)
        /// Space 图标的 storedValue，由 `SpaceIconView` 画成图形。
        case icon(String)
        /// 「这一侧没有自己的值」：没有 pin 主题 / 没有自定义透明度。视图渲染成本地化
        /// 的 `No custom value`（**不是** `Default`）。
        case defaultValue
        /// **千分单位原样带上来**（`850` ⇒ `.percent(milliUnits: 850)`）。渲染精度是
        /// 视图的事：遮罩透明度的滑杆是连续的，`Int(milli / 10)` 这种预先截断会把两个
        /// 确实会被覆盖的值压成同一个词。
        case percent(milliUnits: Int64)
    }

    struct Change: Equatable {
        let field: Field
        let local: Value
        let account: Value
    }

    let localSpaceId: String
    /// 分节标题 = **本机**这一行当前的名称（用户刚刚点选的那一行）。名称本身有差异时
    /// 它照样出现在第一条 `Change` 里。
    let spaceName: String
    let spaceIconName: String
    /// 非空（空差异的 Space 不产出 `SpaceOverwriteDiff`）。顺序恒为 `Field.allCases`
    /// 的声明序，与选择顺序、字典遍历顺序全都无关。
    let changes: [Change]

    var id: String { localSpaceId }

    /// 唯一入口。`decisions` 里只有 `.existing(syncUuid:)` 的行参与；`.addAsNew` 不
    /// 覆盖任何东西，默认 Space 根本不是一行。结果按 `decisions` 的顺序排列。
    ///
    /// 解析不到对应 `PhiAccountSpaceSummary` 或对应 `PhiLocalSpace` 的行**跳过**：
    /// 不产出、不崩溃、也不影响其余行。按 §5.4 的第三条不变量这在向导里不可达，但这是
    /// 一个 internal 纯函数、测试可以直接喂它任意入参，而它挂在一个 App 级阻断模态的
    /// 提交按钮上：**绝不写 `accountSpaces.first { … }!` 这种强解包**。
    static func diffs(decisions: [(localSpaceId: String, assignment: SpacePairingModel.Assignment)],
                      locals: [PhiLocalSpace],
                      accountSpaces: [PhiAccountSpaceSummary],
                      themeDisplayName: (String) -> String?) -> [SpaceOverwriteDiff] {
        var out: [SpaceOverwriteDiff] = []
        for decision in decisions {
            guard case .existing(let syncUuid) = decision.assignment,
                  let local = locals.first(where: { $0.spaceId == decision.localSpaceId }),
                  let account = accountSpaces.first(where: { $0.syncUuid == syncUuid })
            else { continue }
            let changes = Field.allCases.compactMap {
                change($0, local: local, account: account, themeDisplayName: themeDisplayName)
            }
            guard !changes.isEmpty else { continue }
            out.append(SpaceOverwriteDiff(localSpaceId: local.spaceId,
                                          spaceName: local.name,
                                          spaceIconName: local.iconName,
                                          changes: changes))
        }
        return out
    }

    private static func change(_ field: Field,
                               local: PhiLocalSpace,
                               account: PhiAccountSpaceSummary,
                               themeDisplayName: (String) -> String?) -> Change? {
        switch field {
        case .name:
            guard local.name != account.name else { return nil }
            return Change(field: field, local: .text(local.name), account: .text(account.name))
        case .icon:
            guard local.iconName != account.iconName else { return nil }
            return Change(field: field, local: .icon(local.iconName), account: .icon(account.iconName))
        case .color:
            guard local.colorHex != account.colorHex else { return nil }
            return Change(field: field, local: .text(local.colorHex), account: .text(account.colorHex))
        case .theme:
            let localTheme = normalizedThemeId(local.themeId ?? "")
            let accountTheme = normalizedThemeId(account.themeId)
            guard localTheme != accountTheme else { return nil }
            return Change(field: field,
                          local: themeValue(localTheme, themeDisplayName),
                          account: themeValue(accountTheme, themeDisplayName))
        case .opacityLight:
            return opacityChange(field,
                                 local: SyncableSpaces.opacityMilliUnits(local.opacityLight),
                                 account: account.overlayOpacityLightMilli)
        case .opacityDark:
            return opacityChange(field,
                                 local: SyncableSpaces.opacityMilliUnits(local.opacityDark),
                                 account: account.overlayOpacityDarkMilli)
        }
    }

    /// 「无 pin」在本仓库里是空串；把 `"default"` 一起归进去是一次**刻意的选择**，
    /// 不是同义反复：没有任何一条 per-Space pin 会被写成 `"default"`（写进 pin map 的
    /// 一律是注册表里的 id），但 `"default"` 在本仓库里确实是一个活的哨兵值，含义是
    /// `Theme.default`（`ThemeManager` 启动时把读到的 `"default"` 翻成
    /// `Theme.default.id`，M3-1 的设置读取器在全局主题缺省时也写 `?? "default"`）。
    /// 归进来是为了让一个把它塞进 `theme_id` 的对端**不可能**产出
    /// `Theme: No custom value → No custom value` 这种两侧同词的输出。
    /// **所以这一条必须写死，否则后来的读者会把它「修正」成 `.text("Pure")`。**
    private static func normalizedThemeId(_ id: String) -> String {
        (id.isEmpty || id == "default") ? "" : id
    }

    private static func themeValue(_ id: String,
                                   _ themeDisplayName: (String) -> String?) -> Value {
        id.isEmpty ? .defaultValue : .text(themeDisplayName(id) ?? id)
    }

    /// **「无自定义」的判据是 `milli < 0`，不是 `milli == -1`**：真正落地那一侧的
    /// `SyncableSpaces.opacity(_:)` 写的是 `value.intValue < 0 ? nil : …`，任何负数
    /// 都被它当成「清掉自定义透明度」。`-1` 只是本 build 发出去的那个值，不是协议保证。
    private static func opacityChange(_ field: Field, local: Int64, account: Int64) -> Change? {
        let localCleared = local < 0
        let accountCleared = account < 0
        if localCleared, accountCleared { return nil }
        if !localCleared, !accountCleared, local == account { return nil }
        return Change(field: field,
                      local: localCleared ? .defaultValue : .percent(milliUnits: local),
                      account: accountCleared ? .defaultValue : .percent(milliUnits: account))
    }
}
