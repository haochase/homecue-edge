# ESP-SR 语音命令词路线 - 验证运行手册（可委派）

> 配套阅读：`firmware/esp32-audio/README.md` 第 **4C** 节（开启方法、命令词表、排错）。
> 本手册的作用：把「ESP-SR 路线真机验证清单」拆成 **可由编码智能体自动完成** 与
> **必须人在板子前完成** 两类任务，每条都给出目的 / 前置 / 操作 / 预期 / 验收 / 兜底，
> 便于直接派发给其他智能体或人工执行。

---

## 0. 目的（Purpose）

确认固件里 **编译开关隔离的 ESP-SR 离线命令词路线**（`ENABLE_ESP_SR`，默认 0）：

1. 默认关闭时不破坏现有按键 + 串口路线、不破坏 CI / 固件契约。
2. 开关打开时能编译、能在真机上「唤醒词 -> 命令词 -> `/plan`(execute=false)」只提议。
3. 任何语音不可靠的情况下，按键 / 串口兜底永远可用。

**只提议、不执行** 是铁律：识别命令词只调用 `requestPlan(... execute=false ...)`，
真正执行仍需 CONFIRM 键或串口 `homecue:execute`。

---

## 1. Cursor / 编码智能体能否自动化？总览

| # | 清单项 | 能否自动化 | 由谁做 |
| --- | --- | --- | --- |
| 1 | 安装 arduino-cli + ESP32 core + 依赖库 | 可 | 编码智能体 |
| 2 | 切换 `ENABLE_ESP_SR` 编译开关 | 可 | 编码智能体 |
| 3 | **编译冒烟测试**（flag=1 能编过 / flag=0 默认仍编过） | 可 | 编码智能体 |
| 4 | 重新生成命令词音素串（multinet g2p） | 部分可（有工具时） | 编码智能体 |
| 5 | 补 `espSrBegin()` 里 ES7210 I2C 初始化代码 | 部分可（需厂商例程源码） | 编码智能体 |
| 6 | 串口日志抓取脚手架（自动发命令、存日志） | 可 | 编码智能体 |
| 7 | 选分区 / 烧录固件到板子 | 受限（需板子连着，写硬件，建议人工监督） | 人工 / 受控自动 |
| 8 | 烧 `srmodels.bin` 到模型分区 | 受限（同上） | 人工 / 受控自动 |
| 9 | **对板子说唤醒词 + 命令词** | **不可** | 人工 |
| 10 | 麦克风增益 / 唤醒灵敏度按听感调参 | **不可** | 人工 |
| 11 | 按物理 KEY1/2/3、观察 RGB 灯色 | **不可** | 人工 |
| 12 | 最终验收（端到端语音演示） | **不可** | 人工 |

**结论：** 端到端无法全自动，因为决定性环节（说话、听感调参、看灯、按键）是物理/声学的。
但「装环境 + 编译验证 + 改代码 + 抓日志」这部分可完全交给编码智能体，能把人工环节压到最小。

---

## 2. Phase A — 编码智能体可自动完成的任务

> 在仓库根目录执行（用相对路径，勿写绝对路径）。Windows PowerShell；命令保持 ASCII。
> 注意：PowerShell 5.1 不支持 `&&`，多命令用 `;` 或分多次执行。

### A1. 准备工具链

- **目的**：让命令行可编译 ESP32-S3 固件，无需 Arduino IDE GUI。
- **前置**：可联网；磁盘约 2GB。
- **操作**：
  ```powershell
  winget install ArduinoSA.CLI            # 或从 arduino.cc 下载 arduino-cli
  arduino-cli config init
  arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
  arduino-cli core update-index
  arduino-cli core install esp32:esp32    # 建议 3.0.x；自带 ESP_SR / ESP_I2S 库
  arduino-cli lib install ArduinoJson
  ```
- **预期**：`arduino-cli core list` 列出 `esp32:esp32`；`arduino-cli lib list` 含 `ArduinoJson`。
- **验收**：上述命令退出码 0。
- **兜底**：装不上 core 时记录错误，跳到 A3 仅做「flag=0 默认构建」的静态确认。

### A2. 提供编译用的 secrets.h（占位值，勿提交）

- **目的**：编译需要 `secrets.h`（被 gitignore）。用占位值，仅供编译。
- **操作**：
  ```powershell
  Copy-Item firmware\esp32-audio\secrets.h.example firmware\esp32-audio\secrets.h -Force
  ```
  保持示例里的占位值即可（如 `PLACEHOLDER_SSID` / `127.0.0.1` / `8723`），**不要**填真实 WiFi/IP。
- **验收**：`firmware\esp32-audio\secrets.h` 存在；`git status` 不应显示它（已忽略）。

### A3. 编译冒烟测试（核心，价值最高）

- **目的**：证明 `ENABLE_ESP_SR=1` 的 ESP-SR 代码真的能编过，且默认 `=0` 构建不受影响。
- **操作**（两次编译）：
  ```powershell
  # 默认构建（语音关闭，回归）：按键路线分区
  arduino-cli compile -b esp32:esp32:esp32s3 `
    --board-options "PSRAM=opi,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB" `
    firmware\esp32-audio

  # 语音开启构建（ESP-SR）：用带模型的 SR 分区
  arduino-cli compile -b esp32:esp32:esp32s3 `
    --board-options "PSRAM=opi,FlashSize=16M,PartitionScheme=esp_sr_16" `
    --build-property "build.extra_flags=-DENABLE_ESP_SR=1" `
    firmware\esp32-audio
  ```
- **预期**：两条都 `Sketch uses ... bytes`，退出码 0。
- **验收**：默认构建必须过；`-DENABLE_ESP_SR=1` 构建过则证明 ESP-SR 接口对得上当前 core。
- **兜底**：若 flag=1 报 `ESP_SR.h: No such file` 或 API 不匹配，**不要**改默认开关；
  在报告里记录 core 版本与确切报错，列出需调整的头文件/调用（README 4C 已注明 API 因 core 版本而异），
  默认构建仍须保持可编。`--board-options` 的分区名以 `arduino-cli board details -b esp32:esp32:esp32s3` 实际列出的为准。

### A4. 固件契约 + 本地门禁回归

- **目的**：确认改动没破坏既有契约 / CI。
- **操作**：
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-firmware-flow.ps1 -Required
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-local.ps1        # 缺 npm/python 依赖时可加 -SkipFirmware 或只跑能跑的
  powershell -NoProfile -File .\scripts\scan-secrets.ps1 -All
  ```
- **验收**：firmware-flow 18 项全 OK 退出 0；scan-secrets clean；check-local 通过（或说明缺依赖部分）。

### A5.（可选）重新生成命令词音素串

- **目的**：`esp32-audio.ino` 的 `SR_COMMANDS` 第三列目前是占位音素，需按实际模型重生成。
- **操作**：用 esp-sr 仓库的 multinet 命令词生成工具（g2p）对 `I am home` / `sleep mode` / `movie time`
  生成英文 multinet 音素串，替换 `SR_COMMANDS` 第三列；命令词文字可与 `COMMAND_WORDS` 标签不同，
  只要 `sr_cmd_t` id 落在 `0..COMMAND_COUNT-1`。
- **验收**：替换后重跑 A3 的 flag=1 编译仍过；A4 契约仍过。
- **兜底**：无 g2p 工具就保留占位串并在报告标注「待人工在装好 esp-sr 后生成」。

### A6.（可选）补 ES7210 I2C 初始化

- **目的**：双麦 ADC 常需 I2C 配置增益/TDM 槽后 I2S 才有有效音频。
- **操作**：从 Waveshare ESP-SR 例程源码抄 ES7210 的 I2C 寄存器初始化，填进 `espSrBegin()` 里
  `TODO[VENDOR]` 处，置于 `g_srI2s.begin()` 之前。引脚：MCLK=12, BCLK=13, WS=14, DIN=15。
- **验收**：flag=1 编译过；契约过。
- **兜底**：拿不到厂商源码就保留 `TODO[VENDOR]`，在报告里标注为人工补齐项。

> Phase A 完成后：可 `git add` 改动并按 conventional commit 本地提交，**不要 push**；
> 提交前必跑 `scripts\scan-secrets.ps1 -Staged`。

---

## 3. Phase B — 必须人在板子前完成的任务

> 这些步骤无法由智能体替代（物理/声学/看灯/按键）。Phase A 把代码与编译都备好后再做。

### B1. 烧录前设置（Arduino IDE 或 arduino-cli upload）
- 开发板 `ESP32S3 Dev Module`；USB CDC On Boot = Enabled；PSRAM = OPI；Flash = 16MB。
- 分区：**ESP SR 16M (3MB APP/7MB SPIFFS/2.9MB MODEL)**（语音构建），并把 `srmodels.bin`
  （wakenet "hi esp" + multinet5 english）烧入模型分区。
- `secrets.h` 改回 **真实** WiFi / PC 局域网 IP / 8723（勿提交）。
- **验收**：串口出现 `[mode] button-route MVP + ESP-SR voice route` 与 `[esp-sr] ready`。

### B2. 唤醒 + 命令词联调（核心人工环节）
- 对板子清晰说唤醒词（默认 "hi esp"），再说命令词（如 "I am home"）。
- **预期**：串口 `[esp-sr] wake word detected` -> `[esp-sr] command ...` -> `[/plan] proposed N action(s)`；
  RGB 蓝->呼吸->绿；PC 网页（Propose only）显示 plan + trace。
- **验收**：CONFIRM 键 -> `exec ... accepted`；REJECT 键 -> 提议丢弃。

### B3. 针对「hi esp 无响应」风险的人工调参（README 4C.6）
- 麦克风增益（ES7210 寄存器调高、贴近正面说）；模型语言确认 english；唤醒灵敏度调高；
  必要时换唤醒模型 / 重烧 `srmodels.bin`。
- **兜底（永久可用）**：语音任何时候不灵，立刻用 **NEXT/BOOT 键** 或串口
  `homecue:plan [0|1|2]` 触发，演示不中断。可用现成脚本抓证据：
  ```powershell
  .\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 90 -SkipReset -RequireInteraction -AutoSerialLevel4 -SerialCommandIndex 0 -SaveLogPath .\assets\demo\esp32-level4.log -Required
  ```

### B4. 回归确认按键路线（关掉语音）
- `ENABLE_ESP_SR=0`，分区改回 `16M Flash (3MB APP/9.9MB FATFS)`，重烧。
- **验收**：串口 `[mode] button-route MVP (no ESP-SR; voice disabled)`；KEY1->proposed，KEY2->exec，KEY3->reject 正常。

---

## 4. 派发给其他智能体的提示词（可直接粘贴）

> 把下面整段交给一个可执行 Shell / 改代码的编码智能体（仅做 Phase A）。

```
你负责 HomeCue Edge 固件 ESP-SR 路线的【软件侧自动化验证】（不接触真机）。
仓库已在本机，固件目录 firmware/esp32-audio/。严格只做以下 Phase A，不碰 apps/api、apps/web 业务代码。

按 firmware/esp32-audio/VERIFY-ESP-SR-RUNBOOK.md 的 Phase A 执行：
1) 装 arduino-cli + esp32 core(3.0.x) + ArduinoJson；
2) 从 secrets.h.example 复制占位 secrets.h（勿填真实值、勿提交）；
3) 跑两次编译冒烟：默认构建(app3M_fat9M_16MB) 必须过；-DENABLE_ESP_SR=1(esp_sr_16) 构建尝试编过；
   分区名以 `arduino-cli board details -b esp32:esp32:esp32s3` 实际为准；
4) 跑 scripts\check-firmware-flow.ps1 -Required、check-local.ps1、scan-secrets.ps1 -All；
约束：不得把 ENABLE_ESP_SR 默认改成 1；不得让默认构建失败；日志/字符串用 ASCII，
不得出现真实隐私/密钥/绝对路径/真实域名。提交前跑 scan-secrets.ps1 -Staged，本地 commit 但不要 push。
完成后汇报：core 版本、两次编译结果（含报错原文如有）、契约/门禁/scan 结果、是否已 commit、
以及哪些项需人工在真机完成（即 Phase B）。
```

---

## 5. 约束（公共仓库）

- 任何新增字符串/注释/日志：**ASCII**，不得含真实隐私值、真实邮箱、绝对路径、真实域名；用占位符或相对路径。
- `secrets.h`、`.env*` 永不提交。提交前必跑 `scripts\scan-secrets.ps1 -Staged`。
- 真机烧录 / 说话 / 调参 / 按键属人工事项，智能体不得声称已在硬件上验证。
