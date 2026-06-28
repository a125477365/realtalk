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
    try:
        from faster_whisper import WhisperModel

        print(f"[prefetch] 预拉 whisper «{size}» → {model_dir}（首次较久，下到宿主卷后重启即用）…", flush=True)
        WhisperModel(size, device="cpu", compute_type="int8", download_root=model_dir)
        print("[prefetch] whisper 就绪", flush=True)
    except Exception as exc:  # noqa: BLE001 — 预拉失败不阻断启动
        print(
            f"[prefetch] 警告：whisper 预拉失败（{exc}）。首次使用时会再试；"
            "受限网络请在 .env 设 HF_ENDPOINT=https://hf-mirror.com。",
            flush=True,
        )


def _prefetch_tts() -> None:
    if os.getenv("TTS_MODE", "cloud").lower() != "local":
        return
    voice = os.getenv("TTS_DEFAULT_VOICE", "en_US-lessac-medium")
    try:
        from app.tts_local import _ensure_voice

        print(f"[prefetch] 预拉 Piper 音色 «{voice}» …", flush=True)
        _ensure_voice(voice)
        print("[prefetch] Piper 音色就绪", flush=True)
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
