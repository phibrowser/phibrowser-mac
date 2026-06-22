// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import SwiftData

extension LocalStore {

    /// Value-typed view of a `SpaceURLRule` used at the LocalStore boundary.
    /// `replaceURLRules(forSpaceId:with:)` accepts these so the caller never
    /// has to hold a SwiftData `@Model` instance across context boundaries
    /// (which SwiftData forbids); the write closure rehydrates each draft
    /// into a fresh `SpaceURLRule` row.
    ///
    /// `pathPrefix` is canonicalized to GURL-style percent-encoded form at
    /// construction so every downstream consumer (optimistic routing push,
    /// SwiftData write, in-memory cache) sees the same shape as what the
    /// C++ matcher will compare URL paths against at navigation time.
    struct URLRuleDraft {
        var id: String
        var host: String
        var pathPrefix: String?
        var askBeforeRouting: Bool
        var createdDate: Date

        init(id: String = UUID().uuidString,
             host: String,
             pathPrefix: String? = nil,
             askBeforeRouting: Bool = false,
             createdDate: Date = Date()) {
            self.id = id
            self.host = host
            self.pathPrefix = LocalStore.normalizedPathPrefix(pathPrefix)
            self.askBeforeRouting = askBeforeRouting
            self.createdDate = createdDate
        }
    }

    @MainActor
    func getAllURLRules() -> [SpaceURLRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor)
        } catch {
            AppLogError("[LocalStore] getAllURLRules failed: \(error)")
            return []
        }
    }

    @MainActor
    func getURLRules(forSpaceId spaceId: String) -> [SpaceURLRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.spaceId == spaceId },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor)
        } catch {
            AppLogError("[LocalStore] getURLRules(forSpaceId:) failed: \(error)")
            return []
        }
    }

    /// Replaces the entire rule set for `spaceId`. Existing rows are deleted
    /// and `drafts` are inserted in the given order (sortOrder = index).
    /// Other Spaces' rules are untouched.
    ///
    /// Every inserted row gets a fresh UUID even when the caller supplied a
    /// `draft.id`. SwiftData's `@Attribute(.unique)` enforcement on
    /// `SpaceURLRule.id` rejects an insert that reuses an id another row
    /// still holds in the same write context — and the delete-then-insert
    /// pattern here puts both operations in one save, where SwiftData's
    /// internal commit order is not contractual. Generating fresh ids
    /// sidesteps the conflict entirely; the only external consumer that
    /// cared about id stability is the editor, which keys its in-memory
    /// rows on a separate UUID for SwiftUI identity.
    func replaceURLRules(forSpaceId spaceId: String, with drafts: [URLRuleDraft]) {
        performBackgroundWrite { context in
            do {
                let descriptor = FetchDescriptor<SpaceURLRule>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )
                for row in try context.fetch(descriptor) {
                    context.delete(row)
                }
                for (index, draft) in drafts.enumerated() {
                    let row = SpaceURLRule(
                        id: UUID().uuidString,
                        spaceId: spaceId,
                        host: draft.host.lowercased(),
                        pathPrefix: draft.pathPrefix,
                        askBeforeRouting: draft.askBeforeRouting,
                        sortOrder: index,
                        createdDate: draft.createdDate
                    )
                    context.insert(row)
                }
            } catch {
                AppLogError("[LocalStore] replaceURLRules failed: \(error)")
            }
        }
    }

    /// Replaces every Space's URL rule set in one write. Existing rows for
    /// every Space are deleted; the supplied drafts are inserted with
    /// `sortOrder = index` within each `targetSpaceId` bucket. Empty buckets
    /// (Spaces not present in `byTargetSpaceId`) end up with no rules — the
    /// universal editor relies on this so a row that the user just deleted
    /// or moved off a Space is actually gone after save.
    func replaceAllURLRules(_ byTargetSpaceId: [String: [URLRuleDraft]]) {
        performBackgroundWrite { context in
            do {
                for row in try context.fetch(FetchDescriptor<SpaceURLRule>()) {
                    context.delete(row)
                }
                for (spaceId, drafts) in byTargetSpaceId {
                    for (index, draft) in drafts.enumerated() {
                        let row = SpaceURLRule(
                            id: UUID().uuidString,
                            spaceId: spaceId,
                            host: draft.host.lowercased(),
                            pathPrefix: draft.pathPrefix,
                            askBeforeRouting: draft.askBeforeRouting,
                            sortOrder: index,
                            createdDate: draft.createdDate
                        )
                        context.insert(row)
                    }
                }
            } catch {
                AppLogError("[LocalStore] replaceAllURLRules failed: \(error)")
            }
        }
    }

    @MainActor
    func urlRulesPublisher() -> AnyPublisher<[SpaceURLRule], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[SpaceURLRule], Never>([])
        let fetch = { self.getAllURLRules() }
        subject.send(fetch())

        let cancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: { $0.entity.name == SpaceURLRule.entityName }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in subject.send(fetch()) }

        return subject
            .removeDuplicates { lhs, rhs in
                guard lhs.count == rhs.count else { return false }
                return zip(lhs, rhs).allSatisfy { l, r in
                    l.id == r.id &&
                    l.spaceId == r.spaceId &&
                    l.host == r.host &&
                    l.pathPrefix == r.pathPrefix &&
                    l.askBeforeRouting == r.askBeforeRouting &&
                    l.sortOrder == r.sortOrder
                }
            }
            .handleEvents(receiveCancel: { cancellable.cancel() })
            .eraseToAnyPublisher()
    }

    /// Canonicalizes a raw user-entered path prefix into the shape the C++
    /// matcher will compare against. Four steps:
    ///   1. Trim whitespace and reject empty input (so the throttle never
    ///      sees noise like " " or "").
    ///   2. Strip trailing slashes so `/foo/` and `/foo` behave identically,
    ///      then collapse a bare "/" to nil. A sole "/" is degenerate: the
    ///      matcher's prefix-boundary check would make it match only the root
    ///      path and never "/foo", which is never what the user means — nil
    ///      ("match any path") is.
    ///   3. Ensure a leading "/" so the matcher's prefix check has a stable
    ///      base — `url.percentEncodedPath` / `GURL::path()` always start
    ///      with one for any URL with a host.
    ///   4. Decode-then-re-encode so the output is canonical regardless of
    ///      whether the caller typed `/résumé` or pasted `/r%C3%A9sum%C3%A9`.
    ///      Idempotence matters: `URLRuleDraft.init` may run on an already-
    ///      canonical prefix read back from storage, and V1 (raw
    ///      `addingPercentEncoding` without the decode step) double-encodes
    ///      every `%` in that case.
    ///
    /// Both the Swift `URLRouter` and the C++ `phi::PhiURLRouter` compare
    /// against the percent-encoded canonical path, so the stored prefix
    /// must end up in this shape regardless of how the user expressed it.
    static func normalizedPathPrefix(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else {
            return nil
        }
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        // A bare "/" only matches the root under the prefix-boundary check;
        // treat it as "match any path" so the rule isn't silently inert.
        if s == "/" { return nil }
        if !s.hasPrefix("/") {
            s = "/" + s
        }
        // If the input already contained percent-encoded sequences, decode
        // them first so the re-encode step doesn't double-escape every `%`.
        // For literal-`%` cases like `/100%complete` (no valid hex follows),
        // `removingPercentEncoding` returns the string unchanged, and the
        // re-encode correctly escapes the `%` to `%25`.
        if let decoded = s.removingPercentEncoding, decoded != s {
            s = decoded
        }
        return s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
