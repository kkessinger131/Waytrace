import Foundation
import Photos
import UIKit

/// Reads the photo library for the KML export and the daily road map: only photos and videos taken during the chosen
/// recordings (never screenshots), with their own location if they have one.
enum PhotoLibrary {
    enum Access { case allowed, limited, denied }

    /// The access granted so far, or nil if Waytrace hasn't asked yet.
    static var currentAccess: Access? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .allowed
        case .limited: return .limited
        case .notDetermined: return nil
        default: return .denied
        }
    }

    static func requestAccess() async -> Access {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized: return .allowed
        case .limited: return .limited
        default: return .denied
        }
    }

    /// Photos and videos taken between the two dates, oldest first.
    static func items(from start: Date, to end: Date) -> [PhotoInfo] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: options)
        var out: [PhotoInfo] = []
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video,
                  !asset.mediaSubtypes.contains(.photoScreenshot),
                  let taken = asset.creationDate else { return }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
                ?? (asset.mediaType == .video ? "Video" : "Photo")
            let loc = asset.location?.coordinate
            out.append(PhotoInfo(id: asset.localIdentifier, fileName: name, taken: taken,
                                 latitude: loc?.latitude, longitude: loc?.longitude, isVideo: asset.mediaType == .video))
        }
        return out
    }

    // MARK: - The Photos tab

    /// A photo or video with a location, for the Photos tab's map. No file name yet: looking
    /// those up is slow, so it's done only for the ones that need it.
    struct Spot: Equatable, Sendable {
        let id: String
        let taken: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let isVideo: Bool
    }

    /// Every photo and video in the library (never screenshots or hidden ones), oldest first:
    /// the ones with a location, and the times of the ones without.
    static func allSpots() -> (spots: [Spot], unlocated: [Date]) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        var spots: [Spot] = [], unlocated: [Date] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot), let taken = asset.creationDate else { return }
            guard let loc = asset.location else {
                unlocated.append(taken)
                return
            }
            spots.append(Spot(id: asset.localIdentifier, taken: taken,
                              latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                              altitude: loc.verticalAccuracy > 0 ? loc.altitude : nil,
                              isVideo: asset.mediaType == .video))
        }
        return (spots, unlocated)
    }

    /// File names without the extension (IMG_1234), by photo id.
    static func fileNames(for ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
                ?? (asset.mediaType == .video ? "Video" : "Photo")
            out[asset.localIdentifier] = (name as NSString).deletingPathExtension
        }
        return out
    }

    /// A small square picture of one photo, for the map's callout. Called on the main thread,
    /// possibly twice (a quick blurry one, then a sharp one).
    static func thumbnail(id: String, side: CGFloat, done: @escaping (UIImage?) -> Void) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            done(nil)
            return
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side * 3, height: side * 3),
                                              contentMode: .aspectFill, options: options) { image, _ in done(image) }
    }
}
