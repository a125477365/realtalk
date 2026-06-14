"""本地语音转写脚本（faster-whisper，CPU 可用）。

由 setup.sh 选择「本地转写」时启用：镜像构建装好 faster-whisper，
ASR_LOCAL_COMMAND 设为  python /app/app/asr_local.py {input}
本脚本把识别出的中文文本打印到标准输出，供后端管线读取。

模型大小由 ASR_LOCAL_MODEL 控制（tiny/base/small/medium，默认 small），
首次运行会自动下载模型到 ASR_LOCAL_MODEL_DIR（建议挂载持久卷）。
"""
from __future__ import annotations

import os
import sys


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
    # CPU int8：体积小、速度快、无需 GPU
    model = WhisperModel(model_size, device="cpu", compute_type="int8", download_root=model_dir)

    segments, _info = model.transcribe(audio, language="zh", beam_size=1, vad_filter=True)
    out = "".join(seg.text for seg in segments).strip()
    # 句末补句号便于后端按句拆分（管线会再清洗）
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
