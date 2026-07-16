package com.example.realtalkad.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.data.RefineItem
import kotlinx.coroutines.delay

/**
 * 常规对话主界面（新首页）：白底聊天流，自由聊天 / 自由场景 / 严格场景全在这一个界面。
 * AI 卡片（朗读/译/打码）、用户气泡（发音分/语速→详细指导浮层）、指导/提示卡直接插在字幕流里；
 * 顶部：重听 / 场景入口 + 当前用户；底部：采集 + 居中点击说话 + 键盘 / 私教。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatHomeScreen(model: AppViewModel) {
    val items by model.homeItems.collectAsState()
    val status by model.homeStatus.collectAsState()
    val working by model.homeWorking.collectAsState()
    val connected by model.homeConnected.collectAsState()
    val sceneName by model.homeSceneName.collectAsState()
    val sceneStrict by model.homeSceneStrict.collectAsState()
    val showTutor by model.showTutor.collectAsState()
    val tutorMode by model.tutorMode.collectAsState()
    val tutorImmersive by model.tutorImmersive.collectAsState()
    val showPicker by model.showScenePicker.collectAsState()
    val manualRecording by model.homeManualRecording.collectAsState()
    val isRecording by model.isRecording.collectAsState()
    val user by model.user.collectAsState()
    val fontScale by model.fontScale.collectAsState()

    var keyboardMode by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var showAccount by remember { mutableStateOf(false) }
    var showAttach by remember { mutableStateOf(false) }
    var guidanceFor by remember { mutableStateOf<AppViewModel.HomeChatItem?>(null) }
    val listState = rememberLazyListState()

    LaunchedEffect(Unit) { if (!connected && !showTutor) model.startHomeChat() }
    LaunchedEffect(items.size) { if (items.isNotEmpty()) listState.animateScrollToItem(items.size - 1) }

    Box(Modifier.fillMaxSize().background(RT.Background)) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏（左：账户；右：AI 语音开关 + 私教电话）
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 40.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val displayName = user?.displayName?.trim().takeUnless { it.isNullOrEmpty() } ?: "微信用户"
                Row(
                    Modifier.background(RT.Surface, RoundedCornerShape(50)).clickable { showAccount = true }
                        .padding(start = 4.dp, end = 11.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    val avatarUrl = user?.avatarUrl
                    if (!avatarUrl.isNullOrBlank()) {
                        // 微信授权登录带回的头像（headimgurl）
                        coil.compose.AsyncImage(
                            model = avatarUrl,
                            contentDescription = "用户头像",
                            modifier = Modifier.size(34.dp).clip(CircleShape),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        )
                    } else {
                        Box(Modifier.size(34.dp).background(RT.BrandBrush, CircleShape), contentAlignment = Alignment.Center) {
                            Text(displayName.take(1), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    Text(displayName, fontSize = (14 * fontScale).sp, fontWeight = FontWeight.SemiBold,
                        color = RT.TextPrimary, maxLines = 1)
                }
                Spacer(Modifier.weight(1f))
                // AI 语音自动播放开关：开＝彩色喇叭，关＝灰色关闭喇叭（按下立即可见状态变化）
                val autoPlay by model.autoPlayAI.collectAsState()
                Box(
                    Modifier.size(42.dp).background(RT.Surface, CircleShape)
                        .clickable { model.toggleAutoPlayAI() },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (autoPlay) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Filled.VolumeOff,
                        contentDescription = if (autoPlay) "关闭 AI 语音自动播放" else "开启 AI 语音自动播放",
                        tint = if (autoPlay) RT.Accent else RT.TextSecondary,
                        modifier = Modifier.size(21.dp),
                    )
                }
                Spacer(Modifier.width(8.dp))
                // 私教电话：进入全屏私教通话
                Box(
                    Modifier.size(42.dp).background(RT.Surface, CircleShape)
                        .clickable {
                            model.tutorMode.value = "chat"
                            model.showTutor.value = true
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Call, contentDescription = "私教通话", tint = RT.Success, modifier = Modifier.size(20.dp))
                }
            }

            if (isRecording || showTutor || status.isNotBlank()) {
                val statusText = when {
                    isRecording -> "正在采集真实对话…"
                    showTutor && tutorMode == "translate" -> "实时翻译 · 共用字幕界面"
                    showTutor && tutorImmersive -> "私教 · 沉浸聆听中"
                    showTutor -> "私教 · 点击说话"
                    status.isNotBlank() -> status
                    connected -> "已连接"
                    else -> "正在连接"
                }
                Row(
                    Modifier.align(Alignment.CenterHorizontally).background(RT.Surface, RoundedCornerShape(50))
                        .padding(horizontal = 12.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(Modifier.size(6.dp).background(if (isRecording) Color.Red else if (connected) RT.Success else RT.TextSecondary, CircleShape))
                    Text(statusText, fontSize = (11 * fontScale).sp, fontWeight = FontWeight.Medium,
                        color = if (isRecording) Color.Red else RT.TextSecondary, maxLines = 1)
                }
            }

            // 字幕流
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (items.isEmpty()) {
                    items(listOf(0), key = { "empty" }) {
                        Text(
                            if (status.isBlank()) "直接开口说英语，或点下方按钮选场景练习" else status,
                            fontSize = (13 * fontScale).sp, color = RT.TextSecondary,
                            modifier = Modifier.fillMaxWidth().padding(top = 80.dp),
                        )
                    }
                }
                items(items, key = { it.id }) { item ->
                    when (item.kind) {
                        AppViewModel.HomeKind.AI -> AiCard(model, item, fontScale)
                        AppViewModel.HomeKind.USER -> UserBubble(model, item, fontScale) { guidanceFor = item }
                        AppViewModel.HomeKind.GUIDANCE -> GuidanceCard(item, fontScale)
                        AppViewModel.HomeKind.HINT -> HintCard(item, fontScale)
                    }
                }
            }

            // 场景条（名字 + 严格/自由 + 退出）
            sceneName?.let { name ->
                Row(
                    Modifier.fillMaxWidth().background(RT.Surface).padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Movie, contentDescription = null, tint = RT.TextPrimary, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(name, fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (sceneStrict) "严格按剧本" else "自由发挥",
                        color = Color.White, fontSize = (11 * fontScale).sp,
                        modifier = Modifier
                            .background(if (sceneStrict) Color(0xFFF59F00) else RT.Success, RoundedCornerShape(50))
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                    Spacer(Modifier.weight(1f))
                    Text("✕", color = RT.TextSecondary, fontSize = 15.sp,
                        modifier = Modifier.clickable { model.exitHomeScene() }.padding(8.dp))
                }
            }

            // 输入区：等宽左右控制区保证“点击说话”严格居中；采集按钮移到同一行最左。
            if (keyboardMode) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = draft, onValueChange = { draft = it },
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("输入英文或中文…") },
                        keyboardOptions = KeyboardOptions.Default,
                        maxLines = 4,
                    )
                    Box(
                        Modifier.size(46.dp).background(RT.Accent, CircleShape)
                            .clickable { model.sendHomeText(draft); draft = "" },
                        contentAlignment = Alignment.Center,
                    ) { Text("➤", color = Color.White, fontSize = 18.sp) }
                    Text("🎙", fontSize = 20.sp, modifier = Modifier.clickable { keyboardMode = false }.padding(6.dp))
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp).padding(top = 4.dp, bottom = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    // 左：+（附加功能上拉面板）；采集中变成红色停止按钮，一眼可见正在采集
                    Box(
                        Modifier.size(48.dp)
                            .background(if (isRecording) Color.Red else RT.Surface, CircleShape)
                            .border(1.dp, if (isRecording) Color.Transparent else RT.Hairline, CircleShape)
                            .clickable {
                                if (isRecording) model.toggleRecording() else showAttach = true
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            if (isRecording) Icons.Filled.Stop else Icons.Filled.Add,
                            contentDescription = if (isRecording) "停止采集并生成场景" else "更多功能",
                            tint = if (isRecording) Color.White else RT.TextPrimary,
                        )
                    }
                    // 说话按钮：描边样式（与背景区分即可）；录音中红色实心
                    Box(
                        Modifier.weight(1f).height(50.dp)
                            .background(if (manualRecording) Color.Red else RT.Surface, RoundedCornerShape(25.dp))
                            .border(1.5.dp, if (manualRecording) Color.Transparent else RT.Hairline, RoundedCornerShape(25.dp))
                            .clickable(enabled = !working) { model.toggleHomeTalk() },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (working) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                CircularProgressIndicator(color = RT.TextSecondary, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                                Text("请稍候…", color = RT.TextSecondary, fontWeight = FontWeight.SemiBold, fontSize = (16 * fontScale).sp)
                            }
                        } else {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                Icon(
                                    if (manualRecording) Icons.Filled.Stop else Icons.Filled.Mic,
                                    contentDescription = null,
                                    tint = if (manualRecording) Color.White else RT.Accent,
                                    modifier = Modifier.size(19.dp),
                                )
                                Text(
                                    if (manualRecording) "说完了，发送" else "点击说话",
                                    color = if (manualRecording) Color.White else RT.TextPrimary,
                                    fontWeight = FontWeight.SemiBold, fontSize = (16 * fontScale).sp,
                                )
                            }
                        }
                    }
                    Box(
                        Modifier.size(48.dp).background(RT.Surface, CircleShape)
                            .border(1.dp, RT.Hairline, CircleShape)
                            .clickable { keyboardMode = true },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Filled.Keyboard, contentDescription = "键盘输入", tint = RT.TextPrimary) }
                }
            }
        }

        if (showPicker) ScenarioPickerOverlay(model)
        // 私教通话（全屏，Claude 语音式界面）
        if (showTutor) TutorCallScreen(model)
        // 学习提醒「私教来电」
        val incomingReminder by model.incomingReminder.collectAsState()
        incomingReminder?.let { ReminderCallScreen(model, it) }
    }

    if (showAttach) {
        ModalBottomSheet(onDismissRequest = { showAttach = false }) {
            AttachmentSheet(model, isRecording) { showAttach = false }
        }
    }
    if (showAccount) {
        ModalBottomSheet(onDismissRequest = { showAccount = false }) { AccountSheet(model) }
    }
    guidanceFor?.let { item ->
        ModalBottomSheet(onDismissRequest = { guidanceFor = null }) {
            GuidanceDetailSheet(model, item, fontScale)
        }
    }
    // 来电中选「现在练习」→ 打开场景选择流程
    val reminderScene by model.reminderPracticeScene.collectAsState()
    LaunchedEffect(reminderScene) {
        if (reminderScene != null) model.showScenePicker.value = true
    }
}

/** AI 大卡片：文本默认打码（点击文字显示）+ 波形重播/译 按钮 + 中文翻译（缺失时按需翻译）。 */
@Composable
private fun AiCard(model: AppViewModel, item: AppViewModel.HomeChatItem, fontScale: Float) {
    Column(
        Modifier.fillMaxWidth()
            .background(RT.Surface, RoundedCornerShape(16.dp))
            .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            item.text, fontSize = (16 * fontScale).sp, color = RT.TextPrimary,
            modifier = (if (item.masked) Modifier.blur(7.dp) else Modifier)
                .clickable { model.toggleItemMasked(item.id) },
        )
        if (item.masked) {
            Text("🎧 先听后看 · 点击文字显示", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            // 波形＝重新播放这一句（与顶栏喇叭「自动播放开关」含义区分开）
            Icon(
                Icons.Filled.GraphicEq, contentDescription = "重新播放这一句", tint = RT.Accent,
                modifier = Modifier.size(20.dp).clickable { model.speakText(item.text, item.tone) },
            )
            Text(
                "译",
                fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                color = if (item.showTranslation) Color.White else RT.Accent,
                modifier = Modifier
                    .background(if (item.showTranslation) RT.Accent else Color.Transparent, RoundedCornerShape(6.dp))
                    .clickable { model.toggleItemTranslation(item.id) }
                    .padding(horizontal = 7.dp, vertical = 2.dp),
            )
        }
        // 翻译不受打码限制：打码练的是「先听英文」，中文提示不算看答案
        if (item.showTranslation) {
            if (item.translating) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                    Text("正在翻译…", fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
                }
            } else if (item.translation.isNotBlank()) {
                HorizontalDivider(color = RT.Hairline)
                Text(item.translation, fontSize = (14 * fontScale).sp, color = RT.TextSecondary)
            }
        }
    }
}

/** 用户气泡 + 发音/语速指导行（点开详细指导浮层）。 */
@Composable
private fun UserBubble(model: AppViewModel, item: AppViewModel.HomeChatItem, fontScale: Float, onDetail: () -> Unit) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
        Text(
            item.text, fontSize = (16 * fontScale).sp, color = RT.TextPrimary,
            modifier = Modifier
                .background(Color(0xFFEAF3FE), RoundedCornerShape(16.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        )
        // 发音指导入口常驻：没有词级数据（云端 ASR/实时通道）也能进「语境润色」
        Row(
            Modifier.clickable { onDetail() }.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (item.words.isNotEmpty()) {
                val score = (item.words.map { it.probability }.average() * 100).toInt()
                Text("发音 $score", fontSize = (12 * fontScale).sp, fontWeight = FontWeight.Medium,
                    color = if (score >= 80) RT.Success else if (score >= 60) Color(0xFFF59F00) else Color.Red)
            } else {
                Text("发音指导", fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
            }
            if (item.wpm > 0) Text("语速 ${item.wpm}词/分", fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
            Text("详情 ›", fontSize = (12 * fontScale).sp, color = RT.Accent)
        }
    }
}

/** 指导对话卡（评语/纠正/完成总结）——插在字幕流里，不再有专门指导界面。 */
@Composable
private fun GuidanceCard(item: AppViewModel.HomeChatItem, fontScale: Float) {
    Column(
        Modifier.fillMaxWidth().background(Color(0x1AF59F00), RoundedCornerShape(14.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("💡 老师指导", fontSize = (12 * fontScale).sp, fontWeight = FontWeight.SemiBold, color = Color(0xFFB47B00))
        Text(item.text, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
    }
}

/** 中文提示卡（严格场景：下一句该说什么）。 */
@Composable
private fun HintCard(item: AppViewModel.HomeChatItem, fontScale: Float) {
    Column(
        Modifier.fillMaxWidth().background(Color(0x142997F5), RoundedCornerShape(14.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(item.text, fontSize = (14 * fontScale).sp, fontWeight = FontWeight.Medium, color = RT.Accent)
        if (item.translation.isNotBlank()) {
            Text(item.translation, fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
        }
    }
}

/** 详细指导浮层：发音逐词标色 + 评分/语速 + 语境润色三风格。 */
@Composable
fun GuidanceDetailSheet(model: AppViewModel, item: AppViewModel.HomeChatItem, fontScale: Float) {
    val refinements by produceState<List<RefineItem>?>(initialValue = null, item.text) {
        value = runCatching { model.refineText(item.text) }.getOrNull()
    }
    var style by remember { mutableStateOf("地道美式") }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("发音逐词分析", fontWeight = FontWeight.Bold, fontSize = (17 * fontScale).sp, color = RT.TextPrimary)
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            LegendDot("待提高", Color.Red, fontScale); LegendDot("小瑕疵", Color(0xFFF59F00), fontScale); LegendDot("很完美", RT.TextPrimary, fontScale)
        }
        // 逐词标色（FlowRow 简化为自动换行文本组合）
        androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            item.words.forEach { w ->
                Text(
                    w.word, fontSize = (17 * fontScale).sp, fontWeight = FontWeight.Medium,
                    color = if (w.probability < 0.6) Color.Red else if (w.probability < 0.85) Color(0xFFF59F00) else RT.TextPrimary,
                )
            }
        }
        val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            Text("🔊 AI 朗读", color = RT.Accent, fontSize = (13 * fontScale).sp,
                modifier = Modifier.clickable { model.speakText(item.text) })
            Text("📋 复制", color = RT.Accent, fontSize = (13 * fontScale).sp,
                modifier = Modifier.clickable { clipboard.setText(androidx.compose.ui.text.AnnotatedString(item.text)) })
        }
        HorizontalDivider(color = RT.Hairline)

        val overall = if (item.words.isEmpty()) 0 else (item.words.map { it.probability }.average() * 100).toInt()
        Text("评分建议", fontWeight = FontWeight.Bold, fontSize = (16 * fontScale).sp, color = RT.TextPrimary)
        Text(
            buildString {
                append("发音分 $overall")
                if (item.wpm > 0) append(" · 语速 ${item.wpm} 词/分")
                append("。")
                if (overall >= 85) append("发音纯正，继续保持。")
                else if (overall >= 65) append("总体不错，标红的词再跟读几遍。")
                else if (overall > 0) append("多听 AI 朗读，逐词跟读标红部分。")
                if (item.wpm in 1..89) append("语速偏慢，说快一点更自然。")
                else if (item.wpm > 200) append("语速偏快，适当放慢更清晰。")
            },
            fontSize = (13 * fontScale).sp, color = RT.TextSecondary,
        )
        HorizontalDivider(color = RT.Hairline)

        Text("语境润色", fontWeight = FontWeight.Bold, fontSize = (16 * fontScale).sp, color = RT.TextPrimary)
        when {
            refinements == null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Text("正在润色…", fontSize = (13 * fontScale).sp, color = RT.TextSecondary)
            }
            refinements!!.isEmpty() -> Text("润色暂不可用", fontSize = (13 * fontScale).sp, color = RT.TextSecondary)
            else -> {
                Row(Modifier.fillMaxWidth()) {
                    refinements!!.forEach { r ->
                        Text(
                            r.style,
                            fontSize = (14 * fontScale).sp,
                            fontWeight = if (style == r.style) FontWeight.SemiBold else FontWeight.Normal,
                            color = if (style == r.style) RT.Success else RT.TextSecondary,
                            modifier = Modifier.weight(1f).clickable { style = r.style }.padding(vertical = 6.dp),
                        )
                    }
                }
                refinements!!.firstOrNull { it.style == style }?.let { cur ->
                    Text("优化后的句子：${cur.text}", fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Text("🔊 AI 朗读", color = RT.Accent, fontSize = (13 * fontScale).sp,
                            modifier = Modifier.clickable { model.speakText(cur.text) })
                        Text("📋 复制", color = RT.Accent, fontSize = (13 * fontScale).sp,
                            modifier = Modifier.clickable { clipboard.setText(androidx.compose.ui.text.AnnotatedString(cur.text)) })
                    }
                }
            }
        }
        Text("内容由 AI 生成", fontSize = 11.sp, color = RT.TextSecondary, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun LegendDot(label: String, color: Color, fontScale: Float) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(7.dp).background(color, CircleShape))
        Text(label, fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
    }
}

/**
 * 私教通话（顶栏电话按钮进入，全屏）：Claude 语音式界面——
 * 深色底 + 底部光晕随说话音量呼吸、老师头像动嘴、随声音变化的麦克风、
 * 底部一排：音色胶囊（中）+ 退出 X（右）。注重自由对话，不放多余选项。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TutorCallScreen(model: AppViewModel) {
    val connected by model.homeConnected.collectAsState()
    val working by model.homeWorking.collectAsState()
    val aiSpeaking by model.homeAiSpeaking.collectAsState()
    val aiLevel by model.homeAiLevel.collectAsState()
    val userLevel by model.homeUserLevel.collectAsState()
    val mode by model.tutorMode.collectAsState()
    val items by model.homeItems.collectAsState()
    val manualRecording by model.homeManualRecording.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val voices by model.ttsVoices.collectAsState()
    val currentVoice by model.ttsCurrentVoice.collectAsState()
    val showChinese by model.showChineseHint.collectAsState()
    val homeStatus by model.homeStatus.collectAsState()

    var elapsed by remember { mutableStateOf(0) }
    var showVoiceMenu by remember { mutableStateOf(false) }
    var guidanceFor by remember { mutableStateOf<AppViewModel.HomeChatItem?>(null) }

    LaunchedEffect(Unit) { model.startTutor() }
    LaunchedEffect(connected) { while (true) { delay(1000); if (connected) elapsed++ } }

    // 当前活跃声音电平：用户说话取麦克风电平，老师说话取播放电平
    val liveLevel = if (aiSpeaking) aiLevel else userLevel
    val glow by animateFloatAsState(targetValue = liveLevel.coerceIn(0f, 1f), label = "glow")

    Box(Modifier.fillMaxSize().background(Color(0xFF12141A))) {
        // 底部光晕：从底部升到屏幕中部，亮度/范围随说话频率呼吸（参考 Claude 语音界面）
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Transparent,
                    0.55f to Color.Transparent,
                    0.8f to Color(0xFF294F9E).copy(alpha = 0.12f + 0.30f * glow),
                    1f to Color(0xFF4079D9).copy(alpha = 0.30f + 0.45f * glow),
                )
            )
        )

        Column(Modifier.fillMaxSize()) {
            // 顶部：计时 +（翻译模式标记）
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 18.dp).padding(top = 48.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    Modifier.background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(50))
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Box(Modifier.size(7.dp).background(if (connected) RT.Success else Color.Red, CircleShape))
                    Text(String.format("%02d:%02d", elapsed / 60, elapsed % 60),
                        color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp)
                }
                Spacer(Modifier.weight(1f))
                if (mode == "translate") {
                    Text("实时翻译", color = Color.White.copy(alpha = 0.85f), fontWeight = FontWeight.SemiBold,
                        fontSize = (13 * fontScale).sp,
                        modifier = Modifier.background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(50))
                            .padding(horizontal = 12.dp, vertical = 7.dp))
                }
            }

            // 老师头像：固定在顶部（不随字幕滚动）；有 3D 人物素材则按音色性别显示写实人像
            Box(Modifier.fillMaxWidth().padding(top = 6.dp), contentAlignment = Alignment.Center) {
                TutorAvatarView(
                    isFemale = isFemaleVoice(currentVoice),
                    speaking = aiSpeaking,
                    level = aiLevel,
                    listening = !aiSpeaking && connected,
                )
            }

            // 状态行
            Text(
                when {
                    !connected -> "连接断开了，点下方按钮重连"
                    working -> if (mode == "translate") "正在翻译…" else "老师正在思考…"
                    aiSpeaking -> "老师正在说话，开口即可打断"
                    manualRecording -> "正在录音，说完点麦克风发送"
                    // 后端的忙碌/重连/合成失败等提示必须让用户看到（此前永远显示「倾听中」，出错像没反应）
                    homeStatus.isNotBlank() -> homeStatus
                    else -> "倾听中，直接开口说英语"
                },
                color = Color.White.copy(alpha = 0.7f), fontWeight = FontWeight.Medium,
                fontSize = (15 * fontScale).sp,
                modifier = Modifier.fillMaxWidth().padding(top = 14.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )

            // 字幕（最近两条主对话 + 中文翻译）
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 26.dp).padding(top = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items.filter { it.kind == AppViewModel.HomeKind.USER || it.kind == AppViewModel.HomeKind.AI }
                    .takeLast(2).forEach { item ->
                        Column {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(Modifier.size(7.dp).padding(top = 2.dp)
                                    .background(if (item.kind == AppViewModel.HomeKind.USER) RT.Accent else RT.Success, CircleShape))
                                Text(item.text, color = Color.White, fontWeight = FontWeight.Medium, fontSize = (17 * fontScale).sp)
                            }
                            if (item.showTranslation && item.translating) {
                                Text("正在翻译…", color = Color.White.copy(alpha = 0.6f),
                                    fontSize = (13 * fontScale).sp, modifier = Modifier.padding(start = 15.dp))
                            } else if (item.translation.isNotBlank() && (showChinese || item.showTranslation)) {
                                Text(item.translation, color = Color.White.copy(alpha = 0.65f),
                                    fontSize = (14 * fontScale).sp, modifier = Modifier.padding(start = 15.dp))
                            }
                            // 行内小操作（暂停/任意时刻可点）：AI 句=重播+译；用户句=发音指导
                            Row(
                                Modifier.padding(start = 15.dp, top = 3.dp),
                                horizontalArrangement = Arrangement.spacedBy(18.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (item.kind == AppViewModel.HomeKind.AI) {
                                    Icon(
                                        Icons.Filled.GraphicEq, contentDescription = "重新播放这一句",
                                        tint = Color.White.copy(alpha = 0.8f),
                                        modifier = Modifier.size(18.dp).clickable { model.speakText(item.text, item.tone) },
                                    )
                                    Text(
                                        "译", color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        modifier = Modifier
                                            .border(1.dp, Color.White.copy(alpha = 0.4f), RoundedCornerShape(5.dp))
                                            .clickable { model.toggleItemTranslation(item.id) }
                                            .padding(horizontal = 6.dp, vertical = 1.dp),
                                    )
                                } else {
                                    Text(
                                        "发音指导 ›", color = Color.White.copy(alpha = 0.8f),
                                        fontSize = (12 * fontScale).sp, fontWeight = FontWeight.Medium,
                                        modifier = Modifier.clickable { guidanceFor = item },
                                    )
                                }
                            }
                        }
                    }
            }

            Spacer(Modifier.weight(1f))   // 唯一弹性空档：头像+字幕固定在上，麦克风/底栏推到下

            // 中央麦克风：随「用户/老师说话」的音量呼吸；断线时变成重连按钮
            Box(Modifier.fillMaxWidth().padding(bottom = 22.dp), contentAlignment = Alignment.Center) {
                if (!connected) {
                    Text(
                        "↻ 重连", color = Color.Red, fontWeight = FontWeight.SemiBold, fontSize = (17 * fontScale).sp,
                        modifier = Modifier.background(Color.White, RoundedCornerShape(50))
                            .clickable { model.reconnectTutor() }
                            .padding(horizontal = 40.dp, vertical = 15.dp),
                    )
                } else {
                    val ring = 96f + 34f * glow
                    Box(contentAlignment = Alignment.Center) {
                        Box(
                            Modifier.size(ring.dp)
                                .border(2.dp, (if (aiSpeaking) RT.Success else RT.Accent).copy(alpha = 0.35f + 0.4f * glow), CircleShape)
                        )
                        Box(
                            Modifier.size(84.dp)
                                .background(Color.White.copy(alpha = 0.10f), CircleShape)
                                .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
                                .clickable {
                                    // 手动形态点按开始/发送；沉浸形态点按＝暂停/恢复聆听
                                    if (model.freeStream.manualRecording) {
                                        model.freeStream.endManualUtterance()
                                    } else if (model.freeStream.manualCommit) {
                                        model.freeStream.beginManualUtterance()
                                    } else {
                                        model.freeStream.togglePause()
                                    }
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Icons.Filled.Mic, contentDescription = "麦克风", tint = Color.White,
                                modifier = Modifier.size((30 + 6 * glow).dp),
                            )
                        }
                    }
                }
            }

            // 底部一排：音色胶囊（中）+ 退出 X（右）
            Box(Modifier.fillMaxWidth().padding(horizontal = 24.dp)) {
                Box(Modifier.align(Alignment.Center)) {
                    Row(
                        Modifier.background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(50))
                            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(50))
                            .clickable(enabled = voices.isNotEmpty()) { showVoiceMenu = true }
                            .padding(horizontal = 22.dp, vertical = 13.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(currentVoice.ifBlank { "音色" }, color = Color.White.copy(alpha = 0.9f),
                            fontWeight = FontWeight.Medium, fontSize = (16 * fontScale).sp)
                        Text("⇕", color = Color.White.copy(alpha = 0.9f), fontSize = 13.sp)
                    }
                    DropdownMenu(expanded = showVoiceMenu, onDismissRequest = { showVoiceMenu = false }) {
                        voices.forEach { v ->
                            DropdownMenuItem(
                                text = { Text(if (v == currentVoice) "✓ $v" else v) },
                                onClick = { showVoiceMenu = false; model.changeTutorVoice(v) },
                            )
                        }
                    }
                }
                Box(
                    Modifier.align(Alignment.CenterEnd).size(56.dp)
                        .background(Color.White, CircleShape)
                        .clickable { model.closeTutor() },
                    contentAlignment = Alignment.Center,
                ) { Text("✕", color = Color(0xFF262930), fontSize = 20.sp, fontWeight = FontWeight.SemiBold) }
            }

            Text("内容由 AI 生成", color = Color.White.copy(alpha = 0.35f), fontSize = 11.sp,
                modifier = Modifier.padding(top = 10.dp, bottom = 8.dp).fillMaxWidth(),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
    }
    guidanceFor?.let { item ->
        ModalBottomSheet(onDismissRequest = { guidanceFor = null }) {
            GuidanceDetailSheet(model, item, fontScale)
        }
    }
}

/** 女声音色集合（Qwen 本地 + OpenAI）；不在其中默认男声。 */
private val FEMALE_VOICES = setOf(
    "vivian", "serena", "ono_anna", "sohee",   // Qwen 本地
    "coral", "shimmer", "sage", "marin",        // OpenAI
)

fun isFemaleVoice(voice: String): Boolean = voice.lowercase() in FEMALE_VOICES

/**
 * 私教老师头像（固定顶部）：优先用运营放入的写实 3D 人物素材，按当前音色性别选男/女；
 * 素材缺失时回退中性机器人脸（可动嘴）。
 * 素材放置方式（放入后自动生效、无需改代码）：
 *   - 图片：把 3D 渲染图放到 res/drawable，命名 `tutor_female` / `tutor_male`（如 tutor_female.png/.webp）。
 *     静态图无法跟语音动口型，改用「说话时头像发光边框 + 轻微放大」表达"正在说话"。
 *   - 视频口型：需接入 ExoPlayer 播放 raw/ 下的说话循环视频（走这条另说）。
 */
@Composable
fun TutorAvatarView(isFemale: Boolean, speaking: Boolean, level: Float, listening: Boolean) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val resName = if (isFemale) "tutor_female" else "tutor_male"
    val resId = remember(resName) {
        context.resources.getIdentifier(resName, "drawable", context.packageName)
    }
    // 说话循环视频（口型动感）：res/raw/tutor_female.mp4 / tutor_male.mp4，放入即生效。
    // AI 说话时循环播放、安静时定帧；声音永远来自 TTS，视频静音。
    val rawId = remember(resName) {
        context.resources.getIdentifier(resName, "raw", context.packageName)
    }
    if (rawId != 0) {
        val glow by animateFloatAsState(targetValue = if (speaking) level.coerceIn(0f, 1f) else 0f, label = "vidglow")
        Box(Modifier.fillMaxWidth().height(300.dp)) {
            androidx.compose.runtime.key(rawId) {
                androidx.compose.ui.viewinterop.AndroidView(
                    factory = { ctx ->
                        android.widget.VideoView(ctx).apply {
                            setVideoURI(android.net.Uri.parse("android.resource://${ctx.packageName}/$rawId"))
                            setOnPreparedListener { mp ->
                                mp.isLooping = true
                                mp.setVolume(0f, 0f)
                                mp.seekTo(1)   // 显示首帧而不是黑屏
                            }
                        }
                    },
                    update = { v -> if (speaking) { if (!v.isPlaying) v.start() } else if (v.isPlaying) v.pause() },
                    modifier = Modifier.fillMaxSize(),
                )
            }
            // 底部渐隐到背景色，让字幕自然叠在人像下缘
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(0f to Color.Transparent, 0.7f to Color.Transparent, 1f to Color(0xFF12141A))
                )
            )
            Box(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(3.dp)
                    .background(RT.Success.copy(alpha = if (speaking) 0.25f + 0.5f * glow else 0f))
            )
        }
    } else if (resId != 0) {
        val glow by animateFloatAsState(targetValue = if (speaking) level.coerceIn(0f, 1f) else 0f, label = "avglow")
        val scale by animateFloatAsState(
            targetValue = if (speaking) 1f + 0.012f * level else if (listening) 1.006f else 1f, label = "avscale")
        Box(Modifier.fillMaxWidth().height(300.dp)) {
            androidx.compose.foundation.Image(
                painter = androidx.compose.ui.res.painterResource(id = resId),
                contentDescription = if (isFemale) "AI 女老师头像" else "AI 男老师头像",
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                modifier = Modifier.fillMaxSize().scale(scale),
            )
            // 底部渐隐到背景色，让字幕自然叠在人像下缘
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(0f to Color.Transparent, 0.7f to Color.Transparent, 1f to Color(0xFF12141A))
                )
            )
            // 说话指示：底部一条随电平呼吸的发光（静态图没有口型，用它表达"正在说话"）
            Box(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(3.dp)
                    .background(RT.Success.copy(alpha = if (speaking) 0.25f + 0.5f * glow else 0f))
            )
        }
    } else {
        // 无写实素材：回退机器人脸（能动嘴）
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            TutorAvatarFace(mouthOpen = if (speaking) level else 0f, listening = listening)
        }
    }
}

/** 插画风老师头像：脸 + 眨眼 + 随音量开合的嘴（素材可后续替换为真人照片/视频驱动）。 */
@Composable
fun TutorAvatarFace(mouthOpen: Float, listening: Boolean) {
    var blink by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        while (true) { delay(3200); blink = true; delay(140); blink = false }
    }
    val breathe by animateFloatAsState(targetValue = if (listening) 1.015f else 1f, label = "breathe")

    Box(Modifier.size(230.dp).scale(breathe), contentAlignment = Alignment.Center) {
        // 脸
        Box(
            Modifier.size(230.dp).background(
                Brush.linearGradient(listOf(Color(0xFFFADBB8), Color(0xFFF2C29E))), CircleShape,
            )
        )
        // 头发（上半圆）
        Box(
            Modifier.size(244.dp).offset(y = (-8).dp),
            contentAlignment = Alignment.TopCenter,
        ) {
            Box(Modifier.fillMaxWidth().height(96.dp)
                .background(Color(0xFF523826), RoundedCornerShape(topStart = 122.dp, topEnd = 122.dp)))
        }
        // 眼睛
        Row(Modifier.offset(y = (-14).dp), horizontalArrangement = Arrangement.spacedBy(54.dp)) {
            Box(Modifier.width(16.dp).height(if (blink) 3.dp else 18.dp).background(Color(0xFF33261F), RoundedCornerShape(8.dp)))
            Box(Modifier.width(16.dp).height(if (blink) 3.dp else 18.dp).background(Color(0xFF33261F), RoundedCornerShape(8.dp)))
        }
        // 腮红
        Row(Modifier.offset(y = 22.dp), horizontalArrangement = Arrangement.spacedBy(108.dp)) {
            Box(Modifier.size(26.dp, 14.dp).background(Color(0x59F5998C), CircleShape))
            Box(Modifier.size(26.dp, 14.dp).background(Color(0x59F5998C), CircleShape))
        }
        // 嘴：说话随电平开合；安静时浅笑
        val open = mouthOpen.coerceIn(0f, 1f)
        if (open > 0.02f) {
            Box(
                Modifier.offset(y = 52.dp).size(44.dp, (8 + 30 * (open * 1.6f).coerceAtMost(1f)).dp)
                    .background(Color(0xFF8C332E), RoundedCornerShape(50)),
                contentAlignment = Alignment.TopCenter,
            ) { Box(Modifier.padding(top = 1.dp).size(30.dp, 7.dp).background(Color.White, RoundedCornerShape(50))) }
        } else {
            // 聆听：浅笑（向上开口的弧线）
            androidx.compose.foundation.Canvas(Modifier.offset(y = 50.dp).size(48.dp, 20.dp)) {
                val path = androidx.compose.ui.graphics.Path().apply {
                    moveTo(0f, 0f)
                    quadraticBezierTo(size.width / 2f, size.height * 2f, size.width, 0f)
                }
                drawPath(path, Color(0xFF8C4033), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 10f, cap = androidx.compose.ui.graphics.StrokeCap.Round))
            }
        }
    }
}


/** 底部「+」上拉附加功能面板（参考 Claude App「Add to Chat」样式）：
 *  实时录音生成场景 / 上传语音文件 / 选择场景练习（严格或自由）/ 自由对话 / 实时翻译。 */
@Composable
fun AttachmentSheet(model: AppViewModel, isRecording: Boolean, dismiss: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val fontScale by model.fontScale.collectAsState()
    val sceneName by model.homeSceneName.collectAsState()
    val connected by model.homeConnected.collectAsState()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) {
            val name = uri.lastPathSegment?.substringAfterLast('/') ?: "recording.mp3"
            val target = java.io.File(context.cacheDir, name.ifBlank { "recording.mp3" })
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            model.uploadRecording(target)
        }
        dismiss()
    }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Column(
            Modifier.fillMaxWidth()
                .background(RT.Surface, RoundedCornerShape(16.dp))
                .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp)),
        ) {
            AttachRow(
                icon = { Icon(if (isRecording) Icons.Filled.StopCircle else Icons.Filled.GraphicEq,
                    contentDescription = null, tint = if (isRecording) Color.Red else RT.Accent) },
                title = if (isRecording) "停止采集并生成场景" else "实时录音生成场景",
                subtitle = "采集你身边的真实对话，自动还原成英语练习场景",
                fontScale = fontScale,
            ) { dismiss(); model.toggleRecording() }
            HorizontalDivider(color = RT.Hairline, modifier = Modifier.padding(start = 56.dp))
            AttachRow(
                icon = { Icon(Icons.Filled.FileUpload, contentDescription = null, tint = RT.Accent) },
                title = "上传语音文件生成场景",
                subtitle = "上传手机或录音笔里的录音（高级会员）",
                fontScale = fontScale,
            ) { picker.launch("audio/*") }
            HorizontalDivider(color = RT.Hairline, modifier = Modifier.padding(start = 56.dp))
            AttachRow(
                icon = { Icon(Icons.Filled.Movie, contentDescription = null, tint = RT.Accent) },
                title = "选择场景练习",
                subtitle = "选好场景后可选：严格按剧本对话 / 围绕场景自由发挥",
                fontScale = fontScale,
            ) { dismiss(); model.showScenePicker.value = true }
            HorizontalDivider(color = RT.Hairline, modifier = Modifier.padding(start = 56.dp))
            AttachRow(
                icon = { Icon(Icons.Filled.Language, contentDescription = null, tint = RT.Accent) },
                title = "实时翻译",
                subtitle = "说中文出英文、说英文出中文，逐句同传",
                fontScale = fontScale,
            ) {
                dismiss()
                model.tutorMode.value = "translate"
                model.showTutor.value = true
            }
        }
    }
}

@Composable
private fun AttachRow(
    icon: @Composable () -> Unit,
    title: String,
    subtitle: String,
    fontScale: Float,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.width(32.dp), contentAlignment = Alignment.Center) { icon() }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = (16 * fontScale).sp, fontWeight = FontWeight.Medium, color = RT.TextPrimary)
            Text(subtitle, fontSize = (12 * fontScale).sp, color = RT.TextSecondary, maxLines = 2)
        }
    }
}
