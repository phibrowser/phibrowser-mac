// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// D7 / R-D7-1: fields first sync would overwrite when local Space X maps to account Space Y (§5.7). Pure
/// logic without SwiftUI, networking or singletons; themeDisplayName is injected.
///
/// Compare wire-encoded values, not display text, to list exactly the fields snapshot/landing would change.
/// Three string fields use Swift String equality, matching SyncableSpaces landing: NFC/NFD equivalence avoids
/// false differences while preserving case/space sensitivity.
///
/// Product scope is exactly six fields. Exclude rank (two projections of a shared reorder), profile_uuid
/// (shown in Picker choices), and created_at_ms (only a final getAllSpaces sorting tie-break users cannot
/// assess). Adding a seventh requires a separate product decision.
struct SpaceOverwriteDiff: Equatable, Identifiable {
    enum Field: Equatable, CaseIterable {
        case name, icon, color, theme, opacityLight, opacityDark
    }

    /// Semantic values rather than localized strings: views own templates (§6.9), so tests assert
    /// defaultValue/percent(milliUnits: 850), independent of translated display text.
    enum Value: Equatable {
        /// Literal name, color hex or theme display name; the view renders empty strings as an em dash.
        case text(String)
        /// Space icon storedValue rendered by SpaceIconView.
        case icon(String)
        /// No custom theme pin or opacity on this side; localized as No custom value, not Default.
        case defaultValue
        /// Preserve raw thousandths (850 → percent(milliUnits: 850)). The view chooses display precision: the
        /// continuous opacity slider makes early integer-percent truncation hide real overwrite differences.
        case percent(milliUnits: Int64)
    }

    struct Change: Equatable {
        let field: Field
        let local: Value
        let account: Value
    }

    let localSpaceId: String
    /// Section title is the current local Space name just selected by the user. If the name differs, it also
    /// appears as the first Change.
    let spaceName: String
    let spaceIconName: String
    /// Nonempty changes only; order always follows Field.allCases, independent of selection/dictionary order.
    let changes: [Change]

    var id: String { localSpaceId }

    /// Sole entry: include only existing assignments, since addAsNew overwrites nothing and default Space is
    /// not a decision row. Preserve decisions order. Skip missing local/account matches without crashing or
    /// affecting other rows. Though §5.4 invariant 3 prevents this in the wizard, this pure internal function
    /// accepts arbitrary test inputs and drives a blocking-modal submit button; never force-unwrap lookups.
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

    /// No pinned theme is the empty string. Deliberately normalize default to empty too: per-Space pins use
    /// registry IDs, but default is a live sentinel for Theme.default in ThemeManager and M3-1 global
    /// settings. This prevents a peer theme_id sentinel from producing an apparent No custom value → No custom
    /// value change. Do not replace this rule with text(Pure).
    private static func normalizedThemeId(_ id: String) -> String {
        (id.isEmpty || id == "default") ? "" : id
    }

    private static func themeValue(_ id: String,
                                   _ themeDisplayName: (String) -> String?) -> Value {
        id.isEmpty ? .defaultValue : .text(themeDisplayName(id) ?? id)
    }

    /// No custom opacity means milli < 0, not only -1: SyncableSpaces.opacity clears for every negative wire
    /// value. -1 is this build's encoding, not a protocol guarantee.
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
