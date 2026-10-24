// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AMG65",
    platforms: [.macOS(.v14)],
    targets: [
        // libusb (Homebrew) — used only to reach the LCD's bulk interface, which macOS leaves driverless.
        .systemLibrary(name: "CLibUSB", path: "Sources/CLibUSB"),
        .executableTarget(
            name: "AMG65",
            dependencies: ["CLibUSB"],
            path: "Sources/AMG65",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .unsafeFlags(["-L/opt/homebrew/lib"]),
            ]
        ),
    ]
)
