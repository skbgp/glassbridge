// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlassBridge", platforms: [.macOS(.v14)],
    products: [.executable(name: "GlassBridge", targets: ["GlassBridge"])],
    targets: [.executableTarget(name: "GlassBridge")], swiftLanguageModes: [.v5])
