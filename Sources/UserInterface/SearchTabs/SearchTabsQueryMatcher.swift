// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SearchTabsQueryMatcher {
    static let titlePrefixScore = 400
    static let titleContainsScore = 300
    static let hostContainsScore = 200
    static let urlContainsScore = 100

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func match(
        query: String,
        primaryTitle: String,
        primaryURL: String?,
        secondaryTitle: String?,
        secondaryURL: String?
    ) -> SearchTabsMatch? {
        let normalized = normalizedQuery(query)
        guard !normalized.isEmpty else {
            return SearchTabsMatch(score: 0, matchedFields: [])
        }

        var bestScore = 0
        var fields: Set<SearchTabsMatchedField> = []

        scoreText(primaryTitle, query: normalized, prefixField: .title, containsField: .title, bestScore: &bestScore, fields: &fields)
        if let secondaryTitle {
            scoreText(secondaryTitle, query: normalized, prefixField: .secondaryTitle, containsField: .secondaryTitle, bestScore: &bestScore, fields: &fields)
        }
        scoreURL(primaryURL, query: normalized, urlField: .url, hostField: .host, bestScore: &bestScore, fields: &fields)
        scoreURL(secondaryURL, query: normalized, urlField: .secondaryURL, hostField: .secondaryURL, bestScore: &bestScore, fields: &fields)

        guard bestScore > 0 else { return nil }
        return SearchTabsMatch(score: bestScore, matchedFields: fields)
    }

    private static func scoreText(
        _ text: String,
        query: String,
        prefixField: SearchTabsMatchedField,
        containsField: SearchTabsMatchedField,
        bestScore: inout Int,
        fields: inout Set<SearchTabsMatchedField>
    ) {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if normalized.hasPrefix(query) {
            record(score: titlePrefixScore, field: prefixField, bestScore: &bestScore, fields: &fields)
        } else if normalized.contains(query) {
            record(score: titleContainsScore, field: containsField, bestScore: &bestScore, fields: &fields)
        }
    }

    private static func scoreURL(
        _ rawURL: String?,
        query: String,
        urlField: SearchTabsMatchedField,
        hostField: SearchTabsMatchedField,
        bestScore: inout Int,
        fields: inout Set<SearchTabsMatchedField>
    ) {
        guard let rawURL, !rawURL.isEmpty else { return }
        let normalizedURL = rawURL.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let host = URL(string: rawURL)?.host?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
           host.contains(query) {
            record(score: hostContainsScore, field: hostField, bestScore: &bestScore, fields: &fields)
        } else if normalizedURL.contains(query) {
            record(score: urlContainsScore, field: urlField, bestScore: &bestScore, fields: &fields)
        }
    }

    private static func record(
        score: Int,
        field: SearchTabsMatchedField,
        bestScore: inout Int,
        fields: inout Set<SearchTabsMatchedField>
    ) {
        if score > bestScore {
            bestScore = score
            fields = [field]
        } else if score == bestScore {
            fields.insert(field)
        }
    }
}
