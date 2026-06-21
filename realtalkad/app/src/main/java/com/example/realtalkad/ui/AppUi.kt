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
import androidx.compose.material3.Checkbox
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import android.widget.Toast
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.data.ScenarioSummary

/* 统一主题色（与 iOS RTTheme 对应）：「梦幻」渐变作 Hero/强调，内容区干净浅色 */
/// 外观主题（浅/深）当前是否深色，由 MainActivity 按用户选择提供；内容区颜色据此切换。
val LocalRtDark = androidx.compose.runtime.staticCompositionLocalOf { false }

object RT {
    val Accent = Color(0xFF2997F5)            // 天蓝（取自渐变起点）
    val Success = Color(0xFF16A34A)
    // 内容区颜色跟随外观主题（浅色/深色/系统）
    val Background: Color @androidx.compose.runtime.Composable get() = if (LocalRtDark.current) Color(0xFF12131A) else Color(0xFFF7F8FB)
    val Surface: Color @androidx.compose.runtime.Composable get() = if (LocalRtDark.current) Color(0xFF1E2029) else Color.White
    val UserBubble: Color @androidx.compose.runtime.Composable get() = if (LocalRtDark.current) Color(0xFF243247) else Color(0xFFEAF4FF)
    val TextPrimary: Color @androidx.compose.runtime.Composable get() = if (LocalRtDark.current) Color(0xFFEDEEF2) else Color(0xFF16181D)
    val TextSecondary: Color @androidx.compose.runtime.Composable get() = if (LocalRtDark.current) Color(0xFF9AA0AC) else Color(0xFF5B616E)
    val Hairline: Color @androidx.compose.runtime.Composable get() = if (LocalRtDark.current) Color(0x1FFFFFFF) else Color(0x12000000)

    // 蓝→青→粉→橙 梦幻渐变
    val Brand = listOf(Color(0xFF2997F5), Color(0xFF1AC7B3), Color(0xFFF58FB8), Color(0xFFFFC76B))
    val BrandBrush: Brush = Brush.linearGradient(Brand)
}

/// 品牌渐变底色的分段选择器（替代灰底）：整条为「开始采集」同款渐变，选中项白色胶囊。
@androidx.compose.runtime.Composable
fun BrandSegmented(
    options: List<Pair<String, String>>,
    selected: String,
    fontScale: Float = 1f,
    onSelect: (String) -> Unit,
) {
    androidx.compose.foundation.layout.Row(
        Modifier.fillMaxWidth()
            .background(RT.BrandBrush, androidx.compose.foundation.shape.RoundedCornerShape(99.dp))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        options.forEach { (key, label) ->
            val isSel = key == selected
            Box(
                Modifier.weight(1f)
                    .background(
                        if (isSel) Color.White else Color.Transparent,
                        androidx.compose.foundation.shape.RoundedCornerShape(99.dp),
                    )
                    .clickable { onSelect(key) }
                    .padding(vertical = 9.dp),
                contentAlignment = androidx.compose.ui.Alignment.Center,
            ) {
                Text(
                    label,
                    color = if (isSel) RT.Accent else Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = (14 * fontScale).sp,
                )
            }
        }
    }
}

/// 场景卡片；showDate=true 时在底部显示日期+时间（用于「全部」分组列表）。
@androidx.compose.runtime.Composable
private fun ScenarioCard(
    summary: com.example.realtalkad.data.ScenarioSummary,
    fontScale: Float,
    showDate: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .background(RT.Surface, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
            .border(1.dp, RT.Hairline, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
            .clickable { onClick() }
            .padding(14.dp),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                summary.title, fontWeight = FontWeight.SemiBold, fontSize = (15 * fontScale).sp,
                color = RT.TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(3.dp))
            Text(
                summary.summary, fontSize = (13 * fontScale).sp, color = RT.TextSecondary,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(4.dp))
            val meta = if (showDate) "${summary.lineCount} 句 · ${summary.createdAt.take(16).replace("T", " ")}"
            else "${summary.lineCount} 句"
            Text(meta, fontSize = (10 * fontScale).sp, color = RT.TextSecondary.copy(alpha = 0.8f))
        }
        Text("›", color = RT.TextSecondary.copy(alpha = 0.6f), fontSize = (20 * fontScale).sp)
    }
}

/// 通用场景列表：主场景可展开/收起，点子场景让 AI 即时生成中英对话再进对练（主→子两级选择）。
@Composable
private fun PresetCatalogList(
    groups: List<com.example.realtalkad.data.PresetScenarioGroup>,
    fontScale: Float,
    expandedGroup: String?,
    generatingSubId: String?,
    onToggleGroup: (String) -> Unit,
    onPickSub: (String, String) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (groups.isEmpty()) {
        Column(
            modifier.padding(24.dp, 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("暂无通用场景", fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
            Spacer(Modifier.height(6.dp))
            Text(
                "选择场景即可生成对话，无需录音",
                fontSize = (12 * fontScale).sp, color = RT.TextSecondary,
            )
        }
        return
    }
    LazyColumn(
        modifier = modifier,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item(key = "preset-tip") {
            Text(
                "选择场景即可生成对话，无需录音",
                fontSize = (12 * fontScale).sp, color = RT.TextSecondary,
                modifier = Modifier.padding(bottom = 2.dp),
            )
        }
        items(groups, key = { it.id }) { group ->
            val expanded = expandedGroup == group.id
            Column(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(14.dp))
                    .border(1.dp, RT.Hairline, RoundedCornerShape(14.dp)),
            ) {
                Row(
                    Modifier.fillMaxWidth().clickable { onToggleGroup(group.id) }.padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(group.title, fontWeight = FontWeight.SemiBold, fontSize = (16 * fontScale).sp,
                        color = RT.TextPrimary, modifier = Modifier.weight(1f))
                    Text("${group.subs.size} 个", fontSize = (11 * fontScale).sp,
                        color = RT.TextSecondary.copy(alpha = 0.8f))
                    Spacer(Modifier.width(8.dp))
                    Text(if (expanded) "⌄" else "›", color = RT.TextSecondary.copy(alpha = 0.6f),
                        fontSize = (18 * fontScale).sp)
                }
                if (expanded) {
                    group.subs.forEach { sub ->
                        Box(Modifier.fillMaxWidth().height(1.dp).padding(start = 14.dp).background(RT.Hairline))
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable(enabled = generatingSubId == null) { onPickSub(group.id, sub.id) }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(sub.title, fontSize = (14 * fontScale).sp, color = RT.TextPrimary,
                                modifier = Modifier.weight(1f))
                            if (generatingSubId == sub.id) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            } else {
                                Text("›", color = RT.TextSecondary.copy(alpha = 0.6f), fontSize = (16 * fontScale).sp)
                            }
                        }
                    }
                }
            }
        }
    }
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
        modifier = Modifier.fillMaxSize().background(RT.BrandBrush).padding(34.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("RealTalk", fontSize = 40.sp, fontWeight = FontWeight.Bold, color = Color.White)
        Spacer(Modifier.height(8.dp))
        Text("用真实生活，进入英语环境", color = Color.White.copy(alpha = 0.9f))
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
            Text(status, color = Color.White.copy(alpha = 0.9f), fontSize = 13.sp)
        }
    }
}

/* ---------------- 主聊天界面 ---------------- */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainChatScreen(model: AppViewModel) {
    val scenarios by model.todayScenarios.collectAsState()
    val isRecording by model.isRecording.collectAsState()
    val isListening by model.isListening.collectAsState()
    val isSpeaking by model.isSpeaking.collectAsState()
    val isWorking by model.isWorking.collectAsState()
    val user by model.user.collectAsState()
    val showImmersive by model.showImmersive.collectAsState()
    val showVoiceLLM by model.showVoiceLLM.collectAsState()
    val status by model.statusMessage.collectAsState()
    val fontScale by model.fontScale.collectAsState()

    val presetCatalog by model.presetCatalog.collectAsState()
    val isGeneratingPreset by model.isGeneratingPreset.collectAsState()
    val generatingSubId by model.generatingSubId.collectAsState()

    var showAccount by remember { mutableStateOf(false) }
    var roleDialogFor by remember { mutableStateOf<ScenarioSummary?>(null) }
    var scenarioScope by remember { mutableStateOf("today") }
    var expandedPresetGroup by remember { mutableStateOf<String?>(null) }

    val statusText = when {
        status.isNotEmpty() -> status
        isSpeaking -> "AI 正在说话…"
        isListening -> "正在听你说英语…"
        isRecording -> "正在采集真实对话…"
        isWorking -> "正在处理，请稍等"
        else -> user?.tierName ?: "用真实生活练英语"
    }
    val statusColor = when {
        isRecording -> Color.Red
        isSpeaking -> Color(0xFFD97706)
        isListening -> RT.Success
        isWorking -> RT.Accent
        else -> RT.TextSecondary
    }

    val context = LocalContext.current
    LaunchedEffect(status) {
        if (status.isNotEmpty()) {
            Toast.makeText(context, status, Toast.LENGTH_SHORT).show()
        }
    }

    Column(Modifier.fillMaxSize().background(RT.Background).imePadding()) {
        // 顶栏
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).background(RT.BrandBrush, CircleShape)
                    .clickable { showAccount = true },
                contentAlignment = Alignment.Center,
            ) {
                Text((user?.displayName ?: "我").take(1), color = Color.White, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.width(10.dp))
            Column {
                Text("RealTalk", fontWeight = FontWeight.SemiBold, color = RT.TextPrimary)
                Text("场景列表与日期选择", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
            }
            Spacer(Modifier.weight(1f))
        }

        // 顶部状态：低调的「圆点 + 文字」指示器，不再是抢眼的彩色胶囊
        Row(
            Modifier.align(Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.size(6.dp).background(statusColor, CircleShape))
            Text(statusText, fontSize = (12 * fontScale).sp, fontWeight = FontWeight.Medium, color = RT.TextSecondary)
        }
        Spacer(Modifier.height(12.dp))

        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            BrandSegmented(
                options = listOf("today" to "今天", "all" to "全部", "preset" to "通用场景"),
                selected = scenarioScope,
                fontScale = fontScale,
            ) { key ->
                scenarioScope = key
                when (key) {
                    "today" -> model.loadTodayScenarios()
                    "all" -> model.loadScenarioList()
                    "preset" -> model.loadPresetCatalog()
                }
            }
        }
        Spacer(Modifier.height(12.dp))

        // 场景列表
        Text(
            when (scenarioScope) { "today" -> "今日场景"; "preset" -> "通用场景"; else -> "全部场景" },
            fontSize = (12 * fontScale).sp, fontWeight = FontWeight.SemiBold, color = RT.TextSecondary,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        if (scenarioScope == "preset") {
            PresetCatalogList(
                groups = presetCatalog,
                fontScale = fontScale,
                expandedGroup = expandedPresetGroup,
                generatingSubId = if (isGeneratingPreset) generatingSubId else null,
                onToggleGroup = { gid -> expandedPresetGroup = if (expandedPresetGroup == gid) null else gid },
                onPickSub = { gid, sid ->
                    model.generatePresetScenario(gid, sid) { summary -> roleDialogFor = summary }
                },
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        } else if (scenarios.isEmpty()) {
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
                    fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp, color = RT.TextPrimary,
                )
                Spacer(Modifier.height(2.dp))
                Text("点底部按钮采集今天的真实对话，停止后自动生成练习场景",
                    fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
            }
            Spacer(Modifier.weight(1f))
        } else {
            // 竖排列表，方便逐条选择
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (scenarioScope == "all") {
                    // 「今天 / 历史」两段；历史内再按日期分组
                    val today = java.time.LocalDate.now().toString()
                    val todayItems = scenarios.filter { it.createdAt.take(10) == today }
                    val historyGroups = scenarios.filter { it.createdAt.take(10) != today }
                        .groupBy { it.createdAt.take(10) }.entries.sortedByDescending { it.key }
                    if (todayItems.isNotEmpty()) {
                        item(key = "sec-today") {
                            Text("今天", fontWeight = FontWeight.SemiBold, fontSize = (13 * fontScale).sp,
                                color = RT.TextPrimary, modifier = Modifier.padding(top = 4.dp))
                        }
                        items(todayItems, key = { it.sceneId }) { summary ->
                            ScenarioCard(summary, fontScale, showDate = false) { roleDialogFor = summary }
                        }
                    }
                    if (historyGroups.isNotEmpty()) {
                        item(key = "sec-history") {
                            Text("历史", fontWeight = FontWeight.SemiBold, fontSize = (13 * fontScale).sp,
                                color = RT.TextPrimary, modifier = Modifier.padding(top = 8.dp))
                        }
                        historyGroups.forEach { (day, group) ->
                            item(key = "d-$day") {
                                Text(day, fontWeight = FontWeight.Medium, fontSize = (11 * fontScale).sp,
                                    color = RT.TextSecondary.copy(alpha = 0.8f), modifier = Modifier.padding(start = 4.dp, top = 2.dp))
                            }
                            items(group, key = { it.sceneId }) { summary ->
                                ScenarioCard(summary, fontScale, showDate = true) { roleDialogFor = summary }
                            }
                        }
                    }
                } else {
                    items(scenarios, key = { it.sceneId }) { summary ->
                        ScenarioCard(summary, fontScale, showDate = false) { roleDialogFor = summary }
                    }
                }
            }
        }

        // 主操作按钮：录音中为红色，其余用品牌渐变（Box 才能铺渐变）
        Box(
            Modifier
                .fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp).height(56.dp)
                .background(
                    if (isRecording) androidx.compose.ui.graphics.SolidColor(Color.Red) else RT.BrandBrush,
                    RoundedCornerShape(99.dp),
                )
                .clickable(enabled = !isWorking) { model.toggleRecording() },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (isRecording) "停止采集并生成场景" else "开始采集日常对话",
                color = Color.White, fontWeight = FontWeight.SemiBold,
            )
        }
    }

    // 角色选择
    roleDialogFor?.let { summary ->
        AlertDialog(
            onDismissRequest = { roleDialogFor = null },
            title = { Text("练习「${summary.title}」") },
            text = {
                Column {
                    Text("你想扮演谁？", color = RT.TextSecondary, fontSize = (13 * fontScale).sp)
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

    // 对话前询问（指导/对话方式设为 ask 时）
    PrePracticeDialog(model)

    if (showAccount) {
        ModalBottomSheet(onDismissRequest = { showAccount = false }) {
            AccountSheet(model)
        }
    }

    // 沉浸式对练字幕：开练后全屏覆盖在主界面之上
    if (showImmersive) ImmersiveRoleplayScreen(model)
    // 高级会员沉浸式 + 实时语音大模型对练
    if (showVoiceLLM) ImmersiveVoiceLLMScreen(model)
}

/** 对话前询问：指导/对话方式设为「每次询问」时，开练前选择本次方式（可勾选以后不再询问）。 */
@Composable
private fun PrePracticeDialog(model: AppViewModel) {
    val pending by model.pendingPractice.collectAsState()
    val convPref by model.conversationPreference.collectAsState()
    val guidPref by model.guidancePreference.collectAsState()
    if (pending == null) return

    var conversation by remember { mutableStateOf("immersive") }
    var guidance by remember { mutableStateOf("realtime") }
    var rememberConv by remember { mutableStateOf(false) }
    var rememberGuid by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = { model.cancelPendingPractice() },
        title = { Text("开始练习") },
        text = {
            Column {
                if (convPref == "ask") {
                    Text("对话方式", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = RT.TextPrimary)
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("immersive" to "沉浸式", "manual" to "手工触发").forEach { (k, l) ->
                            OutlinedButton(
                                onClick = { conversation = k },
                                modifier = Modifier.weight(1f),
                                border = androidx.compose.foundation.BorderStroke(1.dp, if (conversation == k) RT.Accent else RT.Hairline),
                            ) { Text(l, color = if (conversation == k) RT.Accent else RT.TextSecondary) }
                        }
                    }
                    CheckRow(rememberConv) { rememberConv = it }
                    Spacer(Modifier.height(12.dp))
                }
                if (guidPref == "ask") {
                    Text("指导方式", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = RT.TextPrimary)
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("realtime" to "实时指导", "final" to "结束后指导").forEach { (k, l) ->
                            OutlinedButton(
                                onClick = { guidance = k },
                                modifier = Modifier.weight(1f),
                                border = androidx.compose.foundation.BorderStroke(1.dp, if (guidance == k) RT.Accent else RT.Hairline),
                            ) { Text(l, color = if (guidance == k) RT.Accent else RT.TextSecondary) }
                        }
                    }
                    CheckRow(rememberGuid) { rememberGuid = it }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val conv = if (convPref == "ask") conversation else if (convPref == "manual") "manual" else "immersive"
                val guid = if (guidPref == "ask") guidance else if (guidPref == "final") "final" else "realtime"
                model.confirmPendingPractice(conv, guid, rememberConv, rememberGuid)
            }) { Text("开始") }
        },
        dismissButton = { TextButton(onClick = { model.cancelPendingPractice() }) { Text("取消") } },
    )
}

@Composable
private fun CheckRow(checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clickable { onChange(!checked) },
    ) {
        Checkbox(checked = checked, onCheckedChange = onChange)
        Text("以后不再询问，按此方式", fontSize = 12.sp, color = RT.TextSecondary)
    }
}
