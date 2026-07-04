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
    val Listen = Color(0xFF1FBA62)      // 聆听绿
    val Speak = Color(0xFFF5B21C)       // 可打断黄（AI 说话时可开口打断）
    val Thinking = Color(0xFFE03131)    // 后端处理红（不能打断）
    val Muted = Color.White.copy(alpha = 0.18f)
    val Correction = Color(0xFFFFD166)
}

private data class ImmCaption(
    val speaker: String,
    val text: String,
    val translation: String,
    val color: Color,
    val isUser: Boolean,
)

@Composable
fun ImmersiveRoleplayScreen(model: AppViewModel) {
    val state by model.roleplayState.collectAsState()
    val isVoiceActive by model.isVoiceActive.collectAsState()
    val isListening by model.isListening.collectAsState()
    val isSpeaking by model.isSpeaking.collectAsState()
    val isWorking by model.isWorking.collectAsState()
    val showChineseHint by model.showChineseHint.collectAsState()
    val guidanceMode by model.guidanceMode.collectAsState()
    val conversationMode by model.conversationMode.collectAsState()
    val partial by model.partialSubtitle.collectAsState()
    val practiceHint by model.practiceHint.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val level by model.practiceAudioLevel.collectAsState()
    val aiLevel by model.aiAudioLevel.collectAsState()

    // 字幕区：只显示 AI 与用户已确认的对话内容（不含纠正）
    val dialogueCaptions = state?.messages?.map {
        ImmCaption(if (it.speaker == "user") "You" else "AI", it.content, it.translation.orEmpty(), Color.White, it.speaker == "user")
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
            // 指导区永远给中文提示（与「中文提示」开关无关；开关只管字幕里的中文翻译）
            val prefix = if (state?.latestAccepted == false) "请你用英文继续说" else "请你用英文说"
            "$prefix：${it.sourceText}"
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

            // 字幕区（微信式气泡；中文翻译是否显示由「中文提示」开关控制）
            SubtitlePane(dialogueCaptions, showChineseHint, fontScale, Modifier.weight(1f))

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
                    isManual = conversationMode == "manual",
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
    showTranslation: Boolean,
    fontScale: Float,
    modifier: Modifier,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(captions.size) {
        if (captions.isNotEmpty()) listState.animateScrollToItem(captions.lastIndex)
    }
    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        itemsIndexed(captions) { idx, item ->
            CaptionRow(item, showTranslation, isCurrent = idx == captions.lastIndex, fontScale = fontScale)
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
    // 微信式气泡：AI 在左、我（You）在右
    Row(Modifier.fillMaxWidth()) {
        if (item.isUser) Spacer(Modifier.weight(1f))
        Column(
            Modifier.weight(4f, fill = false)
                .background(
                    if (item.isUser) RTImm.Listen.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.10f),
                    RoundedCornerShape(16.dp),
                )
                .padding(horizontal = 13.dp, vertical = 9.dp),
        ) {
            Text(
                item.text,
                color = Color.White.copy(alpha = if (isCurrent) 1f else 0.7f),
                fontSize = ((if (isCurrent) 20f else 18f) * fontScale).sp,
                fontWeight = FontWeight.SemiBold,
                lineHeight = ((if (isCurrent) 26f else 24f) * fontScale).sp,
            )
            if (showTranslation && item.translation.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    item.translation,
                    color = Color.White.copy(alpha = if (isCurrent) 0.62f else 0.34f),
                    fontSize = (14f * fontScale).sp,
                )
            }
        }
        if (!item.isUser) Spacer(Modifier.weight(1f))
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
    isManual: Boolean,
    guidanceMode: String,
    level: Float,
    aiLevel: Float,
    fontScale: Float,
    onClick: () -> Unit,
    onReplay: () -> Unit,
    onEvaluate: () -> Unit,
) {
    // 沉浸式流模式没有单独的 isListening 标志：只要在对话中、非 AI 说话、非后端处理，麦克风就在聆听
    val listening = !completed && !isWorking && !isSpeaking && isVoiceActive
    val color = when {
        completed -> Color.White
        isWorking -> RTImm.Thinking    // 红：后端处理，不能打断
        isSpeaking -> RTImm.Speak      // 黄：可打断
        listening -> RTImm.Listen      // 绿：聆听
        else -> RTImm.Muted
    }
    val scale = when {
        listening -> 1f + level.coerceIn(0f, 1f) * 0.28f
        isSpeaking -> 1f + aiLevel.coerceIn(0f, 1f) * 0.28f
        else -> 1f
    }
    val label = when {
        completed -> "本轮已完成"
        isWorking -> "已发送，正在识别评分…"
        // 手工触发式没有语音抢话，只能点按打断；沉浸式才是开口即可打断
        isSpeaking -> if (isManual) "AI 正在说话，点击可打断" else "AI 正在说话，开口即可打断"
        !isVoiceActive -> "已暂停，点击继续"
        else -> "正在聆听，说完停顿即可发送"
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
            // 等待按下：绿底 + 红色麦克风 = 轮到你说、但麦克风还没打开；按下后：绿底白色图标（录音中）
            Modifier.size(92.dp)
                .scale(if (pressing) 1.08f else 1f)
                .background(if (willCancel) RTImm.Thinking else RTImm.Listen, CircleShape)
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
                tint = if (pressing) Color.White else Color(0xFFD92B2B),   // 未按下=红麦克风(未开麦)
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
