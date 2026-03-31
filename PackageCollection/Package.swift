// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhiDependencies",
    platforms: [
        .macOS(.v14) 
    ],
    products: [
        .library(
            name: "Dependencies",
            targets: ["Dependencies"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", exact: "5.10.2"),
        .package(url: "https://github.com/SnapKit/SnapKit.git", exact: "5.0.1"),
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", exact: "3.9.0"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", exact: "8.5.0"),
        .package(url: "https://github.com/auth0/Auth0.swift.git", exact: "2.18.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.8.0"),
        .package(url: "https://github.com/phibrowser/Settings.git", exact: "3.1.4"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "8.57.0"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", exact: "4.5.2"),
        .package(url: "https://github.com/Countly/countly-sdk-ios.git", exact: "25.4.8"),
        
    ],
    targets: [
         .target(
            name: "Dependencies",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
                .product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack"),
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "Auth0", package: "Auth0.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "Countly", package: "countly-sdk-ios"),
            ])
    ]
)
