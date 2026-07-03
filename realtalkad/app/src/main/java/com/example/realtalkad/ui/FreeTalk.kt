package com.example.realtalkad.ui

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel

/**
 * 自由对话（一对一语音英语老师）：无场景、无指导区，只有字幕流。
 * 老师的讲解/纠正直接作为对话字幕显示并朗读；可随时开口（说话即抢话打断老师）。
 */
@Composable
fun FreeTalkScreen(model: AppViewModel) {
    val messages by model.freeTalkMessages.collectAsState()
    val status by model.freeTalkStatus.collectAsState()
    val aiSpeaking by model.freeTalkAiSpeaking.collectAsState()
    val level by model.freeTalkLevel.collectAsState()
    val aiLevel by model.freeTalkAiLevel.collectAsState()
    val paused by model.freeTalkPaused.collectAsState()
    val working by model.freeTalkWorking.collectAsState()
    val showChineseHint by model.showChineseHint.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val listState = rememberLazyListState()

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }

    Box(
        Modifier.fillMaxSize().background(
            Brush.verticalGradient(listOf(Color(0xFF0D0F1A), Color(0xFF171A29)))
        ),
    ) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 18.dp).padding(top = 40.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("AI英语私教", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (17 * fontScale).sp)
                    Text(
                        "一对一语音老师 · 可以问语法、单词，或说「练一个打车场景」",
                        color = Color.White.copy(alpha = 0.55f), fontSize = (11 * fontScale).sp,
                    )
                }
                Box(
                    Modifier.background(Color.White.copy(alpha = 0.12f), CircleShape)
                        .clickable { model.stopFreeTalk() }
                        .padding(10.dp),
                ) { Text("✕", color = Color.White.copy(alpha = 0.85f), fontSize = 15.sp) }
            }

            // 字幕流
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                itemsIndexed(messages) { _, line ->
                    val speaker = line.speaker
                    // 翻译显示：用户说中文 → 必附英文翻译（不受开关约束）；其余仅在「中文提示」开时显示
                    val translation = line.translation.trim().takeIf {
                        it.isNotEmpty() && (showChineseHint || (speaker == "user" && line.text.any { c -> c.code in 0x4E00..0x9FFF }))
                    }
                    Row(Modifier.fillMaxWidth()) {
                        if (speaker == "user") Spacer(Modifier.weight(1f, fill = true))
                        Column(
                            Modifier
                                .background(
                                    if (speaker == "user") RT.Accent.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.10f),
                                    RoundedCornerShape(16.dp),
                                )
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                        ) {
                            Text(
                                line.text,
                                color = if (speaker == "user") Color.White else Color.White.copy(alpha = 0.92f),
                                fontSize = (15 * fontScale).sp,
                            )
                            if (translation != null) {
                                Spacer(Modifier.height(4.dp))
                                Text(translation, color = Color.White.copy(alpha = 0.6f), fontSize = (13 * fontScale).sp)
                            }
                        }
                        if (speaker != "user") Spacer(Modifier.weight(1f, fill = true))
                    }
                }
                if (messages.isEmpty()) {
                    itemsIndexed(listOf("")) { _, _ ->
                        Text(
                            if (status.isBlank()) "老师马上开口，直接用英语聊起来吧" else status,
                            color = Color.White.copy(alpha = 0.45f), fontSize = (13 * fontScale).sp,
                            modifier = Modifier.fillMaxWidth().padding(top = 60.dp),
                        )
                    }
                }
            }

            // 底部：与沉浸式同款随音频电平跳动的状态圆钮；点按 = 临时暂停 / 恢复
            Column(
                Modifier.fillMaxWidth().padding(bottom = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (status.isNotBlank() && messages.isNotEmpty()) {
                    Text(status, color = Color(0xFFF3D268), fontSize = (12 * fontScale).sp)
                    Spacer(Modifier.height(6.dp))
                }
                // 聆听绿 / 可打断黄 / 后端处理红 / 暂停灰
                val circleColor = when {
                    paused -> Color.White.copy(alpha = 0.25f)
                    working -> Color(0xFFE03131)   // 红：处理中，不能打断
                    aiSpeaking -> Color(0xFFF5B21C) // 黄：可打断
                    else -> RT.Success              // 绿：聆听
                }
                val pulse = 1f + 0.28f * (if (aiSpeaking) aiLevel else level).coerceIn(0f, 1f)
                Box(
                    Modifier.size((82 * pulse).dp)
                        .background(circleColor, CircleShape)
                        .clickable { model.toggleFreeTalkPause() },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        when { paused -> "▶"; working -> "…"; aiSpeaking -> "🔊"; else -> "🎙" },
                        color = Color.White, fontSize = 26.sp,
                    )
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    when {
                        paused -> "已暂停，点击继续"
                        working -> "已发送，老师正在思考…"
                        aiSpeaking -> "老师正在说话，开口即可打断"
                        else -> "正在聆听，你说完稍停即发送 · 点击可暂停"
                    },
                    color = Color.White.copy(alpha = 0.62f), fontSize = (13 * fontScale).sp, fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}
