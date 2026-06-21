package com.example.realtalkad.ui

import androidx.compose.animation.core.FastOutSlowInEasing
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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import com.example.realtalkad.speech.RealtimeVoiceClient

private object RTVoice {
    val Top = Color(0xFF12203B)
    val Bottom = Color(0xFF05060F)
    val User = Color(0xFF1FBA62)
    val Ai = Color(0xFF514BE0)
}

/**
 * 高级会员「实时语音大模型」沉浸式对练界面（需求第 4 项）。
 * 直接与语音大模型实时对话，后端只做转发，结束后由模型给出评分与分析。
 */
@Composable
fun ImmersiveVoiceLLMScreen(model: AppViewModel) {
    val phase by model.realtime.phase.collectAsState()
    val review by model.realtime.review.collectAsState()
    val statusText by model.realtime.statusText.collectAsState()
    val inputLevel by model.realtime.inputLevel.collectAsState()
    val aiSpeaking by model.realtime.aiSpeaking.collectAsState()
    val fontScale by model.fontScale.collectAsState()

    val finished = phase == RealtimeVoiceClient.Phase.ENDED || phase == RealtimeVoiceClient.Phase.ERROR
    val title = model.roleplayState.collectAsState().value?.scenario?.title

    Box(
        Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(RTVoice.Top, RTVoice.Bottom))),
    ) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        title ?: "实时语音对练",
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = (17f * fontScale).sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        "实时语音大模型 · 高级会员",
                        color = Color.White.copy(alpha = 0.6f),
                        fontSize = (12f * fontScale).sp,
                    )
                }
                Box(
                    Modifier.size(36.dp)
                        .background(Color.White.copy(alpha = 0.12f), CircleShape)
                        .clickable { if (finished) model.dismissVoiceLLM() else model.endVoiceLLMPractice() },
                    contentAlignment = Alignment.Center,
                ) { Text("x", color = Color.White.copy(alpha = 0.85f), fontSize = (15 * fontScale).sp) }
            }

            // 纯语音流对接：不做文字/语音转换，不显示字幕与指导，
            // 界面中央只有一个跟随语音频率跳动的提示圈。
            Spacer(Modifier.weight(1f))
            if (finished) {
                ReviewCard(model, review, phase, statusText, fontScale)
            } else {
                VoiceControls(phase, statusText, inputLevel, aiSpeaking, fontScale) { model.endVoiceLLMPractice() }
            }
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun VoiceControls(
    phase: RealtimeVoiceClient.Phase,
    statusText: String,
    inputLevel: Float,
    aiSpeaking: Boolean,
    fontScale: Float,
    onEnd: () -> Unit,
) {
    val busy = phase == RealtimeVoiceClient.Phase.CONNECTING || phase == RealtimeVoiceClient.Phase.ENDING
    val orbColor = when {
        aiSpeaking -> RTVoice.Ai
        inputLevel > 0.04f -> RTVoice.User
        else -> Color.White.copy(alpha = 0.18f)
    }
    // AI 说话时圆圈连续脉冲（对齐 iOS 的正弦律动）；用户说话时随输入电平放大
    val infinite = rememberInfiniteTransition(label = "orb")
    val pulse by infinite.animateFloat(
        initialValue = 1f,
        targetValue = 1.12f,
        animationSpec = infiniteRepeatable(tween(600, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "pulse",
    )
    val scale = when {
        aiSpeaking -> pulse
        else -> 1f + inputLevel.coerceIn(0f, 1f) * 0.3f
    }

    Column(
        Modifier.fillMaxWidth().padding(bottom = 28.dp, top = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier.size(96.dp).scale(scale).background(orbColor, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (busy) {
                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(32.dp), strokeWidth = 3.dp)
            } else {
                Text(if (aiSpeaking) "🔊" else "🎙", fontSize = (30 * fontScale).sp)
            }
        }
        Text(
            statusText.ifBlank { "请用英文开口说话" },
            color = Color.White.copy(alpha = 0.62f),
            fontSize = (13f * fontScale).sp,
            fontWeight = FontWeight.Medium,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
        OutlinedButton(
            onClick = onEnd,
            enabled = !busy,
            border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.5f)),
        ) { Text("结束并评分", color = Color.White, fontSize = (15f * fontScale).sp) }
    }
}

@Composable
private fun ReviewCard(
    model: AppViewModel,
    review: RealtimeVoiceClient.Review?,
    phase: RealtimeVoiceClient.Phase,
    statusText: String,
    fontScale: Float,
) {
    Column(
        Modifier.fillMaxWidth().padding(20.dp)
            .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(22.dp))
            .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(22.dp))
            .padding(22.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        when {
            review != null -> {
                Text("${review.score}", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 52.sp)
                Text("本轮语音口语得分", color = Color.White.copy(alpha = 0.6f), fontSize = (13f * fontScale).sp)
                Text(
                    review.analysis.ifBlank { "已完成本轮语音对练。" },
                    color = Color.White.copy(alpha = 0.88f),
                    fontSize = (15f * fontScale).sp,
                    lineHeight = (21f * fontScale).sp,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp).verticalScroll(rememberScrollState()),
                )
            }
            phase == RealtimeVoiceClient.Phase.ERROR -> {
                Text("⚠", fontSize = 34.sp)
                Text(
                    statusText.ifBlank { "语音连接已断开" },
                    color = Color.White.copy(alpha = 0.88f),
                    fontSize = (15f * fontScale).sp,
                    textAlign = TextAlign.Center,
                )
            }
            else -> Text(
                statusText.ifBlank { "本轮已结束" },
                color = Color.White.copy(alpha = 0.88f),
                fontSize = (15f * fontScale).sp,
            )
        }
        Button(
            onClick = { model.dismissVoiceLLM() },
            modifier = Modifier.fillMaxWidth().height(50.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.White),
        ) { Text("完成", color = Color.Black, fontWeight = FontWeight.SemiBold, fontSize = (16f * fontScale).sp) }
    }
}
