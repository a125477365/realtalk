package com.example.realtalkad.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel

/** 深色语音界面底色（与 iOS 一致）。 */
private val VoiceBg = Color(0xFF12141A)

/**
 * 会呼吸的圆形麦克风。关键：外层【固定 140dp】占位，脉冲只在内部涨落，
 * 绝不改变自身尺寸——否则整行高度随音量变化，会把上方字幕一起顶得上下抖动。
 */
@Composable
fun PulsingMic(level: Float, paused: Boolean, ringColor: Color = RT.Accent, onClick: () -> Unit) {
    val ring by animateFloatAsState(96f + 34f * level.coerceIn(0f, 1f), label = "ring")
    Box(Modifier.size(140.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(ring.dp).clip(CircleShape)
                .border(2.dp, ringColor.copy(alpha = 0.35f + 0.4f * level.coerceIn(0f, 1f)), CircleShape)
        )
        Box(
            Modifier.size(84.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.10f))
                .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
                .clickable { onClick() },
            contentAlignment = Alignment.Center,
        ) {
            Text(if (paused) "🔇" else "🎤", fontSize = 30.sp)
        }
    }
}

/** 深色语音界面的「+」按钮（音色/语速入口）：固定大小，不随音量跳动。 */
@Composable
fun DarkPlusButton(onClick: () -> Unit) {
    Box(
        Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.10f))
            .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text("＋", color = Color.White.copy(alpha = 0.9f), fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 音色 / 语速底部面板（与设置页、各对话界面同一份状态与通道）。 */
@kotlin.OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun VoiceSpeedSheet(model: AppViewModel, onDismiss: () -> Unit) {
    val voices by model.ttsVoices.collectAsState()
    val current by model.ttsCurrentVoice.collectAsState()
    LaunchedEffect(Unit) { model.loadTtsVoices() }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("音色", fontWeight = FontWeight.SemiBold, color = RT.TextPrimary)
            Spacer(Modifier.height(8.dp))
            // 换行平铺：所有音色一眼看全，不用左右滑
            val rows = voices.chunked(3)
            rows.forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { v ->
                        val sel = v == current
                        Box(
                            Modifier.weight(1f).clip(RoundedCornerShape(50))
                                .background(if (sel) RT.Accent else RT.Background)
                                .border(1.dp, if (sel) Color.Transparent else RT.Hairline, RoundedCornerShape(50))
                                .clickable { model.changeTutorVoice(v) }
                                .padding(vertical = 9.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(v, color = if (sel) Color.White else RT.TextPrimary, fontSize = 12.sp,
                                fontWeight = FontWeight.Medium, maxLines = 1)
                        }
                    }
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
                Spacer(Modifier.height(8.dp))
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

/**
 * 实时翻译全屏：说中文→听到英文，说英文→听到中文（边说边出，服务端自动分句）。
 * 退出时把本次全部原文交给后台生成英文场景（可能切分成多个），回主界面即可练。
 */
@kotlin.OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun TranslateScreen(model: AppViewModel) {
    val items by model.homeItems.collectAsState()
    val connected by model.homeConnected.collectAsState()
    val status by model.homeStatus.collectAsState()
    val userLevel by model.homeUserLevel.collectAsState()
    val aiLevel by model.homeAiLevel.collectAsState()
    val aiSpeaking by model.homeAiSpeaking.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    var showVoice by remember { mutableStateOf(false) }
    var paused by remember { mutableStateOf(false) }
    val level = if (aiSpeaking) aiLevel else userLevel
    val listState = rememberLazyListState()
    val rows = items.filter { it.kind == AppViewModel.HomeKind.TRANSLATE }

    LaunchedEffect(Unit) { model.startTutor() }
    LaunchedEffect(rows.size) { if (rows.isNotEmpty()) listState.animateScrollToItem(rows.size - 1) }

    Column(Modifier.fillMaxSize().background(VoiceBg)) {
        // 顶栏：连接指示 + 退出
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 18.dp).padding(top = 44.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.10f))
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(7.dp).clip(CircleShape)
                    .background(if (connected) RT.Success else Color.Red))
                Spacer(Modifier.width(5.dp))
                Text("实时翻译", color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp)
            }
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
                    .clickable { model.exitTranslate() },
                contentAlignment = Alignment.Center,
            ) { Text("✕", color = Color.White.copy(alpha = 0.9f), fontSize = 15.sp) }
        }

        Text(
            if (!connected) "连接中…" else status.ifBlank { "直接开口说话，中英自动互译" },
            color = Color.White.copy(alpha = 0.7f), fontSize = (15 * fontScale).sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )

        // 成对字幕：原文 + 蓝色译文（占满中间，自动滚到最新）
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            items(rows, key = { it.id }) { item -> DarkTranslateRow(model, item, fontScale) }
        }

        // 「+」音色语速 + 中间大麦克风；整行固定高度，不随音量顶动字幕
        Row(
            Modifier.fillMaxWidth().height(140.dp).padding(bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            DarkPlusButton { showVoice = true }
            Spacer(Modifier.width(22.dp))
            PulsingMic(level, paused) { paused = model.freeStream.togglePause() }
            Spacer(Modifier.width(22.dp))
            Spacer(Modifier.size(48.dp))   // 右侧等宽占位，保证麦克风居中
        }
        Text(
            "翻译内容会自动整理成英文场景，可回主界面练习",
            color = Color.White.copy(alpha = 0.4f), fontSize = 11.sp,
            modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }

    if (showVoice) VoiceSpeedSheet(model) { showVoice = false }
}

/** 深色成对字幕：原文 + 蓝色译文；左右只看【第一个有效字】。 */
@Composable
private fun DarkTranslateRow(model: AppViewModel, item: AppViewModel.HomeChatItem, fontScale: Float) {
    val cn = run {
        var r = false
        for (ch in item.text) {
            if (ch in '一'..'鿿') { r = true; break }
            if (ch in 'a'..'z' || ch in 'A'..'Z') { r = false; break }
        }
        r
    }
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = if (cn) Alignment.End else Alignment.Start,
    ) {
        Text(item.text, color = Color.White, fontSize = (17 * fontScale).sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(5.dp))
        if (item.translating || item.translation.isBlank()) {
            Text("正在翻译…", color = Color.White.copy(alpha = 0.6f), fontSize = (13 * fontScale).sp)
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!cn) {
                    Text("🔊", fontSize = 14.sp,
                        modifier = Modifier.clickable { model.speakText(item.translation) }.padding(end = 8.dp))
                }
                Text(item.translation, color = Color(0xFF5CA8FF),
                    fontSize = (16 * fontScale).sp, fontWeight = FontWeight.SemiBold)
                if (cn) {
                    Text("🔊", fontSize = 14.sp,
                        modifier = Modifier.clickable { model.speakText(item.translation) }.padding(start = 8.dp))
                }
            }
        }
    }
}

/**
 * 沉浸式场景练习：与实时翻译同款深色语音界面 + 圆形麦克风开关。
 * 严格按剧本：中文提示下一句、AI 台词打码点开、说错内联纠正。
 */
@kotlin.OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun ImmersivePracticeScreen(model: AppViewModel) {
    val items by model.homeItems.collectAsState()
    val sceneName by model.homeSceneName.collectAsState()
    val status by model.homeStatus.collectAsState()
    val userLevel by model.homeUserLevel.collectAsState()
    val aiLevel by model.homeAiLevel.collectAsState()
    val aiSpeaking by model.homeAiSpeaking.collectAsState()
    val rp by model.roleplayState.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    var showVoice by remember { mutableStateOf(false) }
    var paused by remember { mutableStateOf(false) }
    val level = if (aiSpeaking) aiLevel else userLevel
    val listState = rememberLazyListState()
    val recent = items.takeLast(5)

    LaunchedEffect(items.size) { if (recent.isNotEmpty()) listState.animateScrollToItem(recent.size - 1) }

    Column(Modifier.fillMaxSize().background(VoiceBg)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 18.dp).padding(top = 44.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
                    .clickable { model.exitScenePractice() },
                contentAlignment = Alignment.Center,
            ) { Text("‹", color = Color.White.copy(alpha = 0.9f), fontSize = 20.sp) }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(sceneName ?: "场景练习", color = Color.White,
                    fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                Text("沉浸式 · 严格按剧本", color = Color.White.copy(alpha = 0.55f), fontSize = 11.sp)
            }
            rp?.let {
                Text("${it.progress}/${it.total}", color = Color.White.copy(alpha = 0.9f),
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(Color.White.copy(alpha = 0.12f))
                        .padding(horizontal = 10.dp, vertical = 6.dp))
            }
        }

        Text(
            when {
                aiSpeaking -> "对方正在说…"
                paused -> "麦克风已关闭"
                status.isNotBlank() -> status
                else -> "按提示开口说英语"
            },
            color = Color.White.copy(alpha = 0.7f), fontSize = (15 * fontScale).sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(recent, key = { it.id }) { item ->
                when (item.kind) {
                    AppViewModel.HomeKind.HINT -> Column(Modifier.fillMaxWidth()) {
                        Text(item.text, color = Color(0xFF5CA8FF),
                            fontSize = (16 * fontScale).sp, fontWeight = FontWeight.SemiBold)
                        if (item.translation.isNotBlank()) {
                            Spacer(Modifier.height(4.dp))
                            if (item.masked) {
                                Text("🙈 英文答案已隐藏 · 点击显示",
                                    color = Color.White.copy(alpha = 0.55f), fontSize = 11.sp,
                                    modifier = Modifier.clickable { model.toggleItemMasked(item.id) })
                            } else {
                                Text(item.translation, color = Color.White.copy(alpha = 0.85f),
                                    fontSize = (14 * fontScale).sp,
                                    modifier = Modifier.clickable { model.toggleItemMasked(item.id) })
                            }
                        }
                    }
                    AppViewModel.HomeKind.AI -> Box(Modifier.fillMaxWidth()
                        .clickable { model.toggleItemMasked(item.id) }) {
                        if (item.masked) {
                            Text("🙈 先听 · 点击显示英文",
                                color = Color.White.copy(alpha = 0.55f), fontSize = 11.sp)
                        } else {
                            Text(item.text, color = Color.White, fontSize = (16 * fontScale).sp)
                        }
                    }
                    AppViewModel.HomeKind.USER -> Text(
                        item.text, color = Color.White.copy(alpha = 0.75f),
                        fontSize = (15 * fontScale).sp,
                        modifier = Modifier.fillMaxWidth(),
                        textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    )
                    AppViewModel.HomeKind.GUIDANCE -> Row(Modifier.fillMaxWidth()) {
                        Text("💡 ", fontSize = 12.sp)
                        Text(item.text, color = Color(0xFFFFB067), fontSize = (14 * fontScale).sp)
                    }
                    else -> {}
                }
            }
        }

        Row(
            Modifier.fillMaxWidth().height(140.dp).padding(bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            DarkPlusButton { showVoice = true }
            Spacer(Modifier.width(22.dp))
            PulsingMic(level, paused, if (aiSpeaking) RT.Success else RT.Accent) {
                paused = model.stream.togglePause()
            }
            Spacer(Modifier.width(22.dp))
            Spacer(Modifier.size(48.dp))
        }
        Text(
            "严格按真实对话练 · 说错会当场纠正",
            color = Color.White.copy(alpha = 0.4f), fontSize = 11.sp,
            modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }

    if (showVoice) VoiceSpeedSheet(model) { showVoice = false }
}
