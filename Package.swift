// swift-tools-version: 6.0
import PackageDescription

// Static libraries produced by `scripts/build.sh` / `scripts/release.sh` (CMake build of the
// SonyHeadphonesClient submodule). MDR_BUILD_DIR selects e.g. the universal release build.
let mdrBuild = Context.environment["MDR_BUILD_DIR"] ?? (Context.packageDirectory + "/build/mdr")

let package = Package(
    name: "SoundConnect",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CMDR",
            path: "Sources/CMDR",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(mdrBuild)/libmdr/src",
                    "-L\(mdrBuild)/libmdr-bt/src",
                    "-L\(mdrBuild)/_deps/fmt-build",
                    "-lmdr", "-lmdr-bt", "-lfmt",
                ]),
            ]
        ),
        .executableTarget(
            name: "SoundConnect",
            dependencies: ["CMDR"],
            path: "Sources/SoundConnect",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
