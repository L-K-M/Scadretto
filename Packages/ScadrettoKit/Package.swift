// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScadrettoKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScadrettoCore", targets: ["ScadrettoCore"]),
        .library(name: "ScadrettoSyntax", targets: ["ScadrettoSyntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/tree-sitter.git", revision: "7f534862c3ec939c3a6ee147f7600ef5c1bf900f"),
        .package(url: "https://github.com/openscad/tree-sitter-openscad.git", revision: "4c36a4fb569688c97cfa28090031e039a6079244"),
    ],
    targets: [
        .target(name: "ScadrettoCore"),
        .target(
            name: "ScadrettoSyntax",
            dependencies: [
                "ScadrettoCore",
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterOpenscad", package: "tree-sitter-openscad"),
            ]
        ),
        .testTarget(name: "ScadrettoCoreTests", dependencies: ["ScadrettoCore"]),
        .testTarget(name: "ScadrettoSyntaxTests", dependencies: ["ScadrettoSyntax", "ScadrettoCore"]),
    ]
)
