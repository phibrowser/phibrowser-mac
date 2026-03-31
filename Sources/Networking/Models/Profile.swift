// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

struct Profile: Codable {
    let id: Int
    let auth0_id: String
    let email: String
    var name: String
    let picture: String
    let last_login: String
    let created_at: String
}

struct UpdateProfileRequest: Codable {
    let name: String?
}

typealias UpdateProfileResponse = Profile
