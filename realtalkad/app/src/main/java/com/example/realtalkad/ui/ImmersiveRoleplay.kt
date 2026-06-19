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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.R

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
    val guidanceMode by model.guidanceMode.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val level by model.practiceAudioLevel.collectAsState()
    val aiLevel by model.aiAudioLevel.collectAsState()

    val captions = buildList {
        state?.messages?.forEach { m ->
            add(ImmCaption(if (m.speaker == "user") "You" else "AI", m.content, m.translation.orEmpty(), Color.White))
            if (guidanceMode == "realtime" && m.speaker == "user" && !m.feedback.isNullOrBlank()) {
                add(ImmCaption("AI", m.feedback, "", RTImm.Correction))
            }
        }
        // 实时模式展示每轮纠正；结束后指导模式仅在完成/按需评估时由 latestFeedback 给出最终建议
        val feedback = state?.latestFeedback?.trim().orEmpty()
        if (feedback.isNotBlank() && lastOrNull()?.text != feedback) {
            add(ImmCaption("AI", feedback, "", RTImm.Correction))
        }
    }

    val promptText = state?.nextLine
        ?.takeIf { state?.completed == false && !isWorking && !isSpeaking }
        ?.let {
            val prefix = if (state?.latestAccepted == false) "请用英文继续说" else "请用英文说"
            "$prefix：${it.sourceText}"
        }

    val listState = rememberLazyListState()
    LaunchedEffect(captions.size, state?.latestFeedback) {
        if (captions.isNotEmpty()) listState.animateScrollToItem(captions.lastIndex)
    }

    Box(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(RTImm.Top, RTImm.Bottom)))
    ) {
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            state?.scenario?.title ?: "对练",
                            color = Color.White,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = (17f * fontScale).sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        state?.let {
                            Text(
                                "第 ${minOf(it.progress + 1, it.total)} / ${it.total} 句 · 我演 ${model.roleName(it.selectedRole)}",
                                color = Color.White.copy(alpha = 0.6f),
                                fontSize = (12f * fontScale).sp,
                            )
                        }
                    }
                    Box(
                        Modifier.size(36.dp)
                            .background(Color.White.copy(alpha = 0.12f), CircleShape)
                            .clickable { model.closeImmersive() },
                        contentAlignment = Alignment.Center,
                    ) { Text("x", color = Color.White.copy(alpha = 0.85f), fontSize = (15 * fontScale).sp) }
                }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("realtime" to "实时指导", "final" to "结束后指导").forEach { (key, label) ->
                        OutlinedButton(
                            onClick = { model.setGuidanceMode(key) },
                            modifier = Modifier.weight(1f),
                            border = androidx.compose.foundation.BorderStroke(
                                1.dp,
                                if (guidanceMode == key) RTImm.Thinking else Color.White.copy(alpha = 0.18f),
                            ),
                        ) {
                            Text(label, color = if (guidanceMode == key) Color.White else Color.White.copy(alpha = 0.62f))
                        }
                    }
                }
            }

            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 22.dp, vertical = 18.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                itemsIndexed(captions) { idx, item ->
                    CaptionRow(item, showSubtitles, isCurrent = idx == captions.lastIndex, fontScale = fontScale)
                }
            }

            PromptCircle(
                promptText = promptText,
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

        // 完成后可一键重玩；「结束后指导」模式可随时取最终评分（中途退出也有评价）
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
        } else if (guidanceMode == "final") {
            OutlinedButton(
                onClick = onEvaluate,
                border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.4f)),
            ) {
                Text("查看评分与建议", color = Color.White.copy(alpha = 0.85f), fontSize = (14f * fontScale).sp)
            }
        }
    }
}
