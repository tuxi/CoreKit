// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CoreKit",
    platforms: [
         .iOS(.v17)
     ],
    products: [
        .library(
            name: "CoreKit",
            targets: ["CoreKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.6.0"),
    ],
    targets: [
        .target(
            name: "CoreKit",
            dependencies: [
                "Alamofire"
            ],
            path: "Sources/CoreKit"
        ),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit"],
            path: "Tests/CoreKitTests"
        ),

    ]
)
