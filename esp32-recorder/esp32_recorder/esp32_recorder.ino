/*
 * RealTalk 录音笔固件（ESP32 + INMP441 I2S 麦克风 + MicroSD）
 *
 * 功能：
 *  1. 按键开始/停止录音，I2S 采集 16kHz/16bit 单声道，WAV 写入 SD 卡（REC0001.WAV 递增）
 *  2. BLE GATT「文件列表 + 分块下载」服务，与 RealTalk iOS/Android App 对接：
 *     - 服务 UUID:  7E400001-B5A3-F393-E0A9-E50E24DCCA9E
 *     - 控制特征(写): 7E400002-…   命令: "LIST" / "GET:<文件名>" / "DEL:<文件名>"
 *     - 数据特征(通知): 7E400003-…
 *       LIST 响应: 每个文件一条 JSON {"n":"REC0001.WAV","s":123456}，结束发 {"end":true}
 *       GET  响应: 二进制块 [4字节小端偏移][数据]，发送完毕发偏移 0xFFFFFFFF
 *
 * 硬件接线（可按需修改下方引脚定义）：
 *   INMP441:  SCK->GPIO14  WS->GPIO15  SD->GPIO32  L/R->GND  VDD->3V3
 *   MicroSD (SPI): CS->GPIO5  MOSI->GPIO23  MISO->GPIO19  SCK->GPIO18
 *   录音按键: GPIO0 (板载 BOOT 键即可，按下接地)
 *   状态 LED: GPIO2 (板载)
 *
 * 编译环境：Arduino IDE / arduino-cli，开发板 "ESP32 Dev Module"
 * 依赖库：ESP32 BLE Arduino（随 esp32 板卡包自带）、SD、FS
 */

#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <FS.h>
#include <SD.h>
#include <SPI.h>
#include <driver/i2s.h>

// ---------------- 引脚 ----------------
#define PIN_I2S_SCK 14
#define PIN_I2S_WS 15
#define PIN_I2S_SD 32
#define PIN_SD_CS 5
#define PIN_BUTTON 0
#define PIN_LED 2

// ---------------- 录音参数 ----------------
#define SAMPLE_RATE 16000
#define BITS_PER_SAMPLE 16
#define I2S_PORT I2S_NUM_0
#define I2S_READ_BUF 2048

// ---------------- BLE 协议 ----------------
#define SERVICE_UUID "7E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CONTROL_UUID "7E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define DATA_UUID "7E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHUNK_PAYLOAD 180  // 配合 247 MTU；App 端会请求 MTU=247

static BLECharacteristic *dataChar = nullptr;
static volatile bool bleConnected = false;
static volatile bool recording = false;

static File wavFile;
static String wavPath;
static uint32_t wavDataBytes = 0;

// 待处理的 BLE 命令（在 loop 中执行，避免在 BLE 回调里做 SD 长操作）
static String pendingCommand;
static portMUX_TYPE cmdMux = portMUX_INITIALIZER_UNLOCKED;

// ---------------- WAV 头 ----------------
static void writeWavHeader(File &f, uint32_t dataBytes) {
  uint32_t byteRate = SAMPLE_RATE * BITS_PER_SAMPLE / 8;
  uint32_t chunkSize = 36 + dataBytes;
  uint16_t blockAlign = BITS_PER_SAMPLE / 8;
  uint8_t header[44] = {
      'R', 'I', 'F', 'F',
      (uint8_t)(chunkSize), (uint8_t)(chunkSize >> 8), (uint8_t)(chunkSize >> 16), (uint8_t)(chunkSize >> 24),
      'W', 'A', 'V', 'E', 'f', 'm', 't', ' ',
      16, 0, 0, 0,      // fmt 块大小
      1, 0,             // PCM
      1, 0,             // 单声道
      (uint8_t)(SAMPLE_RATE), (uint8_t)(SAMPLE_RATE >> 8), (uint8_t)(SAMPLE_RATE >> 16), (uint8_t)(SAMPLE_RATE >> 24),
      (uint8_t)(byteRate), (uint8_t)(byteRate >> 8), (uint8_t)(byteRate >> 16), (uint8_t)(byteRate >> 24),
      (uint8_t)blockAlign, 0,
      BITS_PER_SAMPLE, 0,
      'd', 'a', 't', 'a',
      (uint8_t)(dataBytes), (uint8_t)(dataBytes >> 8), (uint8_t)(dataBytes >> 16), (uint8_t)(dataBytes >> 24)};
  f.seek(0);
  f.write(header, sizeof(header));
}

// ---------------- I2S ----------------
static void setupI2S() {
  i2s_config_t config = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,  // INMP441 输出 24bit 填充在 32bit 帧
      .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 256,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0};
  i2s_pin_config_t pins = {
      .bck_io_num = PIN_I2S_SCK,
      .ws_io_num = PIN_I2S_WS,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = PIN_I2S_SD};
  i2s_driver_install(I2S_PORT, &config, 0, nullptr);
  i2s_set_pin(I2S_PORT, &pins);
}

// ---------------- 录音控制 ----------------
static String nextFileName() {
  for (int index = 1; index <= 9999; index++) {
    char name[20];
    snprintf(name, sizeof(name), "/REC%04d.WAV", index);
    if (!SD.exists(name)) return String(name);
  }
  return "/REC9999.WAV";
}

static void startRecording() {
  wavPath = nextFileName();
  wavFile = SD.open(wavPath, FILE_WRITE);
  if (!wavFile) {
    Serial.println("[rec] SD open failed");
    return;
  }
  wavDataBytes = 0;
  writeWavHeader(wavFile, 0);  // 占位，停止时回填
  recording = true;
  digitalWrite(PIN_LED, HIGH);
  Serial.printf("[rec] start %s\n", wavPath.c_str());
}

static void stopRecording() {
  recording = false;
  if (wavFile) {
    writeWavHeader(wavFile, wavDataBytes);
    wavFile.close();
    Serial.printf("[rec] saved %s (%u bytes)\n", wavPath.c_str(), wavDataBytes);
  }
  digitalWrite(PIN_LED, LOW);
}

static void pumpAudio() {
  static int32_t raw[I2S_READ_BUF / 4];
  static int16_t pcm[I2S_READ_BUF / 4];
  size_t bytesRead = 0;
  i2s_read(I2S_PORT, raw, sizeof(raw), &bytesRead, 0);
  int samples = bytesRead / 4;
  if (samples <= 0 || !wavFile) return;
  for (int i = 0; i < samples; i++) {
    pcm[i] = (int16_t)(raw[i] >> 14);  // 24bit(<<8) → 16bit
  }
  wavFile.write((uint8_t *)pcm, samples * 2);
  wavDataBytes += samples * 2;
}

// ---------------- BLE 文件服务 ----------------
static void notifyChunk(const uint8_t *payload, size_t len, uint32_t offset) {
  uint8_t packet[4 + CHUNK_PAYLOAD];
  packet[0] = offset & 0xFF;
  packet[1] = (offset >> 8) & 0xFF;
  packet[2] = (offset >> 16) & 0xFF;
  packet[3] = (offset >> 24) & 0xFF;
  if (len > 0) memcpy(packet + 4, payload, len);
  dataChar->setValue(packet, 4 + len);
  dataChar->notify();
  delay(8);  // 节流，避免协议栈拥塞丢包
}

static void sendFileList() {
  File root = SD.open("/");
  for (File entry = root.openNextFile(); entry; entry = root.openNextFile()) {
    String name = String(entry.name());
    if (!entry.isDirectory() && (name.endsWith(".WAV") || name.endsWith(".wav"))) {
      char line[80];
      snprintf(line, sizeof(line), "{\"n\":\"%s\",\"s\":%u}", name.c_str(), (uint32_t)entry.size());
      dataChar->setValue((uint8_t *)line, strlen(line));
      dataChar->notify();
      delay(15);
    }
    entry.close();
  }
  root.close();
  const char *end = "{\"end\":true}";
  dataChar->setValue((uint8_t *)end, strlen(end));
  dataChar->notify();
}

static void sendFile(const String &name) {
  String path = name.startsWith("/") ? name : "/" + name;
  File f = SD.open(path, FILE_READ);
  if (!f) {
    Serial.printf("[ble] file not found: %s\n", path.c_str());
    notifyChunk(nullptr, 0, 0xFFFFFFFF);
    return;
  }
  uint8_t buf[CHUNK_PAYLOAD];
  uint32_t offset = 0;
  while (bleConnected) {
    int n = f.read(buf, sizeof(buf));
    if (n <= 0) break;
    notifyChunk(buf, n, offset);
    offset += n;
  }
  f.close();
  notifyChunk(nullptr, 0, 0xFFFFFFFF);  // EOF
  Serial.printf("[ble] sent %s (%u bytes)\n", path.c_str(), offset);
}

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    std::string value = c->getValue();
    portENTER_CRITICAL(&cmdMux);
    pendingCommand = String(value.c_str());
    portEXIT_CRITICAL(&cmdMux);
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override { bleConnected = true; }
  void onDisconnect(BLEServer *server) override {
    bleConnected = false;
    BLEDevice::startAdvertising();
  }
};

static void setupBLE() {
  BLEDevice::init("RealTalk Recorder");
  BLEDevice::setMTU(247);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);
  BLECharacteristic *control = service->createCharacteristic(
      CONTROL_UUID, BLECharacteristic::PROPERTY_WRITE);
  control->setCallbacks(new ControlCallbacks());

  dataChar = service->createCharacteristic(
      DATA_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  dataChar->addDescriptor(new BLE2902());

  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("[ble] advertising as 'RealTalk Recorder'");
}

// ---------------- 主流程 ----------------
void setup() {
  Serial.begin(115200);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);

  if (!SD.begin(PIN_SD_CS)) {
    Serial.println("[sd] mount failed — 检查接线与卡格式(FAT32)");
  } else {
    Serial.printf("[sd] mounted, %.1f MB free\n",
                  (SD.totalBytes() - SD.usedBytes()) / 1024.0 / 1024.0);
  }
  setupI2S();
  setupBLE();
}

void loop() {
  // 按键消抖切换录音
  static uint32_t lastPress = 0;
  if (digitalRead(PIN_BUTTON) == LOW && millis() - lastPress > 400) {
    lastPress = millis();
    if (recording) stopRecording();
    else startRecording();
  }

  if (recording) pumpAudio();

  // 处理 BLE 命令（录音时拒绝下载，避免 SD 总线争用）
  String command;
  portENTER_CRITICAL(&cmdMux);
  if (pendingCommand.length()) {
    command = pendingCommand;
    pendingCommand = "";
  }
  portEXIT_CRITICAL(&cmdMux);

  if (command.length() && bleConnected && !recording) {
    Serial.printf("[ble] cmd: %s\n", command.c_str());
    if (command == "LIST") {
      sendFileList();
    } else if (command.startsWith("GET:")) {
      sendFile(command.substring(4));
    } else if (command.startsWith("DEL:")) {
      String path = "/" + command.substring(4);
      SD.remove(path);
      sendFileList();
    }
  }
}
