// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibreLibreLink",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LibreKit", targets: ["LibreKit"]),
        .executable(name: "LibreLibreLink", targets: ["LibreLibreLink"]),
        .executable(name: "llu", targets: ["llu"]),
    ],
    targets: [
        // Cliente LibreLinkUp + modelos. Compartible con una futura app iOS.
        .target(name: "LibreKit"),
        // App de barra de menú (MenuBarExtra).
        .executableTarget(name: "LibreLibreLink", dependencies: ["LibreKit"]),
        // CLI para probar credenciales y la API sin interfaz.
        .executableTarget(name: "llu", dependencies: ["LibreKit"]),
        .testTarget(name: "LibreKitTests", dependencies: ["LibreKit"]),
    ]
)
