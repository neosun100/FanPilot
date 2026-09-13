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
    /// 🩸 垂直居中要显式做，不能指望默认行为：
    ///   初版用 `lineSpacing = -2.5` 挤压行距，结果整块文字**靠上对齐**（用户实测反馈）。
    ///   负的 lineSpacing 会让 AppKit 的多行布局往上溢出。
    /// ⭐ 正解：用 min/maxLineHeight **固定每行高度**（不要用负行距），
    ///   再用 baselineOffset 把整块下移到按钮垂直中心。
    ///   状态栏按钮高约 22pt，两行 × lineH ⇒ 上下各留 (22 - 2*lineH)/2。
    private func twoLineTitle(_ top: String, _ bottom: String, dim: Bool) -> NSAttributedString {
        let fontSize: CGFloat = 9
        let lineH: CGFloat = 9.5          // 每行固定高度（正值，别用负行距）
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        p.lineSpacing = 0
        p.minimumLineHeight = lineH
        p.maximumLineHeight = lineH
        let color: NSColor = dim ? .disabledControlTextColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .paragraphStyle: p,
            .foregroundColor: color,
            // 负值 = 整块下移。菜单栏文字默认贴上沿，这里把它压到垂直居中。
            .baselineOffset: NSNumber(value: -1.0),
        ]
        return NSAttributedString(string: "\(top)\n\(bottom)", attributes: attrs)
    }

    private func refresh() {
        guard let s = readStatus() else {
            item.button?.attributedTitle = twoLineTitle("FanPilot", "守护未运行", dim: true)
            buildMenu(nil)
            return
        }
        let avgRPM = s.fans.map(\.actual_rpm).reduce(0, +) / Double(max(s.fans.count, 1))
        let temp = String(format: "%.0f°C", s.temp_hottest_c)
        let rpm  = String(format: "%.0f", avgRPM)

        if !s.isFresh {
            // 陈旧就要说出来，绝不静默展示旧值
            item.button?.attributedTitle = twoLineTitle("\(temp) ⚠️", "陈旧", dim: true)
        } else if s.mode == "emergency" {
            item.button?.attributedTitle = twoLineTitle("\(temp) 🔥", rpm, dim: false)
        } else if s.mode.hasPrefix("failsafe") || s.mode.hasPrefix("stopped") {
            item.button?.attributedTitle = twoLineTitle("\(temp) ⚠️", "固件控", dim: true)
        } else {
            item.button?.attributedTitle = twoLineTitle(temp, rpm, dim: false)
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

let app = NSApplication.shared
let ctrl = Controller()
app.delegate = ctrl
app.run()
