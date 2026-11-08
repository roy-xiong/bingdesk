import AppKit
import Foundation
import Combine
import ServiceManagement
import WallpaperCore

enum SwitchMode: String, Codable, CaseIterable {
    case daily, interval
}

struct SavedWallpaper: Codable, Sendable {
    let wallpaper: Wallpaper
    let localURL: URL
    let width: Int
    let height: Int
    let appliedAt: Date
}

struct Preferences: Codable {
    var automatic = true
    var mode: SwitchMode = .daily
    var intervalMinutes = 60
    var lastDailySuccess: Date?
    var lastManual: Date?
    var lastSwitch: Date?
    var current: SavedWallpaper?
}

enum ChangeKind { case latest, random }

/// 菜单栏应用的唯一状态拥有者。界面、偏好和系统桌面操作均在主线程进行。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var preferences: Preferences
    @Published private(set) var preview: NSImage?
    @Published private(set) var busy = false
    @Published private(set) var status = "准备就绪"
    @Published private(set) var lastError: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false

    private let service = WallpaperService()
    private let archive = ImageArchive()
    private var operation: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastAttempt: Date?
    private var started = false
    private let defaults: UserDefaults
    private static let settingsKey = "BingDesk.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.settingsKey)
        var value = saved.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        value.intervalMinutes = min(10080, max(1, value.intervalMinutes))
        preferences = value
        refreshLoginStatus()
    }

    /// 启动后立即补检查；一次性定时器按下一次到期时间调度，休眠不会唤醒电脑。
    func start() {
        guard !started else { return }
        started = true
        refreshPreview()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomatic() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomatic() }
        })
        checkAutomatic()
    }

    /// 显式结束拥有的任务、定时器和通知观察，防止退出流程继续写入状态。
    func stop() {
        started = false
        operation?.cancel()
        previewTask?.cancel()
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    func setAutomatic(_ enabled: Bool) {
        preferences.automatic = enabled
        persist()
        checkAutomatic()
    }

    func setMode(_ mode: SwitchMode) {
        preferences.mode = mode
        // 更改模式从当前时刻重新计时，不立即覆盖用户刚选择的图片。
        if mode == .interval { preferences.lastSwitch = Date() }
        persist()
        armTimer()
    }

    @discardableResult
    func setInterval(_ minutes: Int) -> Bool {
        guard (1...10080).contains(minutes) else {
            lastError = "切换间隔请输入 1～10080 分钟。"
            return false
        }
        preferences.intervalMinutes = minutes
        preferences.lastSwitch = Date()
        lastError = nil
        persist()
        armTimer()
        return true
    }

    func request(_ kind: ChangeKind) {
        guard operation == nil, !busy else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            _ = await self.change(kind, manual: true)
            self.operation = nil
            self.armTimer()
        }
    }

    /// 单次更换的事务：候选下载与校验 → 永久保存 → 设置全部当前屏幕 → 提交状态。
    /// 任一步失败均不提交新元数据；屏幕设置部分失败时尽量回滚已经修改的屏幕。
    @discardableResult
    func change(_ kind: ChangeKind, manual: Bool) async -> Bool {
        guard !busy else { return false }
        busy = true
        lastError = nil
        status = kind == .latest ? "正在获取最新 4K 壁纸…" : "正在寻找另一张 4K 壁纸…"
        defer { busy = false }
        do {
            let candidates: [Wallpaper]
            switch kind {
            case .latest: candidates = try await service.latestCandidates()
            case .random: candidates = try await service.randomCandidates(excludingDate: preferences.current?.wallpaper.date)
            }
            guard !candidates.isEmpty else { throw AppFailure.message("暂时没有可用的 4K 原图，请稍后重试。") }
            var candidateError: Error?
            for wallpaper in candidates.prefix(6) {
                try Task.checkCancellation()
                let prepared: PreparedWallpaper
                do {
                    let protected = Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) })
                    prepared = try await service.prepare(wallpaper, protectedURLs: protected)
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    candidateError = error
                    continue
                }
                // 文件夹授权或磁盘错误不应连续尝试其他候选，以免重复触发系统提示。
                status = "正在保存原图并设置桌面…"
                let permanentURL = try await archive.save(prepared)
                try Task.checkCancellation()
                try setDesktop(permanentURL)
                let now = Date()
                preferences.current = SavedWallpaper(wallpaper: wallpaper, localURL: permanentURL,
                    width: prepared.width, height: prepared.height, appliedAt: now)
                preferences.lastSwitch = now
                if manual { preferences.lastManual = now }
                if kind == .latest { preferences.lastDailySuccess = now }
                lastAttempt = nil
                persist()
                refreshPreview()
                status = "已设置 · \(prepared.width) × \(prepared.height)"
                return true
            }
            throw candidateError ?? AppFailure.message("候选图片均不满足 4K 要求，已保留原壁纸。")
        } catch is CancellationError {
            status = "已取消，保留当前壁纸"
            return false
        } catch {
            lastError = error.localizedDescription
            status = "更换未完成，已保留原壁纸"
            return false
        }
    }

    /// macOS 要求此接口从主线程调用；所有屏幕先保存旧值，避免多屏设置部分成功。
    private func setDesktop(_ url: URL) throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw AppFailure.message("未找到可设置壁纸的显示器。") }
        let snapshots = screens.map { screen in
            (screen, NSWorkspace.shared.desktopImageURL(for: screen), NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        }
        var applied = 0
        do {
            for screen in screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: false
                ])
                applied += 1
            }
        } catch {
            for snapshot in snapshots.prefix(applied) {
                if let oldURL = snapshot.1 {
                    try? NSWorkspace.shared.setDesktopImageURL(oldURL, for: snapshot.0, options: snapshot.2)
                }
            }
            throw error
        }
    }

    func checkAutomatic() {
        timer?.invalidate()
        timer = nil
        guard started, preferences.automatic, operation == nil, !busy else { armTimer(); return }
        let now = Date()
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 300 { armTimer(); return }
        let due: Bool
        switch preferences.mode {
        case .daily:
            due = DailySchedule.shouldCheck(now: now, lastSuccess: preferences.lastDailySuccess,
                lastManual: preferences.lastManual, enabled: true)
        case .interval:
            due = IntervalSchedule.shouldSwitch(now: now, lastSwitch: preferences.lastSwitch,
                interval: TimeInterval(preferences.intervalMinutes * 60), enabled: true)
        }
        guard due else { armTimer(); return }
        lastAttempt = now
        let kind: ChangeKind = preferences.mode == .daily ? .latest : .random
        operation = Task { [weak self] in
            guard let self else { return }
            _ = await self.change(kind, manual: false)
            self.operation = nil
            self.armTimer()
        }
    }

    private func nextDueDate() -> Date {
        let now = Date()
        if let lastAttempt { return max(now.addingTimeInterval(1), lastAttempt.addingTimeInterval(300)) }
        if preferences.mode == .interval {
            return (preferences.lastSwitch ?? now).addingTimeInterval(TimeInterval(preferences.intervalMinutes * 60))
        }
        if DailySchedule.shouldCheck(now: now, lastSuccess: preferences.lastDailySuccess,
                                     lastManual: preferences.lastManual, enabled: preferences.automatic) { return now }
        return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))
            ?? now.addingTimeInterval(3600)
    }

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard started, preferences.automatic, operation == nil, !busy else { return }
        let delay = max(1, min(1800, nextDueDate().timeIntervalSinceNow))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomatic() }
        }
        timer?.tolerance = min(5, delay * 0.05)
    }

    var scheduleDescription: String {
        guard preferences.automatic else { return "自动切换已暂停" }
        if preferences.mode == .daily { return "每日更新 · 启动和唤醒时补检查" }
        let date = nextDueDate().formatted(date: .omitted, time: .shortened)
        return "每 \(preferences.intervalMinutes) 分钟 · 下次约 \(date)"
    }

    func configureLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch { lastError = "登录项设置未完成：" + error.localizedDescription }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func openArchive() {
        do {
            try FileManager.default.createDirectory(at: ImageArchive.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ImageArchive.directory)
        } catch { lastError = "无法打开“下载/微软壁纸”：" + error.localizedDescription }
    }

    private func refreshPreview() {
        previewTask?.cancel()
        guard let url = preferences.current?.localURL else { preview = nil; return }
        previewTask = Task { [weak self, archive] in
            let data = await archive.previewData(at: url)
            guard !Task.isCancelled, let self, self.preferences.current?.localURL == url else { return }
            self.preview = data.flatMap(NSImage.init(data:))
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.settingsKey) }
    }
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
