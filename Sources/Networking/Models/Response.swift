// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

struct Response<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T
}
