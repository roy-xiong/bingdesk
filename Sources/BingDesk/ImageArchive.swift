import Foundation
import CryptoKit
import ImageIO
import WallpaperCore

/// 管理用户永久收藏。此目录与可淘汰的临时缓存分离，永远不主动删除收藏图片。
actor ImageArchive {
    static var directory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("微软壁纸", isDirectory: true)
    }

    /// 采用临时文件加原子移动保存完整原图；同名但内容不同的用户文件会保留。
    func save(_ image: PreparedWallpaper) throws -> URL {
        try Task.checkCancellation()
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = String(image.wallpaper.title.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }.prefix(45).map(String.init).joined())
        let identity = SHA256.hash(data: Data(image.wallpaper.url.absoluteString.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let date = String(image.wallpaper.date.filter(\.isNumber).prefix(8))
        let name = "\(date)_\(title)_\(image.width)x\(image.height)_\(identity)"
        var destination = directory.appendingPathComponent(name + ".jpg")
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink != true, values.isRegularFile == true,
               try checksum(destination) == checksum(image.localURL) {
                return destination
            }
            destination = directory.appendingPathComponent(name + "_" + UUID().uuidString + ".jpg")
        }
        let temporary = directory.appendingPathComponent(".partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: image.localURL, to: temporary)
        try Task.checkCancellation()
        _ = try ImageValidator.dimensions(at: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// 分块比较原图，避免将完整的 4K 文件及其副本同时读入内存。
    private func checksum(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    /// ImageIO 直接生成小尺寸预览，不在界面解码或持有整张 4K 图片。
    func previewData(at url: URL) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 680,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}
