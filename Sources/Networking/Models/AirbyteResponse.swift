// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

struct AirbyteResponse<T: Codable>: Codable {
    let success: Bool
    let data: T?
    let error: AirbyteError?
}

struct AirbyteError: Codable {
    let code: Int
    let message: String
}
