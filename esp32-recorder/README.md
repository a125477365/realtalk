# RealTalk 录音笔（ESP32）

把 ESP32 做成随身录音笔：按键录音存 SD 卡，手机 App（iOS / Android）通过蓝牙直接浏览
录音笔中的文件并分块下载，随后走 App 既有的「上传录音生成场景」流程（高级会员功能）。

## 硬件清单

| 器件 | 说明 |
|------|------|
| ESP32 DevKit（WROOM-32） | 主控 |
| INMP441 | I2S 数字麦克风 |
| MicroSD 卡模块（SPI） | 存储，FAT32 格式 |
| 按键 | 可直接用板载 BOOT 键（GPIO0） |

### 接线

```
INMP441        ESP32          MicroSD(SPI)   ESP32
VDD   ── 3V3                  VCC  ── 5V/3V3（按模块要求）
GND   ── GND                  GND  ── GND
SCK   ── GPIO14               CS   ── GPIO5
WS    ── GPIO15               MOSI ── GPIO23
SD    ── GPIO32               MISO ── GPIO19
L/R   ── GND（左声道）          SCK  ── GPIO18
```

状态 LED 用板载 GPIO2：常亮 = 正在录音。

## 烧录

1. Arduino IDE 安装 esp32 板卡包（Boards Manager 搜 "esp32" by Espressif）。
2. 打开 `esp32_recorder/esp32_recorder.ino`，开发板选 **ESP32 Dev Module**。
3. 编译上传。串口监视器（115200）可看到状态日志。

命令行（arduino-cli）：

```bash
arduino-cli compile --fqbn esp32:esp32:esp32 esp32_recorder
arduino-cli upload  --fqbn esp32:esp32:esp32 -p /dev/ttyUSB0 esp32_recorder
```

## 使用

1. 按一下 BOOT 键开始录音（LED 亮），再按一下停止，文件存为 `REC0001.WAV` 递增。
2. 打开 RealTalk App → 账户 → 上传录音 → 连接蓝牙录音笔。
3. App 列出录音笔中的 WAV 文件，点选后自动分块下载并上传到服务器转写生成场景。
   注意：录音进行中不响应下载（避免 SD 总线争用），先停止录音。

## BLE 协议（与 App 端约定）

广播名 `RealTalk Recorder`，服务 UUID `7E400001-B5A3-F393-E0A9-E50E24DCCA9E`。

| 特征 | UUID（后缀同服务） | 属性 | 说明 |
|------|------|------|------|
| 控制 | `7E400002-…` | Write | 文本命令 |
| 数据 | `7E400003-…` | Notify | 命令响应 |

命令与响应：

- `LIST` → 数据特征逐条通知 `{"n":"REC0001.WAV","s":123456}`（n=文件名，s=字节数），
  全部发完后通知 `{"end":true}`。
- `GET:<文件名>` → 二进制分块：`[4字节小端 offset][payload]`，payload ≤180 字节；
  发送完毕通知 `offset = 0xFFFFFFFF` 的空包表示 EOF。
- `DEL:<文件名>` → 删除文件并重发文件列表。

App 端连接后会请求 MTU 247。对应客户端实现：

- iOS：`realtalk/realtalk/Services/RecorderBLEManager.swift`
- Android：`realtalkad/app/src/main/java/com/example/realtalkad/ble/RecorderBleClient.kt`

## 已知限制

- 录音为 WAV（PCM 16kHz/16bit），MP3 编码对 ESP32 负担过大；后端 `/audio/upload`
  已同时接受 mp3 / wav / m4a，无需转换。
- BLE 吞吐约 8–15 KB/s，1 分钟录音（~2MB）约需 2–4 分钟传输；长录音建议取下 SD 卡
  或在 Web 端上传。
