# BingDesk

原生 macOS 菜单栏必应壁纸工具：每日更新、手动随机切换，只接受实际像素至少 **3840×2160** 的原图。

- Swift + SwiftUI，无第三方运行依赖，macOS 13+，Apple Silicon。
- 自动更新在启动、唤醒和低频定时检查时补偿；当天手动选图不会被自动任务反复覆盖。
- 图片按需下载至磁盘，预览使用缩小图；缓存最多最近 10 张、200 MiB，保留显示器正在使用的文件。
- 断网、图片不达标或设置失败时保留已有壁纸。
- 支持登录启动开关；退出 App 后不再自动更新。

## 下载与安装

在 [Releases](https://github.com/roy-xiong/bingdesk/releases) 下载 DMG，将 App 拖入“应用程序”。自用版采用 ad-hoc 签名，未公证；首次打开如被拦截，请到“系统设置 → 隐私与安全性 → 仍要打开”。本机无需 Xcode。

## 云端构建

GitHub Actions 在 macOS runner 上执行 `swift test --parallel`、Release 构建、签名检查和 DMG 校验。构建产物附带 SHA-256。不要将云端编译成功等同于已在真实桌面验证；安装和换图验收另行记录在发布说明。

## 数据来源

每日图片来自 Bing 官方 zh-CN `HPImageArchive`；历史索引来自 [YanGN-ST/bing_wallpaper_archive](https://github.com/YanGN-ST/bing_wallpaper_archive)。该索引的 UHD 标记仅作候选过滤，下载后仍需校验真实像素。图片版权归原作者与 Bing 所有。

多显示器会设置当前已连接屏幕；其他 Mission Control 桌面空间的行为由 macOS 管理。
