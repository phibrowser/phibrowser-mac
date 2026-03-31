// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - Chromium Enum Mappings

/// Maps to Chromium download::DownloadDangerType
/// Values must match `components/download/public/common/download_danger_type.h`
enum DownloadDangerType: Int {
    case notDangerous = 0
    case dangerousFile = 1          // Suspicious file type (.exe, .bat, etc.)
    case dangerousURL = 2           // URL flagged by SafeBrowsing
    case dangerousContent = 3       // Content flagged by SafeBrowsing
    case maybeDangerousContent = 4  // Pending verdict (IsDangerous()=false)
    case uncommonContent = 5        // Uncommon download content
    case userValidated = 6          // User confirmed keep (IsDangerous()=false)
    case dangerousHost = 7          // From known malware-distributing host
    case potentiallyUnwanted = 8    // PUA - potentially unwanted application
    case allowlistedByPolicy = 9    // Enterprise allowlist (IsDangerous()=false)
    case asyncScanning = 10         // Awaiting async safety scan
    case blockedPasswordProtected = 11  // Encrypted file, cannot scan
    case blockedTooLarge = 12       // File too large to scan
    case sensitiveContentWarning = 13   // Sensitive content warning
    case sensitiveContentBlock = 14     // Sensitive content blocked
    case deepScannedSafe = 15           // Deep scan confirmed safe (IsDangerous()=false)
    case deepScannedOpenedDangerous = 16 // Deep scan flagged dangerous after user opened
    case promptForScanning = 17     // Prompt user to send to SafeBrowsing scan
    case dangerousAccountCompromise = 19 // May steal account credentials
    case deepScannedFailed = 20     // Deep scan failed (IsDangerous()=false)
    case promptForLocalPasswordScanning = 21 // Prompt for local password scan
    case asyncLocalPasswordScanning = 22 // Local password scan in progress
    case blockedScanFailed = 23     // Scan failed, file blocked
    case forceSaveToGDrive = 24     // Policy forces save to Google Drive
}

/// Maps to Chromium download::DownloadItem::InsecureDownloadStatus
/// Values must match Chromium side
enum InsecureDownloadStatus: Int {
    case unknown = 0
    case safe = 1
    case validated = 2   // User confirmed keep
    case warn = 3        // HTTP download, show warning
    case block = 4       // HTTP download, block directly
    case silentBlock = 5 // Silent block (no UI warning)
}

// MARK: - Safety State

/// Display state computed on Mac side from Chromium safety fields
enum DownloadSafetyState: Equatable {
    case normal         // No safety issue
    case scanning       // Scan in progress
    case warning        // Warning (user can Keep or Discard)
    case blocked        // Blocked (malicious file, Discard only)
    case policyBlocked  // Policy blocked (enterprise policy/scan limit, Discard only)
}

// MARK: - Safety State Computation

/// Centralized safety state computation logic, independent of DownloadItem for testability
enum DownloadSafetyComputation {

    /// Maps to Chromium PopulateForDangerousUi (Discard only, no Keep button).
    /// Matches DownloadItemModel::IsMalicious() but excludes 16 (DEEP_SCANNED_OPENED_DANGEROUS)
    /// because Chromium bubble UI shows no warning for type 16 (post-hoc marker after user opened).
    static let maliciousDangerTypes: Set<Int> = [
        DownloadDangerType.dangerousURL.rawValue,
        DownloadDangerType.dangerousContent.rawValue,
        DownloadDangerType.dangerousHost.rawValue,
        DownloadDangerType.potentiallyUnwanted.rawValue,
        DownloadDangerType.dangerousAccountCompromise.rawValue,
    ]

    /// Danger types with scan in progress
    static let scanningDangerTypes: Set<Int> = [
        DownloadDangerType.asyncScanning.rawValue,
        DownloadDangerType.asyncLocalPasswordScanning.rawValue,
    ]

    /// Danger types where Chromium bubble UI shows no warning (even if IsDangerous()==true).
    /// DEEP_SCANNED_OPENED_DANGEROUS: user already opened, post-hoc marker.
    static let noWarningDangerTypes: Set<Int> = [
        DownloadDangerType.deepScannedOpenedDangerous.rawValue,
    ]

    /// Danger types blocked by enterprise policy / scan limits
    static let policyBlockedDangerTypes: Set<Int> = [
        DownloadDangerType.blockedPasswordProtected.rawValue,
        DownloadDangerType.blockedTooLarge.rawValue,
        DownloadDangerType.sensitiveContentBlock.rawValue,
        DownloadDangerType.blockedScanFailed.rawValue,
        DownloadDangerType.forceSaveToGDrive.rawValue,
    ]

    /// Compute display state from Chromium safety fields.
    /// Priority: noWarning > insecure > scanning > policyBlocked > malicious > dangerous > normal
    /// Insecure precedes scanning/policyBlocked to match Chromium PopulateForInProgressOrComplete.
    /// downloadState maps to Chromium download::DownloadItem::DownloadState:
    /// IN_PROGRESS=0, COMPLETE=1, CANCELLED=2, INTERRUPTED=3
    static func computeSafetyState(
        isDangerous: Bool,
        dangerType: Int,
        isInsecure: Bool,
        insecureDownloadStatus: Int,
        downloadState: Int
    ) -> DownloadSafetyState {
        // Chromium bubble UI shows no warning for these types
        if noWarningDangerTypes.contains(dangerType) {
            return .normal
        }
        // Only WARN (3) and BLOCK (4) trigger insecure warning.
        // Matches Chromium PopulateForInProgressOrComplete: insecure checked before danger type.
        let insecureWarningStatuses: Set<Int> = [
            InsecureDownloadStatus.warn.rawValue,
            InsecureDownloadStatus.block.rawValue
        ]
        if isInsecure && insecureWarningStatuses.contains(insecureDownloadStatus) {
            return .warning
        }
        if scanningDangerTypes.contains(dangerType) {
            return .scanning
        }
        // Chromium only shows security subpage for these types when INTERRUPTED;
        // must not fall through to warning/blocked for non-INTERRUPTED state
        if policyBlockedDangerTypes.contains(dangerType) {
            return downloadState == DownloadState.interrupted.rawValue ? .policyBlocked : .normal
        }
        if isDangerous && maliciousDangerTypes.contains(dangerType) {
            return .blocked
        }
        if isDangerous {
            return .warning
        }
        return .normal
    }

    /// Returns short status text key for inline display in download row/toast.
    /// Sourced from Chromium IDS_DOWNLOAD_BUBBLE_STATUS_* strings.
    static func shortWarningTextKey(
        safetyState: DownloadSafetyState,
        dangerType: Int,
        isInsecure: Bool,
        insecureDownloadStatus: Int
    ) -> String? {
        switch safetyState {
        case .normal:
            return nil
        case .scanning:
            return "download.safety.short.scanning"
        case .warning:
            if isInsecure && (insecureDownloadStatus == InsecureDownloadStatus.warn.rawValue
                            || insecureDownloadStatus == InsecureDownloadStatus.block.rawValue) {
                return "download.safety.short.insecure"
            }
            return "download.safety.short.suspicious"
        case .blocked:
            return "download.safety.short.dangerous"
        case .policyBlocked:
            switch dangerType {
            case DownloadDangerType.blockedPasswordProtected.rawValue:
                return "download.safety.short.encrypted"
            case DownloadDangerType.blockedTooLarge.rawValue:
                return "download.safety.short.tooBig"
            case DownloadDangerType.blockedScanFailed.rawValue:
                return "download.safety.short.scanFailed"
            default:
                return "download.safety.short.blocked"
            }
        }
    }

    /// Returns detailed localization key for tooltip/subpage display.
    /// Sourced from Chromium IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_* strings.
    static func warningTextKey(
        safetyState: DownloadSafetyState,
        dangerType: Int,
        isInsecure: Bool,
        insecureDownloadStatus: Int
    ) -> String? {
        switch safetyState {
        case .normal:
            return nil
        case .scanning:
            // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_ASYNC_SCANNING
            return "download.safety.scanning"
        case .warning:
            if isInsecure && (insecureDownloadStatus == InsecureDownloadStatus.warn.rawValue
                            || insecureDownloadStatus == InsecureDownloadStatus.block.rawValue) {
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_INSECURE
                return "download.safety.insecure"
            }
            switch dangerType {
            case DownloadDangerType.dangerousFile.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DANGEROUS_FILE_TYPE
                return "download.safety.dangerousFile"
            case DownloadDangerType.uncommonContent.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_UNCOMMON_FILE
                return "download.safety.uncommonContent"
            case DownloadDangerType.sensitiveContentWarning.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_SENSITIVE_CONTENT_WARNING
                return "download.safety.sensitiveContent"
            case DownloadDangerType.promptForScanning.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_DEEP_SCANNING_PROMPT_UPDATED
                return "download.safety.promptForScanning"
            case DownloadDangerType.promptForLocalPasswordScanning.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_DEEP_SCANNING_PROMPT_LOCAL_DECRYPTION
                return "download.safety.promptForLocalPasswordScanning"
            default:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DANGEROUS
                return "download.safety.genericWarning"
            }
        case .blocked:
            switch dangerType {
            case DownloadDangerType.potentiallyUnwanted.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DECEPTIVE
                return "download.safety.deceptive"
            case DownloadDangerType.dangerousAccountCompromise.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_COOKIE_THEFT
                return "download.safety.accountCompromise"
            default:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DANGEROUS
                return "download.safety.dangerous"
            }
        case .policyBlocked:
            switch dangerType {
            case DownloadDangerType.blockedPasswordProtected.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_ENCRYPTED
                return "download.safety.blockedPasswordProtected"
            case DownloadDangerType.blockedTooLarge.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_TOO_BIG
                return "download.safety.blockedTooLarge"
            case DownloadDangerType.blockedScanFailed.rawValue:
                // Chromium: IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_SCAN_FAILED
                return "download.safety.blockedScanFailed"
            default:
                return "download.safety.policyBlocked"
            }
        }
    }
}
