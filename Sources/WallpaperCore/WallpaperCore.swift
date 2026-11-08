import Foundation
import CryptoKit
import ImageIO

/// 壁纸来源元数据；URL 必须指向 Bing 原始 UHD 图片。
public struct Wallpaper: Codable, Hashable, Sendable {
    public let date: String
    public let title: String
    public let copyright: String
    public let urlbase: String
    public let url: URL
    public let uhd: Bool

    public init(date: String, title: String, copyright: String, urlbase: String, url: URL, uhd: Bool) {
        self.date = date
        self.title = title
        self.copyright = copyright
        self.urlbase = urlbase
        self.url = url
        self.uhd = uhd
    }
}

/// 已通过真实像素验证的磁盘原图，不持有解码位图。
public struct PreparedWallpaper: Sendable {
    public let wallpaper: Wallpaper
    public let localURL: URL
    public let width: Int
    public let height: Int
}

/// 图片头中声明的真实像素尺寸。
public struct ImageDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int
}

/// 由缓存扫描产生的纯值条目。
public struct CacheEntry: Sendable {
    public let url: URL
    public let byteCount: Int64
    public let lastAccess: Date
    public init(url: URL, byteCount: Int64, lastAccess: Date) {
        self.url = url
        self.byteCount = byteCount
        self.lastAccess = lastAccess
    }
}

/// 可恢复失败；调用方应保留上一次已成功设置的壁纸。
public enum WallpaperError: Error, LocalizedError, Sendable {
    case invalidImage
    case insufficientResolution
    case invalidURL
    case invalidResponse
    case noCandidates
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "图片文件无效，无法读取真实尺寸"
        case .insufficientResolution: return "图片真实尺寸不足 3840 × 2160"
        case .invalidURL: return "壁纸地址不是有效的 Bing UHD 原图"
        case .invalidResponse: return "壁纸来源返回了无效响应"
        case .noCandidates: return "暂时没有可用的 UHD 壁纸"
        case .fileTooLarge: return "图片文件超过允许的下载大小"
        }
    }
}

/// 最低原生像素策略，不允许缩放补足分辨率。
public enum ResolutionPolicy {
    public static func accepts(width: Int, height: Int) -> Bool { width >= 3840 && height >= 2160 }
}

/// 自动每日检查策略；失败不更新成功时间，允许在稍后重试。
public enum DailySchedule {
    public static func shouldCheck(now: Date, lastSuccess: Date?, lastManual: Date?, enabled: Bool,
                                   calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        return ![lastSuccess, lastManual].compactMap { $0 }.contains {
            calendar.isDate($0, inSameDayAs: now)
        }
    }
}

/// 固定间隔轮换策略；切换成功后由调用方更新锚点时间。
public enum IntervalSchedule {
    public static func shouldSwitch(now: Date, lastSwitch: Date?, interval: TimeInterval, enabled: Bool) -> Bool {
        guard enabled, interval.isFinite, interval > 0, now.timeIntervalSince1970.isFinite else { return false }
        guard let lastSwitch else { return true }
        let elapsed = now.timeIntervalSince(lastSwitch)
        return elapsed.isFinite && elapsed >= interval
    }
}

/// 缓存淘汰纯策略；受保护文件优先于空间和数量限制，绝不牺牲正在使用的文件。
public enum CachePolicy {
    public static func evictions(entries: [CacheEntry], protectedURLs: Set<URL>, maxCount: Int = 10,
                                 maxBytes: Int64 = 209715200) -> [URL] {
        let protected = Set(protectedURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let sorted = entries.sorted {
            $0.lastAccess == $1.lastAccess ? $0.url.path < $1.url.path : $0.lastAccess < $1.lastAccess
        }
        var count = entries.count
        // Double 避免损坏/异常文件元数据导致 Int64 累加溢出。
        var bytes = entries.reduce(0.0) { $0 + Double(max(0, $1.byteCount)) }
        var result: [URL] = []
        for entry in sorted {
            guard count > max(0, maxCount) || bytes > Double(max(0, maxBytes)) else { break }
            guard !protected.contains(entry.url.standardizedFileURL.resolvingSymlinksInPath()) else { continue }
            result.append(entry.url)
            count -= 1
            bytes -= Double(max(0, entry.byteCount))
        }
        return result
    }
}

/// 网络入口仅允许固定 Bing 主机与无缩放参数的原始 UHD 图片地址。
public enum WallpaperURL {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              ["www.bing.com", "bing.com", "cn.bing.com", "global.bing.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.path == "/th", parts.fragment == nil,
              let items = parts.queryItems, items.count == 1,
              items.first?.name == "id", let identifier = items.first?.value,
              identifier.hasPrefix("OHR."), identifier.hasSuffix("_UHD.jpg") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return identifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 仅从可信主机相对 urlbase 构造 UHD URL；忽略来源中的低清 URL。
    fileprivate static func original(from base: String) -> URL? {
        guard base.hasPrefix("/th?id=OHR."),
              let parts = URLComponents(string: "https://www.bing.com" + base),
              parts.queryItems?.count == 1, let identifier = parts.queryItems?.first?.value,
              !identifier.contains("_UHD"), !identifier.hasSuffix(".jpg"),
              let url = URL(string: "https://www.bing.com/th?id=" + identifier + "_UHD.jpg"),
              isAllowed(url) else { return nil }
        return url
    }
}

/// 官方与历史归档来源解析；坏条目单独跳过，JSON 结构错误则报告给调用方。
public enum WallpaperParser {
    public static func latest(from data: Data) throws -> [Wallpaper] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["images"] as? [[String: Any]] else { throw WallpaperError.invalidResponse }
        return parse(items: items, official: true)
    }

    public static func archive(from data: Data) throws -> [Wallpaper] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw WallpaperError.invalidResponse
        }
        return parse(items: items, official: false)
    }

    public static func archiveYears(from data: Data) throws -> [Int] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw WallpaperError.invalidResponse
        }
        let years = items.compactMap { item -> Int? in
            guard item["uhd"] as? Bool == true, let date = item["date"] as? String, validDate(date) else { return nil }
            return Int(date.prefix(4))
        }
        return Set(years).sorted(by: >)
    }

    /// 用公历组件回读验证日期，拒绝 2 月 30 日等自动进位日期。
    static func validDate(_ text: String) -> Bool {
        guard text.utf8.count == 8, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let year = Int(text.prefix(4)), let month = Int(text.dropFirst(4).prefix(2)),
              let day = Int(text.suffix(2)), year >= 2000 && year <= 2100 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard let value = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: value)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private static func parse(items: [[String: Any]], official: Bool) -> [Wallpaper] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard official || item["uhd"] as? Bool == true,
                  let date = item[official ? "startdate" : "date"] as? String, validDate(date),
                  let base = item["urlbase"] as? String, let url = WallpaperURL.original(from: base),
                  seen.insert(date).inserted else { return nil }
            return Wallpaper(date: date, title: item["title"] as? String ?? "Bing 每日壁纸",
                             copyright: item["copyright"] as? String ?? "", urlbase: base, url: url, uhd: true)
        }.sorted { $0.date > $1.date }
    }
}

/// 仅读取磁盘 ImageIO 元数据，不把 UHD 原图解码到界面内存。
public enum ImageValidator {
    public static func dimensions(at url: URL) throws -> ImageDimensions {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw WallpaperError.invalidImage }
        guard ResolutionPolicy.accepts(width: width, height: height) else { throw WallpaperError.insufficientResolution }
        return ImageDimensions(width: width, height: height)
    }
}

/// 网络请求与缓存归单一 actor 所有；下载跨越 await，调用方仍应串行执行整套桌面切换事务。
public actor WallpaperService {
    private let cacheDirectory: URL
    private let session: URLSession
    private let fileManager = FileManager.default
    private let maximumImageBytes: Int64 = 100 * 1024 * 1024

    /// - Parameter cacheDirectory: 自定义缓存根目录；默认放在 Application Support，绝不扫描永久下载归档。
    public init(cacheDirectory: URL? = nil) {
        let root = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("BingDesk/Wallpapers", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("BingDesk/Wallpapers", isDirectory: true)
        self.cacheDirectory = root.standardizedFileURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    /// 获取官方最近八张图片元数据；实际 UHD 尺寸在 prepare 时核验。
    public func latestCandidates() async throws -> [Wallpaper] {
        guard let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=zh-CN") else {
            throw WallpaperError.invalidURL
        }
        let candidates = try WallpaperParser.latest(from: await fetch(url))
        guard !candidates.isEmpty else { throw WallpaperError.noCandidates }
        return Array(candidates.prefix(8))
    }

    /// 只下载索引和最多三个随机年份 JSON；最多返回十二个真实 UHD 候选，不下载整个图片仓库。
    public func randomCandidates(excludingDate: String?) async throws -> [Wallpaper] {
        let index = try await archiveData(file: "index.json")
        let years = try WallpaperParser.archiveYears(from: index).shuffled().prefix(3)
        var result: [Wallpaper] = []
        for year in years {
            try Task.checkCancellation()
            do {
                let data = try await archiveData(file: "\(year).json")
                result.append(contentsOf: try WallpaperParser.archive(from: data).filter { $0.date != excludingDate }.shuffled())
                if result.count >= 12 { break }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // 某年份损坏或不可用时允许继续有限的其他年份。
            }
        }
        guard !result.isEmpty else { throw WallpaperError.noCandidates }
        return Array(result.shuffled().prefix(12))
    }

    /// 将原图流式下载到磁盘并读取真实尺寸；成功前不改变系统桌面或持久化所选状态。
    public func prepare(_ wallpaper: Wallpaper, protectedURLs: Set<URL>) async throws -> PreparedWallpaper {
        try Task.checkCancellation()
        guard wallpaper.uhd, WallpaperParser.validDate(wallpaper.date), WallpaperURL.isAllowed(wallpaper.url) else {
            throw WallpaperError.invalidURL
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(wallpaper.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = cacheDirectory.appendingPathComponent("\(wallpaper.date)-\(digest).jpg")
        if fileManager.fileExists(atPath: destination.path),
           let dimensions = try? ImageValidator.dimensions(at: destination) {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            try cleanCache(protectedURLs: protectedURLs.union([destination]))
            return PreparedWallpaper(wallpaper: wallpaper, localURL: destination, width: dimensions.width, height: dimensions.height)
        }
        let (temporary, response) = try await session.download(for: URLRequest(url: wallpaper.url))
        defer { try? fileManager.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = http.url, WallpaperURL.isAllowed(finalURL) else { throw WallpaperError.invalidResponse }
        let attributes = try fileManager.attributesOfItem(atPath: temporary.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= maximumImageBytes else { throw WallpaperError.fileTooLarge }
        let dimensions = try ImageValidator.dimensions(at: temporary)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            // 同 URL 在 actor 挂起期间可能已由另一个调用保存。替换必须原子化，避免半文件。
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        try cleanCache(protectedURLs: protectedURLs.union([destination]))
        return PreparedWallpaper(wallpaper: wallpaper, localURL: destination, width: dimensions.width, height: dimensions.height)
    }

    /// 主源不可用时使用 GitHub raw 同文件回退；单次最多两个请求，取消不会触发重试。
    private func archiveData(file: String) async throws -> Data {
        var lastError: any Error = WallpaperError.invalidResponse
        for base in ["https://ygn-bing-wallpaper.pages.dev/data/", "https://raw.githubusercontent.com/YanGN-ST/bing_wallpaper_archive/main/data/"] {
            try Task.checkCancellation()
            guard let url = URL(string: base + file) else { continue }
            do { return try await fetch(url) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    /// JSON 上限八 MiB，避免把大型或错误响应交给解析器。
    private func fetch(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: URLRequest(url: url))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw WallpaperError.invalidResponse }
        return data
    }

    /// 只扫描自身缓存目录的标准命名普通文件；不递归，不跟随符号链接，不接触 Downloads 归档。
    private func cleanCache(protectedURLs: Set<URL>) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys))
        let entries = urls.compactMap { url -> CacheEntry? in
            let name = url.lastPathComponent
            guard name.range(of: #"^[0-9]{8}-[a-f0-9]{64}\.jpg$"#, options: .regularExpression) != nil,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return CacheEntry(url: url, byteCount: Int64(values.fileSize ?? 0), lastAccess: values.contentModificationDate ?? .distantPast)
        }
        for url in CachePolicy.evictions(entries: entries, protectedURLs: protectedURLs) {
            // 删除失败显式抛出，避免错误地宣称已经满足缓存上限。
            try fileManager.removeItem(at: url)
        }
    }
}
