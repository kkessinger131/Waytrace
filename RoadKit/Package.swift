// swift-tools-version: 5.9
//
// RoadKit: the road_to_kml engine (road_to_kml.py, road_aliases.py, road_tracks.py,
// county_fips.py, mirror_stats.py) ported to Swift for the Waytrace app.
// It has no UI and builds on iOS, macOS and Linux, so its tests run anywhere.

import PackageDescription

let package = Package(
    name: "RoadKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoadKit", targets: ["RoadKit"]),
    ],
    dependencies: [
        // GEOS 3.14, the geometry engine Shapely is built on.
        .package(url: "https://github.com/GEOSwift/geos.git", exact: "11.0.0"),
        // Reading the Census Bureau's TIGER/Line zip files.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "RoadKit",
            dependencies: [
                .product(name: "geos", package: "geos"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "RoadKitTests",
            dependencies: [
                "RoadKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            // aliases.zip: ~27,000 names worked out by road_aliases.py, for AliasParityTests.
            resources: [.copy("Fixtures")]
        ),
    ]
)
