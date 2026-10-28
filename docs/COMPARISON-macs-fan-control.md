# FanPilot vs Macs Fan Control —— 实测对照清单

> **这份文档的纪律：每一行都标注证据来源。** 分三档：
> **🔬 实测** = 在本机跑出来的数字／回读 · **📄 源码核实** = 读了代码或符号表 ·
> **❔ 未验证** = 没测过，**不下结论**（MFC 闭源，很多项只能是这一档）。
>
> 对照环境：MacBook Pro M5 Max（Mac17,6）· macOS 26.6.2 (25G83) ·
> Macs Fan Control **1.5.21**（测于 2026-09-20）· FanPilot **2.0.0**（测于 2026-10-28）。
>
> 🔴 **更正（2026-10-28）**：本文初版对照的是 FanPilot 1.3.0，第一条结论写的是「要随温度自动调速 ⇒ 选 FanPilot」。
> **2.0 已删除自适应曲线**，FanPilot 现在同样是定速 —— 那条结论不再成立，已改为下面的「过热保护」。
> 资源数字也已换成 2.0 的实测值（1.3.0 的旧值写在括号里）。
>
> ⚠️ 本文不是推销。MFC 在**若干维度上明确更好**（见 §3），照实写。

---

## 0. 一句话结论

| 你在意什么 | 选哪个 |
|---|---|
| **定速但过热时自动打满** | **FanPilot** —— 定速 + 全核平均 ≥ 90 °C 两风扇打满（5 °C 回差）；MFC 的固定转速不响应温度（实测代价见 §1 第 9 行）|
| **命令行/脚本控制** | **FanPilot** —— MFC 没有任何 CLI/AppleScript/URL scheme（📄 四路核实）|
| **合盖睡眠时风扇停转** | **FanPilot** —— 🔴 MFC **不注册电源通知**，睡眠时风扇按固定值继续转（§2 详述）|
| **资源占用** | **FanPilot** —— 守护 5.8 MB vs MFC 148.5 MB；唤醒 0.20/s vs 5.6/s |
| **签名与公证、机型广度、界面成熟度** | **Macs Fan Control** —— 它是正经公证的商业软件，FanPilot 只有 ad-hoc 签名且**只在一台机器上验证过** |

---

## 1. 逐项对照

| # | 维度 | FanPilot 2.0.0 | Macs Fan Control 1.5.21 | 证据 |
|---|---|---|---|---|
| 1 | **睡眠交还固件** | ✅ 注册 `IORegisterForSystemPower`，`kIOMessageSystemWillSleep` 时写 `F*md=0` | 🔴 **无**。主二进制、特权 helper、全部 Qt 框架**均未导入任何电源管理符号**，只导入 `IOServiceOpen` + `IOConnectCallStructMethod` | 📄 `dyld_info -imports`（方法已过正对照，见 §4）|
| 2 | **命令行控制** | ✅ `fanctl` + 配置文件 | 🔴 **完全没有**：包内无 CLI 二进制 · 无 `.sdef`（不支持 AppleScript）· `Info.plist` 无 `CFBundleURLTypes` · 主程序 `strings` 无任何 `--xxx`/`usage:` | 📄 四路核实 |
| 3 | **配置真源** | ✅ **配置文件**。守护监视配置目录，改完**即刻生效**（原地编辑 ≤ 10 s），不用重启、不用提权 | ⚠️ **进程内存才是真源**。偏好里只是快照（`ActivePreset` = base64 的 `UNSAVED\|1,3200\|1,3200`），必须**重启 App** 才读；且它退出时会**回写覆盖**你的外部修改 | 🔬 base64 解码 + 与 SMC `F*Tg` 交叉验证一致 |
| 4 | **CPU（稳态）** | **0.017%**（1.3.0：0.100%） | **0.30 ~ 0.35%** | 🔬 双方都是 `powermetrics --samplers tasks` 实测（FanPilot 2026-10-28 120 s 窗口；MFC 2026-09-20 两窗口） |
| 5 | **内存 RSS** | **5.8 MB** 守护 + 45 MB 菜单栏 App | **148.5 MB**（主程序 135.5 + helper 13.0） | 🔬 `ps -o rss` |
| 6 | **亚 2ms 定时器** | **0.00 /s** | **0.00 /s** —— 打平，MFC 这项做得很干净 | 🔬 |
| 7 | **唤醒次数** | **0.20 /s** 守护 + 0.43 /s App（1.3.0 守护：0.66 /s） | **5.57 ~ 5.78 /s** | 🔬 |
| 8 | **SMC 写入（稳态）** | **0 次**（验收门禁：60 s 窗口必须为 0）；另有令牌桶 + 抢写让步两道硬上限 | 固定值写一次后基本不再写（实测 `F*Tg` 恒 3200）⇒ 实质也是 **0** | 🔬 `verify.sh` D2；MFC 侧为 SMC 回读 |
| 9 | **过热保护** | ✅ 定速 + 紧急判据温度 ≥ 90 °C 时打满（2.0 已删除自适应曲线） | 🔴 **不会响应温度**。固定值就是固定值 | 🔬 **实测代价**：2026-09-19 MFC 钉 3200 时最高核心冲到 **97.5 °C**（`TCMb` 104 °C），而硬件上限 5349/5777 **只用了 58%** |
| 10 | **签名与公证** | 🔴 **仅 ad-hoc**，无 Developer ID，需 `xattr -dr com.apple.quarantine` | ✅ **Notarized Developer ID**（Ilya Parniuk, ACC5R6RH47）·`spctl` 返回 `accepted` | 📄 `codesign -dv` + `spctl -a -vv` |
| 11 | **开源可审计** | ✅ MIT，全部源码可读 | 🔴 闭源 | — |
| 12 | **SMC 写入键白名单** | ✅ 只允许 `F0md/F1md/F0Tg/F1Tg`，其余一律拒绝（`fanpilotd.c:85`）| ❔ **未验证**（闭源，无法确认它写哪些键）| 📄 / ❔ |
| 13 | **值域夹取** | ✅ 夹在**运行时读到的** `F*Mn`~`F*Mx` 内。<br>⚠️ 诚实补充：`--check-config` 在 SMC 打不开时用本机实测值 `{5349, 5777}` 兜底（`fanpilotd.c:491`）—— **只影响诊断打印，不影响控制路径** | ❔ 未验证 | 📄 源码逐行核实 |
| 14 | **失效安全路径** | ✅ 四条：`SIGTERM`→交还固件 · `SIGKILL`/崩溃→`KeepAlive` ~1s 接管 · 传感器读失败→立即交还 · **睡眠→交还** | ❔ 前三条未验证；**第四条已确证不存在**（见第 1 行）| 📄 |
| 15 | **测试** | ✅ 单元 **112 通过 / 0 失败**（2026-09-20 重跑确认）+ 验收 25 + E2E/回归 45 | ❔ 不适用（闭源）| 🔬 `make unit` |
| 16 | **状态机器可读** | ✅ `/var/run/fanpilot.status.json`（0644，所有人可读）| 🔴 无 | 📄 |
| 17 | **单实例锁** | ✅ `flock`，防两个实例抢写同一组寄存器 | ❔ 未验证 | 📄 |
| 18 | **机型支持广度** | 🔴 **只在 Mac17,6 (M5 Max) 实测过**。不硬编码机型参数（风扇数取 `FNum`、上下限取 `F*Mn`/`F*Mx`），理论上通用但**无其它机型数据** | ✅ 支持极广，含 Intel 与各代 Apple Silicon，多年迭代 | — |
| 19 | **传感器展示丰富度** | 仅控制所需（23 个 `Tp*` + 风扇键）| ✅ 展示大量传感器、多种单位、菜单栏可选显示项 | — |
| 20 | **互斥性** | 🔴 **两者不能共存** —— 会抢写同一组 SMC 寄存器。FanPilot 安装脚本会检测并拒绝安装 | 同 | 🔬 曾实测过野守护与 MFC 抢寄存器，目标值在 3300 ↔ 2540 之间来回跳 |
| 21 | **价格** | 免费（MIT）| 免费（捐赠制）| — |

---

## 2. 🔴 最要紧的一条：MFC 睡眠时风扇不停

**证据链三段，每段都可复算：**

1. **MFC 不注册电源通知** —— `dyld_info -imports` 在主二进制、特权 helper、全部 Qt 框架上
   对 `IORegisterForSystemPower` 命中数**均为 0**；它只导入 `IOServiceOpen` 与
   `IOConnectCallStructMethod`（即纯 SMC 访问）。同一方法在 FanPilot 守护上命中 **1**（正对照通过）。
2. **SMC 手动模式是锁存寄存器** —— 本机实测：停止写入 **60 秒**后 `F*md` 仍为 `1`，**不会自动回退**。
3. **经验先例（同一台机器）** —— FanPilot v1.2.0 之前也缺这条路径，实测合盖睡眠
   **44 分 2 秒**（`Clamshell Sleep`·电池·窗口内零 DarkWake），风扇按睡前的 **3822 RPM**
   一直转到掀盖；整个用户态被冻结，守护一次 SMC 都没写。

⇒ **在 MFC 下合盖带走，风扇会按你设的固定值继续转。** 这不是推测，是同机制在本机被测过一次。

⭐ 这条的通用教训（已写进 FanPilot 架构文档）：
> **把「失效」等同于*进程死掉*是不够的 —— 漏了*进程活着但被冻结*。**
> 冻结比死掉更危险：死掉有 `KeepAlive` 重启接管，冻结让一条陈旧指令在硬件寄存器里无限期生效，
> 且正好发生在最不该吹风的时候。

---

## 3. MFC 明确更好的地方（不粉饰）

1. **公证签名** —— MFC 是 Notarized Developer ID；FanPilot 只有 ad-hoc 签名，从网上下载还要手动解除隔离。
   对多数人来说这是**更重要**的差别。
2. **机型广度** —— MFC 跨 Intel 与各代 Apple Silicon 多年验证；FanPilot **只在一台机器上测过**，
   其它机型属理论兼容。
3. **成熟度与界面** —— 多年迭代的 GUI、丰富传感器展示、多语言。FanPilot 的菜单栏面板功能很窄。
4. **亚 2ms 定时器同为 0** —— MFC 这项做得很干净，不是"重量级 GUI 就一定脏"。
5. **无需 root 守护常驻** —— MFC 用按需调用的特权 helper；FanPilot 是常驻 root LaunchDaemon，
   攻击面更大（虽然有键白名单与值域夹取）。

---

## 4. 🩸 做这份对照时踩的判据坑（方法学，比结论更值得记）

**判断「MFC 有没有注册电源通知」时，我先后用了 5 种方法，只有 1 种是对的。**

| 方法 | 在 FanPilot（**已知阳性**）上的结果 | 结论 |
|---|---|---|
| `strings` | 命中 **0** | ❌ 无分辨力 |
| `nm -u` | 命中 **0** | ❌ 无分辨力 |
| `nm -m` | 命中 **0** | ❌ 无分辨力 |
| `otool -Iv` | 命中 **0** | ❌ 无分辨力 |
| **`dyld_info -imports`** | 命中 **1** | ✅ **唯一可用** |

⭐ **通解：在拿一个方法去证明「目标没有 X」之前，先用它在一个已知有 X 的对照上跑一遍。**
我最初用 `strings` 得到「MFC 没有电源通知」，方向碰巧对了 —— 但那是**运气**：
同一个方法在 FanPilot 上也是 0，说明它根本测不出这件事。
**一个通不过正对照的方法，它的阴性结果没有任何价值。**

（同族教训见 `~/Code/NewMac/docs/runbooks/shell-predicate-traps.md`。）

---

## 5. 复算方法

```bash
# 1. 电源通知（把 <BIN> 换成两边的二进制）
dyld_info -imports <BIN> | grep -c RegisterForSystemPower
#    正对照必须先过：/usr/local/sbin/fanpilotd 应返回 1

# 2. MFC 有没有 CLI / AppleScript / URL scheme
find "$HOME/Applications/Macs Fan Control.app" -name "*.sdef"          # 空 = 不支持 AppleScript
plutil -p ".../Info.plist" | grep -i URLScheme                          # 空 = 无 URL scheme

# 3. MFC 的配置真源
plutil -p ~/Library/Preferences/com.crystalidea.macsfancontrol.plist | grep ActivePreset
#    值形如 "Unsaved:<base64>"，解码后是 UNSAVED|<模式>,<RPM>|<模式>,<RPM>

# 4. 资源占用（两边都用同一口径）
sudo powermetrics --samplers tasks -n 2 -i 10000 --show-process-coalition

# 5. FanPilot 单元测试
cd ~/Code/FanPilot && make unit
```

---

## 6. 相关

- [`../README.md`](../README.md) —— 功能说明与安装
- [`../CHANGELOG.md`](../CHANGELOG.md) —— v1.2.0 睡眠交接那条 bug 的完整根因分析
- [`SMC-RESEARCH.md`](SMC-RESEARCH.md) —— SMC 键位逆向与温度读数的四项可信度验证
- `~/Code/NewMac/docs/runbooks/shell-predicate-traps.md` —— 本文 §4 那类判据坑的档案
