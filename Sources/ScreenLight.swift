import AppKit
import SwiftUI
import Combine
import Carbon
import ServiceManagement

struct Monitor: Decodable, Identifiable {
    let id: String
    let displayID: UInt32
    let name: String
    var ok: Bool
    var percent: Double?
    var current: Int?
    var maximum: Int?
    var error: String?
    var verified: Bool?
}

struct HelperReply: Decodable {
    let ok: Bool
    let error: String?
    let displays: [Monitor]?
    let percent: Double?
    let verified: Bool?
    let current: Int?
    let maximum: Int?
}

enum HelperError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

// One queue owns all DDC transactions. A stuck or disconnected display is bounded
// by a timeout, and can never freeze the app's main thread.
final class DDCClient {
    private let queue = DispatchQueue(label: "local.screenlight.ddc", qos: .userInitiated)
    private struct LiveWrite {
        let id: String
        let percent: Double
        let maximum: Int
        let completion: (Result<Double, Error>) -> Void
    }
    private let liveLock = NSLock()
    private var latestWrites: [String: LiveWrite] = [:]
    private var drainingLiveWrites = false

    // Called synchronously by NSSlider's continuous action, including inside
    // AppKit's mouse tracking run loop. No MainActor Task has to start first.
    func submitLive(_ id: String, percent: Double, maximum: Int, completion: @escaping (Result<Double, Error>) -> Void) {
        liveLock.lock()
        latestWrites[id] = LiveWrite(id: id, percent: percent, maximum: maximum, completion: completion)
        let start = !drainingLiveWrites
        drainingLiveWrites = true
        liveLock.unlock()
        if start { queue.async { self.drainLiveWrites() } }
    }

    private func drainLiveWrites() {
        while true {
            liveLock.lock()
            guard let (id, write) = latestWrites.first else {
                drainingLiveWrites = false
                liveLock.unlock()
                return
            }
            latestWrites.removeValue(forKey: id)
            liveLock.unlock()
            var applied = 0.0
            let status = write.id.withCString { SLWriteBrightness($0, write.percent, UInt16(write.maximum), &applied) }
            let result: Result<Double, Error> = status == 0 ? .success(applied) :
                .failure(HelperError.message(String(format: "亮度写入失败（0x%08x），请重新检测。", UInt32(bitPattern: status))))
            // Common modes include the slider's tracking loop. Dispatching an
            // async Task back to the main actor can otherwise wait for mouse-up.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                write.completion(result)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            Thread.sleep(forTimeInterval: 0.06)
        }
    }

    func resetLiveConnections() {
        queue.async { SLResetBrightnessConnections() }
    }

    func run(_ arguments: [String]) async throws -> HelperReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let executable = Bundle.main.url(forAuxiliaryExecutable: "screenlight-ddc") else {
                        throw HelperError.message("找不到亮度控制组件，请重新解压完整的 App。")
                    }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    let finished = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in finished.signal() }
                    try process.run()
                    if finished.wait(timeout: .now() + 12) == .timedOut {
                        process.terminate()
                        // Ensure no abandoned writer overlaps the next transaction.
                        if finished.wait(timeout: .now() + 1) == .timedOut {
                            kill(process.processIdentifier, SIGKILL)
                            process.waitUntilExit()
                        }
                        throw HelperError.message("显示器响应超时，请重新连接后检测。")
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    guard let reply = try? JSONDecoder().decode(HelperReply.self, from: data) else {
                        throw HelperError.message("未能连接显示器，请重新检测。")
                    }
                    guard process.terminationStatus == 0, reply.ok else {
                        throw HelperError.message(reply.error ?? "显示器没有采用设定亮度，请重新检测。")
                    }
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class BrightnessModel: ObservableObject {
    @Published var monitors: [Monitor] = []
    @Published var scanning = false
    @Published var busy = Set<String>()
    @Published var message: String?
    @Published var selectedID: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginMessage: String?
    @Published var shortcutMessage: String?
    @Published private(set) var softwareMode = UserDefaults.standard.object(forKey: "softwareMode") as? Bool ?? true
    @Published private(set) var hardwareLevels: [String: Double] = [:]
    private let dimmer = SoftwareDimmer()
    private var softwareLevels = UserDefaults.standard.dictionary(forKey: "softwareLevels") as? [String: Double] ?? [:]
    private var softwareSaveTask: Task<Void, Never>?
    private let client = DDCClient()
    private var revisions: [String: Int] = [:]
    private var verificationTasks: [String: Task<Void, Never>] = [:]
    private var reconnect: Task<Void, Never>?
    private var rescanRequested = false
    private var lastScan = Date.distantPast
    var onBrightnessChanged: ((String, Double) -> Void)?

    func scan() {
        guard !scanning else { return }
        guard busy.isEmpty else { rescanRequested = true; return }
        scanning = true
        message = nil
        client.resetLiveConnections()
        Task {
            defer { scanning = false }
            do {
                let reply = try await client.run(["list"])
                monitors = reply.displays ?? []
                hardwareLevels = Dictionary(uniqueKeysWithValues: monitors.compactMap { monitor in
                    monitor.percent.map { (monitor.id, $0) }
                })
                dimmer.removeDisconnected(keeping: Set(monitors.map(\.displayID)))
                if softwareMode {
                    for index in monitors.indices {
                        let level = min(100, max(5, softwareLevels[monitors[index].id] ?? 100))
                        do {
                            try dimmer.set(level, display: monitors[index].displayID)
                            monitors[index].percent = level
                            monitors[index].ok = true
                            monitors[index].error = nil
                        } catch {
                            monitors[index].ok = false
                            monitors[index].error = error.localizedDescription
                        }
                    }
                }
                if !monitors.contains(where: { $0.id == selectedID && $0.ok }) {
                    selectedID = monitors.first(where: \.ok)?.id
                }
                lastScan = Date()
            } catch { message = error.localizedDescription }
        }
    }

    func refreshIfNeeded() {
        if Date().timeIntervalSince(lastScan) > 15 { scan() }
    }

    func scheduleReconnect() {
        reconnect?.cancel()
        reconnect = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            scan()
        }
    }

    func setBrightness(_ id: String, _ value: Double) {
        guard !scanning, let index = monitors.firstIndex(where: { $0.id == id && $0.ok }) else { return }
        selectedID = id
        if softwareMode {
            let level = min(100, max(5, value.rounded()))
            guard monitors[index].percent != level || monitors[index].error != nil else { return }
            do {
                // This is synchronous in the native slider action: no DDC,
                // subprocess, animation transaction, or mouse-up dependency.
                try dimmer.set(level, display: monitors[index].displayID)
                monitors[index].percent = level
                monitors[index].error = nil
                softwareLevels[id] = level
                onBrightnessChanged?(monitors[index].name, level)
                softwareSaveTask?.cancel()
                softwareSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    UserDefaults.standard.set(softwareLevels, forKey: "softwareLevels")
                }
            } catch { monitors[index].error = error.localizedDescription }
            return
        }
        guard let maximum = monitors[index].maximum, (1...65535).contains(maximum) else {
            monitors[index].error = "请重新检测显示器的亮度范围。"
            return
        }
        let clamped = min(100, max(0, value.rounded()))
        guard monitors[index].percent != clamped || monitors[index].error != nil else { return }
        monitors[index].percent = clamped
        monitors[index].error = nil
        revisions[id, default: 0] += 1
        busy.insert(id)
        verificationTasks[id]?.cancel()
        verificationTasks[id] = nil
        let revision = revisions[id]
        client.submitLive(id, percent: clamped, maximum: maximum) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.revisions[id] == revision,
                      let index = self.monitors.firstIndex(where: { $0.id == id }) else { return }
                switch result {
                case .success(let applied):
                    self.monitors[index].percent = applied
                    self.monitors[index].verified = false
                    self.onBrightnessChanged?(self.monitors[index].name, applied)
                    self.scheduleVerification(id, target: clamped, maximum: maximum, revision: revision)
                case .failure(let error):
                    self.monitors[index].error = error.localizedDescription
                    self.monitors[index].ok = false
                    self.busy.remove(id)
                    if self.rescanRequested && self.busy.isEmpty {
                        self.rescanRequested = false
                        self.scan()
                    }
                }
            }
        }
    }

    func changeMode(software: Bool) {
        guard !scanning, busy.isEmpty, softwareMode != software else { return }
        softwareSaveTask?.cancel()
        UserDefaults.standard.set(softwareLevels, forKey: "softwareLevels")
        dimmer.restoreAll()
        softwareMode = software
        UserDefaults.standard.set(software, forKey: "softwareMode")
        scan()
    }

    func restorePicture() {
        softwareSaveTask?.cancel()
        UserDefaults.standard.set(softwareLevels, forKey: "softwareLevels")
        dimmer.restoreAll()
    }

    private func scheduleVerification(_ id: String, target: Double, maximum: Int, revision: Int?) {
        verificationTasks[id]?.cancel()
        verificationTasks[id] = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, revisions[id] == revision else { return }
            do {
                let actual = try await client.run(["read", id])
                guard !Task.isCancelled, revisions[id] == revision,
                      let index = monitors.firstIndex(where: { $0.id == id }) else { return }
                monitors[index].percent = actual.percent
                let expected = Int((target * Double(maximum) / 100).rounded())
                let verified = actual.current == expected && actual.maximum == maximum
                monitors[index].verified = verified
                monitors[index].error = verified ? nil : "显示器没有采用设定亮度，请检查 HDR / 画面模式。"
            } catch {
                guard !Task.isCancelled, revisions[id] == revision,
                      let index = monitors.firstIndex(where: { $0.id == id }) else { return }
                monitors[index].error = error.localizedDescription
                monitors[index].ok = false
            }
            guard !Task.isCancelled, revisions[id] == revision else { return }
            busy.remove(id)
            verificationTasks[id] = nil
            if rescanRequested && busy.isEmpty {
                rescanRequested = false
                scan()
            }
        }
    }

    func step(_ direction: Double) {
        guard !scanning else { return }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let target = monitors.first(where: { $0.displayID == displayID && $0.ok }) ??
            monitors.first(where: { $0.id == selectedID && $0.ok }) ?? monitors.first(where: \.ok)
        guard let target, let percent = target.percent else { return }
        setBrightness(target.id, percent + direction)
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许屏幕亮度。" : nil
        } catch { loginMessage = "无法更新登录项：\(error.localizedDescription)" }
    }
}

@MainActor
private final class BrightnessSliderCell: NSSliderCell {
    override var knobThickness: CGFloat { 18 }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.09 : 0.04).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let progress = CGFloat(min(1, max(0, (doubleValue - minValue) / max(1, maxValue - minValue))))
        if progress > 0 {
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width * progress, height: track.height)
            NSColor.systemOrange.withAlphaComponent(isEnabled ? 0.9 : 0.3).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let rect = NSRect(x: knobRect.midX - 9, y: knobRect.midY - 9, width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.55).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.06).setStroke()
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

@MainActor
private struct ContinuousBrightnessSlider: NSViewRepresentable {
    let value: Double
    let minimum: Double
    let enabled: Bool
    let label: String
    let onChange: (Double) -> Void

    final class TrackingSlider: NSSlider {
        var tracking = false
        override func mouseDown(with event: NSEvent) {
            tracking = true
            defer { tracking = false }
            super.mouseDown(with: event)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSSlider) {
            onChange(sender.doubleValue)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider(frame: .zero)
        slider.cell = BrightnessSliderCell()
        slider.minValue = minimum
        slider.maxValue = 100
        slider.doubleValue = value
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.setAccessibilityLabel(label)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: TrackingSlider, context: Context) {
        context.coordinator.onChange = onChange
        slider.isEnabled = enabled
        slider.minValue = minimum
        slider.setAccessibilityLabel(label)
        if !slider.tracking { slider.doubleValue = value }
    }
}

struct BrightnessView: View {
    @ObservedObject var model: BrightnessModel
    @Environment(\.colorScheme) private var colorScheme
    let quit: () -> Void
    private let accent = Color.orange
    private var cardFill: Color { Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.6 : 0.8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("屏幕亮度").font(.system(size: 16, weight: .semibold))
                    Text("恰到好处的光").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                } else if !model.monitors.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("\(model.monitors.count) 台").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.primary.opacity(0.04), in: Capsule())
                }
            }

            HStack(spacing: 3) {
                modeButton(software: true, title: "软件调光", symbol: "sparkles")
                modeButton(software: false, title: "硬件背光", symbol: "display")
            }
            .padding(3)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.scanning || !model.busy.isEmpty)

            if model.monitors.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "display").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.scanning ? "正在寻找显示器…" : "连接一块显示器")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.message ?? "连接后，点击下方刷新设备。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 35)
            } else {
                VStack(spacing: 12) {
                    ForEach(model.monitors) { monitor in monitorCard(monitor) }
                }
                if let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            HStack(spacing: 9) {
                Image(systemName: "keyboard").font(.system(size: 14)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("快捷调光").font(.system(size: 11, weight: .medium))
                    Text("鼠标所在的外接屏 · 每次 5%")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    keycap("⌃")
                    keycap("⌥")
                    keycap("↑ ↓", width: 33)
                }
            }
            .padding(12)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            if let issue = model.shortcutMessage {
                Text(issue).font(.system(size: 10)).foregroundStyle(.orange)
            }

            HStack {
                Button { model.scan() } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .disabled(model.scanning || !model.busy.isEmpty)
                .help("重新检测显示器及当前亮度")
                Spacer()
                Text(model.softwareMode ? "画面实时调光" : "显示器背光控制")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button { model.toggleLogin() } label: {
                        if model.launchAtLogin { Label("登录时启动", systemImage: "checkmark") }
                        else { Text("登录时启动") }
                    }
                    Button("使用说明") { showHelp() }
                    Divider()
                    Button("退出屏幕亮度", action: quit).keyboardShortcut("q")
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13)).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .accessibilityLabel("设置与更多选项")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            if let info = model.loginMessage {
                Text(info).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 360)
    }

    private func modeButton(software: Bool, title: String, symbol: String) -> some View {
        let selected = model.softwareMode == software
        return Button { model.changeMode(software: software) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .shadow(color: selected ? .black.opacity(0.07) : .clear, radius: 3, y: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选择" : "未选择")
    }

    private func keycap(_ text: String, width: CGFloat = 20) -> some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).frame(width: width, height: 22)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }

    @ViewBuilder private func monitorCard(_ monitor: Monitor) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Image(systemName: "display")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 31, height: 31)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("外接显示器").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: monitor.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(monitor.ok ? Color.green.opacity(0.8) : Color.orange)
            }

            if monitor.ok, let percent = monitor.percent {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.softwareMode ? "画面亮度" : "背光亮度")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(percent))")
                                .font(.system(size: 45, weight: .medium, design: .rounded)).monospacedDigit()
                                .tracking(-1.5)
                            Text("%").font(.system(size: 17, weight: .regular)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(accent.opacity(0.45 + percent / 200))
                        .frame(width: 62, height: 62)
                        .background {
                            Circle().fill(RadialGradient(colors: [accent.opacity(0.16), accent.opacity(0.025)], center: .center, startRadius: 0, endRadius: 35))
                        }
                        .accessibilityHidden(true)
                }

                HStack(spacing: 10) {
                    Image(systemName: "sun.min").font(.system(size: 12)).foregroundStyle(.tertiary)
                    ContinuousBrightnessSlider(value: percent, minimum: model.softwareMode ? 5 : 0, enabled: !model.scanning,
                        label: "\(monitor.name)亮度", onChange: { model.setBrightness(monitor.id, $0) })
                        .frame(height: 24)
                    Image(systemName: "sun.max").font(.system(size: 14)).foregroundStyle(.secondary)
                }

                HStack(spacing: 7) {
                    ForEach([25, 50, 75, 100], id: \.self) { value in
                        let selected = Int(percent) == value
                        Button { model.setBrightness(monitor.id, Double(value)) } label: {
                            Text("\(value)%")
                                .font(.system(size: 10, weight: selected ? .semibold : .medium)).monospacedDigit()
                                .foregroundStyle(selected ? accent : Color.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(selected ? accent.opacity(0.11) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).disabled(model.scanning)
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: model.softwareMode ? "sparkles" : "display")
                    Text(model.softwareMode ? "拖动即刻调光" : (model.busy.contains(monitor.id) ? "正在调整…" : "硬件背光"))
                    Spacer(minLength: 2)
                    if model.softwareMode, let baseline = model.hardwareLevels[monitor.id] {
                        Text("背光保持 \(Int(baseline))%")
                    }
                    Image(systemName: "info.circle")
                        .help(model.softwareMode ? "软件 100% 为当前背光上限。需要更亮时，可先用硬件模式提高背光。正常退出会恢复画面。" : "通过 DDC/CI 控制显示器，实际响应速度取决于显示器。")
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.055), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.025), radius: 10, y: 4)
    }

    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "屏幕亮度"
        alert.informativeText = "软件调光：滑块直接改变画面亮度，背光保持当前值。软件 100% 表示当前背光的完整亮度，可调范围为 5% 到 100%；正常退出会恢复画面。若需更亮，可切换硬件模式提高背光，再切回软件模式。\n\n硬件背光：通过 DDC/CI 调节显示器；部分显示器的背光会延迟生效。\n\n快捷键：Control + Option + ↑ / ↓，每次调节 5%。优先调节鼠标所在的外接屏。\n\n睡眠唤醒或重新连接后会自动检测，也可点击“重新检测”。\n\n开源组件：m1ddc（MIT，© 2021 waydabber）。完整许可随 App 附带。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class BrightnessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = BrightnessModel()
    private var item: NSStatusItem!
    private var brightnessPanel: BrightnessPanel?
    private var panelSubscriptions = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var feedbackPanel: NSPanel?
    private var dismissFeedback: Task<Void, Never>?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = duplicates.first {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSource = termination
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "屏幕亮度")
        item.button?.toolTip = "屏幕亮度 · Control + Option + ↑ / ↓"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        installPanelDismissal()
        model.$monitors.map { $0.count }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePanelPosition() }
            }.store(in: &panelSubscriptions)
        registerHotKeys()
        model.onBrightnessChanged = { [weak self] name, percent in
            self?.item.button?.toolTip = "\(name) · \(Int(percent))%"
            if self?.brightnessPanel?.isVisible != true { self?.showFeedback(name: name, percent: percent) }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.scheduleReconnect() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.model.scheduleReconnect()
                self?.updatePanelPosition()
            }
        })
        model.scan()
        DispatchQueue.main.async { self.showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return true
    }

    @objc private func togglePanel() {
        if brightnessPanel?.isVisible == true { brightnessPanel?.orderOut(nil) } else { showPanel() }
    }

    private func showPanel() {
        guard item?.button != nil else { return }
        model.refreshIfNeeded()
        if brightnessPanel == nil {
            let panel = BrightnessPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "屏幕亮度"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false
            brightnessPanel = panel
        }
        updatePanelPosition()
        NSApp.activate(ignoringOtherApps: true)
        brightnessPanel?.makeKeyAndOrderFront(nil)
    }

    private func updatePanelPosition() {
        guard let panel = brightnessPanel, let button = item?.button, let menuWindow = button.window else { return }
        // Keep both anchor and screens in AppKit's global coordinate space.
        // Display origins may be negative or above the built-in display.
        let anchor = menuWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) })
            ?? menuWindow.screen ?? NSScreen.main
        guard let screen else { return }
        let idealHeight = min(700, 239 + max(1, model.monitors.count) * 276)
        let frame = PanelPlacement.menuPanel(size: CGSize(width: 360, height: CGFloat(idealHeight)), visibleFrame: screen.visibleFrame, anchor: anchor)
        let root = ScrollView {
            BrightnessView(model: model, quit: { NSApp.terminate(nil) })
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(frame, display: true)
    }

    private func installPanelDismissal() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.brightnessPanel?.orderOut(nil) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.brightnessPanel, panel.isVisible else { return }
                if event.window !== panel && event.window !== self.item?.button?.window && !panel.frame.contains(NSEvent.mouseLocation) {
                    panel.orderOut(nil)
                }
            }
            return event
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.brightnessPanel?.orderOut(nil) }
        })
    }

    private func registerHotKeys() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.model.step(identifier.id == 1 ? 5 : -5) }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installed == noErr else {
            model.shortcutMessage = "无法注册全局快捷键，仍可使用滑块调节。"
            return
        }
        for (identifier, key) in [(UInt32(1), UInt32(kVK_UpArrow)), (UInt32(2), UInt32(kVK_DownArrow))] {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x534C4954, id: identifier), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { hotKeys.append(reference) }
            else { model.shortcutMessage = "快捷键被其他软件占用，仍可使用滑块调节。" }
        }
        // Also handle app-directed key events, such as events sent to a focused
        // slider. System hotkey events are consumed by Carbon before this stage.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape), self?.brightnessPanel?.isVisible == true,
               event.window === self?.brightnessPanel {
                MainActor.assumeIsolated { self?.brightnessPanel?.orderOut(nil) }
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            if modifiers == [.control, .option], event.keyCode == UInt16(kVK_UpArrow) || event.keyCode == UInt16(kVK_DownArrow) {
                MainActor.assumeIsolated { self?.model.step(event.keyCode == UInt16(kVK_UpArrow) ? 5 : -5) }
                return nil
            }
            return event
        }
    }

    private func showFeedback(name: String, percent: Double) {
        dismissFeedback?.cancel()
        feedbackPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 108), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                Text("\(Int(percent))%").font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            ProgressView(value: percent, total: 100).tint(.orange).frame(width: 160)
        }.frame(width: 230, height: 108).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        panel.contentView = NSHostingView(rootView: content)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(PanelPlacement.feedback(size: panel.frame.size, visibleFrame: frame), display: false)
        }
        panel.orderFrontRegardless()
        feedbackPanel = panel
        dismissFeedback = Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.restorePicture()
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

@main
struct ScreenLight {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
