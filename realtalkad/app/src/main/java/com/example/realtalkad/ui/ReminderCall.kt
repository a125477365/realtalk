package com.example.realtalkad.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.realtalkad.AppViewModel
import com.example.realtalkad.data.ScenarioSummary

/**
 * 学习提醒「私教来电」：仿即时通讯来电界面。
 * 响铃 → 接听后私教语音询问是否现在练习新场景；「现在练习」走与点场景卡相同的流程，
 * 「暂不/挂断」后该场景不再来电（后端幂等记录）。
 */
@Composable
fun ReminderCallScreen(model: AppViewModel, scenario: ScenarioSummary) {
    var answered by remember { mutableStateOf(false) }
    val fontScale = model.fontScale.value

    Box(
        Modifier.fillMaxSize().background(
            Brush.verticalGradient(listOf(Color(0xFF0D1712), Color(0xFF080D1A)))
        ),
    ) {
        Column(
            Modifier.fillMaxSize().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(110.dp))
            Box(
                Modifier.size(116.dp).background(RT.BrandBrush, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Text("🎓", fontSize = 44.sp) }
            Spacer(Modifier.height(18.dp))
            Text("AI英语私教", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (24 * fontScale).sp)
            Spacer(Modifier.height(8.dp))
            Text(
                if (answered) "有一个新场景还没练习：" else "邀请你练习新场景…",
                color = Color.White.copy(alpha = 0.6f), fontSize = (14 * fontScale).sp,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "《${scenario.title}》",
                color = Color.White.copy(alpha = 0.92f), fontWeight = FontWeight.SemiBold,
                fontSize = (18 * fontScale).sp, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.weight(1f))

            if (!answered) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(
                            Modifier.size(72.dp).background(Color(0xFFE03131), CircleShape)
                                .clickable { model.declineReminder() },
                            contentAlignment = Alignment.Center,
                        ) { Text("✕", color = Color.White, fontSize = 26.sp) }
                        Spacer(Modifier.height(8.dp))
                        Text("挂断", color = Color.White.copy(alpha = 0.6f), fontSize = (13 * fontScale).sp)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(
                            Modifier.size(72.dp).background(RT.Success, CircleShape)
                                .clickable {
                                    answered = true
                                    // 接听后私教语音询问（动态内容不入缓存）
                                    model.voice.speak("Hi! 我看到你有一个新的场景《${scenario.title}》还没练习，现在有时间练一练吗？", cache = false)
                                },
                            contentAlignment = Alignment.Center,
                        ) { Text("☎", color = Color.White, fontSize = 26.sp) }
                        Spacer(Modifier.height(8.dp))
                        Text("接听", color = Color.White.copy(alpha = 0.6f), fontSize = (13 * fontScale).sp)
                    }
                }
            } else {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(
                        Modifier.fillMaxWidth().background(RT.Success, RoundedCornerShape(16.dp))
                            .clickable { model.voice.stop(); model.acceptReminder() }
                            .padding(vertical = 15.dp),
                        contentAlignment = Alignment.Center,
                    ) { Text("现在练习", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (17 * fontScale).sp) }
                    Box(
                        Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.12f), RoundedCornerShape(16.dp))
                            .clickable { model.voice.stop(); model.declineReminder() }
                            .padding(vertical = 13.dp),
                        contentAlignment = Alignment.Center,
                    ) { Text("暂不练习（之后手动进入）", color = Color.White.copy(alpha = 0.75f), fontSize = (15 * fontScale).sp) }
                }
            }
            Spacer(Modifier.height(64.dp))
        }
    }
}
