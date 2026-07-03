package com.example.realtalkad.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
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
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.ble.RecorderBleClient
import com.example.realtalkad.data.PlanItem
import java.io.File

/* 账户面板：会员卡 / 套餐 / 充值 / 上传录音 / 账单 / 退出 */

private fun money(cents: Int) = "¥%.2f".format(cents / 100.0)

@Composable
fun AccountSheet(model: AppViewModel) {
    val user by model.user.collectAsState()
    val billing by model.billing.collectAsState()
    val status by model.statusMessage.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    var showUpload by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showMembership by remember { mutableStateOf(false) }
    var showMembershipPremiumOnly by remember { mutableStateOf(false) }
    var showTickets by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { model.refreshBilling(); model.loadPlans() }

    if (showUpload) {
        UploadSheetContent(model) { showUpload = false }
        return
    }
    if (showSettings) {
        SettingsSheetContent(model) { showSettings = false }
        return
    }
    if (showMembership) {
        MembershipSheetContent(model, premiumOnly = showMembershipPremiumOnly) { showMembership = false; showMembershipPremiumOnly = false }
        return
    }
    if (showTickets) {
        TicketsSheetContent(model) { showTickets = false }
        return
    }

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        // 会员卡：品牌渐变 Hero，白色文字
        item {
            Column(
                Modifier.fillMaxWidth()
                    .background(RT.BrandBrush, RoundedCornerShape(16.dp))
                    .padding(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(user?.displayName ?: "微信用户", fontWeight = FontWeight.SemiBold, color = Color.White)
                            Spacer(Modifier.width(8.dp))
                            Text(
                                user?.tierName ?: "",
                                fontSize = (10 * fontScale).sp, fontWeight = FontWeight.Bold,
                                color = Color.White,
                                modifier = Modifier
                                    .background(Color.White.copy(alpha = 0.22f), RoundedCornerShape(99.dp))
                                    .padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                        user?.planExpiresAt?.let {
                            Text("有效期至 ${it.take(10)}", fontSize = (11 * fontScale).sp, color = Color.White.copy(alpha = 0.85f))
                        }
                    }
                }
                // 账户不显示余额；用量以百分比展示（不暴露金额，避免「月费一半」的疑惑）
                billing?.usage?.let { usage ->
                    Spacer(Modifier.height(10.dp))
                    Text(
                        (if (usage.isMember) "本月额度用量 " else "今日免费用量 ") + "${usage.usagePercent.toInt()}%" +
                            if (usage.overBudget) (if (usage.isMember) "（已用完，下月恢复）" else "（已用完，升级解锁更多）") else "",
                        fontSize = (11 * fontScale).sp,
                        color = Color.White.copy(alpha = if (usage.overBudget) 1f else 0.85f),
                    )
                    Spacer(Modifier.height(5.dp))
                    LinearProgressIndicator(
                        progress = { (usage.usagePercent.toFloat() / 100f).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth(),
                        color = Color.White,
                        trackColor = Color.White.copy(alpha = 0.3f),
                    )
                }
            }
        }

        // 升级 / 续费会员入口
        item {
            SettingsEntry(
                title = when (user?.planTier) {
                    "premium" -> "续费高级会员"
                    "basic" -> "续费 / 升级会员"
                    else -> "升级会员"
                },
                subtitle = if (user?.planTier == "premium") "延长高级会员有效期" else "解锁更多每日用量与高级功能",
                modifier = Modifier.fillMaxWidth(),
                fontScale = fontScale,
            ) { showMembershipPremiumOnly = false; showMembership = true }
        }

        item {
            SettingsEntry(
                title = "设置",
                subtitle = "外观、字体、字幕、自动采集时段",
                modifier = Modifier.fillMaxWidth(),
                fontScale = fontScale,
            ) { showSettings = true }
        }

        // 高级会员专属功能（上传录音 + 沉浸式直连模型对话练习）
        item {
            Column(Modifier.fillMaxWidth()) {
                Text("高级会员专属", fontSize = (12 * fontScale).sp, fontWeight = FontWeight.SemiBold,
                    color = RT.TextSecondary, modifier = Modifier.padding(bottom = 8.dp))
                Column(
                    Modifier.fillMaxWidth()
                        .background(RT.Surface, RoundedCornerShape(16.dp))
                        .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp)),
                ) {
                    // 上传已有语音文件生成场景
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable {
                                if (user?.planTier == "premium") showUpload = true
                                else { showMembershipPremiumOnly = true; showMembership = true }
                            }
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("上传已有语音文件生成场景", fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp)
                            Text(
                                if (user?.planTier == "premium") "支持 mp3 / wav / m4a · 最长 6 小时"
                                else "高级会员专属，升级后可用",
                                fontSize = (11 * fontScale).sp, color = RT.TextSecondary,
                            )
                        }
                        Text(
                            if (user?.planTier == "premium") "›" else "🔒",
                            fontSize = (16 * fontScale).sp,
                            color = if (user?.planTier == "premium") RT.TextSecondary else Color(0xFFF59E0B),
                        )
                    }
                    // 分隔线
                    Spacer(Modifier.height(1.dp).fillMaxWidth().padding(start = 44.dp).background(RT.Hairline))
                    // 沉浸式直连模型对话练习
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable {
                                if (user?.planTier == "premium") { showSettings = true }
                                else { showMembershipPremiumOnly = true; showMembership = true }
                            }
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("语音模型对话练习", fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp)
                            Text(
                                if (user?.planTier == "premium") "在「设置 · 对话方式」选「语音模型对话」，直接与语音大模型语音对话"
                                else "高级会员专属，升级后可用",
                                fontSize = (11 * fontScale).sp, color = RT.TextSecondary,
                            )
                        }
                        Text(
                            if (user?.planTier == "premium") "›" else "🔒",
                            fontSize = (16 * fontScale).sp,
                            color = if (user?.planTier == "premium") RT.TextSecondary else Color(0xFFF59E0B),
                        )
                    }
                }
            }
        }

        item {
            SettingsEntry(
                title = "客服工单",
                subtitle = "反馈问题、申请退款等",
                modifier = Modifier.fillMaxWidth(),
                fontScale = fontScale,
            ) { showTickets = true }
        }

        // 账单
        item { Text("账单", fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp) }
        items(billing?.ledger.orEmpty(), key = { it.id }) { item ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(item.title, fontSize = (13 * fontScale).sp)
                    Text(item.createdAt.take(16).replace("T", " "), fontSize = (10 * fontScale).sp, color = RT.TextSecondary)
                }
                Text(
                    (if (item.amountCents >= 0) "+" else "") + money(item.amountCents),
                    fontSize = (13 * fontScale).sp,
                    fontWeight = FontWeight.Medium,
                    color = if (item.amountCents >= 0) Color(0xFF16A34A) else Color(0xFFE03131),
                )
            }
        }

        // 账号信息（登录方式 + 退出登录，放在底部）
        item {
            Column(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(16.dp))
                    .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
                    .padding(16.dp),
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("登录方式", fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
                    Spacer(Modifier.weight(1f))
                    Text(user?.displayName ?: "微信用户", fontSize = (13 * fontScale).sp, color = RT.TextSecondary)
                }
                Spacer(Modifier.height(1.dp).fillMaxWidth().background(RT.Hairline))
                TextButton(onClick = { model.logout() }) { Text("退出登录", color = Color.Red) }
            }
        }

        item {
            if (status.isNotBlank()) Text(status, fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
        }
    }
}

@Composable
private fun SettingsEntry(title: String, subtitle: String, modifier: Modifier = Modifier, fontScale: Float = 1f, onClick: () -> Unit) {
    Column(
        modifier
            .background(RT.Surface, RoundedCornerShape(16.dp))
            .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
            .clickable { onClick() }
            .padding(14.dp),
    ) {
        Text(title, fontWeight = FontWeight.SemiBold, fontSize = (14 * fontScale).sp, color = RT.TextPrimary)
        Spacer(Modifier.height(3.dp))
        Text(subtitle, fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
    }
}

/** 会员：先选套餐，再弹出微信/支付宝付款方式确认。按档位展示可选套餐。 */
@Composable
private fun MembershipSheetContent(model: AppViewModel, premiumOnly: Boolean = false, onBack: () -> Unit) {
    val order by model.rechargeOrder.collectAsState()
    val status by model.statusMessage.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val user by model.user.collectAsState()
    var selectedPlan by remember { mutableStateOf<PlanItem?>(null) }
    val displayPlans = if (premiumOnly) model.availablePlans().filter { it.tier == "premium" } else model.availablePlans()

    fun actionLabel(plan: PlanItem): String {
        val tier = user?.planTier ?: "free"
        return when {
            plan.tier == tier -> "续费"
            plan.tier == "premium" && tier == "basic" -> "升级"
            else -> "开通"
        }
    }

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ 返回") }
                Text("会员", fontWeight = FontWeight.SemiBold)
            }
        }
        items(displayPlans, key = { it.id }) { plan ->
            Row(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(14.dp))
                    .border(
                        1.dp,
                        if (plan.tier == "premium") Color(0xFFF59E0B).copy(alpha = 0.5f) else RT.Hairline,
                        RoundedCornerShape(14.dp),
                    )
                    .clickable { selectedPlan = plan }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(plan.title, fontWeight = FontWeight.SemiBold, color = if (plan.tier == "premium") Color(0xFFB45309) else RT.Accent)
                        Text(
                            actionLabel(plan),
                            fontSize = (10 * fontScale).sp, fontWeight = FontWeight.Bold,
                            color = if (plan.tier == "premium") Color(0xFFB45309) else RT.Accent,
                            modifier = Modifier.background(
                                (if (plan.tier == "premium") Color(0xFFF59E0B) else RT.Accent).copy(alpha = 0.15f),
                                RoundedCornerShape(99.dp),
                            ).padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    Text(
                        if (plan.months > 1) "每月 ${money(plan.perMonthCents)}" else "按月",
                        fontSize = (11 * fontScale).sp, color = RT.TextSecondary,
                    )
                }
                Text(money(plan.priceCents), fontWeight = FontWeight.SemiBold)
                Text(" ›", color = RT.TextSecondary)
            }
        }
        order?.let { o ->
            item {
                Column(
                    Modifier.fillMaxWidth()
                        .background(RT.Surface, RoundedCornerShape(16.dp))
                        .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
                        .padding(16.dp),
                ) {
                    Text("待支付", fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    Text(o.message, fontSize = (13 * fontScale).sp)
                    o.receiverAccount?.let { Text("收款账号：$it", fontSize = (12 * fontScale).sp, color = RT.TextSecondary) }
                    Text("订单号：${o.orderId}", fontSize = (10 * fontScale).sp, color = RT.TextSecondary)
                    Spacer(Modifier.height(8.dp))
                    Button(
                        onClick = { model.confirmRecharge() },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = RT.Accent),
                    ) { Text("我已完成支付") }
                }
            }
        }
        item {
            if (status.isNotBlank()) Text(status, fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
        }
    }

    // 选中套餐后弹出付款方式
    selectedPlan?.let { plan ->
        var method by remember(plan.id) { mutableStateOf("wechat") }
        AlertDialog(
            onDismissRequest = { selectedPlan = null },
            title = { Text(plan.title) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(money(plan.priceCents), fontWeight = FontWeight.Bold, fontSize = (18 * fontScale).sp)
                    Text("选择付款方式", fontSize = (12 * fontScale).sp, color = RT.TextSecondary)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("wechat" to "微信支付", "alipay" to "支付宝").forEach { (key, label) ->
                            OutlinedButton(
                                onClick = { method = key },
                                modifier = Modifier.weight(1f),
                                border = androidx.compose.foundation.BorderStroke(1.dp, if (method == key) RT.Accent else RT.Hairline),
                            ) { Text(label, color = if (method == key) RT.Accent else RT.TextSecondary) }
                        }
                    }
                }
            },
            confirmButton = {
                Button(onClick = { model.subscribe(plan.id, method); selectedPlan = null }) { Text("确认开通") }
            },
            dismissButton = { TextButton(onClick = { selectedPlan = null }) { Text("取消") } },
        )
    }
}

/** 客服工单：提交 + 查看我的工单与客服回复。 */
@Composable
private fun TicketsSheetContent(model: AppViewModel, onBack: () -> Unit) {
    val tickets by model.myTickets.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    var category by remember { mutableStateOf("feedback") }
    var subject by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var images by remember { mutableStateOf(listOf<String>()) }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia(4)
    ) { uris ->
        if (uris.isNotEmpty()) scope.launch {
            val urls = withContext(kotlinx.coroutines.Dispatchers.IO) { uris.mapNotNull { uriToDataUrl(ctx, it) } }
            images = urls
        }
    }

    LaunchedEffect(Unit) { model.loadMyTickets() }

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ 返回") }
                Text("客服工单", fontWeight = FontWeight.SemiBold)
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("feedback" to "反馈", "refund" to "退款", "bug" to "问题", "other" to "其他").forEach { (key, label) ->
                    OutlinedButton(
                        onClick = { category = key },
                        modifier = Modifier.weight(1f),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 2.dp, vertical = 8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (category == key) RT.Accent else RT.Hairline),
                    ) { Text(label, fontSize = (12 * fontScale).sp, color = if (category == key) RT.Accent else RT.TextSecondary) }
                }
            }
        }
        item { OutlinedTextField(value = subject, onValueChange = { subject = it }, label = { Text("标题") }, modifier = Modifier.fillMaxWidth(), singleLine = true) }
        item { OutlinedTextField(value = body, onValueChange = { body = it }, label = { Text("详细描述") }, modifier = Modifier.fillMaxWidth().height(110.dp)) }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = {
                    picker.launch(androidx.activity.result.PickVisualMediaRequest(
                        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly))
                }) { Text(if (images.isEmpty()) "添加截图（最多 4 张）" else "已选 ${images.size} 张") }
                Spacer(Modifier.width(10.dp))
                images.forEach { url ->
                    dataUrlToBitmap(url)?.let { bmp ->
                        androidx.compose.foundation.Image(
                            bitmap = bmp.asImageBitmap(), contentDescription = null,
                            modifier = Modifier.size(44.dp), contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                }
            }
        }
        item {
            Button(
                onClick = {
                    model.submitSupportTicket(category, subject.trim(), body.trim(), images) {
                        subject = ""; body = ""; images = emptyList()
                    }
                },
                enabled = subject.isNotBlank() && body.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = RT.Accent),
            ) { Text("提交工单") }
        }
        if (tickets.isNotEmpty()) {
            item { Text("我的工单", fontWeight = FontWeight.SemiBold) }
            items(tickets, key = { it.id }) { t ->
                Column(
                    Modifier.fillMaxWidth().background(RT.Surface, RoundedCornerShape(12.dp))
                        .border(1.dp, RT.Hairline, RoundedCornerShape(12.dp)).padding(12.dp),
                ) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(t.subject, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Text(t.statusText, fontSize = (11 * fontScale).sp, color = if (t.status == "resolved") Color(0xFF16A34A) else Color(0xFFD97706))
                    }
                    Text(t.body, fontSize = (13 * fontScale).sp, color = RT.TextSecondary)
                    if (t.images.isNotEmpty()) {
                        Spacer(Modifier.height(4.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            t.images.forEach { url ->
                                dataUrlToBitmap(url)?.let { bmp ->
                                    androidx.compose.foundation.Image(
                                        bitmap = bmp.asImageBitmap(), contentDescription = null,
                                        modifier = Modifier.size(48.dp), contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                    )
                                }
                            }
                        }
                    }
                    if (!t.adminReply.isNullOrBlank()) {
                        Text("客服回复：${t.adminReply}", fontSize = (13 * fontScale).sp, color = RT.Accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsSheetContent(model: AppViewModel, onBack: () -> Unit) {
    val showSubtitles by model.showSubtitles.collectAsState()
    val showChineseHint by model.showChineseHint.collectAsState()
    val guidancePref by model.guidancePreference.collectAsState()
    val conversationPref by model.conversationPreference.collectAsState()
    val user by model.user.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val autoEnabled by model.autoCaptureEnabled.collectAsState()
    val windows by model.captureWindows.collectAsState()
    val appearance by model.appearance.collectAsState()
    val ttsConfigured by model.ttsConfigured.collectAsState()
    val ttsVoices by model.ttsVoices.collectAsState()
    val ttsVoice by model.ttsCurrentVoice.collectAsState()
    LaunchedEffect(Unit) { model.loadTtsVoices() }

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ 返回") }
                Text("设置", fontWeight = FontWeight.SemiBold)
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("显示双语字幕", fontWeight = FontWeight.SemiBold)
                    Text("对话字幕中显示中文辅助内容", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
                }
                Switch(checked = showSubtitles, onCheckedChange = { model.setShowSubtitles(it) })
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("中文提示", fontWeight = FontWeight.SemiBold)
                    Text("开：轮到你说时显示中文、私教每句附中文翻译；关：不显示中文", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
                }
                Switch(checked = showChineseHint, onCheckedChange = { model.setShowChineseHint(it) })
            }
        }
        if (ttsConfigured && ttsVoices.isNotEmpty()) {
            item {
                Text("AI 朗读音色", fontWeight = FontWeight.SemiBold)
                Text("练习时朗读 AI 台词的声音（由后端语音合成）。", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
                Spacer(Modifier.height(8.dp))
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ttsVoices.chunked(3).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                            row.forEach { v ->
                                OutlinedButton(
                                    onClick = { model.setTtsVoice(v) },
                                    modifier = Modifier.weight(1f),
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp, vertical = 6.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, if (ttsVoice == v) RT.Accent else RT.Hairline),
                                ) { Text(v, fontSize = (12 * fontScale).sp, color = if (ttsVoice == v) RT.Accent else RT.TextSecondary) }
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
        }
        item {
            Text("对话方式", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            // 语音模型对话仅高级会员可选
            val convOptions = buildList {
                add("ask" to "每次询问")
                if (user?.planTier == "premium") add("voice" to "语音模型")
                add("immersive" to "沉浸式")
                add("manual" to "手工触发")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                convOptions.forEach { (key, label) ->
                    OutlinedButton(
                        onClick = { model.setConversationPreference(key) },
                        modifier = Modifier.weight(1f),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 2.dp, vertical = 8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (conversationPref == key) RT.Accent else RT.Hairline),
                    ) { Text(label, fontSize = (11 * fontScale).sp, color = if (conversationPref == key) RT.Accent else RT.TextSecondary) }
                }
            }
            Spacer(Modifier.height(10.dp))
            Text("AI 指导方式", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("realtime" to "实时指导", "final" to "结束后", "ask" to "每次询问").forEach { (key, label) ->
                    OutlinedButton(
                        onClick = { model.setGuidancePreference(key) },
                        modifier = Modifier.weight(1f),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp, vertical = 8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (guidancePref == key) RT.Accent else RT.Hairline),
                    ) { Text(label, fontSize = (12 * fontScale).sp, color = if (guidancePref == key) RT.Accent else RT.TextSecondary) }
                }
            }
            Spacer(Modifier.height(4.dp))
            Text(
                if (user?.planTier == "premium")
                    "对话中不可切换。语音模型对话：与实时语音大模型直接语音对话，结束给出评分。手工触发式：长按说话、左滑取消、右滑发送。"
                else
                    "对话中不可切换。手工触发式：长按说话、左滑取消、右滑发送。语音模型对话为高级会员专属。",
                fontSize = (11 * fontScale).sp, color = RT.TextSecondary,
            )
        }
        item {
            Text("外观主题", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色").forEach { (key, label) ->
                    OutlinedButton(
                        onClick = { model.setAppearance(key) },
                        modifier = Modifier.weight(1f),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp, vertical = 8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (appearance == key) RT.Accent else RT.Hairline),
                    ) { Text(label, fontSize = (12 * fontScale).sp, color = if (appearance == key) RT.Accent else RT.TextSecondary) }
                }
            }
        }
        item {
            Text("字体大小 ${"%.0f".format(fontScale * 100)}%", fontWeight = FontWeight.SemiBold)
            Slider(value = fontScale, onValueChange = { model.setFontScale(it) }, valueRange = 0.85f..1.35f, steps = 9)
        }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("按时段自动录音", fontWeight = FontWeight.SemiBold)
                    Text("后台录音需系统允许麦克风与后台运行", fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
                }
                Switch(checked = autoEnabled, onCheckedChange = { model.setAutoCaptureEnabled(it) })
            }
        }
        if (autoEnabled) {
            itemsIndexed(windows) { index, window ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TimeField("开始", window.first, Modifier.weight(1f), fontScale = fontScale) {
                        model.setCaptureWindow(index, it, window.second)
                    }
                    TimeField("结束", window.second, Modifier.weight(1f), fontScale = fontScale) {
                        model.setCaptureWindow(index, window.first, it)
                    }
                    TextButton(onClick = { model.removeCaptureWindow(index) }) { Text("删除", color = Color.Red) }
                }
            }
            item {
                TextButton(onClick = { model.addCaptureWindow() }) { Text("+ 添加时段") }
            }
        }
    }
}

/** 时间选择：点击弹出系统风格时钟选择器，输出 HH:mm，避免手输无效字符串。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeField(label: String, value: String, modifier: Modifier = Modifier, fontScale: Float = 1f, onChange: (String) -> Unit) {
    var showDialog by remember { mutableStateOf(false) }
    val parts = value.split(":")
    val hour = parts.getOrNull(0)?.toIntOrNull()?.coerceIn(0, 23) ?: 9
    val minute = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 59) ?: 0

    Column(
        modifier
            .background(RT.Surface, RoundedCornerShape(12.dp))
            .border(1.dp, RT.Hairline, RoundedCornerShape(12.dp))
            .clickable { showDialog = true }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Text(label, fontSize = (11 * fontScale).sp, color = RT.TextSecondary)
        Spacer(Modifier.height(2.dp))
        Text("%02d:%02d".format(hour, minute), fontWeight = FontWeight.SemiBold, fontSize = (18 * fontScale).sp, color = RT.TextPrimary)
    }

    if (showDialog) {
        val state = rememberTimePickerState(initialHour = hour, initialMinute = minute, is24Hour = true)
        AlertDialog(
            onDismissRequest = { showDialog = false },
            confirmButton = {
                TextButton(onClick = {
                    onChange("%02d:%02d".format(state.hour, state.minute))
                    showDialog = false
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { showDialog = false }) { Text("取消") } },
            title = { Text("选择${label}时间") },
            text = { TimePicker(state = state) },
        )
    }
}

/* ---------------- 上传录音（本地文件 / 蓝牙录音笔） ---------------- */

@Composable
fun UploadSheetContent(model: AppViewModel, onBack: () -> Unit) {
    val context = LocalContext.current
    val jobs by model.audioJobs.collectAsState()
    val isUploading by model.isUploadingAudio.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val recorder = remember { RecorderBleClient(context) }
    val blePhase by recorder.phase.collectAsState()
    val bleFiles by recorder.files.collectAsState()

    LaunchedEffect(Unit) {
        model.loadAudioJobs()
        recorder.onFileDownloaded = { file -> model.uploadRecording(file) }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        // 把 SAF 内容拷到缓存目录后上传
        val name = uri.lastPathSegment?.substringAfterLast('/') ?: "recording.mp3"
        val target = File(context.cacheDir, name.ifBlank { "recording.mp3" })
        context.contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        model.uploadRecording(target)
    }

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ 返回") }
                Text("上传语音文件", fontWeight = FontWeight.SemiBold)
            }
        }
        item {
            Button(
                onClick = { picker.launch("audio/*") },
                enabled = !isUploading,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = RT.Accent),
            ) { Text("从手机选择音频文件") }
        }
        item {
            OutlinedButton(
                onClick = { recorder.startScan() },
                enabled = !isUploading,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    when (val p = blePhase) {
                        is RecorderBleClient.Phase.Scanning -> "正在搜索录音笔…"
                        is RecorderBleClient.Phase.Connecting -> "正在连接…"
                        is RecorderBleClient.Phase.Ready -> "已连接录音笔"
                        is RecorderBleClient.Phase.Downloading -> "读取中 ${(p.progress * 100).toInt()}%"
                        is RecorderBleClient.Phase.Failed -> "连接失败：${p.reason}"
                        else -> "连接蓝牙录音笔"
                    },
                )
            }
        }
        if (bleFiles.isNotEmpty()) {
            item { Text("录音笔中的文件", fontSize = (13 * fontScale).sp, fontWeight = FontWeight.SemiBold) }
            items(bleFiles, key = { it.name }) { file ->
                Row(
                    Modifier.fillMaxWidth()
                        .background(RT.Surface, RoundedCornerShape(12.dp))
                        .border(1.dp, RT.Hairline, RoundedCornerShape(12.dp))
                        .clickable { recorder.download(file) }
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(file.name, fontSize = (13 * fontScale).sp)
                        Text("%.1f MB".format(file.sizeBytes / 1024.0 / 1024.0), fontSize = (10 * fontScale).sp, color = RT.TextSecondary)
                    }
                    Text("下载并上传", fontSize = (12 * fontScale).sp, color = RT.Accent)
                }
            }
        }
        if (isUploading) {
            item { Text("正在上传并转写…", fontSize = (13 * fontScale).sp, color = RT.TextSecondary) }
        }
        if (jobs.isNotEmpty()) {
            item { Text("处理记录", fontSize = (13 * fontScale).sp, fontWeight = FontWeight.SemiBold) }
            items(jobs, key = { it.id }) { job ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(job.filename, fontSize = (13 * fontScale).sp, maxLines = 1)
                        Text(job.createdAt.take(16).replace("T", " "), fontSize = (10 * fontScale).sp, color = RT.TextSecondary)
                    }
                    Text(
                        job.statusText, fontSize = (12 * fontScale).sp, fontWeight = FontWeight.SemiBold,
                        color = when (job.status) {
                            "completed" -> Color(0xFF16A34A)
                            "failed" -> Color.Red
                            else -> Color(0xFFD97706)
                        },
                    )
                }
            }
        }
    }
}

/** 把图片 Uri 压缩为不超过 1280px 的 JPEG，再转成 base64 data URL（控制上传体积）。 */
private fun uriToDataUrl(context: android.content.Context, uri: Uri, maxDim: Int = 1280, quality: Int = 60): String? = try {
    val src = context.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it) }
    if (src == null) null else {
        val scale = minOf(1f, maxDim.toFloat() / maxOf(src.width, src.height, 1))
        val bmp = if (scale < 1f)
            android.graphics.Bitmap.createScaledBitmap(src, (src.width * scale).toInt(), (src.height * scale).toInt(), true)
        else src
        val baos = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, baos)
        "data:image/jpeg;base64," + android.util.Base64.encodeToString(baos.toByteArray(), android.util.Base64.NO_WRAP)
    }
} catch (e: Exception) { null }

/** 把 base64 data URL 解回 Bitmap 用于展示。 */
private fun dataUrlToBitmap(url: String): android.graphics.Bitmap? = try {
    val b64 = url.substringAfter(",", "")
    val bytes = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
} catch (e: Exception) { null }
