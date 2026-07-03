"""本地语音转写脚本（faster-whisper，CPU 可用）。

由 setup.sh 选择「本地转写」时启用：镜像构建装好 faster-whisper，
ASR_LOCAL_COMMAND 设为  python /app/app/asr_local.py {input}
本脚本把识别出的中文文本打印到标准输出，供后端管线读取。

模型大小由 ASR_LOCAL_MODEL 控制（tiny/base/small/medium，默认 small），
首次运行会自动下载模型到 ASR_LOCAL_MODEL_DIR（建议挂载持久卷）。

模型【直下文件】到本地目录后再加载（不走 huggingface_hub 的 API 解析）——因为镜像站(hf-mirror)
对直连文件可用、但 huggingface_hub 的 metadata/API 路径常失败（与 Piper 同法绕开）。
"""
from __future__ import annotations

import os
import sys
import urllib.request

# faster-whisper(ctranslate2 格式) 模型仓库根目录下需要的文件
_WHISPER_FILES = ("config.json", "model.bin", "tokenizer.json", "vocabulary.txt")


def ensure_whisper_model(size: str, model_dir: str) -> str:
    """把 Systran/faster-whisper-<size> 的模型文件直下到 <model_dir>/faster-whisper-<size>/ 并返回该目录。

    走 HF_ENDPOINT（默认 huggingface.co）的 resolve/main 直连文件（urllib），绕开 huggingface_hub 的
    API 解析（镜像站对后者常不可用）。已存在则跳过，不重复下载。
    """
    repo = f"Systran/faster-whisper-{size}"
    base = (os.getenv("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
    dest = os.path.join(model_dir, f"faster-whisper-{size}")
    os.makedirs(dest, exist_ok=True)
    for fn in _WHISPER_FILES:
        target = os.path.join(dest, fn)
        if os.path.exists(target) and os.path.getsize(target) > 0:
            continue
        url = f"{base}/{repo}/resolve/main/{fn}"
        tmp = target + ".part"
        urllib.request.urlretrieve(url, tmp)  # noqa: S310 — 固定可信仓库/镜像
        os.replace(tmp, target)
    return dest


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: asr_local.py <audio_file>", file=sys.stderr)
        return 2
    audio = sys.argv[1]

    try:
        from faster_whisper import WhisperModel
    except Exception as exc:  # noqa: BLE001
        print(f"faster-whisper 未安装：{exc}", file=sys.stderr)
        return 3

    model_size = os.getenv("ASR_LOCAL_MODEL", "small")
    model_dir = os.getenv("ASR_LOCAL_MODEL_DIR", "/app/models")
    # CPU int8：体积小、速度快、无需 GPU。模型文件直下到本地目录后从本地加载。
    try:
        local_path = ensure_whisper_model(model_size, model_dir)
        model = WhisperModel(local_path, device="cpu", compute_type="int8")
    except Exception as exc:  # noqa: BLE001 — 多半是下载模型时网络受限
        print(
            f"whisper 模型加载/下载失败：{exc}. "
            "受限网络请在 .env 设 HF_ENDPOINT=https://hf-mirror.com 后重启，或改用云端 ASR(ASR_MODE=cloud)。",
            file=sys.stderr,
        )
        return 4

    # 语言由调用方经 ASR_LANGUAGE 指定：英语口语练习(沉浸式/私教)="en"、日常对话采集="zh"、空=自动识别。
    # 此前写死 "zh" 会把英语练习识别成中文 → 空输出("本地转写未产生文本输出")。
    language = (os.getenv("ASR_LANGUAGE") or "").strip() or None
    try:
        segments, _info = model.transcribe(audio, language=language, beam_size=1, vad_filter=True)
        out = "".join(seg.text for seg in segments).strip()
        # 短句 + VAD 偶尔整段被过滤 → 关掉 VAD 再试一次，尽量不返回空
        if not out:
            segments, _info = model.transcribe(audio, language=language, beam_size=1, vad_filter=False)
            out = "".join(seg.text for seg in segments).strip()
    except Exception as exc:  # noqa: BLE001
        print(f"whisper 转写失败：{exc}", file=sys.stderr)
        return 5

    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
