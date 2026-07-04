package com.example.realtalkad

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.example.realtalkad.data.ApiClient
import com.example.realtalkad.data.AuthStore
import java.util.concurrent.TimeUnit

/**
 * 学习提醒后台检查（类似 IM 的后台提醒能力）：WorkManager 周期调度（系统最小 15 分钟），
 * 跑与前台相同的「App 触发 + 后端综合裁决」；命中来电 → 发通知（后台无法直接弹全屏来电），
 * 点通知进 App 后前台 15 秒内会再判定一次并弹「私教来电」。
 */
class ReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val auth = AuthStore(applicationContext)
        if (!auth.reminderEnabled) return Result.success()
        val token = auth.token ?: return Result.success()

        // 时段/时间点门槛（与前台同逻辑；后台不知道 App 内忙碌状态，交由用户点通知后前台再确认）
        val cal = java.util.Calendar.getInstance()
        val nowMin = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        fun minuteOf(t: String): Int {
            val p = t.split(":"); return (p.getOrNull(0)?.toIntOrNull() ?: 0) * 60 + (p.getOrNull(1)?.toIntOrNull() ?: 0)
        }
        var inUserWindow: Boolean? = null
        if (auth.reminderMode == "smart") {
            val windows = auth.reminderWindows.split(";").filter { it.contains("-") }
                .map { val p = it.split("-"); p[0] to p[1] }
            if (windows.isNotEmpty()) {
                val inside = windows.any { (s, e) ->
                    val sm = minuteOf(s); val em = minuteOf(e)
                    if (sm <= em) nowMin in sm..em else (nowMin >= sm || nowMin <= em)
                }
                if (!inside) return Result.success()
                inUserWindow = true
            }
        } else {
            val hit = auth.reminderTimes.split(";").filter { it.isNotBlank() }
                .any { kotlin.math.abs(nowMin - minuteOf(it)) <= 8 }   // 后台 15 分钟粒度，放宽到 ±8 分钟
            if (!hit) return Result.success()
            inUserWindow = true
        }

        val api = ApiClient { auth.baseUrl }
        val resp = runCatching {
            api.reminderCheck(AppViewModel.buildReminderRequest(inUserWindow), token)
        }.getOrNull() ?: return Result.success()
        if (resp.decision == "call" && resp.scenario != null) {
            notifyCall(resp.scenario.title)
        }
        return Result.success()
    }

    private fun notifyCall(title: String) {
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel("reminder_call", "私教学习提醒", NotificationManager.IMPORTANCE_HIGH)
        )
        val intent = applicationContext.packageManager.getLaunchIntentForPackage(applicationContext.packageName)
        val pending = PendingIntent.getActivity(
            applicationContext, 0, intent ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(applicationContext, "reminder_call")
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle("AI英语私教 来电")
            .setContentText("邀请你练习新场景《$title》，点按接听")
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        runCatching { nm.notify(1001, notification) }   // 无通知权限时静默失败，前台路径仍可用
    }

    companion object {
        /** 开关打开时调度周期任务（系统最小间隔 15 分钟）；关闭时取消。 */
        fun schedule(context: Context, enabled: Boolean) {
            val wm = WorkManager.getInstance(context)
            if (!enabled) { wm.cancelUniqueWork("reminder_check"); return }
            val request = PeriodicWorkRequestBuilder<ReminderWorker>(15, TimeUnit.MINUTES).build()
            wm.enqueueUniquePeriodicWork("reminder_check", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
