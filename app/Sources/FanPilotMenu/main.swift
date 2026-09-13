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
    let fault: Bool?          // 守护检测到的风扇故障（旧版状态文件没有此字段）
}

struct ConfigInfo: Decodable {
    let min_rpm: Double
    let max_rpm: Double
    let poll_interval: Double
    let ema_seconds: Double
    let slew_up: Double
    let slew_down: Double
    let deadband: Double
    let emergency_temp: Double?
    let curve_autoscale: Int?
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
let configPath = "/usr/local/etc/fanpilot/fanpilot.conf"

func readStatus() -> Status? {
    guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}

// ───────────────────────── 菜单栏 ─────────────────────────

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    /// 菜单里所有会变的行，按固定顺序持有引用 —— 刷新时**就地改 title**，
    /// 不整体替换 menu（菜单打开时替换会打断交互）。
    private var dyn: [NSMenuItem] = []
    private var menuBuilt = false
    private var floorItems: [NSMenuItem] = []
    /// 可选下限档位（6 档）。
    /// ⭐ 刻意**不做自由输入框**：输错一个数字就可能把机器闷住或让风扇常驻高噪，
    ///   而这里根本不需要连续可调 —— 高温段的转速由曲线自适应接管，
    ///   下限只决定「最安静时的地板」。给档位而不给输入框，是拿掉一整类用户错误。
    /// 上界只到 4000：更高的**常驻**转速噪音大且无必要（真要更高，高温段会自动铺上去）。
    static let floorChoices = [1500, 2000, 2500, 3000, 3500, 4000]

    func applicationDidFinishLaunching(_: Notification) {
        // .accessory = 只在菜单栏出现，不进 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        item.menu?.delegate = self
        refresh()
        // 🩸 必须加到 .common 模式：默认的 .default 模式在菜单打开时
        //    （NSEventTrackingRunLoopMode 模态跟踪）**不会触发** ——
        //    那会导致「菜单一打开，里面的数字就冻在打开那一刻」，
        //    而且一关菜单又恢复正常，极难发现。
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
    /// 菜单栏的显示状态。用枚举而不是散落的 bool —— 避免出现「既紧急又陈旧」这类
    /// 自相矛盾的组合，也让每个状态的视觉表达只在一处定义。
    enum Vis { case normal, emergency, fault, firmware, stale }

    private func twoLineImage(_ top: String, _ bottom: String, _ vis: Vis) -> NSImage {
        let h = NSStatusBar.system.thickness          // 实测本机 22pt
        // ⭐ 字号由「两行必须装进 h」反推：9pt 行高约 11pt ⇒ 两行 23pt > 22pt 装不下，
        //    溢出只能往上顶 —— 那才是早先「靠上对齐」的真因。
        let fontSize: CGFloat = 8
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let ink = NSColor.black
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let sTop = NSAttributedString(string: top, attributes: attrs)
        let sBot = NSAttributedString(string: bottom, attributes: attrs)

        // 🩸 固定宽度（消除横跳），但宽度要**尽量窄** —— 菜单栏是稀缺空间，
        //    我们多占一点，别人就少一点。两处收窄：
        //    ① 参照串用 "100°" 而不是 "100°C"：省掉一个字符宽，仍明确是温度
        //    ② **不预留独立标记列**：文字右对齐，短内容天然在左侧留出空隙，
        //       状态标记就画在那段空隙里 ⇒ 标记不额外占宽度
        //    实测：34pt → 见 --render-preview 输出（约 -8pt）
        let refTemp = NSAttributedString(string: "100°", attributes: attrs)
        let refRPM  = NSAttributedString(string: "5777", attributes: attrs)
        let w = ceil(max(refTemp.size().width, refRPM.size().width)) + 1

        let glyphH = ceil(font.ascender - font.descender)
        let gap: CGFloat = 0
        let pad = max(0, (h - glyphH * 2 - gap) / 2)
        let wTop = ceil(sTop.size().width), wBot = ceil(sBot.size().width)

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        // 右对齐（等宽数字 + 右对齐 = 视觉最稳）
        sBot.draw(at: NSPoint(x: w - wBot - 1, y: pad))
        sTop.draw(at: NSPoint(x: w - wTop - 1, y: pad + glyphH + gap))

        // 🩸 状态标记**不能用 emoji**：isTemplate=true 时 AppKit 丢掉颜色、
        //    只用 alpha 当遮罩 ⇒ 🔥 变成一坨纯黑块（已用模板着色模拟实测确证）。
        //    改成自己画的几何标记，单色下依然清晰。
        switch vis {
        case .emergency:
            // 实心竖条 + 顶部缺口，单色下像个感叹号，且宽度不变
            ink.setFill()
            NSRect(x: 0, y: pad + 2, width: 2.5, height: h - pad * 2 - 6).fill()
            NSRect(x: 0, y: pad, width: 2.5, height: 2).fill()
        case .fault:
            // 扁而宽的实心三角（警告号）——垂直居中。
            // 早先做成 5pt宽×20pt高，单色下看着像「尖刺」而不是三角，与紧急态的
            // 实心竖条不易区分。压扁后形状特征明确。
            let cy = h / 2
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: 2.0, y: cy + 3.5))
            tri.line(to: NSPoint(x: 0.0, y: cy - 3.0))
            tri.line(to: NSPoint(x: 4.0, y: cy - 3.0))
            tri.close()
            ink.setFill(); tri.fill()
        case .normal, .firmware, .stale:
            break
        }
        img.unlockFocus()
        img.isTemplate = true

        if vis == .firmware || vis == .stale {
            // 非受控状态用半透明表达（模板着色仍生效）
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
    func previewImage(_ top: String, _ bottom: String, _ vis: Vis = .normal) -> NSImage {
        twoLineImage(top, bottom, vis)
    }

    private func setTitle(_ top: String, _ bottom: String, _ vis: Vis) {
        guard let b = item.button else { return }
        b.image = twoLineImage(top, bottom, vis)
        b.imagePosition = .imageOnly
        b.title = ""
    }

    private func refresh() {
        guard let s = readStatus() else {
            setTitle("--°", "停", .stale)
            updateMenu(nil)
            return
        }
        // 显示两风扇实际转速的**平均**。因为守护给两个风扇下的是同一个目标，
        // 平均值天然是故障指示器：一个风扇停转 ⇒ 平均腰斩（2000 → 1000）一眼可见。
        // （若两风扇目标各异，平均就会掩盖故障 —— 那时才必须改成别的口径。）
        let avgRPM = s.fans.map(\.actual_rpm).reduce(0, +) / Double(max(s.fans.count, 1))
        let temp = String(format: "%.0f°", s.temp_hottest_c)   // 省一个字符宽；单位含义靠 ° 已足够
        let rpm  = String(format: "%.0f", avgRPM)

        let anyFault = s.fans.contains { $0.fault == true }
        if !s.isFresh {
            // 陈旧就要说出来，绝不静默展示旧值
            setTitle(temp, "陈旧", .stale)
        } else if s.mode.hasPrefix("failsafe") || s.mode.hasPrefix("stopped") {
            setTitle(temp, "固件", .firmware)
        } else if anyFault {
            // 故障优先于紧急显示：紧急是"该干的活"，故障是"硬件不对"
            setTitle(temp, rpm, .fault)
        } else if s.mode == "emergency" {
            setTitle(temp, rpm, .emergency)
        } else {
            setTitle(temp, rpm, .normal)
        }
        updateMenu(s)
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

    /// 建一次菜单骨架。**所有会变的行都预先建好**（包括平时隐藏的告警行），
    /// 这样刷新时索引恒定、只改 title，不增删项 —— 菜单打开时也能安全更新。
    private func buildMenuSkeleton(fanCount: Int) {
        let m = NSMenu()
        m.delegate = self
        dyn.removeAll()
        floorItems.removeAll()

        func dynItem(_ indent: Int = 0) -> NSMenuItem {
            let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.indentationLevel = indent
            m.addItem(mi)
            dyn.append(mi)
            return mi
        }

        _ = dynItem()          // 0  模式
        _ = dynItem()          // 1  陈旧告警（平时 isHidden）
        m.addItem(.separator())
        _ = dynItem()          // 2  最热核心
        _ = dynItem()          // 3  平滑后
        m.addItem(.separator())
        for _ in 0..<fanCount {
            _ = dynItem()      // 风扇标题
            _ = dynItem(1)     // 实际/目标(+故障)
            _ = dynItem(1)     // 硬件范围
        }
        m.addItem(.separator())
        _ = dynItem()          // 下限/上限
        _ = dynItem()          // 限幅/死区
        _ = dynItem()          // 轮询/写入
        m.addItem(.separator())

        // ⭐ 唯一需要用户调的东西：转速下限。
        //    不给「编辑配置文件」和「重新加载」——让用户去编辑配置文件、再手动 reload，
        //    本身就是设计失败。守护监视配置 mtime 自动重载，所以点一下即刻生效。
        let floorItem = NSMenuItem(title: "转速下限", action: nil, keyEquivalent: "")
        let floorMenu = NSMenu()
        // 一句话掐掉最容易产生的误解（选高档 ≠ 高负载时更凉）
        let note = NSMenuItem(title: "只影响空闲时的噪音与温度基线", action: nil, keyEquivalent: "")
        note.isEnabled = false
        floorMenu.addItem(note)
        let note2 = NSMenuItem(title: "高温时一律铺到硬件上限，与此设置无关", action: nil, keyEquivalent: "")
        note2.isEnabled = false
        floorMenu.addItem(note2)
        floorMenu.addItem(.separator())
        for v in Self.floorChoices {
            // ⭐ 标签必须描述**真实语义**：下限只决定「空闲时的地板转速」，
            //    它**不改变高温时的散热能力** —— 曲线永远铺到硬件上限(5349/5777)。
            //    🩸 初版把 4000 标成「强散热」是误导：会让人以为选高档能压住高负载。
            //       真实的取舍是「空闲噪音 ↔ 温度基线」，标签就该说这个。
            let hint: String
            switch v {
            case 1500: hint = "最静 · 温度基线最高"
            case 2000: hint = "安静 · 默认"
            case 2500: hint = "较静"
            case 3000: hint = "均衡"
            case 3500: hint = "偏凉 · 常有风声"
            default:   hint = "最凉 · 风声明显"
            }
            let mi = NSMenuItem(title: "\(v) RPM   ·  \(hint)",
                                action: #selector(setFloor(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = v
            floorMenu.addItem(mi)
            floorItems.append(mi)
        }
        floorItem.submenu = floorMenu
        m.addItem(floorItem)

        m.addItem(.separator())
        add(m, "退出", action: #selector(quit), key: "q")

        item.menu = m
        menuBuilt = true
    }

    /// 就地更新（不重建）。dyn 的顺序必须与 buildMenuSkeleton 完全一致。
    private func updateMenu(_ s: Status?) {
        guard let s else {
            if !menuBuilt || dyn.count < 4 { buildMenuSkeleton(fanCount: 0) }
            if dyn.indices.contains(0) { dyn[0].title = "⚠️ 守护未运行"; dyn[0].isHidden = false }
            for i in 1..<dyn.count { dyn[i].isHidden = true }
            return
        }
        // 风扇数变了才重建骨架（正常永不发生，但别假设）
        let need = 7 + s.fans.count * 3
        if !menuBuilt || dyn.count != need { buildMenuSkeleton(fanCount: s.fans.count) }
        guard dyn.count == need else { return }

        var i = 0
        func set(_ t: String, hidden: Bool = false) {
            if dyn.indices.contains(i) { dyn[i].title = t; dyn[i].isHidden = hidden }
            i += 1
        }

        switch s.mode {
        case "normal":    set("自适应控制中")
        case "emergency": set("🔥 紧急全速（温度超阈值）")
        default:          set("⚠️ \(s.mode)")
        }
        let age = Int(Date().timeIntervalSince1970 - s.ts)
        set("⚠️ 状态已陈旧 \(age) 秒 —— 守护可能已卡住", hidden: s.isFresh)

        set(String(format: "最热核心   %.1f °C   (%d 个传感器取最大)",
                   s.temp_hottest_c, s.sensors))
        set(String(format: "平滑后     %.1f °C   (EMA %.0fs，控制用的就是这个)",
                   s.temp_smoothed_c, s.config.ema_seconds))

        for f in s.fans {
            set(String(format: "风扇 %d", f.id))
            set(String(format: "实际 %.0f RPM  ·  目标 %.0f RPM%@",
                       f.actual_rpm, f.target_rpm,
                       f.fault == true ? "   ⚠️ 疑似故障" : ""))
            set(String(format: "硬件范围 %.0f ~ %.0f RPM", f.min, f.max))
        }

        let maxText = s.config.max_rpm > 0 ? String(format: "%.0f", s.config.max_rpm) : "硬件上限"
        set(String(format: "下限 %.0f  ·  上限 %@", s.config.min_rpm, maxText))
        set(String(format: "限幅 升%.0f / 降%.0f RPM每秒  ·  死区 %.0f",
                   s.config.slew_up, s.config.slew_down, s.config.deadband))
        set(String(format: "轮询 %.1fs  ·  累计写入 SMC %d 次",
                   s.config.poll_interval, s.writes_total))

        // 勾选当前生效的下限（读的是守护报告的**生效值**，不是我们以为写进去的值）
        for mi in floorItems {
            mi.state = (abs(Double(mi.tag) - s.config.min_rpm) < 1) ? .on : .off
        }
    }

    // 菜单即将打开时立刻刷一次，避免展示上一个 tick 的旧值
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    /// 改转速下限：只改配置文件里的 min_rpm 一行，守护监视 mtime 自动重载。
    ///
    /// 刻意**不**用 osascript 提权发 SIGHUP：那会每次弹密码框，而且为了显示层
    /// 引入提权路径与「少一个常驻 root 组件」的初衷相悖。
    @objc private func setFloor(_ sender: NSMenuItem) {
        let v = sender.tag
        guard v > 0 else { return }
        writeConfigKey("min_rpm", String(v))
    }

    /// 就地替换配置里某个 key 的值，保留其余内容（含注释）。
    /// 原子写：先写临时文件再 rename —— 守护随时可能在读，不能让它看到半个文件。
    private func writeConfigKey(_ key: String, _ value: String) {
        let url = URL(fileURLWithPath: configPath)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            notify("改配置失败", "读不到 \(configPath)")
            return
        }
        var lines = text.components(separatedBy: "\n")
        var replaced = false
        for (i, line) in lines.enumerated() {
            // 只匹配「行首(可空白) key (可空白) =」，避免命中注释里出现的同名词
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key) else { continue }
            let after = t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard after.hasPrefix("=") else { continue }
            // 保留行尾注释
            let comment = line.firstIndex(of: "#").map { String(line[$0...]) } ?? ""
            lines[i] = "\(key) = \(value)" + (comment.isEmpty ? "" : "    " + comment)
            replaced = true
            break
        }
        if !replaced { lines.append("\(key) = \(value)") }
        text = lines.joined(separator: "\n")

        let tmp = url.appendingPathExtension("tmp")
        do {
            try text.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            notify("改配置失败", "写不了 \(configPath)：\(error.localizedDescription)")
            return
        }
        // 不弹成功提示：下一次 refresh(≤2s) 菜单里的勾选与数值会自己更新，
        // 那就是最好的确认 —— 判「当前事实」，不判「我执行了动作」。
    }

    private func notify(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// --render-preview <png>：把菜单栏那张图连同状态栏边界一起渲染出来，用于**自己**验证
// 垂直居中，而不是让使用者反复肉眼判断。
// （对齐问题连修两版都没中，就是因为我没有可检验的判据 —— 全靠别人看。）
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
   i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let a = CommandLine.arguments
    let topStr = (i + 2 < a.count) ? a[i + 2] : "57°C"
    let botStr = (i + 3 < a.count) ? a[i + 3] : "2384"
    let visArg = (i + 4 < a.count) ? a[i + 4] : "normal"
    let vis: Controller.Vis
    switch visArg {
    case "emergency": vis = .emergency
    case "fault":     vis = .fault
    case "firmware":  vis = .firmware
    case "stale":     vis = .stale
    default:          vis = .normal
    }
    let ctrl = Controller()
    let img = ctrl.previewImage(topStr, botStr, vis)
    // 诊断：报告位图的真实像素尺寸 vs 点尺寸 —— 判断是否被以 1x 渲染（Retina 会糊）
    for r in img.representations {
        FileHandle.standardError.write(
          "  rep: \(r.pixelsWide)x\(r.pixelsHigh)px  声明 \(r.size)pt\n".data(using: .utf8)!)
    }
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

    // ⭐ 模拟 isTemplate=true 的真实效果：AppKit **丢掉颜色**，只用 alpha 当遮罩着色。
    //    不模拟这一步的预览是有盲区的 —— 彩色 emoji 在预览里好看，
    //    在真实菜单栏里会变成纯色剪影。判据必须复现真实渲染路径。
    let tmpl = NSImage(size: canvas.size)
    tmpl.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()
    NSColor.black.set()
    let r = NSRect(origin: .zero, size: canvas.size)
    r.fill(using: .sourceOver)
    // 用图像 alpha 反向擦出形状（destinationIn 保留 alpha 交集）
    img.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
    tmpl.unlockFocus()
    let tmplOut = out.replacingOccurrences(of: ".png", with: "-template.png")
    if let t = tmpl.tiffRepresentation, let rp = NSBitmapImageRep(data: t),
       let pg = rp.representation(using: .png, properties: [:]) {
        try? pg.write(to: URL(fileURLWithPath: tmplOut))
        print("模板着色模拟 → \(tmplOut)")
    }
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
