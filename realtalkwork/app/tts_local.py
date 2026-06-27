"""本地语音合成脚本（Piper，CPU 可用）。

由 setup.sh 选择「本地 Piper」时启用：镜像构建装好 piper-tts（WITH_LOCAL_TTS=true），
TTS_LOCAL_COMMAND 设为  python /app/app/tts_local.py {voice} {out}

约定（与 voice_io._synthesize_local 配合）：
- 待合成文本从【标准输入】读入（避免长文本/引号在命令行里转义出问题）；
- 第 1 个参数是音色（Piper voice 名，如 en_US-lessac-medium / zh_CN-huayan-medium）；
- 第 2 个参数是输出 WAV 路径 {out}；故本地 TTS 的 TTS_FORMAT 应为 wav。

音色模型首次使用会自动下载到 TTS_LOCAL_MODEL_DIR（默认 /app/models，建议挂持久卷，
与本地 ASR 共用同一卷）。
"""
from __future__ import annotations

import os
import sys
import wave


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: tts_local.py <voice> <out_wav>  (text via stdin)", file=sys.stderr)
        return 2
    voice = sys.argv[1].strip()
    out_path = sys.argv[2]
    text = sys.stdin.read().strip()
    if not text:
        print("empty text on stdin", file=sys.stderr)
        return 2

    try:
        from piper import PiperVoice
        from piper.download import ensure_voice_exists, find_voice, get_voices
    except Exception as exc:  # noqa: BLE001
        print(f"piper-tts 未安装：{exc}", file=sys.stderr)
        return 3

    data_dir = os.getenv("TTS_LOCAL_MODEL_DIR", "/app/models")
    os.makedirs(data_dir, exist_ok=True)

    # 解析音色模型；本地没有就联网下载一次（之后命中持久卷，离线可用）
    try:
        model_path, config_path = find_voice(voice, [data_dir])
    except Exception:  # noqa: BLE001 — 未找到 → 下载
        try:
            voices_info = get_voices(data_dir, update_voices=True)
            ensure_voice_exists(voice, [data_dir], data_dir, voices_info)
            model_path, config_path = find_voice(voice, [data_dir])
        except Exception as exc:  # noqa: BLE001
            print(f"音色 {voice} 下载/加载失败：{exc}", file=sys.stderr)
            return 4

    pv = PiperVoice.load(str(model_path), config_path=str(config_path))
    with wave.open(out_path, "wb") as wf:
        pv.synthesize(text, wf)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
