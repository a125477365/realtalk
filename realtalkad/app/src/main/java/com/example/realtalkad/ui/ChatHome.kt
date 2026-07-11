package com.example.realtalkad.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
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
 * 底部：选场景/实时翻译/采集 工具条 + 点击说话 + 键盘输入 + 电话（私教）。
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
    val showPicker by model.showScenePicker.collectAsState()
    val manualRecording by model.homeManualRecording.collectAsState()
    val isRecording by model.isRecording.collectAsState()
    val user by model.user.collectAsState()
    val fontScale by model.fontScale.collectAsState()

    var keyboardMode by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var showAccount by remember { mutableStateOf(false) }
    var guidanceFor by remember { mutableStateOf<AppViewModel.HomeChatItem?>(null) }
    val listState = rememberLazyListState()

    LaunchedEffect(Unit) { if (!connected && !showTutor) model.startHomeChat() }
    LaunchedEffect(items.size) { if (items.isNotEmpty()) listState.animateScrollToItem(items.size - 1) }

    Box(Modifier.fillMaxSize().background(RT.Background)) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 40.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(34.dp).background(RT.BrandBrush, CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Text("R", color = Color.White, fontWeight = FontWeight.Bold) }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("AI 老师", fontWeight = FontWeight.SemiBold, fontSize = (17 * fontScale).sp, color = RT.TextPrimary)
                    Text(
                        when {
                            isRecording -> "正在采集真实对话…"
                            status.isNotBlank() -> status
                            else -> user?.tierName ?: "用真实生活练英语"
                        },
                        fontSize = (11 * fontScale).sp,
                        color = if (isRecording) Color.Red else RT.TextSecondary,
                    )
                }
                Text("👤", fontSize = 22.sp, modifier = Modifier.clickable { showAccount = true }.padding(6.dp))
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
                    Text("🎬 $name", fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
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

            // 工具条：选场景 / 实时翻译 / 采集
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                ToolChip("🎬 选场景", fontScale) { model.showScenePicker.value = true }
                ToolChip("🌐 实时翻译", fontScale) {
                    model.tutorMode.value = "translate"
                    model.showTutor.value = true
                }
                ToolChip(
                    if (isRecording) "⏹ 停止采集并生成场景" else "🎙 采集日常对话",
                    fontScale, tint = if (isRecording) Color.Red else null,
                ) { model.toggleRecording() }
            }

            // 输入区：点击说话 + 键盘 + 电话
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
                    Box(
                        Modifier.weight(1f).height(50.dp)
                            .background(
                                if (manualRecording) Brush.linearGradient(listOf(Color.Red, Color.Red)) else RT.BrandBrush,
                                RoundedCornerShape(16.dp),
                            )
                            .clickable(enabled = !working) { model.toggleHomeTalk() },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (working) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                                Text("请稍候…", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (16 * fontScale).sp)
                            }
                        } else {
                            Text(
                                if (manualRecording) "⏹ 说完了，发送" else "🎙 点击说话",
                                color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (16 * fontScale).sp,
                            )
                        }
                    }
                    Box(
                        Modifier.size(50.dp).background(RT.Surface, RoundedCornerShape(16.dp))
                            .clickable { keyboardMode = true },
                        contentAlignment = Alignment.Center,
                    ) { Text("⌨️", fontSize = 20.sp) }
                    Box(
                        Modifier.size(50.dp).background(RT.Success, CircleShape)
                            .clickable {
                                model.tutorMode.value = "chat"
                                model.showTutor.value = true
                            },
                        contentAlignment = Alignment.Center,
                    ) { Text("📞", fontSize = 20.sp) }
                }
            }
        }

        if (showTutor) TutorCallScreen(model)
        if (showPicker) ScenarioPickerOverlay(model)
        // 学习提醒「私教来电」
        val incomingReminder by model.incomingReminder.collectAsState()
        incomingReminder?.let { ReminderCallScreen(model, it) }
        val showVoiceLLM by model.showVoiceLLM.collectAsState()
        if (showVoiceLLM) ImmersiveVoiceLLMScreen(model)
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

@Composable
private fun ToolChip(label: String, fontScale: Float, tint: Color? = null, onClick: () -> Unit) {
    Text(
        label,
        fontSize = (13 * fontScale).sp, fontWeight = FontWeight.Medium,
        color = tint ?: RT.TextPrimary,
        modifier = Modifier
            .background(RT.Surface, RoundedCornerShape(50))
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

/** AI 大卡片：文本(打码时模糊) + 朗读/译 按钮 + 中文翻译（卡内切换）。 */
@Composable
private fun AiCard(model: AppViewModel, item: AppViewModel.HomeChatItem, fontScale: Float) {
    Column(
        Modifier.fillMaxWidth().background(RT.Surface, RoundedCornerShape(16.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            item.text, fontSize = (16 * fontScale).sp, color = RT.TextPrimary,
            modifier = if (item.masked) Modifier.blur(7.dp) else Modifier,
        )
        if (item.masked) {
            Text("先听老师说完，再看文字 🎧", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("🔊", fontSize = 15.sp, modifier = Modifier.clickable { model.speakText(item.text) })
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
        if (item.showTranslation && item.translation.isNotBlank() && !item.masked) {
            HorizontalDivider(color = RT.Hairline)
            Text(item.translation, fontSize = (14 * fontScale).sp, color = RT.TextSecondary)
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
        if (item.words.isNotEmpty()) {
            val score = (item.words.map { it.probability }.average() * 100).toInt()
            Row(
                Modifier.clickable { onDetail() }.padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("发音 $score", fontSize = (12 * fontScale).sp, fontWeight = FontWeight.Medium,
                    color = if (score >= 80) RT.Success else if (score >= 60) Color(0xFFF59F00) else Color.Red)
                if (item.wpm > 0) Text("语速 ${item.wpm}词/分", fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
                Text("详情 ›", fontSize = (12 * fontScale).sp, color = RT.Accent)
            }
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
 * 私教模式（电话按钮进入）：老师面对面——头像随说话动嘴、字幕/翻译开关、
 * 右上角切换 沉浸式(自动发送)/常规式(点击说话)，断线显示「重连」。与主界面共享同一条流。
 */
@Composable
fun TutorCallScreen(model: AppViewModel) {
    val connected by model.homeConnected.collectAsState()
    val working by model.homeWorking.collectAsState()
    val aiSpeaking by model.homeAiSpeaking.collectAsState()
    val aiLevel by model.homeAiLevel.collectAsState()
    val userLevel by model.homeUserLevel.collectAsState()
    val immersive by model.tutorImmersive.collectAsState()
    val mode by model.tutorMode.collectAsState()
    val items by model.homeItems.collectAsState()
    val manualRecording by model.homeManualRecording.collectAsState()
    val fontScale by model.fontScale.collectAsState()

    var elapsed by remember { mutableStateOf(0) }
    var showSubtitles by remember { mutableStateOf(true) }
    var showTranslation by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) { model.startTutor() }
    LaunchedEffect(connected) { while (true) { delay(1000); if (connected) elapsed++ } }

    Box(
        Modifier.fillMaxSize().background(
            Brush.verticalGradient(0f to Color(0xFFEDEDF2), 0.62f to Color(0xFF211F29), 1f to Color(0xFF211F29))
        ),
    ) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏：退出 + 实时翻译标记 + 沉浸/常规切换
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 44.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(46.dp).background(Color.White.copy(alpha = 0.75f), CircleShape)
                        .clickable { model.closeTutor() },
                    contentAlignment = Alignment.Center,
                ) { Text("⏻", fontSize = 18.sp, color = Color(0xFF595961)) }
                Spacer(Modifier.weight(1f))
                if (mode == "translate") {
                    Text("实时翻译", color = RT.Accent, fontWeight = FontWeight.SemiBold, fontSize = (13 * fontScale).sp,
                        modifier = Modifier.background(Color.White.copy(alpha = 0.75f), RoundedCornerShape(50))
                            .padding(horizontal = 12.dp, vertical = 8.dp))
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    if (immersive) "👁 切为常规" else "〰 切为沉浸",
                    color = RT.Success, fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp,
                    modifier = Modifier.background(Color.White.copy(alpha = 0.75f), RoundedCornerShape(50))
                        .clickable { model.toggleTutorImmersive() }
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }

            // 老师头像（动嘴）
            Box(Modifier.fillMaxWidth().padding(top = 6.dp), contentAlignment = Alignment.Center) {
                TutorAvatarFace(mouthOpen = if (aiSpeaking) aiLevel else 0f, listening = !aiSpeaking && connected)
            }

            // 计时 + 字幕/翻译开关
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    Modifier.background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(50))
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Box(Modifier.size(7.dp).background(if (connected) RT.Success else Color.Red, CircleShape))
                    Text(String.format("%02d:%02d", elapsed / 60, elapsed % 60), color = Color.White, fontSize = 13.sp)
                }
                Spacer(Modifier.weight(1f))
                Text(if (showSubtitles) "💬" else "💬̸", fontSize = 17.sp,
                    modifier = Modifier.background(Color.Black.copy(alpha = 0.35f), CircleShape)
                        .clickable { showSubtitles = !showSubtitles }.padding(10.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (showTranslation) "文A" else "文̸", fontSize = 13.sp, color = Color.White,
                    modifier = Modifier.background(Color.Black.copy(alpha = 0.35f), CircleShape)
                        .clickable { showTranslation = !showTranslation }.padding(10.dp))
            }

            // 字幕（最近两条主对话）
            if (showSubtitles) {
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 8.dp),
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
                                if (showTranslation && item.translation.isNotBlank()) {
                                    Text(item.translation, color = Color.White.copy(alpha = 0.65f),
                                        fontSize = (14 * fontScale).sp, modifier = Modifier.padding(start = 15.dp))
                                }
                            }
                        }
                }
            }

            Spacer(Modifier.weight(1f))

            // 状态行
            Text(
                when {
                    !connected -> "●●● 已断开"
                    working -> if (mode == "translate") "●●● 正在翻译…" else "●●● 老师正在思考…"
                    aiSpeaking -> "●●● 老师正在说话，开口即可打断"
                    manualRecording -> "●●● 正在录音，说完点发送"
                    immersive -> "●●● 倾听中"
                    else -> "●●● 点击下方按钮说话"
                },
                color = Color.White.copy(alpha = 0.6f), fontSize = (14 * fontScale).sp,
                modifier = Modifier.padding(horizontal = 22.dp, vertical = 10.dp),
            )

            // 底部控制：断线=重连 / 沉浸=波形 / 常规=点击说话
            Box(Modifier.fillMaxWidth().padding(bottom = 26.dp), contentAlignment = Alignment.Center) {
                when {
                    !connected -> Text(
                        "🚫 重连", color = Color.Red, fontWeight = FontWeight.SemiBold, fontSize = (17 * fontScale).sp,
                        modifier = Modifier.background(Color.White, RoundedCornerShape(50))
                            .clickable { model.reconnectTutor() }
                            .padding(horizontal = 44.dp, vertical = 14.dp),
                    )
                    immersive -> {
                        val pulse by animateFloatAsState(targetValue = 0.35f + 1.3f * userLevel, label = "wave")
                        Row(
                            Modifier.background(Color.White.copy(alpha = 0.12f), RoundedCornerShape(50))
                                .padding(horizontal = 34.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            repeat(9) { i ->
                                Box(
                                    Modifier.width(4.dp)
                                        .height((8 + ((i * 7) % 9) * 2.4f * pulse).dp)
                                        .background(RT.Success, RoundedCornerShape(2.dp))
                                )
                            }
                            Text(String.format(" %02d:%02d", elapsed / 60, elapsed % 60),
                                color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp)
                        }
                    }
                    else -> Text(
                        if (manualRecording) "⏹ 说完了，发送" else "〰 点击说话",
                        color = if (manualRecording) Color.White else Color(0xFF39401A),
                        fontWeight = FontWeight.SemiBold, fontSize = (18 * fontScale).sp,
                        modifier = Modifier
                            .background(if (manualRecording) Color.Red else Color(0xFFD9F28C), RoundedCornerShape(50))
                            .clickable { model.toggleHomeTalk() }
                            .padding(horizontal = 60.dp, vertical = 15.dp),
                    )
                }
            }
            Text("内容由 AI 生成", color = Color.White.copy(alpha = 0.35f), fontSize = 11.sp,
                modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth(),
                )
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
