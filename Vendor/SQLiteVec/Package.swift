// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SQLiteVec",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SQLiteVec", targets: ["SQLiteVec"]),
    ],
    targets: [
        .target(
            name: "SQLiteVec",
            path: "Sources/SQLiteVec",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
