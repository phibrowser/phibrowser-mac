// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

/// ViewModel for status URL display
class StatusURLViewModel: ObservableObject {
    @Published var url: String = ""
}
