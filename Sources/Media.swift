import AppKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct MediaItem: Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var name: String { url.lastPathComponent }
    var isVideo: Bool { ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) }
    static let extensions: Set<String> = ["jpg","jpeg","heic","heif","png","tif","tiff","gif","bmp","webp","avif","arw","srf","sr2","dng","cr2","cr3","crw","nef","nrw","orf","raf","rw2","pef","rwl","3fr","fff","iiq","mp4","mov","m4v"]
    static func read(_ url: URL) -> MediaItem {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return MediaItem(url: url, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
    }
    static func scan(_ folder: URL) throws -> [MediaItem] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]).filter {
            extensions.contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
        }.map(read).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct MetadataField: Codable, Equatable {
    let id: String
    let title: String
    var visible: Bool = true
    static let defaults: [MetadataField] = [
        .init(id:"date",title:"拍摄时间"), .init(id:"location",title:"拍摄地点"),
        .init(id:"make",title:"相机品牌"), .init(id:"model",title:"相机型号"),
        .init(id:"lensMake",title:"镜头品牌"), .init(id:"lens",title:"镜头型号"),
        .init(id:"aperture",title:"光圈"), .init(id:"shutter",title:"快门"),
        .init(id:"focal",title:"焦距"), .init(id:"iso",title:"ISO"),
        .init(id:"resolution",title:"分辨率"), .init(id:"size",title:"文件大小"),
        .init(id:"type",title:"文件格式"), .init(id:"duration",title:"视频时长"),
        .init(id:"modified",title:"修改时间",visible:false), .init(id:"path",title:"文件路径",visible:false)]
    static func load() -> [MetadataField] {
        guard let data = UserDefaults.standard.data(forKey:"metadataFields"), let fields = try? JSONDecoder().decode([MetadataField].self, from:data) else { return defaults }
        // 丢弃重复字段，并补充新版本字段。
        var seen = Set<String>()
        return fields.filter { field in defaults.contains(where:{$0.id == field.id}) && seen.insert(field.id).inserted } + defaults.filter { def in !fields.contains(where:{$0.id == def.id}) }
    }
    static func save(_ fields: [MetadataField]) { if let data = try? JSONEncoder().encode(fields) { UserDefaults.standard.set(data,forKey:"metadataFields") } }
}

final class MediaLoader {
    static let shared = MediaLoader()
    let queue = OperationQueue()
    private let cache = NSCache<NSString, NSImage>()
    init() { queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated; cache.totalCostLimit = 96 * 1024 * 1024 }
    func clearPending() { queue.cancelAllOperations() }
    static func source(_ url: URL) -> CGImageSource? { CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary) }
    static func decode(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = source(url) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:pixels, kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
    }
    func image(_ item: MediaItem, pixels: Int, completion: @escaping (NSImage?) -> Void) {
        let key = "\(item.url.path):\(item.modified.timeIntervalSince1970):\(pixels)" as NSString
        if let image = cache.object(forKey:key) { completion(image); return }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let cg: CGImage? = autoreleasepool {
                if item.isVideo {
                    let generator = AVAssetImageGenerator(asset:AVURLAsset(url:item.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width:pixels,height:pixels)
                    return try? generator.copyCGImage(at:.zero, actualTime:nil)
                }
                return Self.decode(item.url,pixels:pixels)
            }
            guard operation?.isCancelled == false else { return }
            let image = cg.map { NSImage(cgImage:$0,size:NSSize(width:$0.width,height:$0.height)) }
            if let image = image, let cg = cg, pixels <= 600 { self?.cache.setObject(image,forKey:key,cost:cg.bytesPerRow * cg.height) }
            DispatchQueue.main.async { completion(image) }
        }
        queue.addOperation(operation)
    }
    static func metadata(_ item: MediaItem) -> [String:String] {
        var result = ["size":ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file),"type":item.url.pathExtension.uppercased(),"path":item.url.path,"modified":DateFormatter.localizedString(from:item.modified,dateStyle:.medium,timeStyle:.medium)]
        if item.isVideo {
            let asset = AVURLAsset(url:item.url)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite { result["duration"] = String(format:"%02d:%02d",Int(seconds)/60,Int(seconds)%60) }
            if let track = asset.tracks(withMediaType:.video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                result["resolution"] = "\(Int(abs(size.width))) × \(Int(abs(size.height)))"
            }
            for meta in asset.commonMetadata {
                if meta.commonKey == .commonKeyCreationDate { result["date"] = meta.stringValue }
                if meta.commonKey == .commonKeyLocation { result["location"] = meta.stringValue }
                if meta.commonKey == .commonKeyMake { result["make"] = meta.stringValue }
                if meta.commonKey == .commonKeyModel { result["model"] = meta.stringValue }
            }
            return result
        }
        guard let src = source(item.url), let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [String:Any] else { return result }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String:Any] ?? [:]
        func value(_ dictionary: [String:Any], _ key: CFString) -> String? { dictionary[key as String].map { String(describing:$0) } }
        result["date"] = value(exif,kCGImagePropertyExifDateTimeOriginal) ?? value(tiff,kCGImagePropertyTIFFDateTime)
        result["make"] = value(tiff,kCGImagePropertyTIFFMake)
        result["model"] = value(tiff,kCGImagePropertyTIFFModel)
        result["lensMake"] = value(exif,kCGImagePropertyExifLensMake)
        result["lens"] = value(exif,kCGImagePropertyExifLensModel)
        for key in ["make","model","lensMake","lens"] {
            if let text = result[key], text.trimmingCharacters(in:CharacterSet(charactersIn:"- 0")).isEmpty { result.removeValue(forKey:key) }
        }
        if let n = exif[kCGImagePropertyExifFNumber as String] as? NSNumber, n.doubleValue > 0 { result["aperture"] = "ƒ/\(n)" }
        if let n = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber, n.doubleValue > 0 { result["shutter"] = n.doubleValue < 1 ? "1/\(Int((1 / n.doubleValue).rounded())) s" : "\(n) s" }
        if let n = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber, n.doubleValue > 0 { result["focal"] = "\(n) mm" }
        if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] { result["iso"] = values.map(\.stringValue).joined(separator:", ") }
        if let w = props[kCGImagePropertyPixelWidth as String], let h = props[kCGImagePropertyPixelHeight as String] { result["resolution"] = "\(w) × \(h)" }
        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double, let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let a = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -lat : lat
            let b = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -lon : lon
            result["location"] = String(format:"%.6f, %.6f",a,b)
        }
        return result
    }
}
