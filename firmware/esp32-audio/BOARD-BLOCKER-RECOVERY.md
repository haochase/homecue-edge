# 开发板挂死阻塞 — 问题 / 处置 / 影响 汇总

日期：2026-06-15

## 状态：已解决(2026-06-15)

板子已恢复并烧入修复固件,ESP-SR 初始化通过。关键标记:
`[esp-sr] ES7210 codec ready` / `[esp-sr] ready` / WakeNet(Hi,ESP)+ MultiNet(english)模型已加载 /
WiFi 已连接(192.0.2.110)。

**恢复经过(可复用)**:用户手动重启板子(一次物理上电),配合一个**快速可写探测循环**
(每 ~0.15s 探一次端口是否可写)抢到开机活窗口 → `esptool --before default_reset --after no_reset`
进 ROM loader → 烧 `merged.bin`(整片)→ 再把 `srmodels.bin` 烧入 model 分区(0xD10000)。

**关键教训**:只用 esptool 死循环重试会失败——每次失败要卡满约 10s 的写超时,盲区刚好错过开机后
约 2–5s 的可烧录窗口。必须先用"短超时(200ms)的原始写探测"快速发现活窗口,再立刻触发 esptool。

剩余:实测唤醒词/命令词端到端验收(需 PC 端 uvicorn 运行 + 音响播放)。详见文末待办。

---

## 一句话结论(归档)

开发板当时**软件挂死**(非硬件损坏),其板载 USB-Serial/JTAG 控制器停止响应,导致
**串口无输出、写入超时、无法重新烧录**。常规软件复位手段(esptool 三种复位)在挂死态下全部失败;
最终通过"一次物理上电 + 快速探测抢窗口"恢复。长期根治仍建议引入**可远程控制的
USB VBUS 断电开关**,避免下次没人能到现场。该阻塞**只影响"固件真机落地"这一截**,项目其余推进线不受影响。

---

## 1. 问题现象

- COM7 在 Windows 中枚举正常、可打开。
- 打开后 `BytesToRead = 0`,无任何板端输出(无 boot banner、无 `[esp-sr]`、无 Guru Meditation)。
- 写入 1 字节即抛出 `Write timeout`。
- 烧录(arduino-cli / esptool)在 "Connecting..." 阶段失败,报 `A serial exception error occurred: Write timeout`。
- 2026-06-15 复核:现象与最初记录完全一致,状态未变化。

## 2. 根本原因

1. 板子当前运行的是**旧固件**(开启 ESP-SR,但语音模型未就绪,且当时无"缺模型防护")。
2. 开机时 ESP-SR(AFE/WakeNet)初始化失败:`E AFE_SR: ERROR: Please select wake words!`
   → 触发致命错误(Guru Meditation)。
3. 芯片最终停在**挂死状态**:CPU 卡住 → 串口无输出;USB-Serial/JTAG 控制器不再被服务
   → 批量数据端点不排空 → **写入超时 → 无法烧录**。
4. 性质:**软件崩溃挂死,芯片硬件完好**。只要断电重启一次,即可回到可烧录状态;
   且修复后的新固件已带"缺模型防护",烧入后不会再走到该崩溃路径。

## 3. 已尝试的处置(软件侧,全部失败)

| 手段 | 结果 |
| --- | --- |
| esptool `--before default_reset` | Write timeout |
| esptool `--before usb_reset` | Write timeout |
| 手动 DTR/RTS 复位时序(USB-Serial/JTAG)| 之后写入仍 Write timeout |
| 拔插捕获循环(75s 持续重试连接) | 全程未观测到 COM7 掉线 → 期间未发生真正断电,无法捕获 |
| 局域网 ARP 扫描 Espressif 设备 | 未发现 → 板子未连 WiFi,OTA 当前不可用 |

**结论:连 USB 控制端点上的复位请求都不被响应,软件侧已无剩余手段。**

## 4. 当前约束

- 开发板按键(BOOT/RESET)**无法触碰**。
- 充电器**无法拔除**;板子由**单根 USB 线同时供电+传输**,电源来自主机 USB 的 VBUS(5V)。
- 板子在远处,USB 线缆当前也无法手动拔插。
- 当前 Windows 账户**非管理员**(无法通过设备管理器/pnputil 强制重启 USB 控制器)。
- 笔记本机型:MECHREVO Jiaolong MRID6,INSYDE BIOS。
  - **重启(Restart)≈ 无效**:热重启不掉 5V 轨,VBUS 全程在,板子不冷启动。
  - **关机(Shutdown)+ 拔充电器 + 普通口** 才有机会断电;但这类游戏本常有
    **always-on USB(关机仍供电)**,充电器插着时可能照样供电。

## 5. 处置办法(恢复路径)

### 5.1 立即可行(需现场一次人工)
有人到现场把 USB 线**拔下再插回**(或按 BOOT+RESET 进 download mode)即可。
随后用第 6 节命令烧录已修复固件。

### 5.2 根治:远程可控的 USB VBUS 断电开关
在"电脑 ↔ 开发板"之间引入一个**能被 PC 软件控制、可切断/恢复 VBUS(5V)** 的设备。
选型(省心 → 省钱):

| 档位 | 设备 | 控制方式 | 备注 |
| --- | --- | --- | --- |
| 首选(专用) | Yepkit **YKUSH3** | 自带 Windows CLI `ykushcmd` | 每口独立切 VBUS,免 DIY,测试台标配 |
| 工业级 | Acroname USBHub3+/3c | 官方 API/CLI | 可切电源+数据、测电流,较贵 |
| 省钱(可靠,需动手) | **LCUS-1 USB 继电器模块**(CH340) | USB 串口指令,9600 波特 | 国内易购;需剪线改 VBUS |
| 预算 hub(有坑) | 支持 PPPS 的 hub + `uhubctl` | `uhubctl -a cycle` | 必须挑兼容 hub,Windows 支持弱 |

**避坑**:墙上智能插座无效(电来自 USB VBUS,不是墙插);USB 隔离器不是这个(只隔离不断电);
很多"带电源 USB hub"只直通 VBUS、并不能切断。

#### LCUS-1 接线与控制(省钱方案)
拓扑(两条独立线):

```text
控制路:   电脑 USB 口 ──── LCUS-1 的 USB-A 口         (只供电+收指令,不传板子数据)
数据+供电: 电脑 USB 口 ──[USB-A→USB-C 线]──> 开发板 USB-C
                              ↑ 把这根线的红线(+5V)剪断,
                                两断头分别拧入继电器 COM 和 NC 端子
                                (绿 D+ / 白 D- / 黑 GND 都不剪)
```

- 用 **NC(常闭)**:继电器不通电时导通 → 板子**默认正常供电**。
- 控制指令(十六进制,9600 波特):
  - 触点吸合 = 断开 NC = **给板子断电**:`A0 01 01 A2`
  - 触点释放 = 闭合 NC = **给板子上电**:`A0 01 00 A1`
  - (校验码 = 前三字节之和取低字节)
- 一次断电重启 = 发 `A0 01 01 A2` → 等约 2 秒 → 发 `A0 01 00 A1`。

### 5.3 救活后:彻底摆脱 USB 依赖
物理救活一次、烧入带以下能力的固件后,以后基本不再依赖 USB:

1. **WiFi OTA**:固件本就连 WiFi,加 OTA 后远程更新固件无需 USB。
2. **看门狗 / panic 自动重启**:任何崩溃自动重启而非永久挂死(修复固件已不会走到崩溃路径,看门狗为双保险)。

## 6. 设备到货后的一键恢复流程

```text
LCUS-1 断电(A0 01 01 A2) → 等待约 2s → 上电(A0 01 00 A1)
  → esptool 在冷启动窗口重试抢入 ROM download mode
  → 用已编译好的固件直接 upload(不重新编译)
  → 抓启动日志验收
```

手动烧录命令(已进 download mode 后):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 -Port COM7 -EnableEspSr -Upload -UploadSpeed 115200
```

抓启动日志:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\read-esp32-serial.ps1 -Port COM7 -Seconds 30
```

音响语音端到端测试:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-esp32-sr-audio.ps1 -Port COM7 -Seconds 100 -SkipReset -Required
```

## 7. 已完成的软件侧修复(不依赖板子,均已就绪)

- **缺模型防护**:固件在启动 ESP-SR 前检查 model 分区与所需 WakeNet/MultiNet 模型,缺失则记录错误并回退,不再触发库内崩溃。
- **ES7210 双麦初始化**:在 I2S / ESP-SR begin 前完成采样率、位宽、mic bias/gain、volume 配置。
- **烧录脚本加固**(`scripts/flash-esp32.ps1`):
  - 烧录前先做"端口可写"探测,挂死状态直接快速失败并打印 download-mode 恢复步骤,不再浪费一次约 60s 编译后才报出难懂的 `Write timeout`。
  - 上传失败时同样输出可操作的恢复指引。
- **SR 固件已干净编译**:`ENABLE_ESP_SR=1`、`esp_sr_16` 分区,产物(`esp32-audio.ino.bin`、`srmodels.bin`、bootloader/partitions/merged)就绪,可秒级烧录。
- **文档**:本文件 + `ESP-SR-CURRENT-ISSUES.md` 已更新。
- **secrets 扫描**:`scan-secrets.ps1 -All` clean。

## 8. 影响范围(整个项目 7 条推进线)

| # | 推进线 | 位置 | 受开发板挂死影响? |
| --- | --- | --- | --- |
| 1 | 边缘网关 API(/health /context /devices /plan /execute /voice /devices/reset) | `apps/api` | 否 |
| 2 | Agent/规划智能(多步 tool-calling、trace、propose/execute、provider) | `apps/api` | 否 |
| 3 | Web 控制台(React+Vite,含 `?demo=static` 预览) | `apps/web` | 否 |
| 4 | 固件/硬件终端(button+serial+ESP-SR 路) | `firmware/esp32-audio` | **部分**:源码/编译不影响,**真机烧录+真机验收被卡** |
| 5 | DevEx/工具脚本(flash/serial/SR测试、check-local 等) | `scripts` | 否(静态/PC 侧) |
| 6 | CI/部署(ci.yml、pages.yml) | `.github/workflows` | 否(GitHub 云端) |
| 7 | 安全/隐私治理 + 文档 | 全仓 | 否 |

**被卡(仅"真机"相关)**:固件烧录到真机、串口可观测、ESP-SR 语音端到端验收、
按键/RGB/ES7210 双麦实测、需插板子的现场 demo。

**不受影响**:API、Agent、Web、工具脚本、CI、安全治理、文档,以及通过
Web UI / curl / serial 测试路驱动的核心闭环演示。

**结论**:7 条线里开发板挂死只实质性卡住第 4 条线的"真机落地"部分,瓶颈收敛为单一物理动作——
**给板子远程断电重启一次**。其余线均可继续全速推进。

## 9. 待办 / 下一步

- [x] 物理救活一次 → 烧入修复固件 → 抓启动日志(`[mode] button-route + ESP-SR voice command route` / `[esp-sr] ES7210 codec ready` / `[esp-sr] ready`)。**已完成 2026-06-15**。
- [x] 把 `srmodels.bin` 烧入 model 分区(0xD10000),WakeNet/MultiNet 模型加载成功。
- [ ] 开 PC 端 uvicorn(端口 8723),确认板子 `/health` 返回 200(当前为 connection refused)。
- [ ] 跑音响语音验收:`scripts/test-esp32-sr-audio.ps1 -Port COM7 -SkipReset -Required`。
- [ ] 验收目标:`[esp-sr] wake word detected` / `[voice] command:` / `[/plan] proposed N action(s)`。
- [ ] (根治,降低再次卡死风险)采购 USB VBUS 断电开关(推荐 YKUSH3;省钱用 LCUS-1 继电器改 VBUS),并备好带 **WiFi OTA + 看门狗** 的固件改动,使以后无需 USB 即可远程更新/复位。
# Current update - 2026-06-17

The old recovery note below described a resolved hung-serial state where COM7
enumerated but writes timed out. The current speaker-first blocker is different:
Windows reports `Unknown USB Device (Device Descriptor Request Failed)` with
Code 43 / `CM_PROB_FAILED_POST_START`, and no ESP32 COM port is available.

Current evidence:

```text
assets/demo/esp32-speaker-focus-port-state-now.json
assets/demo/esp32-speaker-audible-now-usb-error-summary.json

state=usb-error
finalPortState=usb-error
detectedPorts=COM3,COM4,COM5,COM6
COM3-COM6 are Bluetooth serial ports, not the ESP32.
```

Software recovery attempts from the current session:

```text
pnputil /scan-devices
-> Access is denied

pnputil /restart-device USB\VID_0000&PID_0002\6&1266488A&0&2
-> Access is denied
```

The latest speaker diagnostic firmware compiles and is ready to flash, but it
has not been uploaded in this state. Once the board re-enumerates as an
Espressif/USB serial COM port, resume with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\resume-esp32-speaker-audible-test.ps1 `
  -Port COM7 `
  -AutoDetectEsp32 `
  -MaxWaitSeconds 900 `
  -ApiHostOverride 192.0.2.118 `
  -ApiPortOverride 8723 `
  -OutputPrefix .\assets\demo\esp32-speaker-audible-recheck-auto `
  -Required
```
