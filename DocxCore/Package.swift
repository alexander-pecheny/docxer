// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DocxCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "DocxCore", targets: ["DocxCore"])],
    targets: [
        .target(name: "DocxCore"),
        .testTarget(name: "DocxCoreTests", dependencies: ["DocxCore"]),
        .executableTarget(name: "docx-bench", dependencies: ["DocxCore"]),
    ],
    swiftLanguageModes: [.v5]
)
