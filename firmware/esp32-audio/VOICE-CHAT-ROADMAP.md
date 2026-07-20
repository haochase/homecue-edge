# ESP32 语音聊天方案

日期：2026-06-15

## 目标

实现一条可持续测试、可逐步产品化的语音聊天链路：

```text
ESP32 负责唤醒和录音
-> 后端负责 ASR + MiMo 聊天 + TTS
-> ESP32 下载 TTS 音频
-> ESP32 板载扬声器播放回复
```

开发测试时，本机音响可以替代真人用户发出语音；回复不再从本机音响播放，而是下发给 ESP32 板载扬声器播放。

## 当前工程状态

已经完成：

1. ESP32 ESP-SR 英文唤醒和固定命令词控制链路。
2. 后端 OpenAI-compatible 文本模型调用能力，当前 `.env` 可通过 `ACTIVE_PROVIDER=mimo` 指向 MiMo。
3. 新增后端 `/voice-chat` 首版：
   - JSON 文本输入可直接调用 MiMo/兼容模型生成聊天回复。
   - WAV 输入支持 ESP32 上传录音；当前机器已验证 Windows `zh-CN` Speech Recognition fallback 可用。
   - `speak=true` 或 `?speak=1` 时，后端在 Windows 本机默认音频设备播放回复。
   - `reply_audio=true` 或 `?reply_audio=1` 时，后端生成短 WAV 并返回给 ESP32 下载播放。
4. 新增持续测试脚本 `scripts/test-voice-chat.ps1`。
5. ESP32 已实现 `homecue:voice-chat [seconds]`：录音、上传 `/voice-chat?reply_audio=1`、下载回复 WAV、经 ES8311/I2S 播放。
6. 新增并验证 `scripts/test-esp32-voice-chat-audio.ps1`：本机音响播放 `Hi E S P` 和 `chat mode`，ESP32 进入聊天录音窗口；本机音响再播放中文用户问题，ESP32 录音上传并用板载喇叭播放回复。

尚未完成：

1. `你好小千` 中文唤醒词模型。
2. 直接用 `你好小千` 在板端本地唤醒并进入聊天模式。
3. 人耳确认板载扬声器实际听感、音量和摆位；当前串口已确认播放函数完成，但听感仍属于现场验收。

## 分阶段路线

### Phase 1: 后端文本聊天 + PC 音响 TTS（已通过）

目的：先证明 MiMo 聊天回复和本机音响播放可用，不依赖 ESP32 录音。

测试命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-voice-chat.ps1 -Text "你好小千，介绍一下你自己" -Speak -Required
```

成功标志：

```text
status = passed
provider = mimo
reply 非空
tts.status = played
```

当前证据：

```text
assets/demo/voice-chat-mimo-text-v3.json
assets/demo/voice-chat-mimo-pc-tts-v3.json
```

### Phase 2: ESP32 临时触发录音上传（已通过）

目的：先不等待中文唤醒模型，用现有串口命令或已验证的 `Hi E S P` 唤醒作为入口，证明 ESP32 能采集麦克风音频并 POST 到后端。

已新增固件命令：

```text
homecue:voice-chat [seconds]
```

ESP-SR 临时语音入口：

```text
Hi E S P -> chat mode -> speak the real question during the recording window
```

行为：

1. 复用当前 ES7210 + I2S 输入配置。
2. 录制 3-5 秒 16 kHz / 16-bit / mono 或 stereo WAV。
3. `POST /voice-chat?reply_audio=1`，Content-Type 为 `audio/wav`。
4. 串口打印：

```text
[/voice-chat] recording 4s...
[/voice-chat] uploading N bytes...
[/voice-chat] heard: ...
[/voice-chat] reply: ...
[/voice-chat] reply_audio: ready /voice-chat/audio/...
[speaker] downloaded N audio bytes
[speaker] playback done
```

当前验证结果：

```text
默认固件构建: passed
ESP-SR 固件构建: passed
firmware-flow: passed
ESP32 record -> ASR -> MiMo -> reply_audio -> board speaker playback: passed by serial log
```

当前证据：

```text
assets/demo/voice-chat-audio-file-reply-audio-v3.json
assets/demo/esp32-board-speaker-voice-chat-v3.log
assets/demo/esp32-voice-chat-audio-test-v1.log
assets/demo/esp32-voice-chat-audio-test-v1-check.json
```

### Phase 3: 中文 ASR 稳定化（当前可用，仍需产品化）

可选路径：

1. Windows Speech Recognition `zh-CN` fallback。
   - 当前状态：已在本机跑通，适合开发验证。
   - 风险：依赖 Windows 本机语音组件，部署到 Linux/设备端时不可直接复用。
2. 本地 `faster-whisper`。
   - 优点：隐私强，接口已预留。
   - 风险：当前 `pip install faster-whisper==1.1.0/1.2.1` 多次卡住，仍不是本机可用路径。
3. 云端 ASR。
   - 优点：中文效果和速度通常更好。
   - 风险：需要新增 provider 配置和隐私边界说明。

### Phase 4: `你好小千` 唤醒

当前 ESP-SR 已加载的是 `Hi ESP` WakeNet 模型。要换成 `你好小千`，不能只改字符串，需要中文 WakeNet/唤醒模型支持。

当前本机核查结果：

```text
scripts/check-esp32-sr-models.ps1 -RequiredWakeKeyword hiesp -RequiredMultinetKeyword english -Required
-> passed: 当前 srmodels.bin 含 hiesp + english multinet

scripts/check-esp32-sr-models.ps1 -RequiredWakeKeyword xiaoqian -RequiredMultinetKeyword english
-> failed: 当前 srmodels.bin 不含 xiaoqian

Probe keywords:
xiaoqian=false
nihaoxiaozhi=false
nihaoxiaoxin=false
```

本地 arduino-esp32 3.0.7 的 `ESP_SR` 封装还在 `esp32-hal-sr.c` 里硬编码筛选 `hiesp`。现在 `scripts/flash-esp32.ps1` 已支持受控覆盖：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 `
  -EnableEspSr `
  -EspSrWakeKeyword xiaoqian `
  -EspSrModelsBin .\path\to\custom-srmodels.bin
```

该流程会把 Arduino `ESP_SR` 库复制到临时 sketch-local `libraries` 目录，只在临时副本里把 WakeNet filter 从 `hiesp` 改成目标关键词，不污染全局 Arduino 安装；随后检查最终 `srmodels.bin` 是否真的包含目标关键词。当前 stock 模型对 `xiaoqian` 会明确失败，避免烧录出必然不可用的固件。

可选路线：

1. 使用厂商/ESP-SR 支持的中文唤醒模型，并替换/重打包 `srmodels.bin`。
2. 若无现成模型，保留 `Hi E S P` 或按键/串口作为开发入口。
3. 后续训练或替换自定义 `你好小千` 唤醒模型，再重新生成并烧录 `srmodels.bin`。
4. 若使用 ESP-IDF 而不是 Arduino `ESP_SR` 封装，可直接走更底层的 ESP-SR 配置来选择 WakeNet/MultiNet。

### Phase 5: ESP32 板载扬声器播放回复（已通过语音入口验证）

当前实现：

```text
/voice-chat?reply_audio=1 返回 reply_audio.url
ESP32 下载 WAV
ESP32 解析 RIFF/fmt/data chunk
ES8311/I2S 输出到板载扬声器
```

已修复的问题：Windows TTS 生成的 WAV `fmt` chunk 长度为 18，Arduino `I2SClass::playWAV()` 默认按 44 字节固定头解析会读错 `data` chunk 并触发 Guru Meditation。固件已改为手动解析 WAV chunk 后写入 I2S。

实测标志：

```text
[esp-sr] wake word detected - say a command word
[esp-sr] wake word channel 2 verified - listening for command
[voice] chat mode
[/voice-chat] recording 6s - speak now
[/voice-chat] provider: mimo
[/voice-chat] reply_audio: ready /voice-chat/audio/...
[speaker] downloaded 113326 audio bytes
[speaker] playing 113326 WAV bytes rate=16000 channels=1 data=113280
[speaker] playback done
```

仍需现场人耳验收：串口能证明 ESP32 下载并调用播放完成，不能替代实际听感确认。

## 当前新增接口

### POST /voice-chat

文本测试：

```json
{
  "text": "你好小千，我们来聊天吧",
  "speak": true
}
```

WAV 上传：

```text
POST /voice-chat?reply_audio=1
Content-Type: audio/wav
Body: raw WAV bytes
```

响应：

```json
{
  "text": "识别出的文本",
  "language": "zh",
  "reply": "MiMo 生成的回复",
  "provider": "mimo",
  "tts": {
    "target": "pc-speaker",
    "status": "skipped"
  },
  "reply_audio": {
    "target": "esp32-speaker",
    "status": "ready",
    "url": "/voice-chat/audio/<id>.wav"
  }
}
```

## 当前判断

MiMo-v2.5-pro 足够作为语音聊天的大脑，但它只处理文本推理，不替代 ASR/TTS 或唤醒词检测。当前已跑通的最小链路是：

```text
PC 音响模拟用户语音
-> ESP32 麦克风录音
-> /voice-chat ASR
-> MiMo 生成短回复
-> 后端 TTS 生成 WAV
-> ESP32 下载并播放
```

下一步产品化重点是把开发入口从串口/`Hi E S P -> chat mode` 换成目标中文唤醒入口 `你好小千`。

## 当前问题汇总

1. `你好小千` 不能只靠 MiMo 触发。
   MiMo 只接收 ASR 后的文本并生成回复；真正监听麦克风并判断唤醒词的是 ESP-SR/WakeNet 或其他唤醒模型。当前板端已验证的是 `Hi E S P`，且本机 `srmodels.bin` 只含 `hiesp` + English MultiNet，不含 `xiaoqian` / `nihaoxiaozhi` / `nihaoxiaoxin`。中文唤醒需要中文 WakeNet/自定义唤醒模型与新的 `srmodels.bin`。

2. ASR 当前依赖 Windows fallback。
   本机 `zh-CN` Speech Recognition fallback 已跑通；`faster-whisper` 安装仍多次卡住，虚拟环境里未稳定出现 `faster_whisper`、`ctranslate2`、`av`。若迁移到非 Windows 环境，需要改用本地 Whisper/云端 ASR 等可部署方案。

3. 板载扬声器仍需人耳听感验收。
   串口日志已确认 ES8311 初始化、回复 WAV 下载、WAV chunk 解析和 I2S 写入完成；但自动日志不能证明现场实际音量、音质和摆位是否满足真实使用。

4. 开发阶段触发方式。
   现在可用 `homecue:voice-chat [seconds]` 通过串口触发录音上传；也可用 `Hi E S P` 后说 `chat mode` 进入同一路径。目标中文入口 `你好小千` 属于后续唤醒模型替换工作。

5. 串口中文显示可能退化为问号。
   后端 JSON 中的中文文本正确；ESP32 串口日志里 `heard` / `reply` 可能显示为 `?`，这主要影响调试可读性，不影响 ASR、MiMo、TTS 或播放链路。
