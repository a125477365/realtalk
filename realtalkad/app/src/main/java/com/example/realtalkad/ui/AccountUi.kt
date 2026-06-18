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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.ble.RecorderBleClient
import java.io.File

/* 账户面板：会员卡 / 套餐 / 充值 / 上传录音 / 账单 / 退出 */

private fun money(cents: Int) = "¥%.2f".format(cents / 100.0)

@Composable
fun AccountSheet(model: AppViewModel) {
    val user by model.user.collectAsState()
    val billing by model.billing.collectAsState()
    val status by model.statusMessage.collectAsState()
    var method by remember { mutableStateOf("wechat") }
    var showUpload by remember { mutableStateOf(false) }
    var showBilling by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { model.refreshBilling(); model.loadPlans() }

    if (showUpload) {
        UploadSheetContent(model) { showUpload = false }
        return
    }
    if (showBilling) {
        BillingSheetContent(model, method, { method = it }) { showBilling = false }
        return
    }
    if (showSettings) {
        SettingsSheetContent(model) { showSettings = false }
        return
    }

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        // 会员卡
        item {
            Column(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(16.dp))
                    .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
                    .padding(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(user?.displayName ?: "微信用户", fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.width(8.dp))
                            Text(
                                user?.tierName ?: "",
                                fontSize = 10.sp, fontWeight = FontWeight.Bold,
                                color = if (user?.planTier == "premium") Color(0xFFB45309) else RT.Accent,
                                modifier = Modifier
                                    .background(
                                        (if (user?.planTier == "premium") Color(0xFFFDE68A) else RT.Accent.copy(alpha = 0.12f)),
                                        RoundedCornerShape(99.dp),
                                    )
                                    .padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                        user?.planExpiresAt?.let {
                            Text("有效期至 ${it.take(10)}", fontSize = 11.sp, color = RT.TextSecondary)
                        }
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text(money(user?.balanceCents ?: 0), fontWeight = FontWeight.Bold, fontSize = 19.sp)
                        Text("余额", fontSize = 10.sp, color = RT.TextSecondary)
                    }
                }
                billing?.usage?.let { usage ->
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "今日 AI 用量 ${usage.todayTokens} / ${usage.dailyLimit} tokens" +
                            if (usage.overLimit) "（已达上限，明天恢复）" else "",
                        fontSize = 11.sp,
                        color = if (usage.overLimit) Color.Red else RT.TextSecondary,
                    )
                    Spacer(Modifier.height(5.dp))
                    LinearProgressIndicator(
                        progress = {
                            (usage.todayTokens.toFloat() / maxOf(1, usage.dailyLimit)).coerceAtMost(1f)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        color = if (usage.overLimit) Color.Red else RT.Accent,
                    )
                }
            }
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SettingsEntry(
                    title = "设置",
                    subtitle = "字体、字幕、自动录音",
                    modifier = Modifier.weight(1f),
                ) { showSettings = true }
                SettingsEntry(
                    title = "会员与充值",
                    subtitle = "套餐、支付订单",
                    modifier = Modifier.weight(1f),
                ) { showBilling = true }
            }
        }

        // 上传录音入口
        item {
            Row(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(16.dp))
                    .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
                    .clickable(enabled = user?.planTier == "premium") { showUpload = true }
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("上传录音生成场景", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    Text(
                        if (user?.planTier == "premium") "本地文件或蓝牙录音笔 · 最长 6 小时 / 300MB"
                        else "高级会员专属功能，升级后可用",
                        fontSize = 11.sp, color = RT.TextSecondary,
                    )
                }
                Text(if (user?.planTier == "premium") "›" else "🔒", fontSize = 16.sp, color = RT.TextSecondary)
            }
        }

        // 账单
        item { Text("账单", fontWeight = FontWeight.SemiBold, fontSize = 14.sp) }
        items(billing?.ledger.orEmpty(), key = { it.id }) { item ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(item.title, fontSize = 13.sp)
                    Text(item.createdAt.take(16).replace("T", " "), fontSize = 10.sp, color = RT.TextSecondary)
                }
                Text(
                    (if (item.amountCents >= 0) "+" else "") + money(item.amountCents),
                    fontSize = 13.sp, fontWeight = FontWeight.Medium,
                    color = if (item.amountCents >= 0) Color(0xFF16A34A) else RT.TextPrimary,
                )
            }
        }

        item {
            if (status.isNotBlank()) Text(status, fontSize = 12.sp, color = RT.TextSecondary)
            TextButton(onClick = { model.logout() }) { Text("退出登录", color = Color.Red) }
        }
    }
}

@Composable
private fun SettingsEntry(title: String, subtitle: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(
        modifier
            .background(RT.Surface, RoundedCornerShape(16.dp))
            .border(1.dp, RT.Hairline, RoundedCornerShape(16.dp))
            .clickable { onClick() }
            .padding(14.dp),
    ) {
        Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = RT.TextPrimary)
        Spacer(Modifier.height(3.dp))
        Text(subtitle, fontSize = 11.sp, color = RT.TextSecondary)
    }
}

@Composable
private fun BillingSheetContent(
    model: AppViewModel,
    method: String,
    onMethodChange: (String) -> Unit,
    onBack: () -> Unit,
) {
    val plans by model.plans.collectAsState()
    val order by model.rechargeOrder.collectAsState()
    val status by model.statusMessage.collectAsState()

    LazyColumn(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ 返回") }
                Text("会员与充值", fontWeight = FontWeight.SemiBold)
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("wechat" to "微信支付", "alipay" to "支付宝").forEach { (key, label) ->
                    OutlinedButton(
                        onClick = { onMethodChange(key) },
                        modifier = Modifier.weight(1f),
                        border = androidx.compose.foundation.BorderStroke(
                            1.dp, if (method == key) RT.Accent else RT.Hairline,
                        ),
                    ) { Text(label, color = if (method == key) RT.Accent else RT.TextSecondary) }
                }
            }
        }
        items(plans, key = { it.id }) { plan ->
            Row(
                Modifier.fillMaxWidth()
                    .background(RT.Surface, RoundedCornerShape(14.dp))
                    .border(
                        1.dp,
                        if (plan.tier == "premium") Color(0xFFF59E0B).copy(alpha = 0.5f) else RT.Hairline,
                        RoundedCornerShape(14.dp),
                    )
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(plan.title, fontWeight = FontWeight.SemiBold, color = if (plan.tier == "premium") Color(0xFFB45309) else RT.Accent)
                    Text(
                        if (plan.months > 1) "每月 ${money(plan.perMonthCents)} · 共 ${money(plan.priceCents)}" else "每月 ${money(plan.perMonthCents)}",
                        fontSize = 11.sp,
                        color = RT.TextSecondary,
                    )
                }
                Button(
                    onClick = { model.subscribe(plan.id, method) },
                    colors = ButtonDefaults.buttonColors(containerColor = if (plan.tier == "premium") Color(0xFFF59E0B) else RT.Accent),
                ) { Text("开通") }
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
                    Text(o.message, fontSize = 13.sp)
                    o.receiverAccount?.let { Text("收款账号：$it", fontSize = 12.sp, color = RT.TextSecondary) }
                    Text("订单号：${o.orderId}", fontSize = 10.sp, color = RT.TextSecondary)
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
            if (status.isNotBlank()) Text(status, fontSize = 12.sp, color = RT.TextSecondary)
        }
    }
}

@Composable
private fun SettingsSheetContent(model: AppViewModel, onBack: () -> Unit) {
    val showSubtitles by model.showSubtitles.collectAsState()
    val guidanceMode by model.guidanceMode.collectAsState()
    val fontScale by model.fontScale.collectAsState()
    val autoEnabled by model.autoCaptureEnabled.collectAsState()
    val autoStart by model.autoCaptureStart.collectAsState()
    val autoEnd by model.autoCaptureEnd.collectAsState()

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
                    Text("对话字幕中显示中文辅助内容", fontSize = 11.sp, color = RT.TextSecondary)
                }
                Switch(checked = showSubtitles, onCheckedChange = { model.setShowSubtitles(it) })
            }
        }
        item {
            Text("默认指导方式", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("realtime" to "实时指导", "final" to "结束后指导").forEach { (key, label) ->
                    OutlinedButton(
                        onClick = { model.setGuidanceMode(key) },
                        modifier = Modifier.weight(1f),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (guidanceMode == key) RT.Accent else RT.Hairline),
                    ) { Text(label, color = if (guidanceMode == key) RT.Accent else RT.TextSecondary) }
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
                    Text("后台录音需系统允许麦克风与后台运行", fontSize = 11.sp, color = RT.TextSecondary)
                }
                Switch(checked = autoEnabled, onCheckedChange = { model.setAutoCaptureEnabled(it) })
            }
        }
        if (autoEnabled) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TextField(
                        value = autoStart,
                        onValueChange = { model.setAutoCaptureStart(it) },
                        label = { Text("开始") },
                        modifier = Modifier.weight(1f),
                    )
                    TextField(
                        value = autoEnd,
                        onValueChange = { model.setAutoCaptureEnd(it) },
                        label = { Text("结束") },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

/* ---------------- 上传录音（本地文件 / 蓝牙录音笔） ---------------- */

@Composable
fun UploadSheetContent(model: AppViewModel, onBack: () -> Unit) {
    val context = LocalContext.current
    val jobs by model.audioJobs.collectAsState()
    val isUploading by model.isUploadingAudio.collectAsState()
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
                Text("上传录音", fontWeight = FontWeight.SemiBold)
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
            item { Text("录音笔中的文件", fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
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
                        Text(file.name, fontSize = 13.sp)
                        Text("%.1f MB".format(file.sizeBytes / 1024.0 / 1024.0), fontSize = 10.sp, color = RT.TextSecondary)
                    }
                    Text("下载并上传", fontSize = 12.sp, color = RT.Accent)
                }
            }
        }
        if (isUploading) {
            item { Text("正在上传并转写…", fontSize = 13.sp, color = RT.TextSecondary) }
        }
        if (jobs.isNotEmpty()) {
            item { Text("处理记录", fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
            items(jobs, key = { it.id }) { job ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(job.filename, fontSize = 13.sp, maxLines = 1)
                        Text(job.createdAt.take(16).replace("T", " "), fontSize = 10.sp, color = RT.TextSecondary)
                    }
                    Text(
                        job.statusText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
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
