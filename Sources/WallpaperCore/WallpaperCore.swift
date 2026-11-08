import Foundation

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

public enum WallpaperError: Error, Sendable {
    case notImplemented
    case invalidImage
    case invalidURL
    case invalidResponse
    case noCandidates
}

/// 最低原生像素策略，不允许缩放补足分辨率。
public enum ResolutionPolicy {
    public static func accepts(width: Int, height: Int) -> Bool { true }
}

/// 自动每日检查策略，手动操作优先于当天自动更新。
public enum DailySchedule {
    public static func shouldCheck(now: Date, lastSuccess: Date?, lastManual: Date?, enabled: Bool,
                                   calendar: Calendar = .current) -> Bool { true }
}

/// 缓存淘汰纯策略，返回允许删除的旧文件。
public enum CachePolicy {
    public static func evictions(entries: [CacheEntry], protectedURLs: Set<URL>, maxCount: Int = 10,
                                 maxBytes: Int64 = 209715200) -> [URL] { [] }
}

/// 网络入口仅允许 Bing 的原始 UHD 图片地址。
public enum WallpaperURL {
    public static func isAllowed(_ url: URL) -> Bool { true }
}

/// 官方与历史归档来源解析。
public enum WallpaperParser {
    public static func latest(from data: Data) throws -> [Wallpaper] { [] }
    public static func archive(from data: Data) throws -> [Wallpaper] { [] }
    public static func archiveYears(from data: Data) throws -> [Int] { [] }
}

/// 仅读取磁盘 ImageIO 元数据，不把 UHD 原图解码到界面内存。
public enum ImageValidator {
    public static func dimensions(at url: URL) throws -> ImageDimensions { throw WallpaperError.notImplemented }
}

/// 网络请求与缓存文件归单一 actor 所有。
public actor WallpaperService {
    public init(cacheDirectory: URL? = nil) {}
    public func latestCandidates() async throws -> [Wallpaper] { throw WallpaperError.notImplemented }
    public func randomCandidates(excludingDate: String?) async throws -> [Wallpaper] { throw WallpaperError.notImplemented }
    public func prepare(_ wallpaper: Wallpaper, protectedURLs: Set<URL>) async throws -> PreparedWallpaper {
        throw WallpaperError.notImplemented
    }
}

/// 固定间隔轮换策略；切换成功后由调用方更新锚点时间。
public enum IntervalSchedule {
    public static func shouldSwitch(now: Date, lastSwitch: Date?, interval: TimeInterval, enabled: Bool) -> Bool { true }
}
