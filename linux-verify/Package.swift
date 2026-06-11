// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "verify",
    targets: [
        .target(name: "PureLogic"),
        .testTarget(name: "PureLogicTests", dependencies: ["PureLogic"]),
    ]
)
