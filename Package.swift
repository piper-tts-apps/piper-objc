// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "piper-objc",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "piper-objc",
            targets: [
                "piper-objc"
            ]),
        .library(name: "piper-player",
                 targets: [
                    "piper-player"
                 ])
    ],
    dependencies: [
        .package(url: "https://github.com/piper-tts-apps/piper1-gpl-spm.git",
                 from: "0.1.20"),
        .package(url: "https://github.com/piper-tts-apps/espeak-ng-spm.git",
                 from: "2026.09.11")
    ],
    targets: [
        .target(
            name: "piper-objc",
            dependencies: [
                .product(name: "piper1-gpl", package: "piper1-gpl-spm"),
                .product(name: "espeak-ng-data", package: "espeak-ng-spm"),
                .target(name: "piper-utils")
            ],
            path: "Sources/piper-objc",
            cxxSettings: [
                .headerSearchPath("utils"),
                .unsafeFlags(["-fmodules", "-fcxx-modules"])
            ]
        ),
        .target(name: "piper-utils"),
        .target(
            name: "piper-player",
            dependencies: [
                .target(name: "piper-objc")
            ]
        ),
        .testTarget(
            name: "piper-objc-tests",
            dependencies: [
                .target(name: "piper-utils"),
                .target(name: "piper-objc")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
