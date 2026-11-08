# WallpaperCore API 合约

Swift 6 / macOS 13；所有公开值类型均为 Sendable，核心不引用 AppKit。

- `Wallpaper: Codable, Hashable, Sendable`：`date: String`（yyyyMMdd）、`title: String`、`copyright: String`、`urlbase: String`、`url: URL`（原始 UHD）、`uhd: Bool`；公开初始化器同名参数。
- `PreparedWallpaper: Sendable`：`wallpaper: Wallpaper`, `localURL: URL`, `width: Int`, `height: Int`。
- `WallpaperService` actor：`init(cacheDirectory: URL? = nil)` 默认 Application Support/BingDesk/Wallpapers；`latestCandidates() async throws -> [Wallpaper]`、`randomCandidates(excludingDate: String?) async throws -> [Wallpaper]`（有限候选，上限 12）、`prepare(_ wallpaper: Wallpaper, protectedURLs: Set<URL>) async throws -> PreparedWallpaper`。图片从 URLSession 下载到临时磁盘，验证真实尺寸，再原子移入缓存；缓存命中仍重新校验；执行淘汰时保护传入的所有屏幕当前 URL 和本次准备文件。
- `ResolutionPolicy.accepts(width: Int, height: Int) -> Bool`。
- `ImageValidator.dimensions(at: URL) throws -> ImageDimensions`：ImageIO 只读取磁盘元数据，要求 >=3840×2160。
- `DailySchedule.shouldCheck(now: Date, lastSuccess: Date?, lastManual: Date?, enabled: Bool, calendar: Calendar = .current) -> Bool`：自动关闭或当天成功/手动换过则 false；失败不写成功时间，允许重试。恢复最新按钮由 App 显式调用，不受该策略限制。
- `CacheEntry(url: URL, byteCount: Int64, lastAccess: Date)`；`CachePolicy.evictions(entries: [CacheEntry], protectedURLs: Set<URL>, maxCount: Int = 10, maxBytes: Int64 = 209715200) -> [URL]`：按旧到新删除，无法满足限制时保留受保护文件。
- `WallpaperParser.latest(from: Data) throws -> [Wallpaper]`；`archive(from: Data) throws -> [Wallpaper]`；`archiveYears(from: Data) throws -> [Int]`。无效日期、URL 或非 UHD 条目跳过。
- `WallpaperURL.isAllowed(_ url: URL) -> Bool`：仅 HTTPS Bing 域名、`/th` 路径与 UHD `id` 参数，拒绝其他远程输入。

所有失败用 Error 抛出，取消沿用 CancellationError；App 负责逐候选有限重试和设置壁纸后的持久化，不在失败时更改系统桌面。下载和来源请求均使用有限超时。缩略图生成属于 App。

- `IntervalSchedule.shouldSwitch(now: Date, lastSwitch: Date?, interval: TimeInterval, enabled: Bool) -> Bool`：正数且有限的秒间隔；无历史时 true，达到间隔时 true；锚点在未来、关闭或无效间隔为 false。App 成功手动换图后重置锚点。
- 永久归档由 App 负责：将 prepare 结果复制到 `~/Downloads/微软壁纸`，桌面使用永久文件。核心仅扫描和删除自身 Application Support 缓存目录的文件，绝不扫描或删除 Downloads。
