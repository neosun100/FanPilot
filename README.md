# FanPilot

**macOS 菜单栏风扇自适应温控工具**，用于替换 `Macs Fan Control`。

目标：**装上就不用管** —— 按温度自动调速，配置面尽可能小。

> 机器：MacBook Pro M5 Max (Mac17,6) · macOS 26.6.2
> 📌 技术调研与全部实测数据：**[`docs/SMC-RESEARCH.md`](docs/SMC-RESEARCH.md)**

---

## 为什么自研

| 动机 | 说明 |
|---|---|
| **自适应** | Macs Fan Control 当前是**固定转速**模式（本机被钉在 3400 RPM，而硬件上限 5349/5777）⇒ 风扇无法随负载升速，散热被人为封顶 |
| **少一个第三方 root 组件** | 它装了常驻 root helper `com.crystalidea.macsfancontrol.smcwrite` 持续写 SMC |
| **配置面可控** | 我们只需要一条曲线，不需要预设管理/许可证/更新检查 |

⚠️ **本项目不解决 2026-09-13 的两次 SoC 看门狗重启。**
那是固件层故障（`iBoot panic` / `wdog`），与风扇控制无因果关系。
证据见 `NewMac/docs/runbooks/assets/panic-2026-09-13/`。

---

## 可行性：已实测确证

| 项 | 结果 |
|---|---|
| IOKit 访问 SMC（M5 Max / SIP on） | ✅ 可用，无需 kext |
| 读传感器 | ✅ **免 root** |
| 写风扇 | 需 **root**（SIP 无需关闭） |
| 风扇数 | 2（`FNum=2`） |
| 控制面 | **仅 4 个键**：`F0md` `F1md` `F0Tg` `F1Tg` |
| 转速范围 | 风扇0 **1350~5349** · 风扇1 **1350~5777**（上限不同！） |
| 控制输入 | `Tp0*` 性能核簇最大值（实测最灵敏 `Tp00`，极差 10.77 °C） |

---

## 架构

```
FanPilot.app（菜单栏 · 无权限）
  ├ SensorReader   IOKit 只读，免 root
  ├ CurveEngine    温度 → 目标 RPM（分段线性 + 滞回）
  └ HelperClient   XPC → helper
          │  {key, value}
FanPilotHelper（root LaunchDaemon）
  └ 唯一职责：SMCWriteKey，带白名单 + 值域校验 + 看门狗
```

### 安全红线（helper 侧强制，不信任调用方）

1. **键白名单** —— 只有那 4 个键可写，其余拒绝
2. **值域校验** —— 目标 RPM 必须在运行时读到的 `F*Mn`~`F*Mx` 内
3. **看门狗** —— App 异常退出后自动把 `F*md` 写回 `0`，**交还固件自动控制**
   > 这条是最重要的失效安全：绝不能把风扇留在"手动低速"。
   > 本机现在的处境正是这个反面教材。

---

## 现状

- [x] SMC 可行性验证（`research/smcprobe.c`）
- [x] 传感器普查与响应性判定（`research/sensors.c` `research/sample.c`）
- [x] 参照实现架构逆向（`Macs Fan Control` 走 SMJobBless）
- [ ] 写入路径验证（需 root 授权，会改动当前风扇设置）
- [ ] helper + XPC
- [ ] 曲线引擎
- [ ] 菜单栏 UI
- [ ] 看门狗与失效安全

## 研究工具（全部只读）

```bash
cd research
clang -O2 -framework IOKit -framework CoreFoundation -o smcprobe smcprobe.c && ./smcprobe
clang -O2 -framework IOKit -framework CoreFoundation -o sensors  sensors.c  && ./sensors
clang -O2 -framework IOKit -framework CoreFoundation -o sample   sample.c   && ./sample 70 2
```
