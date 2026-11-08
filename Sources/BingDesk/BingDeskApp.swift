import AppKit
import SwiftUI

/// 原生菜单栏入口。构建由 GitHub Actions 完成，本机仅运行交付的 App。
@main
@MainActor
struct BingDeskApp: App {
    @StateObject private var model: AppModel

    init() {
        let instance = AppModel()
        _model = StateObject(wrappedValue: instance)
        if let command = CommandLine.arguments.dropFirst().first, command.hasPrefix("--") {
            Task { @MainActor in
                let result = await Diagnostics.run(command, model: instance)
                instance.stop()
                exit(result)
            }
        } else {
            Task { @MainActor in instance.start() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : "photo.on.rectangle.angled")
                .accessibilityLabel("BingDesk 必应壁纸")
        }
        .menuBarExtraStyle(.window)
    }
}
