"""启动期预拉本地模型到 /app/models（宿主持久卷）。

为什么：本地 ASR(whisper)/TTS(Piper) 的模型权重不在镜像里，默认是「首次使用时才下载」，
会导致第一句转写/合成卡顿甚至失败。改由 docker-entrypoint.sh 在启动 API 前调用本脚本一次，
把模型提前拉到 /app/models（宿主目录，挂持久卷）——下到宿主后重启即用、不再重复下载。

行为：
- 仅当 ASR_MODE/TTS_MODE = local 才拉对应模型；云端模式直接跳过、秒过。
- 已存在则不重复下载（faster-whisper 按 download_root 缓存；Piper 音色按文件是否存在判断）。
- 失败只告警、返回 0，不阻断启动（首次使用时还会再试）。
- 在 uvicorn fork 多 worker【之前】只跑一次，避免多 worker 重复下载。
受限网络在 .env 设 HF_ENDPOINT=https://hf-mirror.com / PIPER_VOICES_BASE=镜像 即走镜像站。
"""
from __future__ import annotations

import os


def _prefetch_asr() -> None:
    if os.getenv("ASR_MODE", "cloud").lower() != "local":
        return
    size = os.getenv("ASR_LOCAL_MODEL", "small")
    model_dir = os.getenv("ASR_LOCAL_MODEL_DIR", "/app/models")
    base = os.getenv("HF_ENDPOINT") or "https://huggingface.co（未设 HF_ENDPOINT；国内建议设 hf-mirror.com）"
    try:
        # 直下模型文件(绕开 huggingface_hub 的 API,与 Piper 同法),镜像站对此可用
        from app.asr_local import ensure_whisper_model

        print(f"[prefetch] 预拉 whisper «{size}» → {model_dir}（源 {base}）…", flush=True)
        ensure_whisper_model(size, model_dir)
        print("[prefetch] whisper 就绪", flush=True)
    except Exception as exc:  # noqa: BLE001 — 预拉失败不阻断启动
        hint = "" if os.getenv("HF_ENDPOINT") else " ← 未设 HF_ENDPOINT：在 .env 设 HF_ENDPOINT=https://hf-mirror.com 后重启。"
        print(f"[prefetch] 警告：whisper 预拉失败（{exc}）。首次使用时会再试。{hint}", flush=True)


def _prefetch_tts() -> None:
    if os.getenv("TTS_MODE", "cloud").lower() != "local":
        return
    # 预拉所有【已配置音色】（TTS_VOICES，逗号分隔）+ 中文音色（指导解说用，自动切换）
    voices_env = os.getenv("TTS_VOICES") or os.getenv("TTS_DEFAULT_VOICE", "en_US-lessac-medium")
    voices = [v.strip() for v in voices_env.split(",") if v.strip()]
    zh = os.getenv("PIPER_ZH_VOICE", "zh_CN-huayan-medium")
    if zh and zh not in voices:
        voices.append(zh)
    base = os.getenv("PIPER_VOICES_BASE", "huggingface.co(官方)")
    try:
        from app.tts_local import _ensure_voice

        for v in voices:
            print(f"[prefetch] 预拉 Piper 音色 «{v}»（源 {base}）…", flush=True)
            _ensure_voice(v)
        print(f"[prefetch] Piper 音色就绪（{len(voices)} 个）", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(
            f"[prefetch] 警告：Piper 音色预拉失败（{exc}）。首次合成时会再试；"
            "受限网络请在 .env 设 PIPER_VOICES_BASE 镜像站。",
            flush=True,
        )


def main() -> int:
    _prefetch_asr()
    _prefetch_tts()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
