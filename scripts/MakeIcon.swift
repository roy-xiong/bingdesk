import AppKit
import Foundation

/// 在云端生成原生图标，避免为图标引入第三方运行依赖。
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.27, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 212, yRadius: 212).fill()
NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.39, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 623, y: 600, width: 172, height: 172)).fill()
let rear = NSBezierPath()
rear.move(to: NSPoint(x: 108, y: 250))
rear.line(to: NSPoint(x: 443, y: 702))
rear.line(to: NSPoint(x: 807, y: 250))
rear.close()
NSColor(calibratedRed: 0.54, green: 0.75, blue: 0.67, alpha: 1).setFill()
rear.fill()
let front = NSBezierPath()
front.move(to: NSPoint(x: 347, y: 250))
front.line(to: NSPoint(x: 665, y: 567))
front.line(to: NSPoint(x: 918, y: 250))
front.close()
NSColor(calibratedRed: 0.85, green: 0.92, blue: 0.82, alpha: 1).setFill()
front.fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
catch { fputs("图标生成失败：\(error)\n", stderr); exit(1) }
