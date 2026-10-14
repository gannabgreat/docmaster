// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Convertly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Convertly", targets: ["Convertly"]),
        .executable(name: "convertly-cli", targets: ["convertly-cli"]),
    ],
    targets: [
        .target(name: "ConvertlyCore"),
        .executableTarget(name: "Convertly", dependencies: ["ConvertlyCore"]),
        .executableTarget(name: "convertly-cli", dependencies: ["ConvertlyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
