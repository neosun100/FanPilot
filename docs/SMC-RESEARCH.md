# SMC 风扇控制调研（M5 Max 实测）

> 机器：MacBook Pro **Mac17,6** / Apple **M5 Max** / macOS 26.6.2 (25G83) / SIP **enabled**
> 实测日期：2026-09-13 · 全部数字来自 `research/` 下的探针程序，非查资料所得
>
> **本文只写实测确证的事实。** 推测一律标注「未验证」。

---

## 0. 结论先行

| 问题 | 答案 |
|---|---|
| M5 Max 上还能用 IOKit 访问 SMC 吗？ | ✅ **能**。`IOServiceMatching("AppleSMC")` 直接可用，无需 kext |
| 读传感器需要 root 吗？ | ❌ **不需要**。普通用户可读全部 3669 个键 |
| 写风扇需要什么？ | **root**。SIP 无需关闭 |
| 有几个风扇？ | **2**（`FNum=2`）|
| 控制面有多大？ | **只有 4 个键**：`F0md` `F1md` `F0Tg` `F1Tg` |
| 自研可行吗？ | ✅ 技术上无障碍。难点不在 SMC，在**特权 helper 的签名与安装** |

---

## 1. SMC 访问方式（实测确证）

```c
io_service_t svc = IOServiceGetMatchingService(
    kIOMainPortDefault, IOServiceMatching("AppleSMC"));
IOServiceOpen(svc, mach_task_self(), 0, &conn);
IOConnectCallStructMethod(conn, /*selector=*/2, &in, sizeof(in), &out, &osz);
```

- `IOClass` = `AppleSMCKeysEndpoint`，`IOUserClientClass` = `AppleSMCClient`
- selector **2** = `KERNEL_INDEX_SMC`
- 命令码：`9`=读键信息 · `5`=读字节 · `6`=**写字节** · `8`=按索引取键名
- `#KEY` = **3669** 个键（`F*` 51 个，`T*` 361 个）

⚠️ **`ui16`/`ui32` 是大端**，`flt ` 是小端 float。混了会得出荒谬数值。

---

## 2. 风扇控制键（全部实测值）

`dataAttributes` 的 **0x40 位 = 可写**（实测对照：只读键无此位）。

| 键 | 类型 | attr | 可写 | 含义 | 实测值 |
|---|---|---|:--:|---|---:|
| **`F0md`** | ui8 | `0xd0` | ✅ | 风扇0 模式：**0=固件自动 / 1=手动** | **1** |
| **`F1md`** | ui8 | `0xd0` | ✅ | 风扇1 模式 | **1** |
| **`F0Tg`** | flt | `0xd4` | ✅ | 风扇0 **目标**转速 | **3400** |
| **`F1Tg`** | flt | `0xd4` | ✅ | 风扇1 目标转速 | **3400** |
| `F0Ac` | flt | `0x84` | ❌ | 风扇0 **实际**转速 | 3401 |
| `F1Ac` | flt | `0x84` | ❌ | 风扇1 实际转速 | 3402 |
| `F0Mn` / `F0Mx` | flt | `0x84`/`0x85` | ❌ | 风扇0 转速下限/**上限** | **1350 / 5349** |
| `F1Mn` / `F1Mx` | flt | `0x84`/`0x85` | ❌ | 风扇1 转速下限/**上限** | **1350 / 5777** |

⭐ **两个风扇的上限不同**（5349 vs 5777）—— 写死同一个值是错的，必须各自按 `F*Mx` 归一化。

### 🩸 本机当前状态：风扇被第三方 App 钉死

`F0md = F1md = 1`（手动）且 `F*Tg = 3400`，而上限是 5349/5777
⇒ **风扇跑在最大能力的 59%/63%，且物理上无法随负载升速。**
写入者是 `Macs Fan Control` 的 root helper（`com.crystalidea.macsfancontrol.smcwrite`）。

---

## 3. 温度传感器：必须按「响应性」筛，不能按数值筛

**🩸 最值钱的一条教训。** 按当前温度降序排，最热的两个是：

| 键 | 值 | 70s/35样本 标准差 |
|---|---:|---:|
| `Tf06` | 88.81 °C | **0.000** |
| `Tf16` | 85.97 °C | **0.000** |

**它们完全不动 ⇒ 不是实时温度，是常量。**
形态与分组（`Tf0?`/`Tf1?` 两组，每组位置 `6` 离群）表明它们很可能是
**固件为该风扇区设定的目标/跳闸温度**（未验证，但一致性很强）。

⭐ **推论：Apple 固件自己的温控设定点约 88.8 °C** —— 我们的曲线上限不该超过它。

⚠️ **只看数值会把常量当成"热点告警"**（我第一版就是这么误判的）。
**判据必须是时序方差，不是瞬时值。**

### 可用的控制输入（实测响应负载）

| 键 | 实测范围 | 极差 | 用途 |
|---|---|---:|---|
| **`Tp00`** | 35.03~45.80 | **10.77** | ✅ **首选**：最灵敏 |
| `TCMb` | 44.54~52.47 | 7.93 | ✅ 备选 |
| `TVDP` | 44.57~52.00 | 7.43 | ✅ 备选（电压域）|
| `Tp0X` | 34.72~42.05 | 7.33 | ✅ TempMonitor 在用的 |
| `Tf0A` | 33.84~36.60 | 2.76 | ⚠️ 阻尼重，不适合做控制输入 |

`Tp0*` 是性能核簇（共 20+ 个键，48~55 °C 区间）。
**建议控制输入 = `Tp0*` 簇的最大值**（单点会漏掉局部热点）。

---

## 4. 参照实现：Macs Fan Control 的架构（逆向所得）

只用 `otool`/`strings` 看接口，未反编译逻辑。

- helper 只链 **IOKit + Foundation + Security**：纯用户态 IOKit，**没有自研 kext**
- `Info.plist` 里有 **`SMAuthorizedClients`** ⇒ 走 **SMJobBless** 特权 helper 模式
- helper 字符串：`process_command_write: SMCWriteKey %s %s OK`
  ⇒ 协议极简：**无权限 App 把「键 + 值」发给 root helper，helper 执行写入**
- 通信：`MachServices` = `com.crystalidea.macsfancontrol.smcwrite`

⇒ **我们要复刻的就是这个结构。** 它是这类工具的标准形态，不是什么黑魔法。

---

## 5. 架构决策

```
┌─────────────────────────────┐
│ FanPilot.app（菜单栏，无权限）│  读传感器(免root) + 曲线计算 + UI
│   ├ SensorReader            │  IOKit 只读
│   ├ CurveEngine             │  温度 → 目标 RPM
│   └ HelperClient (XPC)      │
└──────────┬──────────────────┘
           │ XPC：{key, value}
┌──────────▼──────────────────┐
│ FanPilotHelper（root daemon）│  唯一职责：SMCWriteKey
│   + 白名单：只允许写         │  ⛔ 只接受 F0md/F1md/F0Tg/F1Tg
│     这 4 个键                │  ⛔ RPM 必须落在 F*Mn~F*Mx 内
└─────────────────────────────┘
```

### 安全红线（helper 侧强制，不信任 App 侧）

1. **键白名单**：只有 `F0md`/`F1md`/`F0Tg`/`F1Tg` 可写，其余一律拒绝
2. **值域校验**：目标 RPM 必须在实测的 `F*Mn`~`F*Mx` 内，越界拒绝
3. **看门狗**：App 崩溃/退出 → helper 在 N 秒内**自动把 `F*md` 写回 0**（交还固件）
   ⇒ 这条最重要：**任何异常都必须回退到固件自动控制，不能把风扇留在手动低速上**
   （本机现在的处境正是「留在手动 3400」）

### 曲线设计（自适应，无需人管）

- 输入：`Tp0*` 簇最大值
- 映射：分段线性，**滞回**（升温/降温阈值不同）避免转速抖动
- 上界参考固件设定点 **88.8 °C**
- 归一化到各自 `F*Mx`（5349 / 5777 不同）

---

## 6. 未解决 / 待验证

| 项 | 状态 |
|---|---|
| `Tf?6` 是否真是固件跳闸点 | **未验证**（一致性强，但无直接证据）|
| 写入 `F*Tg` 的实际效果 | **未测**（需 root，且会改变用户当前设置，待授权）|
| `md=0` 是否真能交还固件 | **未测**（同上，且这是看门狗的基石，必须验）|
| 合盖/睡眠唤醒后 SMC 状态 | 未测 |
| macOS 升级后键是否变动 | 未知，需要 `F*Mx` 运行时读取而非硬编码 |

---

## 7. 复现方法

```bash
cd research
clang -O2 -framework IOKit -framework CoreFoundation -o smcprobe smcprobe.c
./smcprobe          # 枚举全部键 + 风扇现状
clang -O2 -framework IOKit -framework CoreFoundation -o sensors sensors.c
./sensors           # 传感器普查 + 可写性属性
clang -O2 -framework IOKit -framework CoreFoundation -o sample sample.c
./sample 70 2       # 时序采样（判响应性用）
```

全部**只读**，不写任何 SMC 键。
