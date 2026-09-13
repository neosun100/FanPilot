// FanPilotMenu —— 菜单栏显示（无任何特权）
//
// 职责边界（刻意划得很窄）：
//   ✅ 读 /var/run/fanpilot.status.json 显示温度与转速
//   ✅ 提供几个预设去改配置文件
//   ❌ **绝不直接写 SMC** —— 写入是 root 守护的唯一职责
//   ❌ 不申请任何权限、不内嵌 helper
//
// 为什么读状态文件而不自己读 SMC：守护已经算好了「最热温度 / 平滑值 / 生效配置」，
// 再算一遍会出现两个数字不一致（用户会问「菜单栏说 50°C 守护说 57°C，谁对？」）。
// ⭐ 单一来源：显示层永远显示控制层用的那个数。

import AppKit
import Foundation

// ───────────────────────── 状态模型 ─────────────────────────

struct FanInfo: Decodable {
    let id: Int
    let actual_rpm: Double
    let target_rpm: Double
    let min: Double
    let max: Double
}

struct ConfigInfo: Decodable {
    let min_rpm: Double
    let max_rpm: Double
    let poll_interval: Double
    let ema_seconds: Double
    let slew_up: Double
    let slew_down: Double
    let deadband: Double
}

struct Status: Decodable {
    let ts: Double
    let mode: String
    let temp_hottest_c: Double
    let temp_smoothed_c: Double
    let sensors: Int
    let writes_total: Int
    let config: ConfigInfo
    let fans: [FanInfo]

    /// 状态文件是否新鲜。陈旧 = 守护卡住或已死 —— 这种情况必须显示出来，
    /// 不能继续展示旧数字让人以为一切正常（静默展示陈旧值是最难查的问题）。
    var isFresh: Bool { Date().timeIntervalSince1970 - ts < 15 }
}

let statusPath = "/var/run/fanpilot.status.json"
let configPath = "/usr/local/etc/fanpilot.conf"

func readStatus() -> Status? {
    guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}

// ───────────────────────── 菜单栏 ─────────────────────────

final class Controller: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        // .accessory = 只在菜单栏出现，不进 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 菜单栏两行显示（沿用原软件 menubarTwoLines 的习惯）：上行温度、下行转速
    ///
    /// 🩸 走了两次弯路才找到正解，记下来免得再犯：
    ///   ① 初版 `attributedTitle` + `lineSpacing = -2.5`：负行距让 AppKit 多行布局
    ///      往上溢出 ⇒ 整块**靠上对齐**（用户实测反馈）
    ///   ② 二版改 min/maxLineHeight + `baselineOffset`：**仍然靠上**
    ///      —— NSStatusItem 按钮对多行 attributedTitle **不给精确的垂直控制**
    ///
    /// ⭐ 正解是绕开 AppKit 的文本基线布局：**自己渲染成 NSImage，在图像内做精确居中**。
    ///   像素级可控；且 `isTemplate = true` 让 AppKit 按浅色/深色菜单栏自动着色，
    ///   连主题适配都免了（若画成彩色位图反而要自己监听外观变化重绘）。
    private func twoLineImage(_ top: String, _ bottom: String, dim: Bool) -> NSImage {
        let h = NSStatusBar.system.thickness          // 实测本机 22pt
        // ⭐ 字号由「两行必须装进 h」反推，不能拍脑袋：
        //    9pt 字体行高约 11pt ⇒ 两行 23pt > 22pt，块本身装不下，
        //    溢出只能往上顶 —— 这才是「靠上对齐」的真因（不是偏移没调对）。
        let fontSize: CGFloat = 8
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                    .foregroundColor: NSColor.black]
        let sTop = NSAttributedString(string: top, attributes: attrs)
        let sBot = NSAttributedString(string: bottom, attributes: attrs)

        let wTop = ceil(sTop.size().width), wBot = ceil(sBot.size().width)
        let w = max(wTop, wBot) + 2
        // 用**字形实际视觉高度**（ascender+|descender|）而不是 size().height
        // —— 后者含 leading（行间预留），两行叠加会凭空多出 2~3pt。
        let glyphH = ceil(font.ascender - font.descender)
        let gap: CGFloat = 0
        let blockH = glyphH * 2 + gap
        let pad = max(0, (h - blockH) / 2)             // 装不下时退化为 0，不出现负偏移

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        // 非翻转坐标系：y 从底部起算，所以下行在下、上行在上
        sBot.draw(at: NSPoint(x: w - wBot - 1, y: pad))
        sTop.draw(at: NSPoint(x: w - wTop - 1, y: pad + glyphH + gap))
        img.unlockFocus()
        img.isTemplate = true
        if dim {
            let dimmed = NSImage(size: img.size)
            dimmed.lockFocus()
            img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 0.45)
            dimmed.unlockFocus()
            dimmed.isTemplate = true
            return dimmed
        }
        return img
    }

    /// 供 --render-preview 用：拿到与菜单栏完全相同的那张图
    func previewImage(_ top: String, _ bottom: String) -> NSImage {
        twoLineImage(top, bottom, dim: false)
    }

    private func setTitle(_ top: String, _ bottom: String, dim: Bool) {
        guard let b = item.button else { return }
        b.image = twoLineImage(top, bottom, dim: dim)
        b.imagePosition = .imageOnly
        b.title = ""
    }

    private func refresh() {
        guard let s = readStatus() else {
            setTitle("FanPilot", "守护未运行", dim: true)
            buildMenu(nil)
            return
        }
        let avgRPM = s.fans.map(\.actual_rpm).reduce(0, +) / Double(max(s.fans.count, 1))
        let temp = String(format: "%.0f°C", s.temp_hottest_c)
        let rpm  = String(format: "%.0f", avgRPM)

        if !s.isFresh {
            // 陈旧就要说出来，绝不静默展示旧值
            setTitle("\(temp) ⚠️", "陈旧", dim: true)
        } else if s.mode == "emergency" {
            setTitle("\(temp) 🔥", rpm, dim: false)
        } else if s.mode.hasPrefix("failsafe") || s.mode.hasPrefix("stopped") {
            setTitle("\(temp) ⚠️", "固件控", dim: true)
        } else {
            setTitle(temp, rpm, dim: false)
        }
        buildMenu(s)
    }

    private func add(_ menu: NSMenu, _ title: String,
                     action: Selector? = nil, key: String = "",
                     enabled: Bool = true, indent: Int = 0) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = enabled && action != nil
        mi.indentationLevel = indent
        menu.addItem(mi)
    }

    private func buildMenu(_ s: Status?) {
        let m = NSMenu()
        guard let s else {
            add(m, "⚠️ 守护未运行", enabled: false)
            add(m, "  sudo launchctl bootstrap system \\", enabled: false, indent: 1)
            add(m, "    /Library/LaunchDaemons/com.newmac.fanpilotd.plist", enabled: false, indent: 1)
            m.addItem(.separator())
            add(m, "退出", action: #selector(quit), key: "q")
            item.menu = m
            return
        }

        let modeText: String
        switch s.mode {
        case "normal":    modeText = "自适应控制中"
        case "emergency": modeText = "🔥 紧急全速（温度超阈值）"
        default:          modeText = "⚠️ \(s.mode)"
        }
        add(m, modeText, enabled: false)
        if !s.isFresh {
            add(m, "⚠️ 状态已陈旧 \(Int(Date().timeIntervalSince1970 - s.ts)) 秒 —— 守护可能已卡住",
                enabled: false)
        }
        m.addItem(.separator())

        add(m, String(format: "最热核心   %.1f °C   (%d 个传感器取最大)",
                      s.temp_hottest_c, s.sensors), enabled: false)
        add(m, String(format: "平滑后     %.1f °C   (EMA %.0fs，控制用的就是这个)",
                      s.temp_smoothed_c, s.config.ema_seconds), enabled: false)
        m.addItem(.separator())

        for f in s.fans {
            add(m, String(format: "风扇 %d", f.id), enabled: false)
            add(m, String(format: "实际 %.0f RPM  ·  目标 %.0f RPM",
                          f.actual_rpm, f.target_rpm), enabled: false, indent: 1)
            add(m, String(format: "硬件范围 %.0f ~ %.0f RPM", f.min, f.max),
                enabled: false, indent: 1)
        }
        m.addItem(.separator())

        let maxText = s.config.max_rpm > 0 ? String(format: "%.0f", s.config.max_rpm) : "硬件上限"
        add(m, String(format: "下限 %.0f  ·  上限 %@", s.config.min_rpm, maxText), enabled: false)
        add(m, String(format: "限幅 升%.0f / 降%.0f RPM每秒  ·  死区 %.0f",
                      s.config.slew_up, s.config.slew_down, s.config.deadband), enabled: false)
        add(m, String(format: "轮询 %.1fs  ·  累计写入 SMC %d 次",
                      s.config.poll_interval, s.writes_total), enabled: false)
        m.addItem(.separator())

        add(m, "编辑配置…", action: #selector(openConfig))
        add(m, "重新加载配置", action: #selector(reloadConfig))
        m.addItem(.separator())
        add(m, "退出", action: #selector(quit), key: "q")
        item.menu = m
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    /// 热加载 = 给守护发 SIGHUP。需要 root，所以走 osascript 弹系统授权框
    /// —— 刻意**不**内嵌特权 helper：为了少一个常驻 root 组件，
    /// 那正是我们要替换掉 Macs Fan Control 的理由之一。
    @objc private func reloadConfig() {
        let script = "do shell script \"/usr/bin/killall -HUP fanpilotd\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// --render-preview <png>：把菜单栏那张图连同状态栏边界一起渲染出来，用于**自己**验证
// 垂直居中，而不是让使用者反复肉眼判断。
// （对齐问题连修两版都没中，就是因为我没有可检验的判据 —— 全靠别人看。）
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
   i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let ctrl = Controller()
    let img = ctrl.previewImage("57°C", "2384")
    let h = NSStatusBar.system.thickness
    // 放大 6 倍 + 画出状态栏上下边界，肉眼/程序都能判断是否居中
    let scale: CGFloat = 6
    let canvas = NSImage(size: NSSize(width: img.size.width * scale, height: h * scale))
    canvas.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()
    // 上下边界线（状态栏可用区域）
    NSColor.systemRed.withAlphaComponent(0.5).setStroke()
    let top = NSBezierPath(); top.move(to: NSPoint(x: 0, y: canvas.size.height - 0.5))
    top.line(to: NSPoint(x: canvas.size.width, y: canvas.size.height - 0.5)); top.stroke()
    let bot = NSBezierPath(); bot.move(to: NSPoint(x: 0, y: 0.5))
    bot.line(to: NSPoint(x: canvas.size.width, y: 0.5)); bot.stroke()
    // 中线
    NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
    let mid = NSBezierPath(); mid.move(to: NSPoint(x: 0, y: canvas.size.height / 2))
    mid.line(to: NSPoint(x: canvas.size.width, y: canvas.size.height / 2)); mid.stroke()
    img.draw(in: NSRect(origin: .zero, size: canvas.size),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    canvas.unlockFocus()
    if let tiff = canvas.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: out))
        print("已渲染 \(out)  状态栏高度=\(h)pt  图像=\(img.size)")
    }
    exit(0)
}

let app = NSApplication.shared
let ctrl = Controller()
app.delegate = ctrl
app.run()
