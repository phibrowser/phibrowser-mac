// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Reads and controls page-owned HTML media through Phi's existing private CDP
/// transport. No page handlers are replaced and no persistent script is installed.
/// Cross-origin frames cannot be inspected from the top page's JavaScript context.
enum SidebarMediaBridge {
    struct Playback: Equatable {
        let title: String
        let artist: String?
        let metadataIdentity: String
        let source: String
        let index: Int
        let topDocumentTimeOrigin: Double
        let mediaDocumentTimeOrigin: Double
        let currentTime: Double
        let duration: Double?
        let seekStart: Double?
        let seekEnd: Double?
        let isPlaying: Bool
        let isMuted: Bool
        let canPictureInPicture: Bool
        let isPictureInPicture: Bool

        var canSeek: Bool {
            guard duration != nil, let seekStart, let seekEnd else { return false }
            return seekEnd > seekStart
        }
    }

    enum Action {
        case playPause
        case seek(Double)
        case pictureInPicture
    }

    /// Reuses one page connection for the selected player's one-second refresh.
    /// Candidate discovery and user actions use short independent sessions.
    @MainActor
    final class PollConnection {
        let targetId: String
        private var session: AppDevToolsPageSession?
        private var isClosed = false

        init(targetId: String) { self.targetId = targetId }

        func inspect(fallbackTitle: String) async -> Playback? {
            guard !isClosed else { return nil }
            if session == nil {
                let opened = try? await AppDevToolsPageSession.open(
                    targetId: targetId, timeout: 3)
                guard !isClosed else {
                    opened?.close()
                    return nil
                }
                session = opened
            }
            guard let session else { return nil }
            let value = await SidebarMediaBridge.evaluate(snapshotScript, in: session)
            return SidebarMediaBridge.decode(value, fallbackTitle: fallbackTitle)
        }

        func close() {
            isClosed = true
            session?.close()
            session = nil
        }

        deinit {
            session?.close()
        }
    }

    static func inspect(targetId: String, fallbackTitle: String) async -> Playback? {
        guard let session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else {
            return nil
        }
        defer { session.close() }
        return decode(await evaluate(snapshotScript, in: session),
                      fallbackTitle: fallbackTitle)
    }

    private static func decode(_ value: [String: Any]?,
                               fallbackTitle: String) -> Playback? {
        guard let value,
              let currentTime = value["currentTime"] as? Double,
              let index = value["index"] as? Int,
              let source = value["source"] as? String,
              let metadataIdentity = value["metadataIdentity"] as? String,
              let topDocumentTimeOrigin = value["topDocumentTimeOrigin"] as? Double,
              topDocumentTimeOrigin.isFinite, topDocumentTimeOrigin > 0,
              let mediaDocumentTimeOrigin = value["mediaDocumentTimeOrigin"] as? Double,
              mediaDocumentTimeOrigin.isFinite, mediaDocumentTimeOrigin > 0,
              let isPlaying = value["playing"] as? Bool,
              let isMuted = value["muted"] as? Bool,
              let canPictureInPicture = value["canPictureInPicture"] as? Bool,
              let isPictureInPicture = value["isPictureInPicture"] as? Bool,
              value["ended"] as? Bool == false else { return nil }
        let reportedTitle = (value["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (reportedTitle?.isEmpty == false ? reportedTitle : nil)
            ?? fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (value["artist"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDuration = value["duration"] as? Double
        let duration = rawDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Playback(title: title,
                        artist: artist?.isEmpty == false ? artist : nil,
                        metadataIdentity: metadataIdentity,
                        source: source, index: index,
                        topDocumentTimeOrigin: topDocumentTimeOrigin,
                        mediaDocumentTimeOrigin: mediaDocumentTimeOrigin,
                        currentTime: currentTime.isFinite ? max(0, currentTime) : 0,
                        duration: duration,
                        seekStart: value["seekStart"] as? Double,
                        seekEnd: value["seekEnd"] as? Double,
                        isPlaying: isPlaying, isMuted: isMuted,
                        canPictureInPicture: canPictureInPicture,
                        isPictureInPicture: isPictureInPicture)
    }

    static func perform(_ action: Action, targetId: String,
                        source: String, index: Int,
                        metadataIdentity: String,
                        topDocumentTimeOrigin: Double,
                        mediaDocumentTimeOrigin: Double) async -> Bool {
        guard topDocumentTimeOrigin.isFinite, topDocumentTimeOrigin > 0,
              mediaDocumentTimeOrigin.isFinite, mediaDocumentTimeOrigin > 0 else { return false }
        guard let session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else {
            return false
        }
        defer { session.close() }
        let operation: String
        switch action {
        case .playPause:
            operation = "if (media.paused) { try { await media.play(); } catch (_) { return {ok: false}; } } else { media.pause(); }"
        case .seek(let seconds):
            guard seconds.isFinite else { return false }
            operation = "if (!Number.isFinite(media.duration) || !media.seekable.length) return {ok: false}; const requested = Math.max(0, Math.min(media.duration, \(seconds))); let nearest = null; for (let i = 0; i < media.seekable.length; i++) { const value = Math.max(media.seekable.start(i), Math.min(media.seekable.end(i), requested)); if (nearest === null || Math.abs(value - requested) < Math.abs(nearest - requested)) nearest = value; } media.currentTime = nearest;"
        case .pictureInPicture:
            operation = "if (media.tagName !== 'VIDEO' || !media.ownerDocument.pictureInPictureEnabled || media.disablePictureInPicture || typeof media.requestPictureInPicture !== 'function') return {ok: false}; try { if (media.ownerDocument.pictureInPictureElement === media) await media.ownerDocument.exitPictureInPicture(); else await media.requestPictureInPicture(); } catch (_) { return {ok: false}; }"
        }
        let script = """
        (async () => {
          const media = \(mediaLookupScript)(\(quoted(source)), \(index));
          if (!media) return {ok: false};
          // The target survives same-URL reloads. Check both documents after
          // connection setup, before a delayed action can affect replacement media.
          if (document.defaultView.performance.timeOrigin !== \(topDocumentTimeOrigin)
              || media.ownerDocument.defaultView.performance.timeOrigin !== \(mediaDocumentTimeOrigin)) return {ok: false};
          // Streaming pages can replace a track without replacing its element,
          // blob URL or document. Pin the raw Media Session track fields too.
          const metadata = \(mediaMetadataScript)(media);
          if (!metadata || JSON.stringify(metadata) !== \(quoted(metadataIdentity))) return {ok: false};
          \(operation)
          return {ok: true};
        })()
        """
        let value = await evaluate(script, in: session, userGesture: true)
        return value?["ok"] as? Bool == true
    }

    private static func evaluate(_ expression: String, in session: AppDevToolsPageSession,
                                 userGesture: Bool = false) async -> [String: Any]? {
        guard let reply = try? await session.command(
            "Runtime.evaluate",
            params: ["expression": expression, "returnByValue": true,
                     "userGesture": userGesture,
                     "awaitPromise": userGesture], timeout: 4),
              reply["exceptionDetails"] == nil else { return nil }
        return (reply["result"] as? [String: Any])?["value"] as? [String: Any]
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// A bounded document walk includes same-origin frames without touching
    /// cross-origin frame contents. The selected source survives DOM reorder.
    private static let mediaLookupScript = """
    ((source, index) => {
      const media = [];
      const visit = (doc, depth) => {
        if (depth > 2 || media.length >= 100) return;
        try {
          for (const item of doc.querySelectorAll('audio,video')) {
            if (media.length >= 100) break;
            media.push(item);
          }
          for (const frame of doc.querySelectorAll('iframe')) {
            try { if (frame.contentDocument) visit(frame.contentDocument, depth + 1); } catch (_) {}
          }
        } catch (_) {}
      };
      visit(document, 0);
      if (!source) return media[index] || null;
      if (media[index]?.currentSrc === source) return media[index];
      const matches = media.filter(item => item.currentSrc === source);
      return matches.length === 1 ? matches[0] : null;
    })
    """

    /// Share the exact raw track fields between snapshot and command guard.
    /// Display truncation must not make two different tracks look identical.
    private static let mediaMetadataScript = """
    ((media) => {
      const metadata = media.ownerDocument.defaultView.navigator.mediaSession?.metadata
        || navigator.mediaSession?.metadata;
      const fields = [String(metadata?.title || ''), String(metadata?.artist || ''), String(metadata?.album || '')];
      // Page-owned metadata must not inflate the one-second CDP response.
      // Reject oversized identities rather than truncating distinct tracks.
      return fields.some(value => value.length > 4096) ? null : fields;
    })
    """

    private static let snapshotScript = """
    (() => {
      const media = [];
      const visit = (doc, depth) => {
        if (depth > 2 || media.length >= 100) return;
        try {
          for (const item of doc.querySelectorAll('audio,video')) {
            if (media.length >= 100) break;
            media.push(item);
          }
          for (const frame of doc.querySelectorAll('iframe')) {
            try { if (frame.contentDocument) visit(frame.contentDocument, depth + 1); } catch (_) {}
          }
        } catch (_) {}
      };
      visit(document, 0);
      // A ready but never-started preload is not a sidebar player. Keep a
      // previously played item after it pauses or is rewound to the start.
      const candidates = media.filter(item => item.readyState > 0 && !item.ended
        && (!item.paused || item.currentTime > 0 || item.played.length > 0));
      const item = candidates.find(item => !item.paused && !item.muted && item.volume > 0)
        || candidates.find(item => !item.paused)
        || candidates.find(item => item.currentTime > 0)
        || candidates[0];
      if (!item) return null;
      const metadata = \(mediaMetadataScript)(item);
      if (!metadata) return null;
      return {
        title: metadata[0].slice(0, 300),
        artist: metadata[1].slice(0, 200),
        metadataIdentity: JSON.stringify(metadata),
        source: item.currentSrc || '', index: media.indexOf(item),
        topDocumentTimeOrigin: document.defaultView.performance.timeOrigin,
        mediaDocumentTimeOrigin: item.ownerDocument.defaultView.performance.timeOrigin,
        currentTime: item.currentTime, duration: Number.isFinite(item.duration) ? item.duration : null,
        seekStart: item.seekable.length ? item.seekable.start(0) : null,
        seekEnd: item.seekable.length ? item.seekable.end(item.seekable.length - 1) : null,
        playing: !item.paused, muted: item.muted || item.volume === 0, ended: item.ended,
        canPictureInPicture: item.tagName === 'VIDEO'
          && !!item.ownerDocument.pictureInPictureEnabled && !item.disablePictureInPicture
          && typeof item.requestPictureInPicture === 'function',
        isPictureInPicture: item.ownerDocument.pictureInPictureElement === item
      };
    })()
    """
}
