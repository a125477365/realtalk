package com.example.realtalkad.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel

private object RTImm {
    val Top = Color(0xFF1A1C29)
    val Bottom = Color(0xFF05070D)
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

    val captions = buildList {
        state?.messages?.forEach { m ->
            add(ImmCaption(if (m.speaker == "user") "You" else "AI", m.content, m.translation.orEmpty(), Color.White))
            if (guidanceMode == "realtime" && m.speaker == "user" && !m.feedback.isNullOrBlank()) {
                add(ImmCaption("AI", m.feedback, "", RTImm.Correction))
            }
        }
        val feedback = state?.latestFeedback?.trim().orEmpty()
        if (feedback.isNotBlank() && (guidanceMode == "realtime" || state?.completed == true)) {
            if (lastOrNull()?.text != feedback) {
                add(ImmCaption("AI", feedback, "", RTImm.Correction))
            }
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
                    ) { Text("x", color = Color.White.copy(alpha = 0.85f), fontSize = 15.sp) }
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
                level = level,
                fontScale = fontScale,
                onClick = {
                    when {
                        isSpeaking -> model.interruptAiAndContinue()
                        state?.completed != true && !isWorking -> model.toggleVoiceConversation()
                    }
                },
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
    level: Float,
    fontScale: Float,
    onClick: () -> Unit,
) {
    val transition = rememberInfiniteTransition(label = "ai-pulse")
    val aiScale by transition.animateFloat(
        initialValue = 1f,
        targetValue = 1.12f,
        animationSpec = infiniteRepeatable(tween(420), RepeatMode.Reverse),
        label = "ai-scale",
    )
    val color = when {
        completed -> Color.White
        isWorking -> RTImm.Thinking
        isSpeaking -> RTImm.Speak
        isListening -> RTImm.Listen
        else -> RTImm.Muted
    }
    val scale = when {
        isListening -> 1f + level.coerceIn(0f, 1f) * 0.28f
        isSpeaking -> aiScale
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
                Text(
                    when {
                        completed -> "✓"
                        isSpeaking -> "■"
                        isListening -> "~"
                        isVoiceActive -> "mic"
                        else -> "play"
                    },
                    color = if (completed) Color.Black.copy(alpha = 0.35f) else Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = 24.sp,
                )
            }
        }
        Text(label, color = Color.White.copy(alpha = 0.62f), fontSize = (13f * fontScale).sp, fontWeight = FontWeight.Medium)
    }
}
