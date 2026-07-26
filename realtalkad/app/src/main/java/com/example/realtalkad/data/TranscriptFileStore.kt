package com.example.realtalkad.data

import android.content.Context
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

class TranscriptFileStore(context: Context) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val file: File = File(context.filesDir, "realtalk/capture-transcripts.json")
    private val lock = Any()
    private var items: MutableList<TranscriptItem> = mutableListOf()

    init {
        file.parentFile?.mkdirs()
        items = readItems().toMutableList()
    }

    // ---- 待上送的翻译素材（退出翻译时入队；上送失败留到下次登录补传）----
    private val pendingFile: File = File(context.filesDir, "realtalk/pending-translations.json")

    fun savePendingTranslations(sessions: List<List<TranscriptItem>>) {
        synchronized(lock) {
            runCatching {
                pendingFile.parentFile?.mkdirs()
                if (sessions.isEmpty()) pendingFile.delete()
                else pendingFile.writeText(json.encodeToString(sessions))
            }
        }
    }

    fun loadPendingTranslations(): List<List<TranscriptItem>> = synchronized(lock) {
        runCatching {
            if (!pendingFile.exists()) emptyList()
            else json.decodeFromString<List<List<TranscriptItem>>>(pendingFile.readText())
        }.getOrDefault(emptyList())
    }

    fun add(item: TranscriptItem) {
        synchronized(lock) {
            items.add(item)
            items.sortBy { it.timestamp }
            saveLocked()
        }
    }

    fun pending(): List<TranscriptItem> = synchronized(lock) {
        items.toList()
    }

    fun remove(ids: Set<String>) {
        if (ids.isEmpty()) return
        synchronized(lock) {
            items.removeAll { it.id in ids }
            saveLocked()
        }
    }

    private fun readItems(): List<TranscriptItem> {
        if (!file.exists()) return emptyList()
        return runCatching {
            json.decodeFromString<List<TranscriptItem>>(file.readText())
        }.getOrDefault(emptyList())
    }

    private fun saveLocked() {
        file.parentFile?.mkdirs()
        file.writeText(json.encodeToString(items))
    }
}
