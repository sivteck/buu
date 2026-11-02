import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Errors thrown while preparing an image for upload.
public enum ImageProcessingError: LocalizedError {
    case unreadableImage
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The image could not be read"
        case .encodingFailed: return "The image could not be encoded"
        }
    }
}

/// Downscales and re-encodes images so they are cheap to upload.
public enum ImageProcessor {

    /// Maximum edge length of a prepared image.
    public static let defaultMaxDimension = 2048

    /// JPEG quality used when re-encoding.
    public static let defaultQuality = 0.82

    /// Prepare a raw image for sending to a model.
    ///
    /// Images are downscaled to ``maxDimension`` and re-encoded as JPEG, unless
    /// they have an alpha channel, in which case PNG is used so transparency is
    /// not flattened to black.
    public static func prepare(
        data: Data,
        maxDimension: Int = defaultMaxDimension,
        quality: Double = defaultQuality
    ) throws -> ImagePayload {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageProcessingError.unreadableImage
        }

        let inspectOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, inspectOptions as CFDictionary)
            as? [CFString: Any]
        let hasAlpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        // Small images that already fit are sent untouched: re-encoding them
        // would only lose quality.
        let detectedType = mimeType(for: data)
        let fitsSize = max(pixelWidth, pixelHeight) <= maxDimension
        let fitsBytes = data.count <= 1_500_000
        let alreadyPortable = detectedType == "image/jpeg" || detectedType == "image/png"
        if fitsSize, fitsBytes, alreadyPortable {
            return ImagePayload(mimeType: detectedType, data: data)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageProcessingError.unreadableImage
        }

        let usesPNG = hasAlpha
        let typeIdentifier = usesPNG ? "public.png" : "public.jpeg"

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, typeIdentifier as CFString, 1, nil) else {
            throw ImageProcessingError.encodingFailed
        }
        let destinationOptions: [CFString: Any] = usesPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.encodingFailed
        }

        return ImagePayload(mimeType: usesPNG ? "image/png" : "image/jpeg", data: encoded as Data)
        #else
        return ImagePayload(mimeType: mimeType(for: data), data: data)
        #endif
    }

    /// Pixel size of an image, when it can be determined.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
        #else
        return nil
        #endif
    }

    /// Best effort mime type detection from the magic bytes.
    public static func mimeType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return "application/octet-stream" }
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "image/png" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "image/gif" }
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 { return "image/webp" }
        if bytes[0] == 0x42, bytes[1] == 0x4D { return "image/bmp" }
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "image/heic"
        }
        return "application/octet-stream"
    }
}
