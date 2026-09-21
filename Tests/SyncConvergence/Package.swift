// swift-tools-version:5.9
//
// Hostless convergence harness for the encrypted-sync merge core.
//
// One target: the production merge sources are symlinked in under
// Sources/SyncConvergence/PhiSyncCore, so the harness sees them with the same
// `internal` visibility they have inside the app target -- no `public`
// annotations and no `@testable` build flags are needed, and nothing under
// Sources/ is copied or modified.
//
// SwiftProtobuf is a LOCAL path dependency (Tests/SyncConvergence/.deps is a
// symlink the build script points at an existing checkout of the exact version
// Phi.xcodeproj pins), so the harness needs no network at test time.
import PackageDescription

let package = Package(
    name: "SyncConvergence",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "SwiftProtobuf", path: ".deps/swift-protobuf"),
    ],
    targets: [
        .executableTarget(
            name: "SyncConvergence",
            dependencies: [.product(name: "SwiftProtobuf", package: "SwiftProtobuf")],
            path: "Sources/SyncConvergence"
        ),
    ]
)
