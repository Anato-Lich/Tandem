// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BatteryCore", targets: ["BatteryCore"]),
        .executable(name: "tandemctl", targets: ["tandemctl"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibimobiledevice",
            path: "Sources/CLibimobiledevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice", "libplist"])]
        ),
        // Split out from CLibimobiledevice because libimobiledevice-1.0.pc lists
        // libusbmuxd under Requires.private, so its -L never reaches the link
        // line; its own .pc does supply it.
        .systemLibrary(
            name: "CLibusbmuxd",
            path: "Sources/CLibusbmuxd",
            pkgConfig: "libusbmuxd-2.0",
            providers: [.brew(["libusbmuxd"])]
        ),
        .systemLibrary(
            name: "COpenSSL",
            path: "Sources/COpenSSL",
            pkgConfig: "openssl",
            providers: [.brew(["openssl@3"])]
        ),
        .target(
            name: "CTandemTLS",
            dependencies: ["COpenSSL"],
            path: "Sources/CTandemTLS"
        ),
        .target(
            name: "BatteryCore",
            dependencies: ["CLibimobiledevice", "CLibusbmuxd", "COpenSSL", "CTandemTLS"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "tandemctl",
            dependencies: ["BatteryCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BatteryCoreTests",
            dependencies: ["BatteryCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
