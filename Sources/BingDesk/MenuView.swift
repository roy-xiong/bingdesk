import AppKit
import SwiftUI
import ServiceManagement

/// 以当前壁纸为中心的菜单栏面板，仅在用户展开时显示预览。
@MainActor
struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var intervalText = "60"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("BingDesk", systemImage: "photo.on.rectangle.angled").font(.headline)
                Spacer()
                Text("4K 原图").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1))
                if let image = model.preview {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mountain.2").font(.largeTitle)
                        Text(model.busy ? "正在准备 4K 壁纸" : "每天，换一个视角").font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }
            .frame(width: 336, height: 189).clipped().clipShape(RoundedRectangle(cornerRadius: 10))

            if let current = model.preferences.current {
                Text(current.wallpaper.title).font(.headline).lineLimit(2)
                Text("\(current.width) × \(current.height)  ·  \(current.wallpaper.date)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(current.wallpaper.copyright).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("原图自动保存到“下载/微软壁纸”").font(.subheadline)
            }

            HStack(spacing: 8) {
                Button { model.request(.random) } label: { Label("随机换一张", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.08, green: 0.42, blue: 0.43))
                    .accessibilityIdentifier("randomWallpaper")
                Button { model.request(.latest) } label: { Label("恢复今日", systemImage: "sun.max").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).accessibilityIdentifier("latestWallpaper")
            }.disabled(model.busy)
            HStack(spacing: 6) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }

            Divider()
            Toggle("自动换壁纸", isOn: Binding(get: { model.preferences.automatic }, set: { model.setAutomatic($0) }))
                .accessibilityIdentifier("automaticWallpaper")
            Picker("切换模式", selection: Binding(get: { model.preferences.mode }, set: { model.setMode($0) })) {
                Text("每日最新").tag(SwitchMode.daily)
                Text("定时随机").tag(SwitchMode.interval)
            }.pickerStyle(.segmented).labelsHidden().disabled(!model.preferences.automatic)
            if model.preferences.mode == .interval {
                HStack {
                    Text("每隔")
                    TextField("分钟", text: $intervalText).textFieldStyle(.roundedBorder).frame(width: 72)
                        .accessibilityIdentifier("intervalMinutes")
                    Text("分钟")
                    Spacer()
                    Button("保存间隔") {
                        if let minutes = Int(intervalText), model.setInterval(minutes) {
                            intervalText = String(model.preferences.intervalMinutes)
                        } else if Int(intervalText) == nil { _ = model.setInterval(0) }
                    }
                }.font(.subheadline).disabled(!model.preferences.automatic)
                Text("支持 1～10080 分钟；手动换图后重新计时。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.scheduleDescription).font(.caption).foregroundStyle(.secondary)
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.configureLogin($0) }))
                .accessibilityIdentifier("launchAtLogin")
            if model.loginNeedsApproval {
                Button("前往系统设置允许登录项") { SMAppService.openSystemSettingsLoginItems() }
            }
            Divider()
            HStack {
                Button("打开壁纸文件夹") { model.openArchive() }.buttonStyle(.plain)
                Spacer()
                if let url = URL(string: "https://github.com/roy-xiong/bingdesk") {
                    Link("项目", destination: url).font(.caption)
                }
                Button("退出") { model.stop(); NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }.font(.caption)
        }
        .padding(16).frame(width: 368)
        .onAppear {
            // 菜单栏弹窗默认不会激活应用；主动激活后输入框才能接收键盘焦点。
            if #available(macOS 14.0, *) {
                NSApplication.shared.activate()
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            intervalText = String(model.preferences.intervalMinutes)
            model.refreshLoginStatus()
        }
    }
}
