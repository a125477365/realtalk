package com.example.realtalkad.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/**
 * RealTalk 录音笔（ESP32）BLE 客户端。协议与 iOS RecorderBLEManager / esp32-recorder 固件一致：
 * 控制特征写入 "LIST" / "GET:<文件名>"；数据特征通知返回
 * LIST: 每文件一条 JSON {"n":名称,"s":大小}，结束 {"end":true}
 * GET : [4字节小端偏移][数据]，偏移 0xFFFFFFFF 表示结束
 */
@SuppressLint("MissingPermission") // 权限在 UI 层动态申请后才会调用
class RecorderBleClient(private val context: Context) {

    data class RecorderFile(val name: String, val sizeBytes: Long)

    sealed class Phase {
        data object Idle : Phase()
        data object Scanning : Phase()
        data object Connecting : Phase()
        data object Ready : Phase()
        data class Downloading(val name: String, val progress: Float) : Phase()
        data class Failed(val reason: String) : Phase()
    }

    val phase = MutableStateFlow<Phase>(Phase.Idle)
    val files = MutableStateFlow<List<RecorderFile>>(emptyList())
    var onFileDownloaded: ((File) -> Unit)? = null

    private val adapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    private var gatt: BluetoothGatt? = null
    private var control: BluetoothGattCharacteristic? = null
    private var downloadFile: File? = null
    private var downloadStream: FileOutputStream? = null
    private var downloadExpected = 0L
    private var downloadReceived = 0L
    private var downloadName = ""

    fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: run {
            phase.value = Phase.Failed("请先打开蓝牙")
            return
        }
        files.value = emptyList()
        phase.value = Phase.Scanning
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    fun disconnect() {
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        gatt?.close()
        gatt = null
        control = null
        phase.value = Phase.Idle
    }

    fun requestFileList() {
        files.value = emptyList()
        send("LIST")
    }

    fun download(file: RecorderFile) {
        val target = File(context.cacheDir, file.name)
        downloadFile = target
        downloadStream = FileOutputStream(target)
        downloadExpected = file.sizeBytes
        downloadReceived = 0
        downloadName = file.name
        phase.value = Phase.Downloading(file.name, 0f)
        send("GET:${file.name}")
    }

    @Suppress("DEPRECATION")
    private fun send(command: String) {
        val g = gatt ?: return
        val c = control ?: return
        // 兼容 minSdk 29：API 33 的三参 writeCharacteristic 在低版本不可用
        c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        c.value = command.toByteArray()
        g.writeCharacteristic(c)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            adapter?.bluetoothLeScanner?.stopScan(this)
            phase.value = Phase.Connecting
            gatt = result.device.connectGatt(context, false, gattCallback)
        }

        override fun onScanFailed(errorCode: Int) {
            phase.value = Phase.Failed("扫描失败（$errorCode）")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestMtu(247)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                phase.value = Phase.Idle
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val service = g.getService(SERVICE_UUID) ?: run {
                phase.value = Phase.Failed("不是 RealTalk 录音笔")
                return
            }
            control = service.getCharacteristic(CONTROL_UUID)
            val data = service.getCharacteristic(DATA_UUID) ?: return
            g.setCharacteristicNotification(data, true)
            data.getDescriptor(CCCD_UUID)?.let { descriptor ->
                @Suppress("DEPRECATION")
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                g.writeDescriptor(descriptor)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            phase.value = Phase.Ready
            requestFileList()
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid != DATA_UUID) return
            if (phase.value is Phase.Downloading) handleChunk(value) else handleListPayload(value)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            // API 33 以下走这个回调
            val value = characteristic.value ?: return
            if (characteristic.uuid != DATA_UUID) return
            if (phase.value is Phase.Downloading) handleChunk(value) else handleListPayload(value)
        }
    }

    private fun handleListPayload(value: ByteArray) {
        runCatching {
            val obj = JSONObject(String(value))
            if (obj.optBoolean("end")) {
                phase.value = Phase.Ready
            } else {
                val name = obj.optString("n")
                if (name.isNotEmpty()) {
                    files.value = files.value + RecorderFile(name, obj.optLong("s"))
                }
            }
        }
    }

    private fun handleChunk(value: ByteArray) {
        if (value.size < 4) return
        val offset = ByteBuffer.wrap(value, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
        if (offset == 0xFFFFFFFFL) {
            downloadStream?.close()
            downloadStream = null
            phase.value = Phase.Ready
            downloadFile?.let { onFileDownloaded?.invoke(it) }
            return
        }
        downloadStream?.write(value, 4, value.size - 4)
        downloadReceived += value.size - 4
        val progress = if (downloadExpected > 0) (downloadReceived.toFloat() / downloadExpected).coerceAtMost(1f) else 0f
        phase.value = Phase.Downloading(downloadName, progress)
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("7E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        val CONTROL_UUID: UUID = UUID.fromString("7E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        val DATA_UUID: UUID = UUID.fromString("7E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    }
}
