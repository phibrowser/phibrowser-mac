import Foundation
import SwiftData

typealias TabDataModel = TabDataModelSchemaV14.TabDataModel
typealias ProfileModel = TabDataModelSchemaV14.ProfileModel
enum TabDataType: Int { case tab, pinnedTab, bookmark, bookmarkFolder }
func AppLogError(_ message: String) { fatalError(message) }

// Execute the production query against the actual schema, observing the fetch
// boundary without substituting results or launching the application.
@MainActor final class QueryContext {
    let real: ModelContext
    var fetchedCount = 0
    init(_ real: ModelContext) { self.real = real }
    func fetch(_ descriptor: FetchDescriptor<TabDataModel>) throws -> [TabDataModel] {
        let rows = try real.fetch(descriptor)
        fetchedCount = rows.count
        return rows
    }
}

@main struct BookmarkQueryTests {
    @MainActor static func query(_ context: QueryContext, profileId: String,
                                 spaceId: String) -> [TabDataModel]? {
        /* PRODUCTION_QUERY */
    }

    @MainActor static func container() throws -> ModelContainer {
        let schema = Schema(TabDataModelSchemaV14.models)
        let configuration: ModelConfiguration
        if let index = CommandLine.arguments.firstIndex(of: "--sqlite-directory") {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            configuration = ModelConfiguration(schema: schema,
                url: directory.appendingPathComponent("query-\(UUID().uuidString).sqlite"),
                cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    @MainActor @discardableResult static func row(_ context: ModelContext,
        _ guid: String, profile: ProfileModel?, space: String?, type: TabDataType = .bookmark,
        order: Int = 0, scalarProfile: String? = nil) -> TabDataModel {
        let row = TabDataModel(title: guid, guid: guid, index: order,
            url: URL(string: "https://example.com/\(guid)")!, favicon: nil,
            createdDate: Date(timeIntervalSince1970: Double(order)), updatedDate: Date())
        row.type = type.rawValue
        row.profile = profile
        row.profileId = scalarProfile
        row.spaceId = space
        context.insert(row)
        return row
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func regression() throws {
        let checksFetchScope = !CommandLine.arguments.contains("--baseline-semantics")
        let store = try container()
        let context = store.mainContext
        let a = ProfileModel(profileId: "A"), b = ProfileModel(profileId: "B")
        context.insert(a); context.insert(b)
        row(context, "folder", profile: a, space: "S", type: .bookmarkFolder, order: 2)
        row(context, "leaf", profile: a, space: "S", order: 1)
        row(context, "scalar-disagrees", profile: a, space: "S", order: 3, scalarProfile: "B")
        row(context, "other-space", profile: a, space: "T")
        row(context, "other-profile", profile: b, space: "S", scalarProfile: "A")
        row(context, "no-profile", profile: nil, space: "S", scalarProfile: "A")
        row(context, "no-space", profile: a, space: nil)
        row(context, "tab", profile: a, space: "S", type: .tab)
        row(context, "pin", profile: a, space: "S", type: .pinnedTab)
        try context.save()
        let spy = QueryContext(context)
        let first = query(spy, profileId: "A", spaceId: "S")!
        check(first.map(\.guid) == ["leaf", "folder", "scalar-disagrees"],
              "Preserve relationship ownership, exact Space, types and creation order")
        check(!checksFetchScope || spy.fetchedCount == 3,
              "A Space query must fetch only its 3 rows, fetched \(spy.fetchedCount)")
        check(query(spy, profileId: "B", spaceId: "S")!.map(\.guid) == ["other-profile"],
              "A subsequent query must use its own captured Profile")
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["leaf", "folder", "scalar-disagrees"],
              "Returning to the first Profile must not reuse another query's scope")
        let fresh = QueryContext(ModelContext(store))
        check(query(fresh, profileId: "A", spaceId: "S")!.map(\.guid) == ["leaf", "folder", "scalar-disagrees"],
              "A fresh context must resolve the persisted Profile relationship")
        check(query(spy, profileId: "A", spaceId: "missing")!.isEmpty && (!checksFetchScope || spy.fetchedCount == 0),
              "An empty Space must not materialize other Spaces")
        let leaf = first[0]
        leaf.profile = b
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["folder", "scalar-disagrees"],
              "Pending relationship edits must leave the old Profile query")
        check(query(spy, profileId: "B", spaceId: "S")!.map(\.guid) == ["other-profile", "leaf"],
              "Pending relationship edits must enter the new Profile query")
        try context.save()
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["folder", "scalar-disagrees"],
              "Changing the relationship must remove a row from its old Profile")
        check(query(spy, profileId: "B", spaceId: "S")!.map(\.guid) == ["other-profile", "leaf"],
              "Changing the relationship must add a row to its new Profile")
        leaf.profile = nil; try context.save()
        check(query(spy, profileId: "B", spaceId: "S")!.map(\.guid) == ["other-profile"],
              "Clearing the relationship must exclude the row")
        leaf.profile = a; try context.save()
        leaf.lastSeen = Date(); try context.save()
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["leaf", "folder", "scalar-disagrees"],
              "Visit metadata must not change query membership or ordering")
        leaf.spaceId = "T"
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["folder", "scalar-disagrees"],
              "Pending Space edits must leave the old Space query")
        check(query(spy, profileId: "A", spaceId: "T")!.map(\.guid) == ["other-space", "leaf"],
              "Pending Space edits must enter the new Space query")
        try context.save()
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["folder", "scalar-disagrees"],
              "Moving a bookmark must remove it from its old Space")
        check(query(spy, profileId: "A", spaceId: "T")!.map(\.guid) == ["other-space", "leaf"],
              "Moving a bookmark must include it in its new Space")
        context.delete(first[1]); try context.save()
        check(query(spy, profileId: "A", spaceId: "S")!.map(\.guid) == ["scalar-disagrees"],
              "Deleted folders must leave the query")
        print("PASS: query membership/order/moves/deletes; \(checksFetchScope ? "out-of-scope rows excluded at fetch" : "baseline semantic oracle only")")
    }

    @MainActor static func benchmark() throws {
        let counts: [Int]
        if let index = CommandLine.arguments.firstIndex(of: "--benchmark-count") {
            counts = [Int(CommandLine.arguments[index + 1])!]
        } else { counts = [100, 773, 1000, 3002, 10000] }
        let distributions: [(name: String, spaces: Int, targetPercent: Int?)] =
            CommandLine.arguments.contains("--distribution-matrix")
            ? [("one-space", 1, nil), ("seven-even", 7, nil), ("seven-skewed-90-percent", 7, 90)]
            : [("seven-even", 7, nil)]
        for count in counts {
          for distribution in distributions {
            let store = try container()
            let context = store.mainContext
            let p = ProfileModel(profileId: "P")
            context.insert(p)
            for i in 0..<count {
                let space: Int
                if let percent = distribution.targetPercent {
                    let targetCount = count * percent / 100
                    space = i < targetCount ? 0 : 1 + (i - targetCount) % (distribution.spaces - 1)
                } else { space = i % distribution.spaces }
                row(context, "synthetic-\(i)", profile: p, space: "S\(space)", order: i)
            }
            try context.save()
            let spy = QueryContext(context)
            for _ in 0..<3 { _ = query(spy, profileId: "P", spaceId: "S0") }
            var samples: [Double] = []
            for _ in 0..<15 {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = query(spy, profileId: "P", spaceId: "S0")!
                let expected = distribution.targetPercent.map { count * $0 / 100 }
                    ?? ((count + distribution.spaces - 1) / distribution.spaces)
                check(result.count == expected, "Benchmark membership")
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let sorted = samples.sorted()
            let output: [String: Any] = ["nodes": count, "spaces": distribution.spaces,
                "distribution": distribution.name, "fetched": spy.fetchedCount,
                "samples_ms": samples, "median_ms": sorted[7], "min_ms": sorted[0], "max_ms": sorted[14],
                "backend": CommandLine.arguments.contains("--sqlite-directory") ? "SwiftData SQLite V14" : "SwiftData in-memory V14",
                "compiler": "swiftc \(ProcessInfo.processInfo.environment["BOOKMARK_QUERY_OPTIMIZATION"] ?? "-O")",
                "warmups": 3]
            print(String(data: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), encoding: .utf8)!)
            fflush(stdout)
          }
        }
    }

    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--benchmark") { try benchmark() }
        else { try regression() }
    }
}
