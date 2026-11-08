import Foundation
import Photos

/// Reads the photo library for the photo map: only photos and videos taken during the chosen
/// recordings (never screenshots), with their own location if they have one.
enum PhotoLibrary {
    enum Access { case allowed, limited, denied }

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
}
