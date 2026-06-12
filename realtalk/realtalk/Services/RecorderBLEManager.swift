import Combine
import CoreBluetooth
import Foundation

/// RealTalk 录音笔（ESP32）BLE 客户端。
///
/// GATT 协议（与 esp32-recorder 固件一致）：
/// - 服务:   7E400001-B5A3-F393-E0A9-E50E24DCCA9E
/// - 控制特征(写): 7E400002-…  命令: "LIST" / "GET:<文件名>"
/// - 数据特征(通知): 7E400003-…
///   LIST 响应: 每个文件一条 JSON {"n":"REC0001.WAV","s":123456}，结束 {"end":true}
///   GET  响应: 二进制块 [4字节小端偏移][数据]，偏移 0xFFFFFFFF 表示传输完成
@MainActor
final class RecorderBLEManager: NSObject, ObservableObject {
    struct RecorderFile: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let sizeBytes: Int
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        case ready
        case listing
        case downloading(name: String, progress: Double)
        case failed(String)
    }

    static let serviceUUID = CBUUID(string: "7E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let controlUUID = CBUUID(string: "7E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let dataUUID = CBUUID(string: "7E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var files: [RecorderFile] = []
    @Published private(set) var deviceName: String?

    var onFileDownloaded: ((URL) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var downloadHandle: FileHandle?
    private var downloadURL: URL?
    private var downloadName = ""
    private var downloadExpected = 0
    private var downloadReceived = 0

    func startScan() {
        files = []
        phase = .scanning
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func disconnect() {
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
        controlCharacteristic = nil
        phase = .idle
    }

    func requestFileList() {
        files = []
        phase = .listing
        sendCommand("LIST")
    }

    func download(file: RecorderFile) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        downloadURL = url
        downloadName = file.name
        downloadExpected = file.sizeBytes
        downloadReceived = 0
        downloadHandle = try? FileHandle(forWritingTo: url)
        phase = .downloading(name: file.name, progress: 0)
        sendCommand("GET:\(file.name)")
    }

    private func sendCommand(_ command: String) {
        guard let peripheral, let controlCharacteristic else {
            phase = .failed("录音笔未连接")
            return
        }
        peripheral.writeValue(Data(command.utf8), for: controlCharacteristic, type: .withResponse)
    }

    private func handleListPayload(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["end"] as? Bool == true {
            phase = .ready
            return
        }
        if let name = object["n"] as? String, let size = object["s"] as? Int {
            files.append(RecorderFile(name: name, sizeBytes: size))
        }
    }

    private func handleDataChunk(_ data: Data) {
        guard data.count >= 4 else { return }
        let offset = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if offset == 0xFFFF_FFFF {
            try? downloadHandle?.close()
            downloadHandle = nil
            phase = .ready
            if let downloadURL {
                onFileDownloaded?(downloadURL)
            }
            return
        }
        let payload = data.dropFirst(4)
        downloadHandle?.write(payload)
        downloadReceived += payload.count
        let progress = downloadExpected > 0 ? min(1, Double(downloadReceived) / Double(downloadExpected)) : 0
        phase = .downloading(name: downloadName, progress: progress)
    }
}

extension RecorderBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                central.scanForPeripherals(withServices: [Self.serviceUUID])
            case .unauthorized:
                self.phase = .failed("请在系统设置中允许 RealTalk 使用蓝牙")
            case .poweredOff:
                self.phase = .failed("请先打开蓝牙")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            self.peripheral = peripheral
            self.deviceName = peripheral.name ?? "RealTalk 录音笔"
            self.phase = .connecting
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.phase = .failed(error?.localizedDescription ?? "连接失败")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.controlCharacteristic = nil
            if case .failed = self.phase {} else {
                self.phase = .idle
            }
        }
    }
}

extension RecorderBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            peripheral.discoverCharacteristics([Self.controlUUID, Self.dataUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.controlUUID {
                    self.controlCharacteristic = characteristic
                }
                if characteristic.uuid == Self.dataUUID {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            if self.controlCharacteristic != nil {
                self.phase = .ready
                self.requestFileList()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.dataUUID, let data = characteristic.value else { return }
        Task { @MainActor in
            if case .downloading = self.phase {
                self.handleDataChunk(data)
            } else {
                self.handleListPayload(data)
            }
        }
    }
}
