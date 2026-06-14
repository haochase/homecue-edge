# HomeCue Edge — ESP32-S3-AUDIO-Board 固件操作手册

> 板子：**Waveshare ESP32-S3-AUDIO-Board**（双麦 + ES7210/ES8311 + 7×RGB + 3 用户键，无板载屏/无旋钮）  
> 固件目录：`homecue-edge\firmware\esp32-audio\`  
> 后端端口：**8723**（不是 8000）

---

## 0. 你将得到什么

一块已联网的语音边缘终端：说唤醒词或按用户键 → 向 PC 上的 HomeCue 网关 **提议** 智能家居计划（不自动执行）→ 你在板子上按键确认/拒绝 → 网页与设备状态同步变化。板子负责**语音输入 + RGB 状态灯 + 物理人在环**；计划与 trace 显示在 **PC 网页控制台**（板子无屏）。

数据流概览：

```
唤醒词 / 用户键 → 固定命令词 → 预设 prompt
  → POST /plan（agent_mode=true, execute=false）【只提议，不执行】
  → RGB 转绿「就绪」，PC 网页显示 plan + trace
  → CONFIRM 键 → POST /execute（真正执行）
     REJECT 键  → 丢弃提议
     NEXT 键    → 切换下一条命令词
```

---

## 1. 准备清单

### 1.1 硬件

| 物品 | 说明 |
| --- | --- |
| Waveshare ESP32-S3-AUDIO-Board | 你手头这块即可，MVP **不需要**外接喇叭/屏幕 |
| USB-C 数据线 | 能传数据（不是仅充电线）；本机已连接则跳过插线 |
| 2.4 GHz WiFi | ESP32-S3 **不支持** 5 GHz-only 网络 |

### 1.2 软件（Windows）

| 软件 | 用途 | 下载 |
| --- | --- | --- |
| Arduino IDE 2.x | 编译/烧录固件 | https://www.arduino.cc/en/software |
| Python 3.10+ | 跑 FastAPI 网关 | 项目 `apps/api` 已有 `.venv` 时可复用 |
| Node.js 18+ | 跑网页控制台（联调阶段） | https://nodejs.org/ |
| curl | 自测 `/health` | Windows 10/11 自带；或用 PowerShell `Invoke-WebRequest` |

### 1.3 烧录前请先记下来（后面要填进 `secrets.h`）

在记事本里准备好这四项，**不要写进 git**：

| 信息 | 怎么获取 | 示例 |
| --- | --- | --- |
| WiFi 名称（2.4G） | 路由器背面 / 手机热点设置 | `MyHome-2.4G` |
| WiFi 密码 | 同上 | `********` |
| PC 局域网 IPv4 | 见 **第 6 节** `ipconfig` | `192.168.1.100` |
| PC 端口 | 固定 | `8723` |

---

## 2. 安装 Arduino IDE 与 ESP32 支持

> 若已装过 Arduino IDE 2.x 且能选到 `ESP32S3 Dev Module`，可跳到 **第 3 节**。

### 2.1 下载并安装 Arduino IDE

1. 打开 https://www.arduino.cc/en/software ，下载 **Windows Win 10 and newer** 安装包。
2. 双击安装，全程默认下一步即可。
3. 安装完成后启动 **Arduino IDE 2**。

### 2.2 添加 ESP32 板管理器 URL

1. 菜单 **文件 (File)** → **首选项 (Preferences)**。
2. 找到 **「附加开发板管理器网址」(Additional boards manager URLs)**。
3. 填入（若已有其他 URL，用逗号隔开追加）：

   ```
   https://espressif.github.io/arduino-esp32/package_esp32_index.json
   ```

4. 点 **确定**。

### 2.3 安装 esp32 开发板包

1. 左侧 **开发板管理器 (Boards Manager)** 图标（或 **工具 → 开发板 → 开发板管理器**）。
2. 搜索框输入 `esp32`。
3. 找到 **esp32 by Espressif Systems**，点 **安装**（建议 3.0.x，与 Waveshare wiki 一致）。
4. 等待下载完成（首次可能 5–15 分钟）。

### 2.4 选择开发板与关键参数

菜单 **工具 (Tools)**，逐项设置：

| 菜单项 | 值 | 说明 |
| --- | --- | --- |
| **开发板 (Board)** | **ESP32S3 Dev Module** | Waveshare 官方推荐 |
| **USB CDC On Boot** | **Enabled** | USB-C 直连时串口走 USB，必须开 |
| **PSRAM** | **OPI PSRAM** | 板载 8MB PSRAM |
| **Flash Size** | **16MB (128Mb)** | 板载 16MB Flash |
| **Partition Scheme** | 见下方 | 语音识别模型需要专用分区 |
| **Upload Speed** | **921600** | 失败时改 **115200** |
| **端口 (Port)** | `COMx` | 见 **第 2.5 节** 在设备管理器里查 COM 号，Arduino 里选同一个口 |

**分区方案怎么选：**

- 烧录 **带语音识别模型** 的厂商例程 → **ESP SR 16M (3MB APP/7MB SPIFFS/2.9MB MODEL)**
- 烧录 **HomeCue 固件**（无内置 ESP-SR 模型）→ **16M Flash (3MB APP/9.9MB FATFS)** 或空间足够的 APP 分区

### 2.5 确认 USB 驱动与 COM 口

1. 板子用 USB-C 连上 PC（你已连接可跳过）。
2. `Win + R` → 输入 `devmgmt.msc` → 回车。
3. 展开 **端口 (COM 和 LPT)**，应出现类似：
   - `USB Serial Device (COM5)` 或
   - `Silicon Labs CP210x (COM5)`
4. Arduino IDE **工具 → 端口** 选同一个 `COMx`。

**找不到 COM 口？** 见 **第 13 节**「COM 口找不到」。

---

## 3. 安装依赖库

### 3.1 ArduinoJson（HomeCue 固件必需）

1. **工具 → 管理库 (Library Manager)**。
2. 搜索 `ArduinoJson`。
3. 选作者 **Benoit Blanchon**，安装 **7.x**（不要装 6.x）。

### 3.2 厂商例程自带库（烧录第 4 节前需要）

Waveshare 例程包里的 `arduino/libraries` 已包含 ESP-SR、TCA9555 扩展、RGB 等依赖，**不要**在库管理器里乱搜同名库。

操作：

1. 从 wiki 下载整包 Demo（见 **第 4.1 节**）。
2. 解压后，把包内 `arduino/libraries/` 下**所有文件夹**复制到：

   ```
   C:\Users\<你的用户名>\Documents\Arduino\libraries\
   ```

3. 重启 Arduino IDE。

### 3.3 验证库是否就绪

打开 **文件 → 示例**，若能看到 Waveshare 相关示例或 `ESP_SR` 相关项，说明库路径正确。

---

## 4. 第一步：烧录厂商官方例程验证硬件

> **在做任何 HomeCue 改动之前，先证明板子硬件是好的。** 麦克风、唤醒词、RGB 灯、按键都应在厂商例程里跑通。

### 4.1 下载厂商 Demo 包

1. 打开 Waveshare wiki：  
   **https://www.waveshare.com/wiki/ESP32-S3-AUDIO-Board**
2. 在页面中找到 **Demo / 示例程序** 下载链接（通常名为 **ESP32-S3-AUDIO-Board Demo** 或类似 ZIP）。
3. 解压到例如：`E:\waveshare\ESP32-S3-AUDIO-Board-Demo\`

> 新版文档站：https://docs.waveshare.com/ESP32-S3-AUDIO-Board — 同样有 Demo 下载与 Arduino 环境说明。

### 4.2 打开哪个例程？

在解压目录里找 **Arduino** 子目录：

| 路径（解压后） | 用途 |
| --- | --- |
| `Arduino/examples/LVGL_Arduino/` | **推荐首选**：含语音识别 + 板载设备初始化；唤醒词默认 **「hi esp」** |
| 若包内另有 `esp_sr` / Speech Recognition 独立 sketch | 纯语音唤醒+识别，无 LVGL 依赖，也可用于验硬件 |

**操作：**

1. Arduino IDE → **文件 → 打开**。
2. 选中 `LVGL_Arduino.ino`（或包内 Speech Recognition / `esp_sr` 相关 `.ino`）。
3. IDE 会打开整个 sketch 文件夹，保持默认即可。

> MVP **不需要**插 TF 卡、外接屏、摄像头。语音识别在 LVGL 例程里**播放音频前**可用；若例程强依赖外设，优先找包内纯 `esp_sr` 语音 demo，或参考 wiki **ESP-IDF** 区的 `esp_sr_02` 说明对照 Arduino 版。

### 4.3 烧录前检查（语音识别例程）

**工具** 菜单再次确认：

| 项 | 值 |
| --- | --- |
| Board | ESP32S3 Dev Module |
| USB CDC On Boot | Enabled |
| PSRAM | OPI PSRAM |
| Flash Size | 16MB (128Mb) |
| **Partition Scheme** | **ESP SR 16M (3MB APP/7MB SPIFFS/2.9MB MODEL)** |
| Port | 你的 COM 口 |
| Upload Speed | 921600（失败改 115200） |

### 4.4 编译并烧录

1. 点击 **→（上传）** 按钮。
2. 等待底部输出出现 **`Hard resetting via RTS pin...`** 或 **`Leaving...`**，表示成功。
3. 若失败，见 **第 13 节**「烧录失败」。

**进入下载模式（烧录卡住时）：**

1. **按住 BOOT** 键不放；
2. 短按一下 **RESET**；
3. 松开 BOOT；
4. 再点一次上传。

### 4.5 打开串口监视器

1. 右上角 **监视器 (Monitor)** 图标，或 **工具 → 串口监视器**。
2. 右下角波特率选 **115200**。
3. 按一下板子 **RESET**，应看到启动日志（芯片型号、初始化信息等）。

### 4.6 预期现象（验收硬件）

| 动作 | 预期 |
| --- | --- |
| 对板子清晰说 **「hi esp」**（语速稍慢、发音标准） | 串口出现 wake / 唤醒相关日志；**7 颗 RGB 灯**有颜色变化（例程可能呼吸/闪烁） |
| 唤醒后说英文命令词（例程默认，如背光相关命令） | 串口打印识别到的 command id / 文本 |
| 按 3 个用户键之一 | 串口有按键事件（若例程已映射） |

**同时做一件事：** 在例程源码里搜索 `TCA9555`、`RGB`、`key`、`button`，**记下**驱动 RGB 和读按键的函数名与调用方式——后面接 HomeCue 固件要用（**第 9 节**）。

### 4.7 常见失败与处理

| 现象 | 处理 |
| --- | --- |
| `A fatal error occurred: Failed to connect` | BOOT+RESET 进下载模式；换 USB 口/线；Upload Speed 改 115200 |
| 编译报 `ESP_SR` / 分区不够 | Partition 改 **ESP SR 16M (...)** |
| 能烧录但串口无输出 | 确认 **USB CDC On Boot = Enabled**；波特率 115200；按 RESET |
| 唤醒无反应 | 靠近板子、降低环境噪音；对双麦正面说话；wiki 提供 MIC 测试音频可外放辅助 |
| 识别率低 | 先用英文默认模型；中文需按 wiki「Switch to Chinese recognition model」换模型文件 |

---

## 4B. 按键路线快速通道（跳过厂商语音验证）

> **适合你现在的情况：** 厂商 LVGL 例程已烧过但「hi esp」无反应，或不想装 ESP-SR 模型分区。  
> 直接烧 HomeCue 固件，用 **3 个用户键 + BOOT** 与 PC 后端、网页 **Propose only** 联调。  
> **不需要** 复制厂商 `arduino/libraries`，**不需要** ESP SR 分区。  
> **注意：** 按 KEY1 触发 `/plan` 后请耐心等待（串口会显示 `requesting (may take up to 60s)...`）；PC 上 `uvicorn` 必须已运行，且 MiMo/Qwen 在线规划可能需 20–60 秒。

### 4B.1 前提

| 项 | 说明 |
| --- | --- |
| 厂商例程 | **可选**。已烧过 LVGL 例程证明 USB/COM 可用即可；也可跳过第 4 节 |
| 依赖库 | 仅 **ArduinoJson 7.x**（见第 3.1 节） |
| 分区 | **16M Flash (3MB APP/9.9MB FATFS)** — **不是** ESP SR 分区 |
| 后端 | PC 上 `uvicorn` 绑定 `0.0.0.0:8723`（见第 5 节） |

### 4B.2 按键映射（固件默认）

板子通过 I2C 读 TCA9555（地址 `0x20`，SDA=11/SCL=10），**无需**厂商库：

| 物理键 | TCA9555 引脚 | 动作 | 串口日志 |
| --- | --- | --- | --- |
| **用户键 1**（KEY1） | EXIO 9 | 触发 `/plan`（`execute=false`），循环命令词 | `[key] NEXT -> I'm home` 等 |
| **用户键 2**（KEY2） | EXIO 10 | 确认 → `POST /execute` | `[key] CONFIRM` |
| **用户键 3**（KEY3） | EXIO 11 | 拒绝，丢弃提议 | `[key] REJECT` |
| **BOOT**（GPIO0） | — | **仅当 TCA9555 未检测到**：无提议时触发 `/plan`；有提议时确认执行 | 同上 |
| **USB 串口测试命令** | — | 自动化测试触发 `/plan` / `/execute` / `/reject` | `[serial] PLAN -> ...` / `[serial] CONFIRM` |

RGB 环形灯在按键路线下 **只打 Serial 日志**（`[RGB] READY (green)` 等），待接厂商驱动后才会亮真灯。

串口测试命令用于自动化验证，不改变真实按键路线：

```text
homecue:plan 0      # 触发第 0 条固定命令词的 /plan
homecue:plan 1      # Sleep mode
homecue:plan 2      # Movie time
homecue:execute     # 确认并 POST /execute
homecue:reject      # 丢弃当前提议
homecue:health      # 重新检查 /health
```

自动化采集 Level 4 证明时可运行：

```powershell
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 90 -SkipReset -RequireInteraction -AutoSerialLevel4 -SerialCommandIndex 0 -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json -Required
```

固定 prompt（KEY1 / BOOT 触发时发送到 `/plan`）：

| 命令词 | prompt 摘要 |
| --- | --- |
| I'm home | 刚回家很累，舒适房间 + 放松观影模式 |
| Sleep mode | 睡眠模式，柔和灯光 + 温和提醒 |
| Movie time | 观影夜：暖光、影院模式、环境音 |

### 4B.3 配置 secrets.h（逐步）

```powershell
cd homecue-edge\firmware\esp32-audio
Copy-Item secrets.h.example secrets.h
notepad secrets.h
```

逐项填写：

```cpp
#define WIFI_SSID      "你的2.4G-WiFi名"      // 不能是 5G-only
#define WIFI_PASSWORD  "你的WiFi密码"
#define PC_HOST        "192.168.1.100"        // ipconfig 里 WLAN 的 IPv4
#define PC_PORT        "8723"
```

**查 PC IP：**

```powershell
ipconfig
```

示例输出（把 `192.168.1.100` 填进 `PC_HOST`）：

```
无线局域网适配器 WLAN:
   IPv4 地址 . . . . . . . . . . . . : 192.168.1.100
```

### 4B.4 Arduino 烧录设置（与语音识别例程不同）

**文件 → 打开** → `homecue-edge\firmware\esp32-audio\esp32-audio.ino`

**工具** 菜单：

| 菜单项 | 值 |
| --- | --- |
| 开发板 | ESP32S3 Dev Module |
| USB CDC On Boot | **Enabled** |
| PSRAM | OPI PSRAM |
| Flash Size | 16MB (128Mb) |
| **Partition Scheme** | **16M Flash (3MB APP/9.9MB FATFS)** |
| Upload Speed | 921600（失败改 115200） |
| 端口 | **COM7**（你的板子；设备管理器核对） |

点击 **上传**。烧录前若卡住：按住 BOOT → 短按 RESET → 松开 BOOT → 再上传。

### 4B.5 串口预期日志

1. 打开串口监视器，波特率 **115200**，按 **RESET**。
2. 预期启动序列：

```
[HomeCue Edge] ESP32-S3-AUDIO-Board firmware booting...
[mode] button-route MVP (no ESP-SR; voice disabled)
[keys] TCA9555 OK — KEY1=plan KEY2=confirm KEY3=reject BOOT=plan-fallback
[WiFi] connecting to YourSSID ...
........
[WiFi] connected, IP = 192.168.1.50
[/health] HTTP 200
[RGB] IDLE (dim)
```

3. 按 **用户键 1**（或 TCA9555 失败时按 **BOOT**）：

```
[key] NEXT -> I'm home
[RGB] THINKING (breathing)
[/plan] requesting (may take up to 60s)...
[/plan] proposed 3 action(s) - awaiting confirmation
  precheck light.set_scene -> accepted (...)
  precheck ac.set_temperature -> accepted (...)
[RGB] READY (green)
```

4. 按 **用户键 2**（或 BOOT-only 模式下再按 **BOOT**）：

```
[key] CONFIRM
  exec light.set_scene -> accepted
  exec ac.set_temperature -> accepted
[RGB] READY (green)
```

5. 按 **用户键 3** 拒绝时：

```
[key] REJECT - discarding proposal
[RGB] REJECTED (red)
```

**故障对照：** `[/plan] HTTP -1` → 查第 6–7 节 IP/防火墙；`[/plan] HTTP -11 — read timeout` → 后端 LLM 太慢或未响应，确认 `uvicorn` 在跑或改用 `PLANNER_PROVIDER=mock`；`TCA9555 not detected` → 仍可用 BOOT 单键联调。

### 4B.6 网页联调（Propose only）

1. 保持后端 `uvicorn` 在 `0.0.0.0:8723` 运行。
2. 新开 PowerShell：

```powershell
cd homecue-edge\apps\web
npm install
npm run dev
```

3. 浏览器打开 **http://127.0.0.1:5173**
4. 勾选 **「Propose only」**（与板子 `execute=false` 一致）。
5. 联调顺序：

| 步骤 | 板子操作 | 网页预期 |
| --- | --- | --- |
| 1 | 按 **KEY1**（或 BOOT） | 出现 plan、trace、precheck |
| 2 | 按 **KEY3** | 提议丢弃 |
| 3 | 再按 **KEY1** | 新 plan 显示 |
| 4 | 按 **KEY2** | 设备状态更新（已执行） |

### 4B.7 按键路线验收清单

- [ ] Partition = **16M Flash (3MB APP/9.9MB FATFS)**，非 ESP SR
- [ ] `secrets.h` 已填 WiFi + `PC_HOST`（局域网 IPv4）+ `8723`
- [ ] `curl http://127.0.0.1:8723/health` 与 `curl http://<PC_IP>:8723/health` 均返回 `"status":"ok"`
- [ ] 串口见 `[mode] button-route MVP` + `WiFi connected` + `[/health] HTTP 200`
- [ ] KEY1 → `proposed N action(s)`；KEY2 → `exec ... accepted`；KEY3 → `REJECT`
- [ ] 网页 **Propose only** 下，KEY2 确认后设备状态变化可见
- [ ] （可选）语音唤醒仍无反应 — **可忽略**，按键路线不依赖 ESP-SR

---

## 5. 第二步：启动 PC 后端

> 板子通过 WiFi 访问你 PC 上的 FastAPI。**必须**绑定 `0.0.0.0`，不能只绑 `127.0.0.1`。

### 5.1 打开 PowerShell，进入 API 目录

```powershell
cd homecue-edge\apps\api
```

### 5.2 确认虚拟环境（首次）

若还没有 `.venv`：

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
```

### 5.3 启动网关（端口 8723）

```powershell
.\.venv\Scripts\python -m uvicorn app.main:app --host 0.0.0.0 --port 8723
```

**预期输出（示例）：**

```
INFO:     Started server process [12345]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8723 (Press CTRL+C to quit)
```

窗口保持打开，不要关。

### 5.4 本机自测 `/health`

**新开一个** PowerShell 窗口：

```powershell
curl http://127.0.0.1:8723/health
```

**预期 JSON（字段可能略有差异）：**

```json
{"status":"ok","planner_provider":"mock",...}
```

或用 PowerShell：

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8723/health | Select-Object -ExpandProperty Content
```

若这里都不通，先修后端，不要烧录板子。

---

## 6. 第三步：查 PC 局域网 IP

板子填的 `PC_HOST` 必须是 **局域网 IPv4**，不能填 `127.0.0.1`。

```powershell
ipconfig
```

找当前上网那张网卡的 **IPv4 地址**，例如：

```
无线局域网适配器 WLAN:
   IPv4 地址 . . . . . . . . . . . . : 192.168.1.100
```

记下这个地址 → 后面写入 `secrets.h` 的 `PC_HOST`。

**注意：**

- 笔记本同时有 WiFi + 以太网时，选**和板子连同一个路由器**的那块网卡 IP。
- PC 换网络后 IP 可能变，需重新改 `secrets.h` 并重新烧录（或 OTA 前先保证能连上）。

---

## 7. 第四步：Windows 防火墙放行 8723

板子从局域网访问 `http://<PC_HOST>:8723`，Windows 必须允许入站 TCP 8723。

### 7.1 图形界面（推荐）

1. **开始菜单** → 搜索 **「Windows Defender 防火墙」** → **高级设置**。
2. 左侧 **入站规则** → 右侧 **新建规则...**。
3. **规则类型**：端口 → 下一步。
4. **TCP**，特定本地端口填 **`8723`** → 下一步。
5. **允许连接** → 下一步。
6. 域/专用/公用全勾（至少勾 **专用**）→ 下一步。
7. 名称填 **`HomeCue API 8723`** → 完成。

首次运行 uvicorn 时若弹出「允许访问」，也点 **允许**。

### 7.2 可选：PowerShell 一行（需管理员）

右键「以管理员身份运行」PowerShell：

```powershell
New-NetFirewallRule -DisplayName "HomeCue API 8723" -Direction Inbound -Protocol TCP -LocalPort 8723 -Action Allow
```

### 7.3 验证「局域网能访问」

把 `192.168.1.100` 换成你第 6 节查到的 IP：

```powershell
curl http://192.168.1.100:8723/health
```

应返回与 5.4 相同的 JSON。  
若本机 `127.0.0.1` 通、局域网 IP 不通 → 几乎一定是防火墙问题。

---

## 8. 第五步：配置 secrets.h

### 8.1 复制模板

```powershell
cd homecue-edge\firmware\esp32-audio
Copy-Item secrets.h.example secrets.h
```

### 8.2 编辑 `secrets.h`

用记事本或 VS Code 打开 `secrets.h`，改成你的真实值（**示例，勿提交 git**）：

```cpp
#define WIFI_SSID      "你的2.4G-WiFi名"
#define WIFI_PASSWORD  "你的WiFi密码"
#define PC_HOST        "192.168.1.100"   // 第 6 节的 IPv4
#define PC_PORT        "8723"
```

### 8.3 安全提醒

- `secrets.h` 已在 `homecue-edge/.gitignore` 中，**不要** `git add` 它。
- 不要把真实 WiFi 密码、API key 写进任何会提交的仓库文件。
- 本手册不出现真实密钥。

---

## 9. 第六步：接入厂商代码到 esp32-audio.ino

`esp32-audio.ino` 是 HomeCue 胶水层；音频、RGB、按键驱动在厂商例程里。搜索 **`TODO[VENDOR]`**，共 **4 处**。

### 9.1 总原则

1. **从第 4 步例程复制**，不要从零写驱动。
2. 先求 **端到端联网通**，语音可以后接。
3. **最小可运行版**：跳过 `pollVoiceCommand()`，在 `setup()` 末尾调一次 `requestPlan(...)`，用 **BOOT 键** 当 `KEY_CONFIRM`（见 9.5）。

### 9.2 `setup()` — 硬件初始化

**文件位置：** `esp32-audio.ino` 约 274–284 行。

**要接什么：** 从厂商例程 `setup()` / 初始化函数复制：

- I2C：`SDA=GPIO11`, `SCL=GPIO10`
- **TCA9555** GPIO 扩展芯片初始化
- **7×RGB** 灯初始化（经 TCA9555 或例程里的 WS2812 助手）
- **3 用户键** 输入配置
- **ES7210** 双麦 I2S 初始化（若走语音）
- **ESP-SR** WakeNet + MultiNet 模型加载（若走语音）

**从哪抄：** 第 4 步打开的 `LVGL_Arduino`（或 `esp_sr`）里 `setup()`、`Speech_Init()`、`I2C_Init` 等等价代码。

### 9.3 `setRgbState()` — RGB 状态灯

**要接什么：** 把枚举状态映射到颜色：

| 状态 | 颜色 | 含义 |
| --- | --- | --- |
| `RGB_LISTENING` | 蓝 | 正在听命令 |
| `RGB_THINKING` | 呼吸/闪烁 | 等待 `/plan` |
| `RGB_READY` | 绿 | 计划已提议，待确认 |
| `RGB_REJECTED` | 红 | 用户拒绝或守卫拦截 |
| `RGB_OFFLINE` | 黄 | WiFi/网关不可达 |
| `RGB_IDLE` | 灭/暗 | 空闲 |

**从哪抄：** 例程里控制 RGB 环形灯的函数（常含 `RGB`、`LED`、`TCA9555` 关键字）。

### 9.4 `readUserKey()` — 三个用户键

**要接什么：** 防抖读取，返回：

- `KEY_CONFIRM` — 确认执行
- `KEY_REJECT` — 丢弃提议
- `KEY_NEXT` — 切换下一条命令词并重新 `/plan`
- `KEY_NONE` — 无按键

**从哪抄：** 例程里按键扫描 / TCA9555 读输入寄存器部分；确认 3 个用户键对应哪几个 expander 引脚。

### 9.5 `pollVoiceCommand()` — 语音命令词

**要接什么：** ES7210 采音 → ESP-SR 唤醒 → MultiNet 识别 → 返回 `COMMAND_WORDS` 数组下标 `0..2`：

| 下标 | 标签 | 发送到 `/plan` 的 prompt |
| --- | --- | --- |
| 0 | I'm home | 回家放松场景… |
| 1 | Sleep mode | 睡眠模式… |
| 2 | Movie time | 观影模式… |

**从哪抄：** 例程里识别回调；把厂商 command id **映射**到上表下标（可先只映射 1 个命令词验通）。

**最小可运行捷径（无语音）：**

```cpp
// setup() 末尾，WiFi 连上后：
requestPlan(COMMAND_WORDS[0].prompt);

// readUserKey() 里临时：
if (digitalRead(0) == LOW) return KEY_CONFIRM;  // BOOT 键低电平触发，以你板子为准
```

这样不接 ESP-SR 也能演示 **提议 → 按键确认 → 执行**。

### 9.6 烧录 HomeCue 前的分区提醒

接完语音模型或仅用网络胶水层时，**工具 → Partition Scheme** 改回：

**16M Flash (3MB APP/9.9MB FATFS)**（无内置 SR 模型时）

若你把 ESP-SR 库整包链进 HomeCue 且体积很大，再视编译大小选更大 APP 分区。

---

## 10. 第七步：烧录 HomeCue 固件并串口验证

### 10.1 打开并烧录

1. Arduino IDE → **文件 → 打开** →  
   `homecue-edge\firmware\esp32-audio\esp32-audio.ino`
2. 确认 `secrets.h` 在同目录且已填写。
3. **工具** 检查：ESP32S3 Dev Module、USB CDC Enabled、OPI PSRAM、16MB Flash、正确 COM 口。
4. 点击 **上传**。

### 10.2 串口监视器

- 波特率 **115200**
- 按 **RESET**

### 10.3 预期日志（按顺序）

```
[HomeCue Edge] ESP32-S3-AUDIO-Board firmware booting...
[WiFi] connecting to YourSSID ...
........
[WiFi] connected, IP = 192.168.1.50
```

触发一次 `/plan`（语音、NEXT 键、或你在 `setup()` 里写的测试调用）后：

```
[RGB] THINKING (breathing)
[/plan] proposed 3 action(s) - awaiting confirmation
  precheck light.brightness -> accepted (...)
  precheck ac.temperature -> accepted (...)
[RGB] READY (green)
```

按 **CONFIRM**（或你映射的 BOOT 键）：

```
[key] CONFIRM
  exec light.brightness -> accepted
  exec ac.temperature -> accepted
[RGB] READY (green)
```

**若 `[/plan] HTTP -1` 或超时：** 板子 ping 不通 PC → 查 **第 6–7 节** IP 与防火墙。  
**若 `HTTP 404/500`：** 后端没起或版本不对 → 查 **第 5 节**。

### 10.4 可选：板子侧 health 检查

在 `setup()` 里 `connectWifi()` 之后可临时加（调试完删掉）：

```cpp
HTTPClient http;
http.begin(healthUrl());
int code = http.GET();
Serial.printf("[health] HTTP %d\n", code);
http.end();
```

预期 `HTTP 200`。

---

## 11. 第八步：与网页联调

### 11.1 启动网页控制台

**再开一个** PowerShell（后端 8723 保持运行）：

```powershell
cd homecue-edge\apps\web
npm install
npm run dev
```

浏览器打开：**http://127.0.0.1:5173**

（也可用一键脚本 `homecue-edge\scripts\start-dev.ps1`，但会绑 `127.0.0.1`；板子走局域网 IP 时，后端需按 **第 5.3 节** 单独用 `0.0.0.0` 启动。）

### 11.2 网页侧设置

1. 勾选 **「Propose only」**（只提议、不自动执行）— 与板子 `execute=false` 行为一致。
2. 保持 **Agent mode** 开启（若界面有该选项）。

### 11.3 联调流程

| 步骤 | 操作 | 网页预期 |
| --- | --- | --- |
| 1 | 板子触发命令（语音 / NEXT / 测试 `requestPlan`） | 出现 agent 计划、trace、设备预校验 |
| 2 | 板子按 **REJECT** | 提议丢弃；状态回空闲 |
| 3 | 再次触发命令 | 新计划显示 |
| 4 | 板子按 **CONFIRM** | 「已执行」/ 设备状态更新 |

板子 RGB 与网页应**语义一致**：绿=待确认/成功，红=拒绝，黄=离线。

---

## 12. 验收清单（MVP）

全部打勾即硬件 MVP 完成：

- [ ] **第 4 节**：厂商语音例程烧录成功，唤醒词「hi esp」有反应，RGB 会亮
- [ ] **第 5 节**：`uvicorn` 在 `0.0.0.0:8723` 运行，`curl http://127.0.0.1:8723/health` 返回 `"status":"ok"`
- [ ] **第 6–7 节**：`curl http://<PC局域网IP>:8723/health` 从本机用局域网 IP 可访问
- [ ] **第 8 节**：`secrets.h` 已配置且未提交 git
- [ ] **第 9–10 节**：HomeCue 固件烧录成功，串口见 `WiFi connected` + `proposed N action(s)`
- [ ] 板子 **CONFIRM** 后串口有 `exec ... accepted`
- [ ] **第 11 节**：网页 **Propose only** 下，板子确认后设备状态变化可见
- [ ] （可选）**REJECT** 后提议消失，RGB 红或回空闲
- [ ] （可选）`POST /voice` 未装 whisper 时返回 **501** — **可忽略**，MVP 用固定命令词

---

## 13. 常见问题排查

### WiFi 连不上

| 检查项 | 做法 |
| --- | --- |
| 是否 2.4G | 手机热点开 2.4G 测一次 |
| SSID/密码 | 重新核对 `secrets.h`，注意首尾空格 |
| 路由器隔离 | 关闭 AP 隔离开关；板子与 PC 同网段 |
| 串口日志 | 看 `[WiFi] connection FAILED` 前有无 `....` 超时 |

### health / plan 超时（HTTP -1）

| 检查项 | 做法 |
| --- | --- |
| PC_HOST | 必须是 `ipconfig` 的局域网 IP，不是 `127.0.0.1` |
| 后端绑定 | 必须 `--host 0.0.0.0` |
| 防火墙 | **第 7 节** 规则是否添加 |
| 同网段 | 板子 IP（串口打印）与 PC IP 前三段应一致，如 `192.168.1.x` |

### 防火墙疑似拦截

- 暂时关闭专用网络防火墙测试（测完记得打开）。
- 确认入站规则针对 **TCP 8723** 且 profile 包含当前网络类型。

### COM 口找不到

1. 换 USB 口（优先主板直连，少经过 Hub）。
2. 确认是 **数据线**。
3. **设备管理器** 看有无黄色叹号 → 装 CP210x/CH340 驱动（视板子 USB 芯片而定）。
4. **BOOT 按住再插线** 再松 BOOT，看是否出现新 COM 口。

### 烧录失败

| 报错 | 处理 |
| --- | --- |
| `Failed to connect` | BOOT+RESET 下载模式；Upload Speed → 115200 |
| `Timed out waiting for packet header` | 同上；关占用 COM 的串口监视器 |
| 分区溢出 | 换更大 APP 的 Partition Scheme |

### 板子 ping 不通 PC

- Windows **专用网络** 可能阻止 ping，与 HTTP 无关；以 `curl http://PC_IP:8723/health` 为准。
- 若 HTTP 也不通：防火墙 + IP + 后端绑定三项逐一排除。

### whisper /voice 返回 501

- **正常**，表示 PC 未装 `faster-whisper`。
- MVP 用 **固定命令词 → `/plan` 文本**，不依赖 `/voice`。
- 若要 stretch：在 `apps/api` 按 `requirements.txt` 注释安装 whisper。

### 语音识别率低

- 先用 wiki 默认英文模型与「hi esp」。
- 中文环境按 wiki 换中文 `srmodels.bin` 与命令词表。
- 环境噪音大时改用 **NEXT 键 / BOOT 键** 触发（见 **第 9.5 节** 捷径）。

---

## 14. 演示录像建议（约 30 秒）

一条 30 秒演示 take：

| 时间 | 画面 | 解说要点 |
| --- | --- | --- |
| 0–5s | 板子 + PC 网页同屏 | 「ESP32 双麦语音入口，PC 边缘网关」 |
| 5–12s | 说唤醒词 + 命令词（或按 NEXT） | RGB 蓝→呼吸；网页弹出 plan + trace |
| 12–18s | 特写网页 trace / 守卫预校验 | 「先提议，不自动执行」 |
| 18–24s | 按 CONFIRM 键 | RGB 绿；网页设备状态变化 |
| 24–30s | （可选）按 REJECT 或展示拦截 | 「物理按键人在环 + 本地守卫」 |

**拍摄前检查：** 第 12 节清单全勾；浏览器打开 `http://127.0.0.1:5173` 且 **Propose only** 已勾选；串口监视器关掉避免占 COM 口。

---

## 附录：HomeCue 使用的 API

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/health` | 网关存活 |
| POST | `/plan` | `execute=false` 只提议 + precheck + trace |
| POST | `/execute` | 确认后真正执行 |
| POST | `/voice` | （stretch）上传 WAV；未装 whisper 时 **501** |

`POST /plan` 请求体示例：

```json
{
  "prompt": "I just got home...",
  "network_mode": "online",
  "agent_mode": true,
  "execute": false
}
```

---

## 附录：硬件引脚速查

| 功能 | 引脚 |
| --- | --- |
| ES7210 I2S | MCLK=12, SCLK=13, LRCK=14, ASDOUT=15 |
| I2C | SDA=11, SCL=10 |
| RGB / 用户键 | 经 **TCA9555** 扩展，以厂商例程为准 |

---

**相关文档：**

- 项目说明：`README.md`（仓库根目录）
