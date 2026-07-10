// swift-tools-version: 5.9
import PackageDescription

// A tiny C-callable shim over TagLib (the copy bundled by CXXTagLib) that does
// SURGICAL, lossless tag edits — changing only the artist frame and preserving
// the ID3 version and every other frame. This is deliberately not SFBAudioEngine's
// high-level model, which rewrites the whole tag and drops fields it doesn't model.
let package = Package(
    name: "MDTagShim",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MDTagShim", targets: ["MDTagShim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/CXXTagLib", .upToNextMinor(from: "2.3.0")),
    ],
    targets: [
        .target(name: "MDTagShim",
                dependencies: [.product(name: "taglib", package: "CXXTagLib")]),
    ],
    cxxLanguageStandard: .cxx17
)
