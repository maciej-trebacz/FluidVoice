// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nemotron",
    platforms: [.macOS("15.0")],
    products: [.library(name: "CNemotron", targets: ["CNemotron"])],
    targets: [.target(name: "CNemotron", publicHeadersPath: "include")]
)
