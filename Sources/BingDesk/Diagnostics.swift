import AppKit
import Foundation
import WallpaperCore

struct DesktopReport: Codable {
    let path: String?
    let width: Int?
    let height: Int?
    let matchesSavedWallpaper: Bool
}

struct InstallationReport: Codable {
    let archiveDirectory: String
    let automatic: Bool
    let mode: String
    let intervalMinutes: Int
    let current: SavedWallpaper?
    let desktops: [DesktopReport]
    let loginEnabled: Bool
    let loginNeedsApproval: Bool
    let error: String?
}

/// 由已构建的安装包提供诊断入口，验证真实二进制、真实图片和系统读回值。
/// 正常菜单不展示这些开发用参数，也不需要在本机安装或调用编译器。
@MainActor
enum Diagnostics {
    static func report(_ model: AppModel) -> InstallationReport {
        let desktops = NSScreen.screens.map { screen in
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
            let dimensions = url.flatMap { try? ImageValidator.dimensions(at: $0) }
            return DesktopReport(path: url?.path, width: dimensions?.width, height: dimensions?.height,
                matchesSavedWallpaper: url?.standardizedFileURL == model.preferences.current?.localURL.standardizedFileURL)
        }
        return InstallationReport(archiveDirectory: ImageArchive.directory.path,
            automatic: model.preferences.automatic, mode: model.preferences.mode.rawValue,
            intervalMinutes: model.preferences.intervalMinutes, current: model.preferences.current,
            desktops: desktops, loginEnabled: model.loginEnabled, loginNeedsApproval: model.loginNeedsApproval,
            error: model.lastError)
    }

    static func emit<T: Encodable>(_ report: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    static func run(_ command: String, model: AppModel) async -> Int32 {
        switch command {
        case "--diagnose":
            emit(report(model)); return 0
        case "--enable-login":
            model.configureLogin(true); emit(report(model)); return model.loginEnabled ? 0 : 1
        case "--set-daily":
            model.setMode(.daily); model.setAutomatic(true); emit(report(model)); return 0
        case "--apply-today":
            let success = await model.change(.latest, manual: true)
            emit(report(model)); return success ? 0 : 1
        case "--apply-random":
            let success = await model.change(.random, manual: true)
            emit(report(model)); return success ? 0 : 1
        case "--smoke-test":
            let daily = await model.change(.latest, manual: false)
            let first = model.preferences.current
            let dayDeduplicated = !DailySchedule.shouldCheck(now: Date(), lastSuccess: model.preferences.lastDailySuccess,
                lastManual: model.preferences.lastManual, enabled: true)
            let random = daily ? await model.change(.random, manual: true) : false
            let second = model.preferences.current
            let bothPreserved = [first?.localURL, second?.localURL].allSatisfy {
                guard let url = $0 else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
            let distinct = first?.wallpaper.date != second?.wallpaper.date
            let desktopsMatch = !NSScreen.screens.isEmpty && report(model).desktops.allSatisfy(\.matchesSavedWallpaper)
            let restored = random ? await model.change(.latest, manual: true) : false
            emit(SmokeReport(daily: daily, random: random, distinct: distinct,
                preservedOriginals: bothPreserved, dayDeduplicated: dayDeduplicated,
                desktopReadback: desktopsMatch, restoredDaily: restored, installation: report(model)))
            return daily && random && distinct && bothPreserved && dayDeduplicated && desktopsMatch && restored ? 0 : 1
        default:
            if command.hasPrefix("--set-interval="), let minutes = Int(command.dropFirst("--set-interval=".count)),
               model.setInterval(minutes) {
                model.setMode(.interval); model.setAutomatic(true); emit(report(model)); return 0
            }
            emit(report(model)); return 2
        }
    }

    private struct SmokeReport: Codable {
        let daily: Bool
        let random: Bool
        let distinct: Bool
        let preservedOriginals: Bool
        let dayDeduplicated: Bool
        let desktopReadback: Bool
        let restoredDaily: Bool
        let installation: InstallationReport
    }
}
