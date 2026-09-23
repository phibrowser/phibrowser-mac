// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum FeedbackV2Limits {
    static let attachmentCount = 10
    static let attachmentBytes: Int64 = 20 * 1024 * 1024
}

enum FeedbackV2AttachmentType: String, Codable {
    case screenshot
    case log
    case other
}

struct FeedbackV2PresignAttachmentRequest: Codable {
    let filename: String
    let mimeType: String
    let size: Int64
    let attachmentType: FeedbackV2AttachmentType

    enum CodingKeys: String, CodingKey {
        case filename
        case mimeType = "mime_type"
        case size
        case attachmentType = "attachment_type"
    }
}

struct FeedbackV2PresignRequest: Codable {
    let attachments: [FeedbackV2PresignAttachmentRequest]
}

struct FeedbackV2PresignedAttachment: Codable {
    let filename: String
    let objectKey: String
    let uploadURL: String
    let expiresIn: Int
    let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case filename
        case objectKey = "object_key"
        case uploadURL = "upload_url"
        case expiresIn = "expires_in"
        case headers
    }
}

struct FeedbackV2PresignData: Codable {
    let attachments: [FeedbackV2PresignedAttachment]
}

struct FeedbackV2SubmitAttachment: Codable {
    let objectKey: String
    let filename: String
    let mimeType: String
    let size: Int64
    let attachmentType: FeedbackV2AttachmentType

    enum CodingKeys: String, CodingKey {
        case objectKey = "object_key"
        case filename
        case mimeType = "mime_type"
        case size
        case attachmentType = "attachment_type"
    }
}

struct FeedbackV2SubmitRequest: Codable {
    let description: String
    let contactEmail: String?
    let metadata: FeedbackV2Metadata
    let attachments: [FeedbackV2SubmitAttachment]

    enum CodingKeys: String, CodingKey {
        case description
        case contactEmail = "contact_email"
        case metadata
        case attachments
    }
}

struct FeedbackV2Metadata: Codable {
    struct Browser: Codable {
        let name: String?
        let version: String
        let channel: String?
        let revision: String?
        // Optional so feedback queued before these fields were added remains readable.
        let aiEnabled: Bool?
        let useNTP: Bool?

        enum CodingKeys: String, CodingKey {
            case name, version, channel, revision
            case aiEnabled = "ai_enabled"
            case useNTP = "use_ntp"
        }
    }

    struct Page: Codable {
        let url: String?
        let title: String?
    }

    struct ClientContext: Codable {
        let category: String?
        let userAgent: String?
        let locale: String?
        let traceID: String?

        enum CodingKeys: String, CodingKey {
            case category
            case userAgent = "user_agent"
            case locale
            case traceID = "trace_id"
        }
    }

    struct Component: Codable {
        let id: String
        let name: String?
        let type: String?
        let version: String
    }

    let browser: Browser
    let page: Page?
    let clientContext: ClientContext
    let components: [Component]
    let extra: [String: String]

    enum CodingKeys: String, CodingKey {
        case browser
        case page
        case clientContext = "client_context"
        case components
        case extra
    }
}

struct FeedbackV2SubmitData: Codable {
    let feedbackID: Int
    let uniqueReportIdentifier: String
    let attachmentCount: Int

    enum CodingKeys: String, CodingKey {
        case feedbackID = "feedback_id"
        case uniqueReportIdentifier = "unique_report_identifier"
        case attachmentCount = "attachment_count"
    }
}
