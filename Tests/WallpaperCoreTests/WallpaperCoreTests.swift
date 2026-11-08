import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import WallpaperCore

final class WallpaperCoreTests: XCTestCase {
    func testResolutionRejectsUpscaleAndWrongAspectSize() {
        XCTAssertTrue(ResolutionPolicy.accepts(width: 3840, height: 2160))
        XCTAssertTrue(ResolutionPolicy.accepts(width: 7680, height: 4320))
        XCTAssertFalse(ResolutionPolicy.accepts(width: 1920, height: 1080))
        XCTAssertFalse(ResolutionPolicy.accepts(width: 4000, height: 2000))
        XCTAssertFalse(ResolutionPolicy.accepts(width: -1, height: 2160))
    }

    func testScheduleAllowsRetryButRespectsManualAndSuccess() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1804672800)
        let today = now.addingTimeInterval(-60)
        let yesterday = now.addingTimeInterval(-86400)
        XCTAssertTrue(DailySchedule.shouldCheck(now: now, lastSuccess: nil, lastManual: nil, enabled: true, calendar: calendar))
        XCTAssertTrue(DailySchedule.shouldCheck(now: now, lastSuccess: yesterday, lastManual: yesterday, enabled: true, calendar: calendar))
        XCTAssertFalse(DailySchedule.shouldCheck(now: now, lastSuccess: today, lastManual: nil, enabled: true, calendar: calendar))
        XCTAssertFalse(DailySchedule.shouldCheck(now: now, lastSuccess: nil, lastManual: today, enabled: true, calendar: calendar))
        XCTAssertFalse(DailySchedule.shouldCheck(now: now, lastSuccess: nil, lastManual: nil, enabled: false, calendar: calendar))
    }

    func testIntervalScheduleValidatesIntervalAndElapsedTime() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertTrue(IntervalSchedule.shouldSwitch(now: now, lastSwitch: nil, interval: 3600, enabled: true))
        XCTAssertTrue(IntervalSchedule.shouldSwitch(now: now, lastSwitch: now.addingTimeInterval(-3600), interval: 3600, enabled: true))
        XCTAssertFalse(IntervalSchedule.shouldSwitch(now: now, lastSwitch: now.addingTimeInterval(-3599), interval: 3600, enabled: true))
        XCTAssertFalse(IntervalSchedule.shouldSwitch(now: now, lastSwitch: now.addingTimeInterval(1), interval: 3600, enabled: true))
        XCTAssertFalse(IntervalSchedule.shouldSwitch(now: now, lastSwitch: nil, interval: 3600, enabled: false))
        for interval: TimeInterval in [0, -1, .infinity, -.infinity, .nan] {
            XCTAssertFalse(IntervalSchedule.shouldSwitch(now: now, lastSwitch: nil, interval: interval, enabled: true))
        }
    }

    func testEvictionProtectsActiveScreensAndRespectsBothLimits() {
        let entries = (0..<12).map { CacheEntry(url: URL(fileURLWithPath: "/cache/\($0).jpg"), byteCount: 25 * 1024 * 1024, lastAccess: Date(timeIntervalSince1970: Double($0))) }
        let protected: Set<URL> = [entries[0].url, entries[1].url]
        XCTAssertEqual(CachePolicy.evictions(entries: entries, protectedURLs: protected), entries[2...5].map(\.url))
        XCTAssertEqual(CachePolicy.evictions(entries: entries, protectedURLs: Set(entries.map(\.url))), [])
        XCTAssertEqual(CachePolicy.evictions(entries: entries, protectedURLs: [], maxCount: 10, maxBytes: .max), entries[0...1].map(\.url))
    }

    func testURLRejectsForeignHostsHTTPThumbnailsAndCredentialTricks() throws {
        let valid = try XCTUnwrap(URL(string: "https://www.bing.com/th?id=OHR.Test_ZH-CN123_UHD.jpg"))
        XCTAssertTrue(WallpaperURL.isAllowed(valid))
        for text in ["http://www.bing.com/th?id=OHR.Test_UHD.jpg", "https://bing.com.evil.test/th?id=OHR.Test_UHD.jpg", "https://www.bing.com/th?id=OHR.Test_1920x1080.jpg", "https://evil.test/th?id=OHR.Test_UHD.jpg", "https://user:pass@www.bing.com/th?id=OHR.Test_UHD.jpg"] {
            XCTAssertFalse(WallpaperURL.isAllowed(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testOfficialParserBuildsUHDFromBaseAndRejectsInvalidDate() throws {
        let data = Data(#"{"images":[{"startdate":"20261108","title":"今日","copyright":"作者","urlbase":"/th?id=OHR.Test_ZH-CN123","url":"/th?id=OHR.Test_ZH-CN123_1920x1080.jpg"},{"startdate":"20260230","urlbase":"/th?id=OHR.Invalid"}]}"#.utf8)
        let images = try WallpaperParser.latest(from: data)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.date, "20261108")
        XCTAssertEqual(images.first?.url.absoluteString, "https://www.bing.com/th?id=OHR.Test_ZH-CN123_UHD.jpg")
        XCTAssertEqual(images.first?.copyright, "作者")
    }

    func testArchiveParserUsesUHDFlagAndNeverThumbnail() throws {
        let data = Data(#"[{"date":"20261107","title":"历史","copyright":"作者","urlbase":"/th?id=OHR.History","uhd":true,"thumbnail":"thumbnails/x.webp"},{"date":"20261106","urlbase":"/th?id=OHR.NoUHD","uhd":false},{"date":"20260230","urlbase":"/th?id=OHR.BadDate","uhd":true},{"date":"20261105","urlbase":"https://evil.test/th?id=OHR.Bad","uhd":true}]"#.utf8)
        let images = try WallpaperParser.archive(from: data)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.url.absoluteString, "https://www.bing.com/th?id=OHR.History_UHD.jpg")
    }

    func testArchiveIndexExtractsOnlyValidUHDYears() throws {
        let data = Data(#"[{"date":"20261107","uhd":true},{"date":"20251101","uhd":true},{"date":"20241101","uhd":false},{"date":"20260230","uhd":true}]"#.utf8)
        XCTAssertEqual(try WallpaperParser.archiveYears(from: data), [2026, 2025])
    }

    func testImageValidatorReadsRealDiskDimensionsAndRejectsSmallImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = directory.appendingPathComponent("large.png")
        let small = directory.appendingPathComponent("small.png")
        try writePNG(to: large, width: 3840, height: 2160)
        try writePNG(to: small, width: 1920, height: 1080)
        let dimensions = try ImageValidator.dimensions(at: large)
        XCTAssertEqual(dimensions.width, 3840)
        XCTAssertEqual(dimensions.height, 2160)
        XCTAssertThrowsError(try ImageValidator.dimensions(at: small))
        let invalid = directory.appendingPathComponent("fake.jpg")
        try Data("not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try ImageValidator.dimensions(at: invalid))
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
