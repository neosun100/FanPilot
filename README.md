<p align="center">
  <img src="assets/logo.svg" width="120" height="120" alt="FanPilot"/>
</p>

<h1 align="center">FanPilot</h1>

<p align="center">
  <b>macOS 风扇定速工具</b><br/>
  把风扇定在你要的转速，然后什么都不做。
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/macOS-13%2B%20·%20Apple%20Silicon-0F4C75"/>
  <img alt="tests" src="https://img.shields.io/badge/tests-155%20passing-3AAFA9"/>
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue"/>
</p>

---

## 这是什么

macOS 不让你控制风扇转速。机器凉的时候风扇完全停转，热起来才由固件接管——而固件的启动阈值很高（本机实测 **68.8 °C 时风扇仍是 0 转**）。

FanPilot 只做一件事：**把两个风扇定死在你指定的百分比**（如 50%、88%），并在菜单栏显示最高核心温度。

| | |
|---|---|
| **定速** | 一个百分比管两个风扇：各按自己的硬件上限折算（本机 85% ⇒ 4547 / 4910 RPM） |
| **几乎不打扰系统** | 写一次就不再动 SMC —— **稳态写 SMC 0 次**；每 10 s 一次只读巡检；见 [资源占用](#资源占用) |
| **防写入风暴** | 写入令牌桶硬上限 + 发现别的程序抢写时主动让步，绝不互相拉锯 |
| **失效安全** | 睡眠 / 退出 / 读不到温度都交还出厂的「固件自动控制」；过热（默认全核平均 ≥ 90 °C）直接打满 |

> ⚠️ 本工具直接写 SMC 风扇寄存器。目标值都被夹在硬件自己报告的 `F*Mn`~`F*Mx` 范围内。
> 但你仍应了解自己在做什么。

---

## 安装

> **要求**：Apple Silicon Mac · macOS 13+ · 与其它风扇控制软件**互斥**（两者会抢写 SMC）
>
> 📊 **已经在用 Macs Fan Control？** 先看
> [**21 项实测对照**](docs/COMPARISON-macs-fan-control.md) 再决定换不换 ——
> 每一行都标了证据来源，也如实写了 **MFC 更好的 5 个地方**（公证签名、机型广度、成熟度…）。
> 最要紧的一条差别：MFC **不注册电源通知**，合盖睡眠时风扇会按固定值继续转。

### 第 0 步：先做兼容性预检（只读，什么都不改）

FanPilot 依赖 SMC 的 `F*Tg` 键可写、`FNum` 可读、`Tp*` 传感器存在。这些在不同机型上不一定成立，
所以**先确认你的机器支不支持，再装东西**——不要先装一个 root 守护、然后才发现不兼容。

```bash
tar -xzf FanPilot-*.tar.gz && cd FanPilot-*/
bash install/precheck.sh
```

输出示例（本机）：

```
── SMC 接口（决定能不能用）
  ✅ SMC 可读（IOServiceMatching("AppleSMC") 成功）
  ✅ 检测到 2 个风扇（FNum）
  ✅ 风扇0: 范围 1350~5349 RPM · 当前 2014 RPM · 模式 0（0=固件 1=手动）
  ✅ 风扇1: 范围 1350~5777 RPM · 当前 2018 RPM · 模式 0
  ✅ 温度传感器可读（当前最热 53.7 °C）
── 冲突检查
  ✅ 无其它风扇控制软件
  ✅ 完全兼容，可以安装
```

有 ❌ 阻断项就**不要装**。预检完全只读，不会改动任何东西。

### 方式 A：用安装包（推荐）

从 [Releases](https://github.com/neosun100/FanPilot/releases/latest) 下载 `FanPilot-<版本>.tar.gz`：

```bash
tar -xzf FanPilot-*.tar.gz
cd FanPilot-*/
bash install.sh
```

`install.sh` 会依次做 5 件事，每步都会打印结果：

| 步骤 | 做什么 | 要 sudo？ |
|---|---|:--:|
| 1 | 解除 Gatekeeper 隔离（见下方说明） | ❌ |
| 2 | 跑兼容性预检 + 冲突检查，**有阻断项就中止** | ❌ |
| 3 | 装控制守护 `fanpilotd`（root LaunchDaemon） | ✅ |
| 4 | 装菜单栏 App 到 `/Applications` + 开机自启 | ❌ |
| 5 | 跑 29 项验收，全绿才算成功 | ✅ |

> **为什么要 sudo**：写 SMC 风扇寄存器需要 root（读不需要）。守护是**全机唯一**能写 SMC 的进程；
> 菜单栏 App 完全无特权，只读状态文件。这个权限边界是刻意划的，见[架构](#架构)。

> **关于 Gatekeeper**：包内二进制是 **ad-hoc 签名**（自用工具，没有 Apple Developer ID）。
> 从网上下载的文件带 `com.apple.quarantine` 属性，Gatekeeper 会拒绝执行。
> `install.sh` 第一步执行 `xattr -dr com.apple.quarantine` 解除——
> 这不是绕过安全机制，而是你对自己下载的东西做**显式授信**。
> 介意的话请走方式 B 从源码编译。

### 方式 B：从源码编译

不想信任预编译二进制就自己编。需要 **Xcode Command Line Tools**（`xcode-select --install`）：

```bash
git clone https://github.com/neosun100/FanPilot.git
cd FanPilot

make                 # 编译守护 fanpilotd 与命令行工具 fanctl（C，无第三方依赖）
make precheck        # 兼容性预检（只读）
make install         # 装 root LaunchDaemon（会要 sudo）
make verify          # 29 项验收，含反向断言

make app                        # 编译菜单栏 App（需要 Swift 6+）
bash install/install-app.sh     # 装 App + 开机自启（不需要 sudo）
```

跑一遍全部测试（可选，155 项）：`make test`

### 装了什么、装在哪

装 root 守护这种事应该完全透明：

| 路径 | 内容 | 谁的 |
|---|---|---|
| `/usr/local/sbin/fanpilotd` | 控制守护（约 55 KB，纯 C） | root |
| `/Library/LaunchDaemons/com.newmac.fanpilotd.plist` | 守护的 launchd 配置（`RunAtLoad` + `KeepAlive`） | root |
| `/usr/local/etc/fanpilot/fanpilot.conf` | 配置（`key = value`，带注释） | **你**（App 要能改） |
| `/var/run/fanpilot.status.json` | 运行状态（守护写，`0644`） | root 写 / 所有人可读 |
| `/var/log/fanpilotd.log` | 守护日志 | root |
| `/Applications/FanPilot.app` | 菜单栏 App（约 300 KB） | 你 |
| `~/Library/LaunchAgents/com.newmac.fanpilot.menu.plist` | App 的开机自启 | 你 |

不装任何内核扩展、不改 SIP、不装第三方依赖、不联网。

### 确认装好了

```bash
cat /var/run/fanpilot.status.json      # 应看到实时温度与两个风扇的目标/实际转速
sudo launchctl print system/com.newmac.fanpilotd | grep -E 'state|runs'
```

`state = running` 且 `runs = 1` 就对了。**`runs` 短时间暴涨说明守护在崩溃重启循环**（`KeepAlive` 在反复救它），
这时看 `/var/log/fanpilotd.log`。

菜单栏右侧应出现两行小字：上行温度、下行转速。

### 卸载

```bash
sudo bash install/uninstall.sh    # 守护
# App：
launchctl bootout gui/$(id -u)/com.newmac.fanpilot.menu
rm -f ~/Library/LaunchAgents/com.newmac.fanpilot.menu.plist
rm -rf /Applications/FanPilot.app
```

> 卸载脚本**先让守护把风扇交还固件，再删文件**。顺序反了会把风扇永久留在手动模式
> ——实测 SMC **不会**自动回退（停止写入 60 秒后仍保持手动）。脚本里还有一道无条件兜底，
> 即使守护的信号处理没跑成也会强制写回 `F*md=0`。

### 常见问题

**菜单栏没出现图标？**
App 是 `LSUIElement`（不进 Dock），只在菜单栏。若菜单栏项太多可能被折叠——
先确认进程在跑：`pgrep -x FanPilot`。日志在 `/tmp/fanpilot-menu.log`。

**显示「守护未运行」？**
`sudo launchctl print system/com.newmac.fanpilotd` 看状态，`/var/log/fanpilotd.log` 看原因。
最常见是**有其它风扇软件在抢写 SMC**——安装时会检测并拒绝，但如果是装完之后才装的其它软件就不会被拦。

**选定速档报 Permission denied？**
配置属主被改成了 root。修：`sudo chown $(whoami) /usr/local/etc/fanpilot/fanpilot.conf`
（原子写需要**目录**也可写，所以配置放在专属目录 `/usr/local/etc/fanpilot/` 下）。

**风扇一直不转 / 转速是 0？**
先跑预检确认 `F*Tg` 可写。若守护 `mode` 显示 `stopped_firmware_auto`，
说明它已交还固件——固件在凉的时候本来就让风扇停转（本机实测 68.8 °C 时仍是 0 转）。

---

## 使用

<p align="center">
  <img src="assets/menubar-states.png" alt="菜单栏四种状态" width="100%"/>
</p>

菜单栏两行：上行**最高核心温度**、下行两个风扇的平均实际转速。
固定宽度，四种状态宽度一致，**不会横跳挤占其他图标**。状态标记是**贴底细条**而不是 emoji：

- **正常** —— 无标记
- **紧急全速** —— 贴底实心条（温度 ≥ 阈值，两风扇打满；降到阈值 − 5 °C 以下恢复定速）
- **风扇故障** —— 贴底虚线条（某个风扇实际转速不到目标一半）
- **固件接管 / 陈旧** —— 整体变淡（守护已退出，或状态超过 3 个巡检周期没更新）

点开下拉面板：

```
定速运行中  ·  稳态不写 SMC
────────────────────────────────
最高核心   81.8 °C
全核平均   75.0 °C   ← 紧急判据 ≥90°C（还差 15.0）
────────────────────────────────
风扇 0  —— 目标 4547 RPM（上限 5349 的 85%）
    实际 4553 RPM  ·  硬件范围 1350 ~ 5349
风扇 1  —— 目标 4910 RPM（上限 5777 的 85%）
    实际 4905 RPM  ·  硬件范围 1350 ~ 5777
────────────────────────────────
每 10s 巡检一次  ·  累计写 SMC 4 次
────────────────────────────────
固定转速        85%   ▸   30% … 100% 八档 · 自定义百分比…
开机自动启动
```

选一档**即刻生效**（守护监视配置目录），不需要密码、不需要「重新加载」。
要 88% 这种不在档位里的值，点「自定义百分比…」输入即可（0~100；低于硬件下限按下限转，不会停转）。

### 配置

```ini
percent = 85            # 各风扇硬件上限的百分比（0~100），两风扇各自折算
check_interval = 10     # 安全巡检间隔（秒，5~60）
emergency_temp = 90     # 紧急打满阈值（70~95，硬夹）
emergency_source = average   # 紧急判据：max（最高核心）/ average（全核平均）/ min
```

配置对你可写（菜单栏 App 无特权），所以它被当作**不可信输入**：所有安全阈值在守护代码里硬夹。

### 温度读数可信吗？

验过。`SMC` 类型是 `flt`（IEEE-754），手工核对过字节级解码；与第三方 App 独立实现交叉验证；
并用物理反证排除了华氏度（若空闲期的 34 是华氏 = 1.1 °C，比室温低 35 度，不可能）。
完整四项验证见 [`docs/SMC-RESEARCH.md` §3.1](docs/SMC-RESEARCH.md)。

> 顺带一个会让人困惑的现象：其它温度 App 可能显示比我们**低约 10 °C**。
> 那不是单位错，而是它们把多个键（含风扇区等偏凉的传感器）**混合并平滑**后显示。
> 两个数都对，口径不同；混合平滑值低于真实结温，不适合当控制输入。

---

## 架构

<p align="center">
  <img src="assets/architecture.svg" alt="FanPilot 架构" width="100%"/>
</p>

两层按权限隔离，数据单向流动：

- **`fanpilotd`**（root LaunchDaemon，C）—— 全机唯一能写 SMC 的进程。`flock` 单实例锁，`KeepAlive` 兜底。
- **`FanPilot.app`**（菜单栏，Swift/AppKit）—— **无任何权限**，只读状态 JSON，绝不碰 SMC。

配置文件对用户可写（否则无特权的 App 改不了设置），因此**配置被当作不可信输入**：所有安全阈值在守护代码里硬夹，不相信文件里写的值。

### 事件驱动：写一次，然后什么都不做

SMC 的 `F*md=1`（手动）与 `F*Tg`（目标）是**锁存**寄存器——实测停写 60 秒后仍保持。所以：

| 事件 | 守护做什么 |
|---|---|
| 启动 / 唤醒 / 改配置 | 写 `md=1` + `Tg=目标`（回读已一致则不写） |
| 每 10 s 巡检 | **只读**：温度 + 回读风扇寄存器。① 过热 ⇒ 打满 ② 被外部改了 ⇒ 纠正 ③ 读不到温度 ⇒ 交还固件 |
| 系统将睡眠 | 交还固件 |
| `SIGTERM` | 交还固件后退出 |

信号、配置变化、电源事件都由 dispatch source / IOKit 通知**推**过来，没有任何轮询定时器。

### 🔴 防写入风暴

1.x 自适应模式约 **2.3 万次/天** 写 SMC，与本机 2026-09-13~14 的 5 次 PMU 看门狗复位相关
（相关 ≠ 因果，见 CHANGELOG 1.3.0）。2.0 稳态写入为 0，另有两道硬上限防 bug 与防抢写：

| 防线 | 规则 | 单测里的最坏情形 |
|---|---|---|
| 写入令牌桶 | 突发 ≤ 40 次，长期 ≤ 120 次/小时，超出停写并留痕 | 每秒都想写、持续 1 小时 ⇒ 放行 ≤ 121 次 |
| 抢写让步 | 10 分钟内被外部改动 ≥ 3 次 ⇒ 让步 30 分钟 | 被持续抢写 1 天 ⇒ 纠正写入 ≤ 294 次，且不拉锯 |
| 紧急回差 | 进入 ≥ 阈值，解除 < 阈值 − 5 °C | 温度在 89/91 °C 抖 20 次 ⇒ 只切换 1 次 |

### 失效安全

| 场景 | 机制 | 暴露窗口 |
|---|---|---|
| 正常退出 / `SIGTERM` / 卸载 | 信号处理器写 `F*md=0` 交还固件 | 0 |
| `SIGKILL` / 崩溃 / 内核 panic | launchd `KeepAlive` 重启，新实例接管 | ~1 s |
| 传感器读取失败 | 立即交还固件，不用陈旧值继续控制 | 0 |
| **系统睡眠 / 合盖** | `kIOMessageSystemWillSleep` → 写 `F*md=0` 交还固件；唤醒后重新接管 | 0 |

实测确认 **SMC 不会自动回退**（停止写入 60 秒后仍保持手动模式），所以 `KeepAlive` 不是可选项而是安全机制本身。

⭐ 守护死掉时风扇保持最后的定速 —— 比出厂固件空闲时的 0 转风量大，失效方向偏安全。

🩸 **睡眠那一条曾经完全不存在**，代价是真实发生过的 bug：2026-09-14 合盖睡眠 44 分钟（电池），
风扇按睡前的 **3822 RPM 一直转**。根因是设计时把「失效」等同于**进程死掉**，
漏了「进程活着但被冻结」——而冻结比死掉更危险：死掉有 `KeepAlive` 重启接管，
冻结让一条陈旧指令在硬件寄存器里无限期生效，且正好发生在最不该吹风的时候。

睡眠路径最难测（要真睡一次，且睡着时没有任何进程能记录），所以做了可离线触发的判据：

```bash
sudo fanpilotd --selftest-pm     # 投喂一条 WillSleep，回读 F*md 是否真变 0
```

---

## 资源占用

2026-10-28 本机实测（M5 Max，`powermetrics --samplers tasks` 120 秒窗口；`ps` RSS）：

| | CPU | 唤醒 / 秒 | 内存 | 稳态写 SMC |
|---|---:|---:|---:|---:|
| **`fanpilotd` 2.0** | **0.017 %** | **0.20** | **5.8 MB** | **0** |
| FanPilot.app 2.0（菜单栏） | 0.026 % | 0.43 | 45 MB | —（从不写） |
| `fanpilotd` 1.x（自适应） | 0.10 % | 0.66 | 5.7 MB | ≈ 2.3 万次/天 |
| Macs Fan Control 1.5.21 | 0.30 ~ 0.35 % | 5.6 | 148.5 MB | ≈ 0 |

App 的 45 MB 几乎全是 AppKit 本身；它每 10 秒读一次状态文件，内容不变就不重绘。
`verify.sh` 把守护的预算钉成门禁：**CPU < 0.05 %、RSS < 8 MB、稳态 60 秒写 SMC = 0 次**，超了即验收失败。

---

## 测试

```bash
make test     # 单元 60 + 验收 29 + E2E/回归 66 = 155 项
```

| 层 | 内容 |
|---|---|
| `tests/unit_logic.c` | **60 项** —— `fanlogic.h` 全部纯逻辑：配置解析、硬夹、百分比折算、紧急回差、防写入风暴（令牌桶 / 抢写让步） |
| `install/verify.sh` | **29 项** —— 运行状态、失效安全、**稳态 60 秒 0 写入**、资源预算、反向断言 |
| `tests/e2e.sh` | **66 项** —— 用户路径 + 按真实 bug 编号的回归（含活体：目录噪音不触发重载、被抢写时让步） |

关键判据都做过**变异验证**：把修过的缺陷改回去（容差 50、桶容量 16、去掉回差、永远重写、不剥注释……），测试必须变红 —— 8/8 变红。

**反向断言和正向断言一样重要**——只验"能用"会漏掉"不该能用的也能用"。例如：越界百分比必须被夹、第二个实例必须启动失败、恶意配置的安全阈值必须被夹住、0 写入必须伴随「巡检仍在进行」（否则可能是卡死的假绿）。

---

## 文档

| | |
|---|---|
| [`docs/COMPARISON-macs-fan-control.md`](docs/COMPARISON-macs-fan-control.md) | **与 Macs Fan Control 的 21 项实测对照**（每行标注证据来源：实测／源码核实／未验证）。含 MFC 明确更好的 5 个地方 —— 不粉饰 |
| [`docs/SMC-RESEARCH.md`](docs/SMC-RESEARCH.md) | SMC 逆向调研：键位、可写性判定、传感器筛选方法、全部实测数据 |
| [`docs/PLAN.md`](docs/PLAN.md) | 设计与开发计划：控制算法、安全红线、资源预算、被推翻的设计 |

调研工具（全部只读，不写任何 SMC 键）：

```bash
make research
./research/smcprobe    # 枚举全部 3669 个 SMC 键 + 风扇现状
./research/sensors     # 传感器普查 + 可写性属性
./research/sample 70 2 # 时序采样（判传感器响应性用）
./research/bench       # 读取开销基准
```

> 🩸 **传感器必须按「时序方差」筛，不能按瞬时值筛。** 按数值排最热的两个键是 `Tf06`=88.81 °C 与
> `Tf16`=85.97 °C，看着像热点告警——实测 70 秒 35 个样本**标准差 0.000**，它们是常量
> （很可能是固件跳闸点），不是实时温度。判据是方差，不是瞬时值。

---

## 兼容性

在 **MacBook Pro M5 Max (Mac17,6) / macOS 26.6.2 / SIP 启用**上开发与实测。

不硬编码任何机型参数：风扇数量取自 `FNum`，上下限取自 `F*Mn`/`F*Mx`，传感器在启动时枚举。
理论上适用于有可写 `F*Tg` 键的 Apple Silicon Mac，但**只在上述机型验证过**。

---

## 待办

- [ ] **下拉面板真截图** —— `assets/menubar-states.png` 是 App **渲染代码导出的真实输出**
      （不是模拟图），但下拉面板需要人工截图（`Cmd+Shift+4`）。不用模拟图冒充截图。
- [ ] **真机合盖复验睡眠交接** —— 代码路径已用 `fanpilotd --selftest-pm` 验证
      （投喂 `kIOMessageSystemWillSleep` 后回读 `F*md` 确认变 0），但**真实合盖一次**
      的端到端确认还没做。判据：合盖 10 分钟后掀开，
      `pmset -g log | grep "Entering Sleep"` 有条目 + 全程听不到风扇
- [ ] **其他机型验证** —— 只在 **Mac17,6 (M5 Max)** 实测过。
      `install/precheck.sh` 可在安装前只读自检，但没有其它机型的真机数据
- [ ] **`Tf?6` 是否真是固件跳闸点** —— `Tf06`=88.81 / `Tf16`=85.97 恒定不变，
      一致性很强但无直接证据（见 [`docs/SMC-RESEARCH.md`](docs/SMC-RESEARCH.md) §6）
- [ ] **`fanctl kv` 的温度口径与守护不同** —— 它只读 5 个键（守护读 23 个），
      两边的 `temp_hottest` 可能不同。机器可读面应改成透传守护的状态 JSON

---

## 许可

MIT
