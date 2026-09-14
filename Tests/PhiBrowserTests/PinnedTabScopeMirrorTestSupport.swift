// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// 清掉 pin 作用域镜像键与它的两个 sidecar。
///
/// **这不是测试卫生，是在保护开发机上那一份真的偏好。** `LocalStore.changePinnedTabScope`
/// 的成功路径按 §7.1 第 2 步写 `UserDefaults.standard`，而 hosted XCTest bundle 跑在 Phi
/// host 里——那个「standard」就是 Phi 自己的偏好域，不是一次性 suite。任何跑真迁移的用例
/// 于是会把 `PhiPinnedTabScope` 留成它最后迁到的那个值；等开发者下次正常启动 Phi，挂载账户
/// 时的重播会按 §7.1 第 3 步情形二判这个键权威，把他真实的 pin 迁到那个作用域去。
///
/// 三个键一起清（不是只清主键）：只清主键会留下一对与它不匹配的 sidecar。清干净之后重播走
/// 情形一，按行重新播种、并把两个 sidecar 一并写成匹配，三者重新一致。
///
/// 每一个会驱动 `changePinnedTabScope` 的测试类都在 `tearDown` 里调它。
extension XCTestCase {
    func clearPinnedTabScopeMirrorDefaults() {
        let defaults = UserDefaults.standard
        let key = PinnedTabScopeMirror.key
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: SyncableSettings.timestampKey(for: key))
        defaults.removeObject(forKey: SyncableSettings.valueKey(for: key))
    }
}
