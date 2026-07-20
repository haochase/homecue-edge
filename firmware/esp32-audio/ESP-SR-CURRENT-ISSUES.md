# ESP-SR 语音控制当前状态

日期：2026-06-15

## 当前结论

语音控制主链路已经通过真机验证：本机音响播放唤醒词后，开发板进入 ESP-SR 命令窗口；随后播放命令词 `I am home`，开发板识别为 `I'm home`，触发 `/plan`，并返回 5 条 proposed actions。自动确认执行闭环也已通过，串口确认后 5 条动作均返回 `accepted`。

当前不再把“语音控制不可用”视为阻塞项。后续主要注意事项是测试方式：固定时间连续播放“唤醒词 + 命令词”容易让命令词早于 WakeNet channel verification，从而造成误判失败。应使用事件驱动测试：监听到 `wake word channel ... listening for command` 后再播放命令词。

## 已验证通过

1. 固件可启动并进入 ESP-SR route。

   ```text
   [mode] button-route + ESP-SR voice command route (propose only)
   [esp-sr] ES7210 codec ready
   [esp-sr] ready - say the wake word, then a command word
   ```

2. ESP-SR 模型已加载。

   ```text
   wakeNet9_v1h24_Hi,ESP_3_0.63_0.635
   MN5Q8_v2_english_8_0.9_0.90
   ```

3. WakeNet 唤醒通过。

   ```text
   [esp-sr] wake word detected - say a command word
   [esp-sr] wake word channel 2 verified - listening for command
   ```

4. MultiNet 命令词识别通过。

   ```text
   [voice] command: I'm home
   ```

5. 语音命令触发 `/plan` 通过。

   ```text
   [/plan] proposed 5 action(s) - awaiting confirmation
   ```

6. 确认后执行闭环通过。

   ```text
   [serial] CONFIRM
     exec light.set_scene -> accepted
     exec ac.set_temperature -> accepted
     exec projector.set_mode -> accepted
     exec speaker.play -> accepted
     exec reminder.set -> accepted
   ```

## 当前有效配置

固件已回归到与 ESP_SR 官方 Basic 示例一致、并且实测可识别的音频输入组合：

```cpp
.i2s_format = ES7210_I2S_FMT_I2S
.mic_gain = ES7210_MIC_GAIN_30DB
.tdm_enable = 0
es7210_config_volume(g_es7210, 12)
g_srI2s.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)
ESP_SR.begin(..., SR_CHANNELS_STEREO, SR_MODE_WAKEWORD)
```

之前尝试的 `I2S_MODE_TDM + SR_CHANNELS_MONO` 组合会导致唤醒/命令识别不稳定，不应作为当前主线配置。

## 新增诊断能力

1. 模型分区预检查。

   固件启动 ESP-SR 前检查 `model` 分区和 WakeNet/MultiNet 模型，缺失时明确打印错误并保留按键/串口兜底路径。

2. ES7210 初始化。

   固件在 I2S 和 ESP-SR 初始化前配置 ES7210 采样率、I2S 格式、位宽、mic bias、gain 和 volume。

3. 启动期麦克风采样诊断。

   固件会输出 `mic diag startup`，用于观察麦克风数据是否全零、是否削波、左右/偶奇样本是否异常。

4. 强制命令窗口。

   临时诊断串口命令：

   ```text
   homecue:voice-command-window
   ```

   该命令可跳过唤醒词，直接验证 MultiNet 命令词识别和 `/plan` 链路。

5. 事件驱动语音测试脚本。

   `scripts/test-esp32-sr-audio.ps1` 新增 `-EventDriven` 模式：先播放唤醒词，监听到开发板进入命令窗口后再播放命令词。

## 关键证据日志

端到端语音 `/plan` 验证：

```text
assets/demo/esp32-event-driven-audio-test-v2.log
assets/demo/esp32-event-driven-audio-test-v2-check.json
```

端到端语音 + 确认执行验证：

```text
assets/demo/esp32-event-driven-audio-execute-test-v2.log
assets/demo/esp32-event-driven-audio-execute-test-v2-check.json
```

回归配置启动日志：

```text
assets/demo/esp32-std-stereo-regression-boot.log
```

命令窗口单测：

```text
assets/demo/esp32-std-stereo-command-window-plan.log
```

## 推荐复测命令

只验证语音触发 `/plan`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-esp32-sr-audio.ps1 -Port COM7 -Seconds 150 -EventDriven -WakePhrase "Hi E S P" -CommandPhrase "I am home" -ExpectedCommandLabel "I'm home" -ExpectedActionCount 5 -Required
```

验证语音触发 `/plan` 后再自动确认执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-esp32-sr-audio.ps1 -Port COM7 -Seconds 170 -EventDriven -WakePhrase "Hi E S P" -CommandPhrase "I am home" -ExpectedCommandLabel "I'm home" -ExpectedActionCount 5 -AutoConfirm -ExpectedExecutionCount 5 -Required
```

## 保留注意事项

1. 固定间隔 TTS 测试仍可能失败。

   原因是 TTS 说完唤醒词后，命令词可能在 ESP-SR 完成 channel verification 之前已经开始播放。此类失败不应直接判定为语音链路失败。

2. 音响位置和音量仍会影响 WakeNet。

   当前测试是在本机已连接音响、音量足够的状态下通过。若换设备或摆位，优先使用 `-EventDriven` 模式重新验证。

3. `homecue:voice-command-window` 是诊断入口。

   它对调试有用，但产品化前可以考虑移除或只在调试构建中启用。

## 当前状态一句话

ESP-SR 语音控制已经在真机上完成验证：音响播放唤醒词和命令词可以触发 HomeCue `/plan`，并且在确认后能执行全部 proposed actions。
