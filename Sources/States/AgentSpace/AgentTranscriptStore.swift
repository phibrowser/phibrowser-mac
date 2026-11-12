// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// One line of an agent task's live transcript — the session console a user
/// can open from View ▸ Agent Transcript or an agent pip's context menu.
/// Entries are display-only: the durable session lives with the driver (the
/// code agent's own conversation); this is its mirror in the browser.
struct AgentTranscriptEntry: Identifiable, Equatable {
    enum Kind: String {
        /// Automatic primitive log from the skill ("goto example.com").
        case action
        /// Agent-authored caption (`setStatus` / `narrate`) — the agent
        /// telling the watching user what it is doing.
        case narration
        /// Round separator ("round started" / "round ended").
        case round
        /// Lifecycle: task started/completed, ownership flips.
        case status
        /// `markError` / failed completion.
        case error
        /// A command the user typed into the console — echoed at enqueue
        /// time, delivered to the driver via `agentSpace.readUserMessages`.
        case user
        /// The driving code agent's conversational prose, mirrored from its
        /// session (the Claude Code / Codex reply text), so the console reads
        /// like the agent's own transcript — not just the browser steps.
        case assistant
        /// The driving agent's reasoning summary, mirrored from its session —
        /// rendered dim italic, the way the origin CLIs set thinking apart.
        case thinking
        /// A tool call from the driving agent's session (a shell command, a
        /// file edit), titled the way the origin CLI displays it ("Bash(git
        /// status)", "Ran git status").
        case tool
    }

    let id: UUID
    let timestamp: Date
    /// Global append order, so the merged multi-task feed sorts exactly by
    /// arrival — wall-clock timestamps can collide within a millisecond.
    let seq: Int
    let kind: Kind
    let text: String
    /// Optional dimmed second line (a URL, char count, js preview).
    let detail: String?
    /// The driving agent a mirrored line came from ("claude", "codex", …) —
    /// picks the origin CLI's visual language in the console (Claude Code's
    /// >/⏺/⎿ beats vs Codex's ▌/•/└ cells). nil for app- and skill-authored
    /// lines, which keep Phi's own console style.
    let agent: String?
    /// The task's pip ordinal at append time, so the merged feed can tag
    /// lines "R1"/"R2" when several tasks are live without re-resolving
    /// tasks that have since completed.
    let taskNumber: Int
}

/// Ephemeral Codex state displayed at the transcript tail. Unlike an
/// `AgentTranscriptEntry`, this is replaced in place and never becomes part
/// of transcript history.
enum CodexTranscriptActivity: String {
    case working
    case waiting
}

/// Ephemeral Claude Code state displayed at the transcript tail — the
/// terminal's spinner status line ("✽ Mulling… (6s · thinking with xhigh
/// effort)") while a turn runs, and its resting past-tense summary
/// ("Cogitated for 28s · 1 shell still running") once it ends. Replaced in
/// place like Codex's working/waiting row; never part of history. Parsed
/// from the mirror daemon's JSON activity payload (see mirror-claude.mjs
/// turnActivity).
struct ClaudeTranscriptActivity: Equatable {
    enum Phase: String {
        case working
        case idle
    }

    let phase: Phase
    /// Turn start (epoch ms). Drives the live elapsed readout and seeds the
    /// turn's whimsical verb, so the spinner and the later summary conjugate
    /// the SAME verb. nil when the mirror missed the turn's start (daemon
    /// restarted mid-turn).
    let startTimestampMs: Double?
    /// Claude Code's configured reasoning effort ("xhigh"), or nil.
    let effort: String?
    /// Total turn duration from the session's turn_duration record (idle).
    let durationMs: Double?
    /// Background shells still running when the turn ended (idle).
    let shellsRunning: Int

    init?(payloadText: String) {
        guard let data = payloadText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let phase = (obj["phase"] as? String).flatMap(Phase.init(rawValue:))
        else { return nil }
        self.phase = phase
        self.startTimestampMs = (obj["startTs"] as? NSNumber)?.doubleValue
        self.effort = (obj["effort"] as? String).map { String($0.prefix(16)) }
        self.durationMs = (obj["durationMs"] as? NSNumber)?.doubleValue
        self.shellsRunning = max(0, (obj["shellsRunning"] as? NSNumber)?.intValue ?? 0)
    }
}

/// Bounded per-task transcript buffers, separate from `AgentTask` on purpose:
/// the task dict republishes on every cursor move, and a growing array inside
/// it would make each cursor update an O(entries) copy — the same reasoning
/// that keeps `AgentEffect` out of `tasksBySpaceId`. Keyed by taskId, not
/// spaceId: entries arrive taskId-first and must survive a persistent task's
/// Space re-bind.
@MainActor
final class AgentTranscriptStore: ObservableObject {
    static let shared = AgentTranscriptStore()

    /// Ring cap per task: old lines fall off, ids stay stable for SwiftUI
    /// diffing. 500 lines ≈ a long session; the authoritative record is the
    /// driver's own transcript, not this mirror.
    static let maxEntriesPerTask = 500
    /// Terse single-line entries (actions, status, rounds) are capped short;
    /// mirrored conversation (assistant prose, user prompts) keeps its shape
    /// up to a much larger bound so a paragraph isn't guillotined.
    static let maxTerseChars = 300
    static let maxProseChars = 4000
    static let maxDetailChars = 500

    @Published private(set) var entriesByTaskId: [String: [AgentTranscriptEntry]] = [:]
    @Published private(set) var codexActivityByTaskId: [String: CodexTranscriptActivity] = [:]
    @Published private(set) var claudeActivityByTaskId: [String: ClaudeTranscriptActivity] = [:]

    /// Wall-clock of the last append per task — the continuity signal for
    /// task re-creates (see `AgentSpaceManager.beginTranscript`). Kept apart
    /// from entry timestamps, which mirrored lines backdate to authored time.
    private var lastAppendByTaskId: [String: Date] = [:]

    private var nextSeq = 0

    private init() {}

    /// `timestamp` is when the line was authored — usually now, but a mirrored
    /// session line passes the source event's real time so backfilled prose
    /// (forwarded after the heredoc it describes) still sorts into its true
    /// place in the feed rather than after the actions it introduced.
    func append(taskId: String, kind: AgentTranscriptEntry.Kind,
                text: String, detail: String? = nil, agent: String? = nil,
                taskNumber: Int, timestamp: Date = Date()) {
        let sourceAgent = agent.map { String($0.prefix(16)) }
        // Conversation lines keep their paragraph shape; terse lines collapse
        // to one line.
        let multiline = kind == .assistant || kind == .user || kind == .narration
            || kind == .thinking
        let sanitizedText = Self.sanitize(
            text, cap: multiline ? Self.maxProseChars : Self.maxTerseChars,
            keepBreaks: multiline)
        let sanitizedDetail = detail.map {
            // Codex collaboration cells carry one indented agent/status per
            // line, so only they keep their breaks.
            Self.sanitize(
                $0, cap: Self.maxDetailChars,
                keepBreaks: kind == .tool && sourceAgent == "codex")
        }
        var entries = entriesByTaskId[taskId] ?? []

        nextSeq += 1
        let entry = AgentTranscriptEntry(
            id: UUID(),
            timestamp: timestamp,
            seq: nextSeq,
            kind: kind,
            text: sanitizedText,
            detail: sanitizedDetail,
            agent: sourceAgent,
            taskNumber: taskNumber)
        entries.append(entry)
        if entries.count > Self.maxEntriesPerTask {
            entries.removeFirst(entries.count - Self.maxEntriesPerTask)
        }
        entriesByTaskId[taskId] = entries
        lastAppendByTaskId[taskId] = Date()
    }

    /// When the task's console last received a line (wall-clock), or nil.
    func lastAppend(taskId: String) -> Date? {
        lastAppendByTaskId[taskId]
    }

    func setCodexActivity(taskId: String, activity: CodexTranscriptActivity) {
        codexActivityByTaskId[taskId] = activity
    }

    func setClaudeActivity(taskId: String, activity: ClaudeTranscriptActivity) {
        claudeActivityByTaskId[taskId] = activity
    }

    /// User-facing feed clear: the mirrored live activity rows are state, not
    /// history, so they stay visible while stored lines are removed.
    func clearEntries(taskId: String) {
        entriesByTaskId[taskId] = nil
        lastAppendByTaskId[taskId] = nil
    }

    func clearAllEntries() {
        entriesByTaskId = [:]
        lastAppendByTaskId = [:]
    }

    func clear(taskId: String) {
        clearEntries(taskId: taskId)
        codexActivityByTaskId[taskId] = nil
        claudeActivityByTaskId[taskId] = nil
    }

    /// Frees buffers of tasks no longer alive — called when the console
    /// closes, so an open panel can keep showing how a task ended but nothing
    /// outlives the last reader.
    func clearAll(except liveTaskIds: Set<String>) {
        entriesByTaskId = entriesByTaskId.filter { liveTaskIds.contains($0.key) }
        codexActivityByTaskId = codexActivityByTaskId.filter { liveTaskIds.contains($0.key) }
        claudeActivityByTaskId = claudeActivityByTaskId.filter { liveTaskIds.contains($0.key) }
        lastAppendByTaskId = lastAppendByTaskId.filter { liveTaskIds.contains($0.key) }
    }

    /// Strips control characters (both senders are freeform / LLM-authored)
    /// and caps the length. `keepBreaks` keeps newlines and tabs so mirrored
    /// prose wraps as paragraphs; otherwise everything collapses to one line.
    private static func sanitize(_ text: String, cap: Int, keepBreaks: Bool) -> String {
        var s = String(text.map { ch -> Character in
            if ch == "\n" || ch == "\t" { return keepBreaks ? ch : " " }
            if ch.unicodeScalars.count == 1,
               CharacterSet.controlCharacters.contains(ch.unicodeScalars.first!) {
                return " "
            }
            return ch
        })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > cap {
            s = String(s.prefix(cap)) + "…"
        }
        return s
    }
}
