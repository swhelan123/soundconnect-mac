// swift-tools-version: 6.0
import PackageDescription

// Static libraries produced by `scripts/build.sh` (CMake build of the SonyHeadphonesClient submodule).
let mdrBuild = Context.packageDirectory + "/build/mdr"

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
