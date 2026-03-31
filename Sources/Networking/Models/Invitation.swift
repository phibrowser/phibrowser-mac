// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - User View
struct UserView: Codable {
    let id: Int
    let email: String
    let name: String
    let picture: String?
}

// MARK: - Activation Info
struct ActivationInfo: Codable {
    let myActivation: MyActivation
    let inviteQuota: InviteQuota
    let myInvitationCodes: [InvitationCode]
    let usersIInvited: [InvitedUser]
    
    enum CodingKeys: String, CodingKey {
        case myActivation = "my_activation"
        case inviteQuota = "invite_quota"
        case myInvitationCodes = "my_invitation_codes"
        case usersIInvited = "users_i_invited"
    }
}

// MARK: - My Activation
struct MyActivation: Codable {
    let isActivated: Bool
    let activatedAt: String?
    let activationType: String? // "invitation" or "admin"
    let activatedByAdmin: UserView?
    let invitedBy: UserView?
    let activatedByCode: CodeInfo?
    
    enum CodingKeys: String, CodingKey {
        case isActivated = "is_activated"
        case activatedAt = "activated_at"
        case activationType = "activation_type"
        case activatedByAdmin = "activated_by_admin"
        case invitedBy = "invited_by"
        case activatedByCode = "activated_by_code"
    }
}

// MARK: - Invite Quota
struct InviteQuota: Codable {
    let inviteLimit: Int
    let invitedCount: Int
    let remainingQuota: Int
    
    enum CodingKeys: String, CodingKey {
        case inviteLimit = "invite_limit"
        case invitedCount = "invited_count"
        case remainingQuota = "remaining_quota"
    }
}

// MARK: - Invitation Code
struct InvitationCode: Codable {
    let id: Int
    let code: String
    let ownerUser: UserView
    let usageLimit: Int
    let usedCount: Int
    let isActive: Bool
    let expiresAt: String?
    let createdAt: String
    let updatedAt: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case code
        case ownerUser = "owner_user"
        case usageLimit = "usage_limit"
        case usedCount = "used_count"
        case isActive = "is_active"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Code Info
struct CodeInfo: Codable {
    let id: Int
    let code: String
}

// MARK: - Invited User
struct InvitedUser: Codable {
    let id: Int
    let email: String
    let name: String
    let picture: String?
    let isActivated: Bool
    let activatedAt: String?
    let invitationCode: CodeInfo?
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case picture
        case isActivated = "is_activated"
        case activatedAt = "activated_at"
        case invitationCode = "invitation_code"
    }
}

// MARK: - Create Invitation Code Request
struct CreateInvitationCodeRequest: Codable {
    let usageLimit: Int
    let expiresAt: String?
    
    enum CodingKeys: String, CodingKey {
        case usageLimit = "usage_limit"
        case expiresAt = "expires_at"
    }
}

// MARK: - Invite Validation Request
struct InviteValidationRequest: Codable {
    let inviteCode: String
    let sessionToken: String
    
    enum CodingKeys: String, CodingKey {
        case inviteCode = "invite_code"
        case sessionToken = "session_token"
    }
}

// MARK: - Invite Validation Response
struct InviteValidationResponse: Codable {
    let activated: Bool
    let invitedBy: String?
    let plan: String?
    let userId: String
    
    enum CodingKeys: String, CodingKey {
        case activated
        case invitedBy = "invited_by"
        case plan
        case userId = "user_id"
    }
}
