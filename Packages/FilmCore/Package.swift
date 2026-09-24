// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FilmCore",
    platforms: [.iOS(.v17)],        // scrollTargetBehavior/.topBarTrailing 等 iOS17 API；2026 年起无更低适配需求
    products: [
        .library(name: "FilmCore", targets: ["FilmCore"]),
        .library(name: "FilmUI", targets: ["FilmUI"]),
    ],
    targets: [
        .target(name: "FilmCore", path: "Sources/FilmCore",
                resources: [.copy("js/drpy"), .copy("Resources")]),
        .target(name: "FilmUI", dependencies: ["FilmCore"], path: "Sources/FilmUI"),
        .testTarget(name: "FilmCoreTests", dependencies: ["FilmCore"], path: "Tests/FilmCoreTests",
                    resources: [.copy("Fixtures")]),
    ]
)
