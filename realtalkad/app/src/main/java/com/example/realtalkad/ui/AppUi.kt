package com.example.realtalkad.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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

/// 把 ISO 时间按本地时区折算成日期字符串（与 iOS 本地日期分组一致；解析失败回退 UTC 日期前缀）。
private fun sceneLocalDate(iso: String): String = try {
    java.time.OffsetDateTime.parse(iso).atZoneSameInstant(java.time.ZoneId.systemDefault()).toLocalDate().toString()
} catch (e: Exception) {
    iso.take(10)
}

/// 不同会员可见历史窗口说明。
private fun historyWindowHint(tier: String?): String = when (tier) {
    "premium" -> "高级会员可查看近 1 个月的历史场景"
    "basic" -> "基础会员可查看近 2 周的历史场景；升级高级会员可看近 1 个月"
    else -> "非会员仅显示近 2 天的场景；开通会员可保存更久（基础 2 周 / 高级 1 个月）"
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

/// 上一次对练得分小标签（场景卡用）。
@Composable
private fun LastScoreBadge(score: Int?, fontScale: Float) {
    if (score == null) return
    val c = if (score >= 80) RT.Success else RT.Accent
    Text(
        "上次 $score",
        color = c, fontWeight = FontWeight.SemiBold, fontSize = (11 * fontScale).sp,
        modifier = Modifier.background(c.copy(alpha = 0.12f), RoundedCornerShape(99.dp))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/// 场景卡片；showDate=true 时在底部显示日期+时间（用于「全部」分组列表）。单击进入对练，长按弹菜单。
@kotlin.OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@androidx.compose.runtime.Composable
private fun ScenarioCard(
    summary: com.example.realtalkad.data.ScenarioSummary,
    fontScale: Float,
    showDate: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit = {},
) {
    Row(
        Modifier.fillMaxWidth()
            .background(RT.Surface, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
            .border(1.dp, RT.Hairline, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
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
        LastScoreBadge(summary.lastScore, fontScale)
        Spacer(Modifier.width(8.dp))
        Text("›", color = RT.TextSecondary.copy(alpha = 0.6f), fontSize = (20 * fontScale).sp)
    }
}

/// 通用场景列表：主场景可展开/收起，点子场景直接进入对练（场景已含完整对话，无需生成）。
@Composable
private fun PresetCatalogList(
    groups: List<com.example.realtalkad.data.PresetSceneGroup>,
    fontScale: Float,
    expandedGroup: String?,
    onToggleGroup: (String) -> Unit,
    onPickScene: (com.example.realtalkad.data.PresetSceneItem) -> Unit,
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
                "没有录音也能练：选一个场景，直接与 AI 对话",
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
                "没有录音也能练：选一个场景，直接进入对话练习",
                fontSize = (12 * fontScale).sp, color = RT.TextSecondary,
                modifier = Modifier.padding(bottom = 2.dp),
            )
        }
        items(groups, key = { it.group }) { group ->
            val expanded = expandedGroup == group.group
            Column(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(14.dp))
                    .border(1.dp, RT.Hairline, RoundedCornerShape(14.dp)),
            ) {
                Row(
                    Modifier.fillMaxWidth().clickable { onToggleGroup(group.group) }.padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(group.group, fontWeight = FontWeight.SemiBold, fontSize = (16 * fontScale).sp,
                        color = RT.TextPrimary, modifier = Modifier.weight(1f))
                    Text("${group.scenes.size} 个", fontSize = (11 * fontScale).sp,
                        color = RT.TextSecondary.copy(alpha = 0.8f))
                    Spacer(Modifier.width(8.dp))
                    Text(if (expanded) "⌄" else "›", color = RT.TextSecondary.copy(alpha = 0.6f),
                        fontSize = (18 * fontScale).sp)
                }
                if (expanded) {
                    group.scenes.forEach { scene ->
                        Box(Modifier.fillMaxWidth().height(1.dp).padding(start = 14.dp).background(RT.Hairline))
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable { onPickScene(scene) }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(scene.title, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
                                Text("${scene.lineCount} 句", fontSize = (11 * fontScale).sp,
                                    color = RT.TextSecondary.copy(alpha = 0.8f))
                            }
                            LastScoreBadge(scene.lastScore, fontScale)
                            Spacer(Modifier.width(8.dp))
                            Text("›", color = RT.TextSecondary.copy(alpha = 0.6f), fontSize = (16 * fontScale).sp)
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
    // 全局失败提示框：放在根部，覆盖任意界面（主页/对练/语音/上传等）
    FailureAlertDialog(model)
}

/// 中断流程的系统/模型/额度异常弹窗：渲染在独立 Dialog 窗口，置于所有界面之上。
@Composable
private fun FailureAlertDialog(model: AppViewModel) {
    val alert by model.failureAlert.collectAsState()
    alert?.let { a ->
        AlertDialog(
            onDismissRequest = { model.dismissFailureAlert() },
            title = { Text(a.title) },
            text = { Text(a.message) },
            confirmButton = { TextButton(onClick = { model.dismissFailureAlert() }) { Text("我知道了") } },
        )
    }
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
    // 等待后台处理时禁用其它操作按钮，避免误触发新请求
    val busy = isWorking

    var showAccount by remember { mutableStateOf(false) }
    var roleDialogFor by remember { mutableStateOf<ScenarioSummary?>(null) }
    var scenarioScope by remember { mutableStateOf("today") }
    var expandedPresetGroup by remember { mutableStateOf<String?>(null) }
    var expandedDate by remember { mutableStateOf<String?>(null) }
    var menuScene by remember { mutableStateOf<ScenarioSummary?>(null) }   // 长按弹「开始对话/删除」
    var deleteScene by remember { mutableStateOf<ScenarioSummary?>(null) }

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
                // 今天/全部都用同一份列表（按本地日期解读），避免「全部有今天的场景、今天标签却没有」的不一致
                when (key) {
                    "preset" -> model.loadPresetCatalog()
                    else -> model.loadScenarioList()
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
                onToggleGroup = { g -> expandedPresetGroup = if (expandedPresetGroup == g) null else g },
                onPickScene = { scene -> if (!busy) roleDialogFor = model.presetSummary(scene) },
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        } else {
            val today = java.time.LocalDate.now().toString()
            val todayItems = scenarios.filter { sceneLocalDate(it.createdAt) == today }
            val isEmpty = if (scenarioScope == "all") scenarios.isEmpty() else todayItems.isEmpty()
            if (isEmpty) {
                // 空态：引导先采集真实对话生成场景
                Column(
                    Modifier.fillMaxWidth().padding(16.dp, 8.dp)
                        .background(RT.Surface, RoundedCornerShape(14.dp))
                        .border(1.dp, RT.Hairline, RoundedCornerShape(14.dp))
                        .clickable(enabled = !busy) { model.toggleRecording() }
                        .padding(12.dp),
                ) {
                    Text("今天还没有场景", fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
                    Spacer(Modifier.height(2.dp))
                    Text("点底部按钮采集今天的真实对话，停止后自动生成练习场景",
                        fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
                }
                Spacer(Modifier.weight(1f))
            } else if (scenarioScope == "all") {
                // 全部：先按日期折叠，点某天才展开当天场景；并提示不同会员可见历史窗口
                val groups = scenarios.groupBy { sceneLocalDate(it.createdAt) }.entries.sortedByDescending { it.key }
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    item(key = "hint") {
                        Text(historyWindowHint(user?.planTier), fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
                    }
                    items(groups.toList(), key = { it.key }) { (day, items) ->
                        val expanded = expandedDate == day
                        Column(
                            Modifier.fillMaxWidth().background(RT.Surface, RoundedCornerShape(14.dp))
                                .border(1.dp, RT.Hairline, RoundedCornerShape(14.dp)),
                        ) {
                            Row(
                                Modifier.fillMaxWidth().clickable { expandedDate = if (expanded) null else day }.padding(14.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(if (day == today) "今天" else day, fontWeight = FontWeight.SemiBold,
                                    fontSize = (16 * fontScale).sp, color = RT.TextPrimary, modifier = Modifier.weight(1f))
                                Text("${items.size} 个", fontSize = (11 * fontScale).sp, color = RT.TextSecondary.copy(alpha = 0.8f))
                                Spacer(Modifier.width(8.dp))
                                Text(if (expanded) "⌄" else "›", color = RT.TextSecondary.copy(alpha = 0.6f), fontSize = (18 * fontScale).sp)
                            }
                            if (expanded) {
                                items.forEach { summary ->
                                    Box(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 5.dp)) {
                                        ScenarioCard(summary, fontScale, showDate = false,
                                            onClick = { if (!busy) roleDialogFor = summary },
                                            onLongClick = { menuScene = summary })
                                    }
                                }
                                Spacer(Modifier.height(6.dp))
                            }
                        }
                    }
                }
            } else {
                // 今天：从同一份列表里按本地日期筛出今天的场景，平铺展示
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    items(todayItems, key = { it.sceneId }) { summary ->
                        ScenarioCard(summary, fontScale, showDate = false,
                            onClick = { if (!busy) roleDialogFor = summary },
                            onLongClick = { menuScene = summary })
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
                .clickable(enabled = !busy) { model.toggleRecording() },
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

    // 长按场景卡：开始对话 / 删除
    menuScene?.let { summary ->
        AlertDialog(
            onDismissRequest = { menuScene = null },
            title = { Text(summary.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            text = {
                Column {
                    OutlinedButton(
                        onClick = { menuScene = null; roleDialogFor = summary },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("开始对话") }
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(
                        onClick = { val s = summary; menuScene = null; deleteScene = s },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("删除场景", color = Color(0xFFE03131)) }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { menuScene = null }) { Text("取消") } },
        )
    }

    // 删除确认
    deleteScene?.let { summary ->
        AlertDialog(
            onDismissRequest = { deleteScene = null },
            title = { Text("删除场景") },
            text = { Text("删除「${summary.title}」？删除后将无法恢复。") },
            confirmButton = {
                TextButton(onClick = { val id = summary.sceneId; deleteScene = null; model.deleteScenario(id) }) {
                    Text("删除", color = Color(0xFFE03131))
                }
            },
            dismissButton = { TextButton(onClick = { deleteScene = null }) { Text("取消") } },
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
    val user by model.user.collectAsState()
    if (pending == null) return

    var conversation by remember { mutableStateOf("manual") }   // 默认手工触发式
    var guidance by remember { mutableStateOf("realtime") }
    var rememberConv by remember { mutableStateOf(false) }
    var rememberGuid by remember { mutableStateOf(false) }
    // 语音模型对话仅高级会员可选
    val convOptions = buildList {
        if (user?.planTier == "premium") add("voice" to "语音模型")
        add("immersive" to "沉浸式")
        add("manual" to "手工触发")
    }

    AlertDialog(
        onDismissRequest = { model.cancelPendingPractice() },
        title = { Text("开始练习") },
        text = {
            Column {
                if (convPref == "ask") {
                    Text("对话方式", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = RT.TextPrimary)
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        convOptions.forEach { (k, l) ->
                            OutlinedButton(
                                onClick = { conversation = k },
                                modifier = Modifier.weight(1f),
                                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 2.dp, vertical = 8.dp),
                                border = androidx.compose.foundation.BorderStroke(1.dp, if (conversation == k) RT.Accent else RT.Hairline),
                            ) { Text(l, fontSize = 13.sp, color = if (conversation == k) RT.Accent else RT.TextSecondary) }
                        }
                    }
                    if (conversation == "voice") {
                        Spacer(Modifier.height(4.dp))
                        Text("与实时语音大模型直接语音对话，结束后给出评分。", fontSize = 11.sp, color = RT.TextSecondary)
                    }
                    CheckRow(rememberConv) { rememberConv = it }
                    Spacer(Modifier.height(12.dp))
                }
                // 语音模型对话不走逐句文字指导，故选它时不再询问指导方式
                if (guidPref == "ask" && conversation != "voice") {
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
                // 非 ask 时按保存的偏好（含 voice），由 VM 负责把 voice 解析为高级会员专属
                val conv = if (convPref == "ask") conversation else convPref
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
