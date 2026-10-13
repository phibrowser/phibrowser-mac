// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The shell's typed boundary to one WebContents' native MediaSession.
/// Tokens identify observed browser state, not individual DOM media elements.
@MainActor
enum NativeMediaAdapter {
    struct Playback: Equatable {
        let token: String
        let sourceToken: String
        let title: String
        let artist: String?
        let currentTime: Double?
        let duration: Double?
        let isPlaying: Bool
        let isMuted: Bool
        let isTabMuted: Bool
        let canPlay: Bool
        let canPause: Bool
        let volume: Double?
        let canSetVolume: Bool
        let canPreviousTrack: Bool
        let canNextTrack: Bool
        let canSeek: Bool
        let canEnterPictureInPicture: Bool
        let canExitPictureInPicture: Bool
        let isPictureInPicture: Bool
        var canPlayPause: Bool { isPlaying ? canPause : canPlay }
        var canPictureInPicture: Bool {
            isPictureInPicture ? canExitPictureInPicture : canEnterPictureInPicture
        }
    }

    enum Action { case playPause, previousTrack, nextTrack, seek(Double), pictureInPicture }

    @MainActor
    final class Subscription {
        private let controls: PhiMediaControls
        private var isClosed = false

        init?(wrapper: WebContentWrapper & NSObject, fallbackTitle: String,
              observer: @escaping (Playback?) -> Void) {
            // The shell can be built against a newer header than its bundled
            // Framework. Never send the new selector to an older wrapper.
            guard wrapper.responds(to: NSSelectorFromString("mediaControls")) else { return nil }
            controls = wrapper.mediaControls
            controls.startObserving { [weak self] value in
                // Native contract: callbacks and access are on the UI thread.
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    observer(Self.decode(value, fallbackTitle: fallbackTitle))
                }
            }
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            controls.stopObserving()
        }

        func snapshot(fallbackTitle: String) -> Playback? {
            guard !isClosed else { return nil }
            return Self.decode(controls.snapshot(), fallbackTitle: fallbackTitle)
        }

        /// Map the displayed intent explicitly. A stale pause button must never
        /// turn into play because the site paused before the click was handled.
        @discardableResult
        func perform(_ action: Action, expected: Playback) -> Bool {
            guard !isClosed, let fresh = snapshot(fallbackTitle: ""),
                  fresh.token == expected.token, fresh.sourceToken == expected.sourceToken else { return false }
            let nativeAction: PhiMediaControlAction
            var seconds = 0.0
            switch action {
            case .playPause:
                guard expected.isPlaying ? fresh.canPause : fresh.canPlay else { return false }
                nativeAction = expected.isPlaying ? .pause : .play
            case .previousTrack:
                guard fresh.canPreviousTrack else { return false }
                nativeAction = .previousTrack
            case .nextTrack:
                guard fresh.canNextTrack else { return false }
                nativeAction = .nextTrack
            case .seek(let requested):
                guard requested.isFinite, fresh.canSeek, let duration = fresh.duration else { return false }
                nativeAction = .seekTo
                seconds = min(max(requested, 0), duration)
            case .pictureInPicture:
                if expected.isPictureInPicture {
                    guard fresh.isPictureInPicture, fresh.canExitPictureInPicture else { return false }
                    nativeAction = .exitPictureInPicture
                } else {
                    guard fresh.canEnterPictureInPicture else { return false }
                    nativeAction = .enterPictureInPicture
                }
            }
            return controls.perform(nativeAction, expectedToken: expected.token, seconds: seconds)
        }

        @discardableResult
        func setVolume(_ volume: Double, expected: Playback) -> Bool {
            guard !isClosed, volume.isFinite,
                  controls.responds(to: NSSelectorFromString("setVolume:expectedToken:")),
                  let fresh = snapshot(fallbackTitle: ""), fresh.canSetVolume,
                  fresh.token == expected.token, fresh.sourceToken == expected.sourceToken else { return false }
            return controls.setVolume(min(max(volume, 0), 1), expectedToken: expected.token)
        }

        private static func decode(_ value: [String: Any]?, fallbackTitle: String) -> Playback? {
            guard let value, let token = value["token"] as? String, !token.isEmpty,
                  let sourceToken = value["sourceToken"] as? String, !sourceToken.isEmpty,
                  let playing = value["playing"] as? Bool,
                  let muted = value["muted"] as? Bool,
                  let tabMuted = value["tabMuted"] as? Bool,
                  let canPlay = value["canPlay"] as? Bool,
                  let canPause = value["canPause"] as? Bool,
                  let canSeek = value["canSeek"] as? Bool,
                  let canEnter = value["canEnterPictureInPicture"] as? Bool,
                  let canExit = value["canExitPictureInPicture"] as? Bool,
                  let inPictureInPicture = value["isPictureInPicture"] as? Bool else { return nil }
            let title = (value["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = (value["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let position = (value["currentTime"] as? Double).flatMap { $0.isFinite ? max(0, $0) : nil }
            let duration = (value["duration"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let volume = (value["volume"] as? Double).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            return Playback(token: token, sourceToken: sourceToken,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
                artist: artist.flatMap { $0.isEmpty ? nil : $0 }, currentTime: position, duration: duration,
                isPlaying: playing, isMuted: muted, isTabMuted: tabMuted,
                canPlay: canPlay, canPause: canPause,
                volume: volume, canSetVolume: value["canSetVolume"] as? Bool == true && volume != nil,
                canPreviousTrack: value["canPreviousTrack"] as? Bool ?? false,
                canNextTrack: value["canNextTrack"] as? Bool ?? false,
                canSeek: canSeek && position != nil && duration != nil,
                canEnterPictureInPicture: canEnter,
                canExitPictureInPicture: canExit && inPictureInPicture,
                isPictureInPicture: inPictureInPicture)
        }

        isolated deinit { close() }
    }
}
