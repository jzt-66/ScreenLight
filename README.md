# ScreenLight · 屏幕亮度

一个轻量的 macOS 菜单栏亮度工具，支持外接显示器的软件调光与硬件背光控制。

## 功能

- **软件调光**：拖动时直接调整画面亮度，背光保持固定，范围为 5–100%。
- **硬件背光**：通过 DDC/CI 调节显示器背光，响应速度取决于显示器及连接方式。
- **菜单栏面板**：暖橙色界面，支持系统深浅外观与多屏边界定位。
- **快捷操作**：25%、50%、75%、100% 预设；Control + Option + ↑ / ↓ 每次调节 5%。
- **本地设置**：保存调光模式和软件亮度；可选登录时启动。

软件模式的 100% 是当前硬件背光下的完整画面亮度。若需要更亮，可以先在硬件模式提高背光，再切回软件模式。正常退出或切回硬件模式时会恢复原画面曲线。

## 环境

- Apple 芯片 Mac（arm64）。
- 应用声明最低 macOS 14；目前仅在 Apple M4、macOS 27.0.1 上验证。
- 源码构建使用 Xcode 27.2、Apple Clang / Swift 和 Python 3，无额外包管理器依赖。

## 构建

在源码根目录运行：

```bash
bash build.sh /private/tmp/ScreenLight-build
```

应用位于 `/private/tmp/ScreenLight-build/屏幕亮度.app`，可将它移入“应用程序”。这是本地临时签名构建，未进行 Apple 公证。

构建输出默认使用 `.build/` 缓存；可以通过 `SCREENLIGHT_BUILD_DIR` 指定其他位置。建议在非同步文件夹中生成 App，避免同步服务添加的 Finder 元数据影响签名校验。

## 使用

启动后点击菜单栏的小太阳，选择“软件调光”或“硬件背光”，拖动滑块即可。快捷键优先控制鼠标所在的外接显示器。软件模式会恢复上次的软件亮度，硬件模式读取显示器当前背光。

硬件模式依赖显示器、线材和扩展坞的 DDC/CI 支持，可在显示器菜单中检查 DDC/CI。部分显示器即使返回新的亮度值，实际背光也会延迟变化；软件模式用于需要即时画面反馈的场景。

## 代码检查

先构建，再运行：

```bash
bash test.sh /private/tmp/ScreenLight-build/屏幕亮度.app
```

检查包括 DDC 数据包编解码、无效命令参数及多显示器面板边界定位。这些检查不代替真实显示器上的视觉与交互验证。

## 项目结构

- `Sources/ScreenLight.swift`：菜单栏、界面、快捷键及调光调度。
- `Sources/SoftwareDimmer.swift`：软件亮度曲线和恢复逻辑。
- `Sources/LiveDDC.m`：硬件亮度写入及连接缓存。
- `Sources/DDCHelper.m`：显示器发现和亮度读取辅助程序。
- `Sources/PanelPlacement.swift`：多屏面板定位。
- `Vendor/m1ddc/`：保留许可的第三方显示器发现代码。

## 第三方代码

显示器发现及 IOAV 通道映射基于 [m1ddc](https://github.com/waydabber/m1ddc)，遵循其 MIT 许可。详见 [THIRD_PARTY.md](THIRD_PARTY.md) 和 [原许可文件](Vendor/m1ddc/LICENSE)。硬件通道使用的 IOAV / CoreDisplay 私有接口可能随系统更新变化。
