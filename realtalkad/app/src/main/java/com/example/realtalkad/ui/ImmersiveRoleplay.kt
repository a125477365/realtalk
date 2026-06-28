package com.example.realtalkad.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.R
import kotlin.math.roundToInt

private object RTImm {
    // 深蓝调暗色背景（呼应品牌渐变蓝端，同时保证字幕可读）
    val Top = Color(0xFF12203B)
    val Bottom = Color(0xFF05060F)
    val Listen = Color(0xFF1FBA62)
    val Speak = Color(0xFFE03131)
    val Thinking = Color(0xFF514BE0)
    val Muted = Color.White.copy(alpha = 0.18f)
    val Correction = Color(0xFFFFD166)
}

private data class ImmCaption(
    val speaker: String,
    val text: String,
    val translation: String,
    val color: Color,
)

@Composable
fun ImmersiveRoleplayScreen(model: AppViewModel) {
    val state by model.roleplayState.collectAsState()
    val isVoiceActive by model.isVoiceActive.collectAsState()
    val isListening by model.isListening.collectAsState()
    val isSpeaking by model.isSpeaking.collectAsState()
    val isWorking by model.isWorking.collectAsState()
    val showSubtitles by model.showSubtitles.collectAsState()
    val showRefHint by model.showRefHint.collectAsState()
    val guidanceMode by model.guidanceMode.collectAsState()
    val conversationMode by model.conversationMode.collectAsState()
    val partial by model.partialSubtitle.collectAsState()
    val practiceHint by model.practiceHint.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val level by model.practiceAudioLevel.collectAsState()
    val aiLevel by model.aiAudioLevel.collectAsState()

    // 字幕区：只显示 AI 与用户已确认的对话内容（不含纠正）
    val dialogueCaptions = state?.messages?.map {
        ImmCaption(if (it.speaker == "user") "You" else "AI", it.content, it.translation.orEmpty(), Color.White)
    } ?: emptyList()

    // 指导区只显示「当前这句」的纠正建议：说错时给更自然的英文，说对/进入下一句即清空。
    // 不累积历史每轮反馈，也不把「正确…」确认语当提示展示（避免被误当成要翻译的中文）。
    val guidanceTexts = buildList {
        if (guidanceMode == "realtime") {
            val fb = state?.latestFeedback?.trim().orEmpty()
            if (fb.isNotBlank() && !fb.startsWith("正确") && !fb.startsWith("回答正确")) add(fb)
        }
    }

    // 下一句要说的中文提示（仅展示、不语音播报）
    val nextLineHint = state?.nextLine
        ?.takeIf { state?.completed == false && !isWorking && !isSpeaking }
        ?.let {
            val prefix = if (state?.latestAccepted == false) "请你用英文继续说" else "请你用英文说"
            val ref = if (showRefHint && it.english.isNotBlank()) "\n参考提示：${it.english}" else ""
            "$prefix：${it.sourceText}$ref"
        }

    Box(
        Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(RTImm.Top, RTImm.Bottom)))
    ) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏
            Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(state?.scenario?.title ?: "对练", color = Color.White, fontWeight = FontWeight.SemiBold,
                            fontSize = (17f * fontScale).sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        state?.let {
                            Text("第 ${minOf(it.progress + 1, it.total)} / ${it.total} 句 · 我演 ${model.roleName(it.selectedRole)}",
                                color = Color.White.copy(alpha = 0.6f), fontSize = (12f * fontScale).sp)
                        }
                    }
                    Box(Modifier.size(36.dp).background(Color.White.copy(alpha = 0.12f), CircleShape)
                        .clickable { model.closeImmersive() }, contentAlignment = Alignment.Center) {
                        Text("x", color = Color.White.copy(alpha = 0.85f), fontSize = (15 * fontScale).sp)
                    }
                }
            }

            // 字幕区（含双语/仅英文切换）
            SubtitlePane(dialogueCaptions, showSubtitles, fontScale, Modifier.weight(1f)) {
                model.setShowSubtitles(it == "bilingual")
            }

            // 完成显示最终评分卡；否则显示指导区
            if (state?.completed == true) {
                ReviewCard(
                    score = ((state?.score ?: 0.0) * 100).roundToInt(),
                    analysis = reviewAnalysis(state?.latestFeedback),
                    fontScale = fontScale,
                )
            } else {
                GuidancePane(nextLineHint, practiceHint, guidanceTexts, guidanceMode, fontScale)
            }

            // 控制区（下一句提示已移到指导区，这里不显示 promptText）
            val isUserTurnNow = state?.completed == false && !isWorking && !isSpeaking &&
                state?.nextLine != null && isVoiceActive
            if (conversationMode == "manual" && isUserTurnNow) {
                ManualTalkControl(model, null, partial, fontScale)
            } else {
                PromptCircle(
                    promptText = null,
                    completed = state?.completed == true,
                    isWorking = isWorking,
                    isSpeaking = isSpeaking,
                    isListening = isListening,
                    isVoiceActive = isVoiceActive,
                    guidanceMode = guidanceMode,
                    level = level,
                    aiLevel = aiLevel,
                    fontScale = fontScale,
                    onClick = {
                        when {
                            isSpeaking -> model.interruptAiAndContinue()
                            state?.completed != true && !isWorking -> model.toggleVoiceConversation()
                        }
                    },
                    onReplay = { model.replayScenario() },
                    onEvaluate = { model.requestFinalEvaluation() },
                )
            }
        }
    }
}

@Composable
private fun SubtitlePane(
    captions: List<ImmCaption>,
    showSubtitles: Boolean,
    fontScale: Float,
    modifier: Modifier,
    onToggle: (String) -> Unit,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(captions.size) {
        if (captions.isNotEmpty()) listState.animateScrollToItem(captions.lastIndex)
    }
    Column(modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.fillMaxWidth()) {
                BrandSegmented(
                    options = listOf("bilingual" to "双语", "en" to "仅英文"),
                    selected = if (showSubtitles) "bilingual" else "en",
                    fontScale = fontScale,
                    onSelect = onToggle,
                )
            }
        }
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 22.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            itemsIndexed(captions) { idx, item ->
                CaptionRow(item, showSubtitles, isCurrent = idx == captions.lastIndex, fontScale = fontScale)
            }
        }
    }
}

@Composable
private fun GuidancePane(nextLineHint: String?, englishHint: String?, guidanceTexts: List<String>, guidanceMode: String, fontScale: Float) {
    Column(
        Modifier.fillMaxWidth().height(150.dp).padding(horizontal = 12.dp)
            .background(Color.White.copy(alpha = 0.05f), RoundedCornerShape(16.dp))
            .border(1.dp, Color.White.copy(alpha = 0.10f), RoundedCornerShape(16.dp))
            .padding(14.dp),
    ) {
        Column(
            Modifier.verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (nextLineHint != null) {
                Text(nextLineHint, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (16f * fontScale).sp)
            }
            if (englishHint != null) {
                Text(englishHint, color = Color.White.copy(alpha = 0.92f), fontSize = (15f * fontScale).sp)
            }
            guidanceTexts.forEach { t ->
                Text("· $t", color = RTImm.Correction, fontSize = (14f * fontScale).sp)
            }
            if (nextLineHint == null && englishHint == null && guidanceTexts.isEmpty()) {
                Text(
                    if (guidanceMode == "final") "结束后会给出整体评分与建议" else "AI 的中文纠正建议会显示在这里",
                    color = Color.White.copy(alpha = 0.4f), fontSize = (13f * fontScale).sp,
                )
            }
        }
    }
}

/// 完成评分卡：大号分数 + 建议（与 iOS reviewCard 对应）。
@Composable
private fun ReviewCard(score: Int, analysis: String, fontScale: Float) {
    Column(
        Modifier.fillMaxWidth().height(200.dp).padding(horizontal = 12.dp)
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(16.dp))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(16.dp))
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("$score", color = Color.White, fontWeight = FontWeight.Bold, fontSize = (44f * fontScale).sp)
        Text("本轮口语得分", color = Color.White.copy(alpha = 0.6f), fontSize = (12f * fontScale).sp)
        Spacer(Modifier.height(8.dp))
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text(
                analysis, color = Color.White.copy(alpha = 0.85f),
                fontSize = (14f * fontScale).sp, lineHeight = (20f * fontScale).sp,
            )
        }
    }
}

/// 评分卡分析文字：去掉与大号分数重复的「最终评分 N/100。」前缀。
private fun reviewAnalysis(feedback: String?): String {
    val fb = feedback?.trim().orEmpty()
    val fallback = "本轮已完成，可点「重新对话」再练一次。"
    if (fb.startsWith("最终评分")) {
        val idx = fb.indexOf('。')
        if (idx >= 0) return fb.substring(idx + 1).trim().ifEmpty { fallback }
    }
    return fb.ifEmpty { fallback }
}

@Composable
private fun CaptionRow(item: ImmCaption, showTranslation: Boolean, isCurrent: Boolean, fontScale: Float) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(
            "${item.speaker}: ${item.text}",
            color = item.color.copy(alpha = if (isCurrent) 1f else 0.5f),
            fontSize = ((if (isCurrent) 28f else 22f) * fontScale).sp,
            fontWeight = FontWeight.SemiBold,
            lineHeight = ((if (isCurrent) 34f else 28f) * fontScale).sp,
        )
        if (showTranslation && item.translation.isNotBlank()) {
            Text(
                item.translation,
                color = Color.White.copy(alpha = if (isCurrent) 0.62f else 0.32f),
                fontSize = (15f * fontScale).sp,
            )
        }
    }
}

@Composable
private fun PromptCircle(
    promptText: String?,
    completed: Boolean,
    isWorking: Boolean,
    isSpeaking: Boolean,
    isListening: Boolean,
    isVoiceActive: Boolean,
    guidanceMode: String,
    level: Float,
    aiLevel: Float,
    fontScale: Float,
    onClick: () -> Unit,
    onReplay: () -> Unit,
    onEvaluate: () -> Unit,
) {
    val color = when {
        completed -> Color.White
        isWorking -> RTImm.Thinking
        isSpeaking -> RTImm.Speak
        isListening -> RTImm.Listen
        else -> RTImm.Muted
    }
    val scale = when {
        // 绿色：随用户说话的真实麦克风电平跳动
        isListening -> 1f + level.coerceIn(0f, 1f) * 0.28f
        // 红色：随 AI 实际输出音量跳动（Visualizer 实时电平，非固定正弦）
        isSpeaking -> 1f + aiLevel.coerceIn(0f, 1f) * 0.28f
        else -> 1f
    }
    val label = when {
        completed -> "本轮已完成"
        isWorking -> "等待后台处理"
        isSpeaking -> "AI 正在说话，点击可停止"
        isListening -> "正在听你说英语"
        !isVoiceActive -> "已暂停"
        else -> "准备进入下一句"
    }

    Column(
        Modifier.fillMaxWidth().padding(bottom = 28.dp, top = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (!promptText.isNullOrBlank()) {
            Text(
                promptText,
                color = Color.White,
                fontSize = (17f * fontScale).sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 22.dp),
            )
        }
        Box(
            Modifier.size(86.dp)
                .scale(scale)
                .background(color, CircleShape)
                .border(1.dp, Color.White.copy(alpha = 0.12f), CircleShape)
                .clickable(enabled = !completed) { onClick() },
            contentAlignment = Alignment.Center,
        ) {
            if (isWorking) {
                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(30.dp), strokeWidth = 3.dp)
            } else {
                val iconRes = when {
                    completed -> R.drawable.ic_check
                    isSpeaking -> R.drawable.ic_stop
                    isListening -> R.drawable.ic_graphic_eq
                    isVoiceActive -> R.drawable.ic_mic
                    else -> R.drawable.ic_play_arrow
                }
                Icon(
                    painter = painterResource(iconRes),
                    contentDescription = label,
                    tint = if (completed) Color.Black.copy(alpha = 0.4f) else Color.White,
                    modifier = Modifier.size(34.dp),
                )
            }
        }
        Text(label, color = Color.White.copy(alpha = 0.62f), fontSize = (13f * fontScale).sp, fontWeight = FontWeight.Medium)

        // 完成后可一键重玩（不再显示「查看评分与建议」按钮：完成后会自动展示评分卡）
        if (completed) {
            OutlinedButton(
                onClick = onReplay,
                border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.5f)),
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_replay),
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.size(8.dp))
                Text("重新对话", color = Color.White, fontSize = (14f * fontScale).sp)
            }
        }
    }
}

/** 手工触发式：长按说话；向左滑到取消区松手=取消，否则=发送。 */
@Composable
private fun ManualTalkControl(
    model: AppViewModel,
    promptText: String?,
    partial: String,
    fontScale: Float,
) {
    var pressing by remember { mutableStateOf(false) }
    var dragX by remember { mutableStateOf(0f) }
    val cancelThreshold = -160f
    val willCancel = pressing && dragX < cancelThreshold

    Column(
        Modifier.fillMaxWidth().padding(bottom = 28.dp, top = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (!promptText.isNullOrBlank()) {
            Text(
                promptText,
                color = Color.White,
                fontSize = (17f * fontScale).sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 22.dp),
            )
        }
        if (pressing) {
            Text(
                partial.ifBlank { "请说英文…" },
                color = Color.White.copy(alpha = 0.92f),
                fontSize = (15f * fontScale).sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 20.dp),
            )
            Row(Modifier.fillMaxWidth().padding(horizontal = 48.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("取消", color = if (willCancel) RTImm.Speak else Color.White.copy(alpha = 0.55f), fontWeight = FontWeight.SemiBold, fontSize = (14f * fontScale).sp)
                Text("发送", color = if (willCancel) Color.White.copy(alpha = 0.55f) else RTImm.Listen, fontWeight = FontWeight.SemiBold, fontSize = (14f * fontScale).sp)
            }
        }
        Box(
            Modifier.size(92.dp)
                .scale(if (pressing) 1.08f else 1f)
                .background(if (willCancel) RTImm.Speak else if (pressing) RTImm.Listen else RTImm.Thinking, CircleShape)
                .border(1.dp, Color.White.copy(alpha = 0.12f), CircleShape)
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        pressing = true
                        dragX = 0f
                        model.beginManualUtterance()
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull() ?: break
                            dragX = change.position.x - down.position.x
                            if (!change.pressed) break
                        }
                        val cancel = dragX < cancelThreshold
                        pressing = false
                        dragX = 0f
                        if (cancel) model.cancelManualUtterance() else model.sendManualUtterance()
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = painterResource(if (pressing && willCancel) R.drawable.ic_stop else R.drawable.ic_mic),
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(32.dp),
            )
        }
        Text(
            if (pressing) "松开发送 · 向左滑取消" else "请长按并说话",
            color = Color.White.copy(alpha = 0.62f),
            fontSize = (13f * fontScale).sp,
            fontWeight = FontWeight.Medium,
        )
    }
}
