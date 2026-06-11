// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-pjsip-gen",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PJSIPSwiftGenCore",
            targets: ["PJSIPSwiftGenCore"]
        ),
        .executable(
            name: "pjsip-swift-gen",
            targets: ["pjsip-swift-gen"]
        ),
        .plugin(
            name: "PJSIPSwiftGenPlugin",
            targets: ["PJSIPSwiftGenPlugin"]
        ),
        .plugin(
            name: "PJSIPSwiftGenCommand",
            targets: ["PJSIPSwiftGenCommand"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/laconicman/swift-pjsip",
            branch: "main"
        )
    ],
    targets: [
        .target(
            name: "PJSIPSwiftGenCore"
        ),
        .executableTarget(
            name: "pjsip-swift-gen",
            dependencies: ["PJSIPSwiftGenCore"]
        ),
        .plugin(
            name: "PJSIPSwiftGenPlugin",
            capability: .buildTool(),
            dependencies: ["pjsip-swift-gen"]
        ),
        .plugin(
            name: "PJSIPSwiftGenCommand",
            capability: .command(
                intent: .custom(
                    verb: "generate-pjsip-helpers",
                    description: "Generate Swift helpers (extensions, conformances) from PJSIP C headers."
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Write generated Swift files back into the package source directory."
                    )
                ]
            ),
            dependencies: ["pjsip-swift-gen"]
        ),
        .testTarget(
            name: "PJSIPSwiftGenCoreTests",
            dependencies: ["PJSIPSwiftGenCore"]
        )
    ]
)
