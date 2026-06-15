package com.example.realtalkad.ui

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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.data.ChatMessage
import com.example.realtalkad.data.ScenarioSummary

/* Claude 风格主题色（与 iOS RTTheme 对应） */
object RT {
    val Background = Color(0xFFF7F8FB)
    val Surface = Color.White
    val UserBubble = Color(0xFFEEF0FB)
    val Accent = Color(0xFF4F46E5)
    val Success = Color(0xFF16A34A)
    val TextPrimary = Color(0xFF16181D)
    val TextSecondary = Color(0xFF5B616E)
    val Hairline = Color(0x12000000)
}

@Composable
fun RealTalkApp(model: AppViewModel) {
    val user by model.user.collectAsState()
    if (user == null) LoginScreen(model) else MainChatScreen(model)
}

/* ---------------- 登录 ---------------- */

@Composable
fun LoginScreen(model: AppViewModel) {
    val isWorking by model.isWorking.collectAsState()
    val status by model.statusMessage.collectAsState()
    Column(
        modifier = Modifier.fillMaxSize().background(RT.Background).padding(34.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("RealTalk", fontSize = 40.sp, fontWeight = FontWeight.Bold, color = RT.TextPrimary)
        Spacer(Modifier.height(8.dp))
        Text("用真实生活，进入英语环境", color = RT.TextSecondary)
        Spacer(Modifier.height(36.dp))
        Button(
            onClick = { model.loginWithWeChat() },
            enabled = !isWorking,
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0DAE4D)),
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(14.dp),
        ) {
            Text(if (isWorking) "正在授权…" else "微信快速登录", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        if (status.isNotBlank()) {
            Spacer(Modifier.height(16.dp))
            Text(status, color = RT.TextSecondary, fontSize = 13.sp)
        }
    }
}

/* ---------------- 主聊天界面 ---------------- */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainChatScreen(model: AppViewModel) {
    val messages by model.chatMessages.collectAsState()
    val partial by model.partialSubtitle.collectAsState()
    val scenarios by model.todayScenarios.collectAsState()
    val isRecording by model.isRecording.collectAsState()
    val isListening by model.isListening.collectAsState()
    val isSpeaking by model.isSpeaking.collectAsState()
    val isVoiceActive by model.isVoiceActive.collectAsState()
    val user by model.user.collectAsState()

    var draft by remember { mutableStateOf("") }
    var showAccount by remember { mutableStateOf(false) }
    var roleDialogFor by remember { mutableStateOf<ScenarioSummary?>(null) }

    val listState = rememberLazyListState()
    // 要求 13：字幕自动向上滚动
    LaunchedEffect(messages.size, partial) {
        val total = messages.size + (if (partial.isNotBlank()) 1 else 0)
        if (total > 0) listState.animateScrollToItem(total - 1)
    }

    Column(Modifier.fillMaxSize().background(RT.Background).imePadding()) {
        // 顶栏
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).background(RT.Accent.copy(alpha = 0.16f), CircleShape)
                    .clickable { showAccount = true },
                contentAlignment = Alignment.Center,
            ) {
                Text((user?.displayName ?: "我").take(1), color = RT.Accent, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.width(10.dp))
            Column {
                Text("RealTalk", fontWeight = FontWeight.SemiBold, color = RT.TextPrimary)
                Text(
                    when {
                        isSpeaking -> "AI 正在说话…"
                        isListening -> "正在听你说英语…"
                        isRecording -> "正在采集真实对话…"
                        else -> user?.tierName ?: ""
                    },
                    fontSize = 11.sp, color = RT.TextSecondary,
                )
            }
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.size(36.dp)
                    .background(RT.Surface, CircleShape)
                    .border(1.dp, RT.Hairline, CircleShape)
                    .clickable { model.toggleRecording() },
                contentAlignment = Alignment.Center,
            ) {
                Text(if (isRecording) "■" else "●", color = if (isRecording) Color.Red else RT.TextSecondary)
            }
        }

        // 今日场景
        Text(
            "今日场景",
            fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = RT.TextSecondary,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        if (scenarios.isEmpty()) {
            // 空态：引导先采集真实对话生成场景
            Column(
                Modifier.fillMaxWidth().padding(16.dp, 8.dp)
                    .background(RT.Surface, RoundedCornerShape(14.dp))
                    .border(1.dp, RT.Hairline, RoundedCornerShape(14.dp))
                    .clickable { model.toggleRecording() }
                    .padding(12.dp),
            ) {
                Text(
                    "今天还没有场景",
                    fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = RT.TextPrimary,
                )
                Spacer(Modifier.height(2.dp))
                Text("点这里采集今天的真实对话，自动生成练习场景",
                    fontSize = 12.sp, color = RT.TextSecondary)
            }
        } else {
            LazyRow(
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(scenarios, key = { it.sceneId }) { summary ->
                    Column(
                        Modifier.width(200.dp)
                            .background(RT.Surface, RoundedCornerShape(14.dp))
                            .border(1.dp, RT.Hairline, RoundedCornerShape(14.dp))
                            .clickable { roleDialogFor = summary }
                            .padding(12.dp),
                    ) {
                        Text(summary.title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                            color = RT.TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.height(3.dp))
                        Text(summary.summary, fontSize = 12.sp, color = RT.TextSecondary,
                            maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.height(4.dp))
                        Text("${summary.lineCount} 句", fontSize = 10.sp, color = RT.TextSecondary.copy(alpha = 0.8f))
                    }
                }
            }
        }

        // 消息流
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            items(messages, key = { it.id }) { message -> ChatRow(message) }
            if (partial.isNotBlank()) {
                item(key = "partial") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        Text(
                            partial, color = RT.TextSecondary,
                            modifier = Modifier
                                .background(RT.UserBubble.copy(alpha = 0.6f), RoundedCornerShape(18.dp))
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                        )
                    }
                }
            }
        }

        // 输入栏
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
                .background(RT.Surface, RoundedCornerShape(26.dp))
                .border(1.dp, RT.Hairline, RoundedCornerShape(26.dp))
                .padding(start = 8.dp, end = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = { Text("和 RealTalk 说说今天想练什么", fontSize = 14.sp) },
                modifier = Modifier.weight(1f),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                maxLines = 4,
            )
            TextButton(onClick = { model.toggleVoiceConversation() }) {
                Text(if (isVoiceActive) "⏸" else "🎤", fontSize = 22.sp)
            }
            TextButton(
                onClick = { model.sendText(draft); draft = "" },
                enabled = draft.isNotBlank(),
            ) { Text("↑", fontSize = 22.sp, color = if (draft.isNotBlank()) RT.Accent else RT.TextSecondary) }
        }
        Spacer(Modifier.height(6.dp))
    }

    // 角色选择
    roleDialogFor?.let { summary ->
        AlertDialog(
            onDismissRequest = { roleDialogFor = null },
            title = { Text("练习「${summary.title}」") },
            text = {
                Column {
                    Text("你想扮演谁？", color = RT.TextSecondary, fontSize = 13.sp)
                    Spacer(Modifier.height(10.dp))
                    summary.roles.filter { it.isUserCandidate }.forEach { role ->
                        OutlinedButton(
                            onClick = {
                                roleDialogFor = null
                                model.startScenarioPractice(summary, role.id)
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("${role.name}（${role.description}）", maxLines = 1, overflow = TextOverflow.Ellipsis) }
                        Spacer(Modifier.height(6.dp))
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { roleDialogFor = null }) { Text("取消") } },
        )
    }

    if (showAccount) {
        ModalBottomSheet(onDismissRequest = { showAccount = false }) {
            AccountSheet(model)
        }
    }
}

@Composable
fun ChatRow(message: ChatMessage) {
    when (message.sender) {
        ChatMessage.Sender.ASSISTANT -> Row(verticalAlignment = Alignment.Top) {
            Box(Modifier.padding(top = 8.dp).size(6.dp).background(RT.Accent, CircleShape))
            Spacer(Modifier.width(10.dp))
            Text(message.text, color = RT.TextPrimary, lineHeight = 22.sp)
        }
        ChatMessage.Sender.USER -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Text(
                message.text, color = RT.TextPrimary,
                modifier = Modifier
                    .background(RT.UserBubble, RoundedCornerShape(18.dp))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
        ChatMessage.Sender.SYSTEM -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            Text(
                message.text, color = RT.Accent, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .background(RT.Accent.copy(alpha = 0.10f), RoundedCornerShape(99.dp))
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            )
        }
    }
}
