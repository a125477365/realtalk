package com.example.realtalkad

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.Box
import com.example.realtalkad.ui.RealTalkApp
import com.example.realtalkad.ui.theme.RealtalkadTheme

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        permissionLauncher.launch(
            arrayOf(
                Manifest.permission.RECORD_AUDIO,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            ),
        )
        setContent {
            val appearance by model.appearance.collectAsState()
            val dark = when (appearance) {
                "light" -> false
                "dark" -> true
                else -> androidx.compose.foundation.isSystemInDarkTheme()
            }
            androidx.compose.runtime.CompositionLocalProvider(
                com.example.realtalkad.ui.LocalRtDark provides dark
            ) {
                RealtalkadTheme(darkTheme = dark, dynamicColor = false) {
                    Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
                        Box(Modifier.padding(innerPadding)) {
                            RealTalkApp(model)
                        }
                    }
                }
            }
        }
        handleVoiceCommand(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleVoiceCommand(intent)
    }

    /** 处理 Google 助手 / 桌面快捷指令的「开始 / 结束录音」语音命令。 */
    private fun handleVoiceCommand(intent: Intent?) {
        when (intent?.action) {
            ACTION_START_CAPTURE -> model.startCapture()
            ACTION_STOP_CAPTURE -> model.stopCapture()
        }
    }

    companion object {
        const val ACTION_START_CAPTURE = "com.example.realtalkad.action.START_CAPTURE"
        const val ACTION_STOP_CAPTURE = "com.example.realtalkad.action.STOP_CAPTURE"
    }
}
