// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidePanel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SidePanelCore", targets: ["SidePanelCore"]),
    ],
    targets: [
        // Tiny C shim around forkpty(3) / ioctl(2). Everything that has to happen
        // between fork() and exec() lives here, where it is async-signal-safe.
        .target(
            name: "CPTY",
            path: "Sources/CPTY",
            linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]
        ),
        // Platform-independent logic: VT/xterm emulator, PTY process, key encoding,
        // address resolution, bookmark/history stores. Foundation only — unit tested.
        .target(
            name: "SidePanelCore",
            dependencies: ["CPTY"],
            path: "Sources/SidePanelCore"
        ),
        .testTarget(
            name: "SidePanelCoreTests",
            dependencies: ["SidePanelCore"],
            path: "Tests/SidePanelCoreTests"
        ),
    ]
)

#if os(macOS)
// The macOS app: AppKit panel, SwiftUI interface, WebKit browser, terminal renderer.
// Declared only on macOS so the core can be built and tested on Linux CI too.
package.products.append(.executable(name: "SidePanel", targets: ["SidePanel"]))
package.targets.append(
        .executableTarget(
            name: "SidePanel",
            dependencies: ["SidePanelCore"],
            path: "Sources/SidePanel",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
)
#endif
