// FanPilotMenu —— 菜单栏显示（无任何特权）
//
// 职责边界（刻意划得很窄）：
//   ✅ 读 /var/run/fanpilot.status.json 显示温度与转速
//   ✅ 选一个百分比 → 改配置文件里的 `percent` 一行（守护监视目录，即刻生效）
//   ❌ **绝不直接写 SMC** —— 写入是 root 守护的唯一职责
//   ❌ 不申请任何权限、不内嵌 helper
//
// 资源纪律（2.0）：
//   · 刷新 10 秒一次（= 守护巡检间隔；更快只是重复读同一份文件）
//   · 显示内容没变就**不重绘**菜单栏图像
//   · 「launchctl print」这类要 fork 子进程的查询**只在打开菜单时**做
//     🩸 1.x 每 2 秒刷新都 fork 一次 launchctl ⇒ 约 4.3 万次进程创建/天

import AppKit
import Foundation

// ───────────────────────── 状态模型 ─────────────────────────

struct FanInfo: Decodable {
    let id: Int
    let set_rpm: Double
    let target_rpm: Double
    let actual_rpm: Double
    let min: Double
    let max: Double
}

struct ConfigInfo: Decodable {
    let percent: Double
    let check_interval: Double
    let emergency_temp: Double
    let emergency_source: String
}

struct Status: Decodable {
    let ts: Double
    let mode: String
    let temp_hottest_c: Double
    let temp_average_c: Double
    let temp_coolest_c: Double
    let sensors: Int
    let writes_total: Int
    let external_overrides: Int
    let config: ConfigInfo
    let fans: [FanInfo]

    /// 陈旧 = 守护卡住或已死 —— 必须显示出来，不能继续展示旧数字让人以为一切正常。
    /// 阈值 = 3 个巡检周期 + 5s 余量（守护每个周期都会写一次）。
    var isFresh: Bool { Date().timeIntervalSince1970 - ts < config.check_interval * 3 + 5 }

}

let statusPath = "/var/run/fanpilot.status.json"
let configPath = "/usr/local/etc/fanpilot/fanpilot.conf"
let daemonPlist = "/Library/LaunchDaemons/com.newmac.fanpilotd.plist"

func readStatus() -> Status? {
    guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}

// ───────────────────────── 开机自启（用户域 LaunchAgent）─────────────────────────
//
// 只管**菜单栏 App** 自己的自启。守护是 root LaunchDaemon、必须常开，不给开关。
enum LoginItem {
    static let label = "com.newmac.fanpilot.menu"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static let appPath = "/Applications/FanPilot.app/Contents/MacOS/FanPilot"

    /// 判**当前事实**：决定「下次登录会不会起」的是 plist 是否存在。
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 是否真的被 launchd 管着。⚠️ 会 fork 一个 launchctl —— 只许在打开菜单时调用。
    static var isLoaded: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static let plistBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key><array><string>\(appPath)</string></array>
      <key>RunAtLoad</key><true/>
      <!-- 显示层不用 KeepAlive：它挂了不影响风扇控制（守护是独立的 root LaunchDaemon） -->
      <key>KeepAlive</key><false/>
      <key>ProcessType</key><string>Interactive</string>
      <key>StandardOutPath</key><string>/tmp/fanpilot-menu.log</string>
      <key>StandardErrorPath</key><string>/tmp/fanpilot-menu.log</string>
    </dict>
    </plist>
    """

    @discardableResult
    static func enable() -> Bool {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? plistBody.write(to: plistURL, atomically: true, encoding: .utf8)) != nil
        else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return isEnabled
    }

    /// 关闭自启 = 删掉 plist。刻意**不** bootout：那会立刻杀掉正在运行的本 App。
    @discardableResult
    static func disable() -> Bool {
        try? FileManager.default.removeItem(at: plistURL)
        return !isEnabled
    }
}

// ───────────────────────── 菜单栏 ─────────────────────────

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    /// 菜单里所有会变的行，按固定顺序持有引用 —— 刷新时**就地改 title**，不整体替换。
    private var dyn: [NSMenuItem] = []
    private var menuBuilt = false
    private var loginItem: NSMenuItem?
    private var fixedRoot: NSMenuItem?
    private var presetItems: [NSMenuItem] = []
    /// 上一次刷新实际写了多少行 —— 供 `--dump-menu` 做「槽位数 == 写入数」的机械断言。
    private var lastSlotWrites = -1
    private var builtMenu: NSMenu?
    private var lastTitle = ""

    /// 定速档：**各风扇硬件上限的百分比**（使用者 2026-10-28 指定只用一个百分比）。
    /// 两风扇上限不同（5349 / 5777），同一百分比各自折算 ⇒ 两风扇「一样卖力」。
    /// 「自定义…」可输入任意 0~100：任何值最终都被守护夹在硬件 [F*Mn, F*Mx] 内，
    /// 且过热打满不受此设置影响 ⇒ 输入框不会把机器置于危险状态。
    static let presets: [(pct: Int, hint: String)] = [
        (30, "最静"), (40, "安静"), (50, "均衡"), (60, "偏凉"),
        (70, "凉 · 有风声"), (80, "很凉 · 风声明显"), (90, "接近全速"), (100, "全速"),
    ]
    private var customItem: NSMenuItem?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 只在菜单栏出现，不进 Dock、不抢焦点
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        refresh()
        // 🩸 必须加到 .common 模式：默认的 .default 模式在菜单打开时（事件跟踪模式）
        //    **不会触发** ⇒ 菜单一打开里面的数字就冻住。
        let t = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 2.0       // 允许系统把唤醒和别的定时器合并（省电）
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 菜单栏两行显示：上行温度、下行转速（自己渲染成模板图，见下方 🩸）
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
        let pad = max(2, (h - glyphH * 2 - gap) / 2 + 1)   // +1 给贴底标记条让位
        let wTop = ceil(sTop.size().width), wBot = ceil(sBot.size().width)

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        // 右对齐（等宽数字 + 右对齐 = 视觉最稳）
        sBot.draw(at: NSPoint(x: w - wBot - 1, y: pad))
        sTop.draw(at: NSPoint(x: w - wTop - 1, y: pad + glyphH + gap))

        // 🩸 状态标记的两条约束，都是实测踩出来的：
        //   ① **不能用 emoji**：isTemplate=true 时 AppKit 丢掉颜色、只用 alpha 当遮罩
        //      ⇒ 🔥 变成一坨纯黑块（已用模板着色模拟确证）
        //   ② **不能画在左侧空隙里**：初版靠"文字右对齐天然留左空隙"来放标记，
        //      但下限是 4 位数时（5349 / 1247）文字占满全宽、左边没有空隙，
        //      标记直接压在数字上，数字读不出来。
        //      而加一个专用标记列又要多占 ~5pt 宽度（菜单栏是稀缺空间）。
        // ⇒ 正解：画成**贴底的整宽细条**。零宽度成本，且位于文字下沿之外，
        //   物理上不可能与任何文字重叠。
        switch vis {
        case .emergency:
            // 实心整宽条 = 最强提示
            ink.setFill()
            NSRect(x: 0, y: 0, width: w, height: 2).fill()
        case .fault:
            // 虚线整宽条（3 段）= 与紧急态一眼可分，且同样不占宽度
            ink.setFill()
            let seg = (w - 4) / 3
            for k in 0..<3 {
                NSRect(x: CGFloat(k) * (seg + 2), y: 0, width: seg, height: 2).fill()
            }
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
        // 显示内容没变就不重绘（每次重绘都要分配位图 + 让菜单栏重新合成）
        let key = "\(top)|\(bottom)|\(vis)"
        guard key != lastTitle else { return }
        lastTitle = key
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
        // 两风扇实际转速的平均。注意两风扇目标不同（各自按百分比），
        // 所以平均**不能**当故障指示 —— 故障在菜单里逐风扇判（见 updateMenu）。
        let avgRPM = s.fans.map(\.actual_rpm).reduce(0, +) / Double(max(s.fans.count, 1))
        // 菜单栏温度 = **最高核心**（使用者 2026-10-28 指定：最关注整颗 CPU 最热的那一处）。
        // 紧急判据用哪个口径另由配置 emergency_source 决定，菜单里标在对应那一行旁边。
        let temp = String(format: "%.0f°", s.temp_hottest_c)
        let rpm  = String(format: "%.0f", avgRPM)
        if !s.isFresh {
            setTitle(temp, "陈旧", .stale)        // 陈旧就说出来，绝不静默展示旧值
        } else if s.mode.hasPrefix("failsafe") || s.mode.hasPrefix("stopped") {
            setTitle(temp, "固件", .firmware)
        } else if s.fans.contains(where: fanLooksFaulty) {
            setTitle(temp, rpm, .fault)
        } else if s.mode == "emergency" {
            setTitle(temp, rpm, .emergency)
        } else {
            setTitle(temp, rpm, .normal)
        }
        updateMenu(s)
    }

    /// 实际转速不到目标一半 = 疑似故障（卡住 / 断线）。
    /// 定速模式下目标只在启动/改档时变化，爬升 0→满速实测 6~9s < 一个刷新周期，误报窗口很小。
    private func fanLooksFaulty(_ f: FanInfo) -> Bool {
        f.target_rpm > 0 && f.actual_rpm >= 0 && f.actual_rpm < f.target_rpm * 0.5
    }

    /// 建一次菜单骨架。**所有会变的行都预先建好**，刷新时索引恒定、只改 title。
    private func buildMenuSkeleton(fanCount: Int) {
        let m = NSMenu()
        m.delegate = self
        dyn.removeAll()
        presetItems.removeAll()

        func dynItem(_ indent: Int = 0) {
            let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.indentationLevel = indent
            m.addItem(mi)
            dyn.append(mi)
        }

        dynItem()              // 0 状态
        dynItem()              // 1 陈旧告警（平时 isHidden）
        m.addItem(.separator())
        dynItem()              // 2 最高核心
        dynItem()              // 3 全核平均
        m.addItem(.separator())
        for _ in 0..<fanCount {
            dynItem()          // 风扇 N  定速 …
            dynItem(1)         // 实际 … RPM
        }
        m.addItem(.separator())
        dynItem()              // SMC 写入 / 外部改动
        m.addItem(.separator())

        // ⭐ 唯一需要用户调的东西：定速档。入口右侧显示当前值（不用点开就知道）。
        let root = NSMenuItem(title: "固定转速", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let note = NSMenuItem(title: "两个风扇按各自硬件上限的百分比 · 选完即刻生效", action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        sub.addItem(.separator())
        for p in Self.presets {
            let mi = NSMenuItem(title: "", action: #selector(setPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = p.pct
            sub.addItem(mi)
            presetItems.append(mi)
        }
        sub.addItem(.separator())
        let custom = NSMenuItem(title: "自定义百分比…", action: #selector(askCustom), keyEquivalent: "")
        custom.target = self
        sub.addItem(custom)
        customItem = custom
        root.submenu = sub
        m.addItem(root)
        fixedRoot = root
        m.addItem(.separator())

        loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem?.target = self
        m.addItem(loginItem!)
        dynItem(1)             // 守护自启状态（只读）
        m.addItem(.separator())
        let q = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)

        builtMenu = m
        item?.menu = m          // `item?`：--dump-menu 模式下没有状态栏项
        menuBuilt = true
    }

    /// `--dump-menu`：把整份菜单按真实层级打印出来，并断言「骨架槽位数 == 写入行数」。
    /// 🩸 1.x 菜单错位一格好几天没人发现 —— 只有真的把菜单渲染一遍才暴露。
    func dumpMenu() -> Int32 {
        updateMenu(readStatus())
        func walk(_ m: NSMenu, _ depth: Int) {
            for it in m.items {
                if it.isSeparatorItem { print(String(repeating: "  ", count: depth) + "───"); continue }
                if it.isHidden { continue }
                let pad = String(repeating: "  ", count: depth + it.indentationLevel)
                print(pad + it.title + (it.state == .on ? " [✓]" : ""))
                if let sub = it.submenu { walk(sub, depth + 1) }
            }
        }
        guard let m = builtMenu else { print("✗ 菜单未构建"); return 1 }
        walk(m, 0)
        let okSlots = (lastSlotWrites == dyn.count)
        print("\n槽位 \(dyn.count) · 写入 \(lastSlotWrites) · \(okSlots ? "✅ 匹配" : "❌ 不匹配")")
        return okSlots ? 0 : 1
    }

    /// 某个百分比对应每个风扇的 RPM —— **镜像** `fanlogic.h` 的 `fl_fan_target()`
    /// （权威实现在那里；这里只用于菜单显示，不参与控制）
    private func presetRPMs(_ pct: Double, _ s: Status) -> [Int] {
        s.fans.map { f in Int(min(f.max, max(f.min, (f.max * pct / 100 + 0.5).rounded(.down)))) }
    }

    private func updateMenu(_ s: Status?) {
        guard let s else {
            if !menuBuilt || dyn.count < 2 { buildMenuSkeleton(fanCount: 0) }
            dyn[0].title = "⚠️ 守护未运行 —— 风扇由固件自动控制"
            dyn[0].isHidden = false
            for i in 1..<dyn.count { dyn[i].isHidden = true }
            lastSlotWrites = dyn.count
            return
        }
        let need = 6 + s.fans.count * 2
        if !menuBuilt || dyn.count != need { buildMenuSkeleton(fanCount: s.fans.count) }
        guard dyn.count == need else { return }

        var i = 0
        func set(_ t: String, hidden: Bool = false) {
            if dyn.indices.contains(i) { dyn[i].title = t; dyn[i].isHidden = hidden }
            i += 1
        }

        let et = s.config.emergency_temp
        switch s.mode {
        case "normal":    set("定速运行中  ·  稳态不写 SMC")
        case "emergency": set(String(format: "🔥 紧急全速 —— 温度已达 %.0f°C（降到 %.0f°C 以下恢复定速）",
                                     et, et - 5))
        case "failsafe_sensor_read_failed": set("⚠️ 读不到温度 —— 已交还固件自动控制")
        case "stopped_firmware_auto":       set("守护已停止 —— 风扇由固件自动控制")
        case "yielded_external_writer":     set("🛑 有别的程序在改风扇 —— FanPilot 暂时让步 30 分钟（改一次档可立即接管）")
        case "write_budget_exhausted":      set("🛑 SMC 写入过于频繁 —— 已暂停写入，几分钟后自动恢复")
        default:          set("⚠️ \(s.mode)")
        }
        let age = Int(Date().timeIntervalSince1970 - s.ts)
        set("⚠️ 状态已陈旧 \(age) 秒 —— 守护可能已卡住", hidden: s.isFresh)

        // 紧急判据标在它所盯的那一行温度旁，带阈值与余量（同一事实只写一处）
        func mark(_ key: String, _ v: Double) -> String {
            guard key == s.config.emergency_source else { return "" }
            return v >= et ? String(format: "   ← 紧急判据 ≥%.0f°C 已触发", et)
                           : String(format: "   ← 紧急判据 ≥%.0f°C（还差 %.1f）", et, et - v)
        }
        set(String(format: "最高核心   %.1f °C%@", s.temp_hottest_c, mark("max", s.temp_hottest_c)))
        set(String(format: "全核平均   %.1f °C%@", s.temp_average_c, mark("average", s.temp_average_c)))

        for f in s.fans {
            let pct = f.max > 0 ? f.target_rpm / f.max * 100 : 0
            set(String(format: "风扇 %d  —— 目标 %.0f RPM（上限 %.0f 的 %.0f%%）", f.id, f.target_rpm, f.max, pct))
            set(String(format: "实际 %.0f RPM  ·  硬件范围 %.0f ~ %.0f%@",
                       f.actual_rpm, f.min, f.max, fanLooksFaulty(f) ? "   ⚠️ 疑似故障" : ""))
        }
        set(String(format: "每 %.0fs 巡检一次  ·  累计写 SMC %d 次%@",
                   s.config.check_interval, s.writes_total,
                   s.external_overrides > 0
                     ? String(format: "  ·  ⚠️ 被外部改动 %d 次（有别的风扇软件？）", s.external_overrides)
                     : ""))

        let dOn = FileManager.default.fileExists(atPath: daemonPlist)
        set(dOn ? "风扇守护：开机自启 ✓（系统级，始终开启）"
                : "⚠️ 风扇守护未安装开机自启 —— 重启后风扇将交还固件")

        // 🔴 骨架槽位数与 set() 调用数必须严格相等（越界写入会被 contains 静默吃掉）
        if i != dyn.count {
            let msg = "🐞 菜单槽位不匹配：骨架 \(dyn.count) 行，写入 \(i) 行"
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
            dyn[0].title = msg
        }
        lastSlotWrites = i

        // 定速档：判**守护报告的生效值**，不判「我点过哪个」
        let pct = s.config.percent
        var matched = false
        for mi in presetItems {
            let rpms = presetRPMs(Double(mi.tag), s)
            let hint = Self.presets.first { $0.pct == mi.tag }?.hint ?? ""
            mi.title = "\(mi.tag)%   ·  \(rpms.map(String.init).joined(separator: " / ")) RPM   ·  \(hint)"
            let on = abs(Double(mi.tag) - pct) < 0.05
            mi.state = on ? .on : .off
            matched = matched || on
        }
        customItem?.state = matched ? .off : .on
        customItem?.title = matched ? "自定义百分比…" : String(format: "自定义百分比…（当前 %@%%）", pctText(pct))
        fixedRoot?.title = "固定转速        \(pctText(pct))%"
    }

    /// 自启勾选状态。判**当前事实**（plist 是否存在 + 是否被 launchd 加载）。
    private func refreshLoginItem() {
        guard let li = loginItem else { return }
        let on = LoginItem.isEnabled
        li.state = on ? .on : .off
        li.title = (on && !LoginItem.isLoaded) ? "开机自动启动（已启用，下次登录生效）" : "开机自动启动"
    }

    @objc private func toggleLogin() {
        let want = !LoginItem.isEnabled
        let ok = want ? LoginItem.enable() : LoginItem.disable()
        if !ok {
            notify("设置开机自启失败",
                   want ? "写不了 \(LoginItem.plistURL.path)" : "删不掉 \(LoginItem.plistURL.path)")
        }
        refreshLoginItem()
    }

    /// 打开菜单时：立刻刷一次（不展示上一个 tick 的旧值），并做那些要 fork 子进程的查询
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === builtMenu else { return }   // 子菜单打开也会回调，只处理根菜单
        refresh()
        refreshLoginItem()
    }

    private func pctText(_ p: Double) -> String {
        p == p.rounded() ? String(format: "%.0f", p) : String(format: "%.1f", p)
    }

    @objc private func setPreset(_ sender: NSMenuItem) {
        writeConfigKey("percent", String(sender.tag))
    }

    /// 自定义百分比：一个输入框。只接受 0~100 的数字，否则说清楚为什么不收。
    @objc private func askCustom() {
        let a = NSAlert()
        a.messageText = "固定转速（百分比）"
        a.informativeText = "0~100。两个风扇按各自硬件上限折算；低于硬件下限会按下限转，不会停转。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = readStatus().map { pctText($0.config.percent) } ?? "50"
        a.accessoryView = field
        a.addButton(withTitle: "设定")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        a.window.level = .floating
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
                                   .replacingOccurrences(of: "%", with: "")
        guard let v = Double(raw), v >= 0, v <= 100 else {
            notify("没有设定", "「\(field.stringValue)」不是 0~100 之间的数字。")
            return
        }
        writeConfigKey("percent", pctText(v))
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
            notify("改配置失败",
                   """
                   写不了 \(configPath)

                   \(error.localizedDescription)

                   多半是配置属主被改成了 root。修复：
                   sudo chown $(whoami) \(configPath)
                   """)
            return
        }
        // 不弹成功提示：守护即刻重载，下一次刷新菜单里的勾选会自己更新 —— 判当前事实
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// 🔴 弹窗必须先 activate + 置顶再 runModal：.accessory App 的裸 runModal
    ///    会藏在别的窗口后面 ⇒ 菜单全灰「卡死」（macos-menubar-app 铁律 7）。
    private func notify(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.window.level = .floating
        a.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// --dump-menu：打印整份菜单 + 断言槽位契约。退出码非 0 = 菜单结构坏了。
if CommandLine.arguments.contains("--dump-menu") {
    // 必须先持有强引用：NSMenuItem.target 是 weak，临时对象会在语句内就被释放
    let dumpCtrl = Controller()
    exit(dumpCtrl.dumpMenu())
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
