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
    let temp_source: String?        // "max" | "average" | "min"
    let emergency_source: String?   // 紧急判据口径，**独立**于 temp_source
}

struct Status: Decodable {
    let ts: Double
    let mode: String
    let temp_hottest_c: Double
    let temp_average_c: Double?   // 全核平均（旧版状态文件没有）
    let temp_coolest_c: Double?   // 最低核
    let temp_smoothed_c: Double
    let sensors: Int
    let writes_total: Int
    let config: ConfigInfo
    let fans: [FanInfo]

    /// 状态文件是否新鲜。陈旧 = 守护卡住或已死 —— 这种情况必须显示出来，
    /// 不能继续展示旧数字让人以为一切正常（静默展示陈旧值是最难查的问题）。
    var isFresh: Bool { Date().timeIntervalSince1970 - ts < 15 }
}

/// 按口径名取温度。**权威实现是 `src/fanlogic.h` 的 `fl_pick_temp()`**（守护真正用的那份）；
/// 这里只为菜单显示「距紧急阈值还差多少」而镜像一份，不参与任何控制决策。
/// ⚠️ 改 fanlogic.h 的口径语义时，这里也要改。
func fl_pick(_ key: String, _ s: Status) -> Double {
    switch key {
    case "average": return s.temp_average_c ?? s.temp_hottest_c
    case "min":     return s.temp_coolest_c ?? s.temp_hottest_c
    default:        return s.temp_hottest_c
    }
}

let statusPath = "/var/run/fanpilot.status.json"
let configPath = "/usr/local/etc/fanpilot/fanpilot.conf"

func readStatus() -> Status? {
    guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}


// ───────────────────────── 开机自启（用户域 LaunchAgent）─────────────────────────
//
// 只管**菜单栏 App** 自己的自启。
// ⛔ 刻意不提供「守护的自启开关」：守护是真正控风扇的那一半，关掉它风扇就交还固件，
//    整个工具失去意义；而且它是 root LaunchDaemon，改它需要提权。
//    ⇒ 把「显示层的自启」和「控制层的自启」混成一个开关会误导人。
enum LoginItem {
    static let label = "com.newmac.fanpilot.menu"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static let appPath = "/Applications/FanPilot.app/Contents/MacOS/FanPilot"

    /// 判**当前事实**：决定「下次登录会不会起」的是 plist 是否存在。
    /// （不判「我执行过 bootstrap」—— 那是动作不是事实。）
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 当前是否真的被 launchd 管着（用于区分「已启用但本次没加载」）
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
      <!-- 显示层不用 KeepAlive：它挂了不影响风扇控制（守护是独立的 root LaunchDaemon）。
           KeepAlive 是给「挂了就有安全后果」的东西用的，不是给所有东西用的。 -->
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
        // 立即 bootstrap，这样不用等到下次登录也算「已启用且已加载」
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return isEnabled
    }

    /// 关闭自启 = 删掉 plist。
    /// 🩸 刻意**不**调 `launchctl bootout`：那会立刻杀掉正在运行的本 App，
    ///    用户点一下「关闭开机自启」结果 App 消失，看起来像崩溃。
    ///    「以后开机不再启动」≠「现在退出」—— 这两件事不能混。
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
    /// 菜单里所有会变的行，按固定顺序持有引用 —— 刷新时**就地改 title**，
    /// 不整体替换 menu（菜单打开时替换会打断交互）。
    private var dyn: [NSMenuItem] = []
    private var menuBuilt = false
    private var floorItems: [NSMenuItem] = []
    private var loginItem: NSMenuItem?
    private var srcItems: [NSMenuItem] = []
    /// 上一次刷新实际写了多少行 —— 供 `--dump-menu` 做「槽位数 == 写入数」的机械断言。
    private var lastSlotWrites = -1
    private var builtMenu: NSMenu?
    /// 温度口径三档。决定**曲线与菜单栏显示**用哪个温度。
    /// ⚠️ 紧急判据用独立设置 emergency_source，不跟随此项 —— 见 fanlogic.h 的说明。
    static let tempSources: [(key: String, name: String, hint: String)] = [
        ("max",     "最高核心温度", "最保守 · 风扇最早升速"),
        ("average", "全核平均温度", "默认 · 比最高低约 3~13°C"),
        ("min",     "最低核心温度", "最安静 · 比最高低约 20~25°C"),
    ]
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
        // ⭐ 菜单栏显示**控制层实际使用的那个数** —— 显示与控制必须同源，
        //    否则会出现「菜单栏 72° 为什么风扇满转」这种无法解释的不一致。
        let ctlTemp = (s.config.temp_source == "average")
            ? (s.temp_average_c ?? s.temp_hottest_c)
            : s.temp_hottest_c
        let temp = String(format: "%.0f°", ctlTemp)   // 省一个字符宽；单位含义靠 ° 已足够
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
        srcItems.removeAll()

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
        // 🩸 三档温度口径上线时**只加了 set() 没加槽位**，导致从「平滑后」往下
        //    整体错位一格：风扇标题跑到缩进层、轮询行挂到「开机自动启动」下面、
        //    最后一行被静默丢弃（`dyn.indices.contains(i)` 把越界写入吃掉了）。
        //    ⭐ 教训：骨架槽位数与 set() 调用数是**同一个契约的两半**，
        //       改一边必须改另一边 —— 已加 --dump-menu 做机械断言（见文件末尾）。
        _ = dynItem()          // 2  最高核心
        _ = dynItem()          // 3  全核平均
        _ = dynItem()          // 4  最低核心
        _ = dynItem(1)         // 5  平滑后（缩进：它是上面三者之一的派生量）
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
        // 开机自启（可切换）+ 守护自启状态（只读，因为它必须常开）
        loginItem = NSMenuItem(title: "开机自动启动",
                               action: #selector(toggleLogin), keyEquivalent: "")
        loginItem?.target = self
        m.addItem(loginItem!)
        _ = dynItem(1)     // 守护自启状态（只读）
        m.addItem(.separator())

        // ⭐ 温度口径：三档可切，改完即刻生效（守护监视配置 mtime）
        let srcItem = NSMenuItem(title: "温度口径", action: nil, keyEquivalent: "")
        let srcMenu = NSMenu()
        let n1 = NSMenuItem(title: "决定曲线与菜单栏显示用哪个温度", action: nil, keyEquivalent: "")
        n1.isEnabled = false; srcMenu.addItem(n1)
        srcMenu.addItem(.separator())
        for (i, t) in Self.tempSources.enumerated() {
            let mi = NSMenuItem(title: "\(t.name)   ·  \(t.hint)",
                                action: #selector(setTempSource(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = i
            srcMenu.addItem(mi); srcItems.append(mi)
        }
        srcItem.submenu = srcMenu
        m.addItem(srcItem)
        // ⛔ 这里原有一行「90°C 紧急判据用：XXX」。已删除：紧急判据现在直接标在
        //    它所监视的那一行温度旁边（`← 紧急判据 ≥90°C`）。同一事实只写一处 ——
        //    两处并存时，改了一处忘另一处就会出现「菜单自己跟自己矛盾」。
        m.addItem(.separator())

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

        builtMenu = m
        item?.menu = m          // `item?`：--dump-menu 模式下没有状态栏项，不能强解包
        menuBuilt = true
    }

    /// `--dump-menu`：把整份菜单按真实层级打印出来，并断言「骨架槽位数 == 写入行数」。
    /// 🩸 为什么必须有：菜单错位一格（平滑后往下全部串行、最后一行被丢弃）
    ///    靠肉眼看不出来，靠 grep 源码也查不出来 —— 只有**真的把菜单渲染一遍**才暴露。
    ///    这是「用机械量而不是字面量做判据」的又一例。
    func dumpMenu() -> Int32 {
        let s = readStatus()
        updateMenu(s)
        func walk(_ m: NSMenu, _ depth: Int) {
            for it in m.items {
                if it.isSeparatorItem { print(String(repeating: "  ", count: depth) + "───"); continue }
                if it.isHidden { continue }
                let pad = String(repeating: "  ", count: depth + it.indentationLevel)
                let chk = it.state == .on ? " [✓]" : ""
                print(pad + it.title + chk)
                if let sub = it.submenu { walk(sub, depth + 1) }
            }
        }
        guard let m = builtMenu else { print("✗ 菜单未构建"); return 1 }
        walk(m, 0)
        let okSlots = (lastSlotWrites == dyn.count)
        print("\n槽位 \(dyn.count) · 写入 \(lastSlotWrites) · \(okSlots ? "✅ 匹配" : "❌ 不匹配")")
        return okSlots ? 0 : 1
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
        let need = 10 + s.fans.count * 3
        if !menuBuilt || dyn.count != need { buildMenuSkeleton(fanCount: s.fans.count) }
        guard dyn.count == need else { return }

        var i = 0
        func set(_ t: String, hidden: Bool = false) {
            if dyn.indices.contains(i) { dyn[i].title = t; dyn[i].isHidden = hidden }
            i += 1
        }

        let src   = s.config.temp_source ?? "max"
        let esrc  = s.config.emergency_source ?? "max"
        let etemp = s.config.emergency_temp ?? 90
        func srcName(_ k: String) -> String {
            switch k {
            case "average": return "全核平均"
            case "min":     return "最低核心"
            default:        return "最高核心"
            }
        }

        // 第一行说清「现在按什么调速」—— 光写「自适应控制中」等于没说，
        // 使用者真正要知道的是**哪个温度在驱动风扇**（三档可切，切错了不该看不出来）。
        switch s.mode {
        case "normal":    set("自适应控制中  ·  按「\(srcName(src))」调速")
        case "emergency": set(String(format: "🔥 紧急全速 —— 「%@」已达 %.0f°C",
                                     srcName(esrc), etemp))
        default:          set("⚠️ \(s.mode)")
        }
        let age = Int(Date().timeIntervalSince1970 - s.ts)
        set("⚠️ 状态已陈旧 \(age) 秒 —— 守护可能已卡住", hidden: s.isFresh)

        // 三档温度全列出来，并在**它所驱动的那一行**旁边写清它的作用。
        // 🩸 旧版用 `★曲线` / `!紧急` 两个符号，两个问题：
        //    ① 符号没有说明，菜单里没有图例 ⇒ 只有作者看得懂；
        //    ② `！紧急` 读起来像**告警**（"81.9°C！紧急"），实际只是
        //       「紧急阈值盯的是这一档」—— 把状态说成了事件，是最坏的一类误导。
        //    ⇒ 改成箭头 + 完整词组，并把阈值和当前余量一起写出来。
        func mark(_ k: String) -> String {
            var parts: [String] = []
            if k == src  { parts.append("曲线输入") }
            if k == esrc {
                let v = fl_pick(k, s)
                parts.append(v >= etemp
                    ? String(format: "紧急判据 ≥%.0f°C 已触发", etemp)
                    : String(format: "紧急判据 ≥%.0f°C（还差 %.1f）", etemp, etemp - v))
            }
            return parts.isEmpty ? "" : "   ← " + parts.joined(separator: " · ")
        }
        // 固件自己的温控设定点约 88.8°C（SMC-RESEARCH §3：Tf?6 恒定不变，未直接验证）。
        // 最高核心超过它就该让使用者看见 —— 否则菜单里摆着 95°C 却毫无提示。
        let hot = s.temp_hottest_c
        let hotFlag = hot >= 95 ? "   🔥 很烫"
                    : hot >= 88.8 ? "   ⚠️ 偏高（固件设定点约 89°C）" : ""
        set(String(format: "最高核心   %.1f °C%@%@", hot, mark("max"), hotFlag))
        set(String(format: "全核平均   %.1f °C%@", s.temp_average_c ?? -1, mark("average")))
        set(String(format: "最低核心   %.1f °C%@", s.temp_coolest_c ?? -1, mark("min")))
        // 缩进一级：它是上面某一档的派生量，不是第四个独立温度（旧版平级摆放会让人误以为是）
        set(String(format: "平滑后 %.1f °C  ·  EMA %.0fs  ·  这个数才进曲线",
                   s.temp_smoothed_c, s.config.ema_seconds))

        for f in s.fans {
            // 用掉多少散热能力 —— 只看 RPM 数字看不出「还有多少余量没用」，
            // 而这正是三档口径最容易造成误解的地方（选 min 时余量常大量闲置）。
            let used = f.max > 0 ? f.target_rpm / f.max * 100 : 0
            set(String(format: "风扇 %d  —— 已用 %.0f%% 散热能力", f.id, used))
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

        // 守护自启状态（只读）：它必须常开，所以不给开关，但要**显式显示出来**
        let dPlist = "/Library/LaunchDaemons/com.newmac.fanpilotd.plist"
        let dOn = FileManager.default.fileExists(atPath: dPlist)
        set(dOn ? "风扇控制守护：开机自启 ✓（系统级，始终开启）"
                : "⚠️ 风扇控制守护未安装开机自启 —— 重启后风扇将交还固件")

        // 🔴 骨架槽位数 与 set() 调用数 必须严格相等。不等就是有行错位/被丢弃 ——
        //    而 `set` 里的 `dyn.indices.contains(i)` 会把越界写入**静默吃掉**，
        //    实测正是这样让菜单错位一格好几天没人发现（降级必须留痕，不许静默通过）。
        if i != dyn.count {
            let msg = "🐞 菜单槽位不匹配：骨架 \(dyn.count) 行，写入 \(i) 行"
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
            if dyn.indices.contains(0) { dyn[0].title = msg }
        }
        lastSlotWrites = i

        // 勾选当前生效的下限（读的是守护报告的**生效值**，不是我们以为写进去的值）
        for mi in floorItems {
            mi.state = (abs(Double(mi.tag) - s.config.min_rpm) < 1) ? .on : .off
        }
        for mi in srcItems {
            mi.state = (Self.tempSources[mi.tag].key == src) ? .on : .off
        }
        refreshLoginItem()
    }

    @objc private func setTempSource(_ sender: NSMenuItem) {
        guard Self.tempSources.indices.contains(sender.tag) else { return }
        writeConfigKey("temp_source", Self.tempSources[sender.tag].key)
    }

    /// 自启勾选状态。判**当前事实**（plist 是否存在），不判「我点过开关」。
    private func refreshLoginItem() {
        guard let li = loginItem else { return }
        let on = LoginItem.isEnabled
        li.state = on ? .on : .off
        // 「已启用但本次未加载」是个真实存在的中间态，必须说出来而不是显示成正常
        if on && !LoginItem.isLoaded {
            li.title = "开机自动启动（已启用，下次登录生效）"
        } else {
            li.title = "开机自动启动"
        }
    }

    @objc private func toggleLogin() {
        let want = !LoginItem.isEnabled
        let ok = want ? LoginItem.enable() : LoginItem.disable()
        if !ok {
            notify("设置开机自启失败",
                   want ? "写不了 \(LoginItem.plistURL.path)"
                        : "删不掉 \(LoginItem.plistURL.path)")
        }
        refreshLoginItem()
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
            // 报错要给**可操作**的下一步，不能只说「失败了」
            notify("改配置失败",
                   """
                   写不了 \(configPath)

                   \(error.localizedDescription)

                   多半是配置属主被改成了 root。修复：
                   sudo chown $(whoami) \(configPath)
                   """)
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
