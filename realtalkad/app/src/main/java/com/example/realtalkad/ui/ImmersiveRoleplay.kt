package com.example.realtalkad.ui

import androidx.compose.foundation.background
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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.foundation.clickable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel

/* 沉浸式对练字幕配色 */
private object RTImm {
    val Top = Color(0xFF29216B)
    val Bottom = Color(0xFF0D0A24)
    val Accent = Color(0xFF8C85FA)
    val Good = Color(0xFF66D98C)
    val Warn = Color(0xFFFAC75C)
}

private data class ImmCaption(
    val speaker: String,
    val english: String,
    val chinese: String,
    val note: String?,
    val accepted: Boolean,
    val isUser: Boolean,
    val awaitingUser: Boolean,
)

/**
 * 沉浸式对练字幕：深色影院式背景，大字幕随对话自动上滚。
 * AI 句中英双语同显；轮到用户先显示中文提示，开口后显示英文识别与纠错标注。
 */
@Composable
fun ImmersiveRoleplayScreen(model: AppViewModel) {
    val rp by model.roleplayState.collectAsState()
    val partial by model.partialSubtitle.collectAsState()
    val isVoiceActive by model.isVoiceActive.collectAsState()
    val isListening by model.isListening.collectAsState()
    val isSpeaking by model.isSpeaking.collectAsState()
    val state = rp

    val captions = buildList {
        if (state != null) {
            state.messages.forEach { m ->
                val isUser = m.speaker == "user"
                add(
                    ImmCaption(
                        speaker = if (isUser) "我" else model.roleName(m.role),
                        english = m.content,
                        chinese = m.translation.orEmpty(),
                        note = if (isUser) m.feedback else null,
                        accepted = m.feedback.isNullOrBlank(),
                        isUser = isUser,
                        awaitingUser = false,
                    )
                )
            }
            val next = state.nextLine
            if (!state.completed && next != null && partial.isBlank() &&
                state.messages.lastOrNull()?.speaker != "user"
            ) {
                add(
                    ImmCaption(
                        speaker = "我", english = "", chinese = next.sourceText,
                        note = null, accepted = true, isUser = true, awaitingUser = true,
                    )
                )
            }
        }
    }

    val listState = rememberLazyListState()
    LaunchedEffect(captions.size, partial, state?.latestFeedback) {
        val total = captions.size + (if (partial.isNotBlank()) 1 else 0)
        if (total > 0) listState.animateScrollToItem(total - 1)
    }

    Box(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(RTImm.Top, RTImm.Bottom)))
    ) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏：标题 / 进度 / 关闭
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        state?.scenario?.title ?: "对练",
                        color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    if (state != null) {
                        Text(
                            "第 ${minOf(state.progress + 1, state.total)} / ${state.total} 句 · 我演 ${model.roleName(state.selectedRole)}",
                            color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp,
                        )
                    }
                }
                Box(
                    Modifier.size(36.dp)
                        .background(Color.White.copy(alpha = 0.12f), CircleShape)
                        .clickable { model.closeImmersive() },
                    contentAlignment = Alignment.Center,
                ) { Text("✕", color = Color.White.copy(alpha = 0.85f), fontSize = 15.sp) }
            }

            // 字幕区（自动上滚）
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 22.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(26.dp),
            ) {
                itemsIndexed(captions) { idx, item ->
                    CaptionRow(item, isCurrent = idx == captions.size - 1)
                }
                if (partial.isNotBlank()) {
                    item(key = "partial") {
                        Text(
                            partial, color = Color.White.copy(alpha = 0.9f),
                            fontSize = 22.sp, fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }

            // 底部控制
            Column(
                Modifier.fillMaxWidth().padding(bottom = 28.dp, top = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    statusText(state?.completed == true, isSpeaking, isListening, isVoiceActive),
                    color = Color.White.copy(alpha = 0.8f), fontSize = 15.sp, fontWeight = FontWeight.Medium,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(28.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ControlButton("🔊", "重听") { model.replayLastAi() }
                    Box(
                        Modifier.size(76.dp)
                            .background(
                                if (isVoiceActive) RTImm.Accent else Color.White.copy(alpha = 0.18f),
                                CircleShape,
                            )
                            .clickable { model.toggleVoiceConversation() },
                        contentAlignment = Alignment.Center,
                    ) { Text(if (isVoiceActive) "⏸" else "🎤", fontSize = 28.sp) }
                    ControlButton("💡", "提示") { model.requestHint() }
                }
            }
        }
    }
}

@Composable
private fun CaptionRow(item: ImmCaption, isCurrent: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            item.speaker.uppercase(),
            color = if (item.isUser) RTImm.Accent else Color.White.copy(alpha = 0.5f),
            fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
        )
        if (item.awaitingUser) {
            Text("该你说", color = RTImm.Accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(item.chinese, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
        } else {
            Text(
                item.english,
                color = Color.White.copy(alpha = if (isCurrent) 1f else 0.42f),
                fontSize = if (isCurrent) 30.sp else 22.sp, fontWeight = FontWeight.SemiBold,
            )
            if (item.chinese.isNotBlank()) {
                Text(
                    item.chinese,
                    color = Color.White.copy(alpha = if (isCurrent) 0.7f else 0.3f),
                    fontSize = if (isCurrent) 17.sp else 15.sp,
                )
            }
            val note = item.note
            if (!note.isNullOrBlank()) {
                Text(
                    (if (item.accepted) "✓ " else "💡 ") + note,
                    color = if (item.accepted) RTImm.Good else RTImm.Warn,
                    fontSize = 14.sp,
                )
            }
        }
    }
}

@Composable
private fun ControlButton(icon: String, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(
            Modifier.size(50.dp)
                .background(Color.White.copy(alpha = 0.1f), CircleShape)
                .clickable { onClick() },
            contentAlignment = Alignment.Center,
        ) { Text(icon, fontSize = 18.sp) }
        Text(label, color = Color.White.copy(alpha = 0.6f), fontSize = 11.sp)
    }
}

private fun statusText(completed: Boolean, speaking: Boolean, listening: Boolean, voiceActive: Boolean): String =
    when {
        speaking -> "AI 正在说…"
        listening -> "请用英语说出这句"
        completed -> "这轮练习已完成 🎉"
        !voiceActive -> "已暂停，点麦克风继续"
        else -> "准备好了就开口说"
    }
