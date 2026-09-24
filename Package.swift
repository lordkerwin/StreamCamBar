// swift-tools-version:5.9
// For editor/Xcode support. Use ./build.sh to produce the .app bundle.
import PackageDescription

let package = Package(
    name: "StreamCamBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StreamCamBar",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
