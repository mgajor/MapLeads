// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MapLeads",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MapLeads", targets: ["MapLeads"])],
    targets: [.executableTarget(name: "MapLeads")]
)
