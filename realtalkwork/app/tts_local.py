"""本地语音合成脚本（Piper 独立二进制，CPU 可用）。

镜像构建（WITH_LOCAL_TTS=true，默认开）装好 Piper 官方二进制到 /opt/piper；
TTS_LOCAL_COMMAND 设为  python /app/app/tts_local.py {voice} {out}

约定（与 voice_io._synthesize_local 配合）：
- 待合成文本从【标准输入】读入（长文本/特殊字符不必走命令行转义）；
- 第 1 个参数是音色（Piper voice 名，如 en_US-lessac-medium）；第 2 个是输出 WAV 路径 {out}
  （故本地 TTS 的 TTS_FORMAT 应为 wav）。

音色模型与本地 ASR 的 whisper 模型一样【首次使用时下载】到 TTS_LOCAL_MODEL_DIR（默认 /app/models，
建议挂持久卷）。受限网络可用 PIPER_VOICES_BASE 指向镜像站。
"""
from __future__ import annotations

import os
import subprocess
import sys
import urllib.request

PIPER_BIN = os.getenv("PIPER_BIN", "/opt/piper/piper")
MODEL_DIR = os.getenv("TTS_LOCAL_MODEL_DIR", "/app/models")
# HuggingFace 上 rhasspy/piper-voices；受限网络可换镜像（如 https://hf-mirror.com/rhasspy/piper-voices/resolve/main）
VOICES_BASE = os.getenv("PIPER_VOICES_BASE", "https://huggingface.co/rhasspy/piper-voices/resolve/main")


def _hf_rel(voice: str) -> str:
    """en_US-lessac-medium → en/en_US/lessac/medium/en_US-lessac-medium"""
    lang_region, name, quality = voice.split("-", 2)
    lang = lang_region.split("_")[0]
    return f"{lang}/{lang_region}/{name}/{quality}/{voice}"


def _ensure_voice(voice: str) -> tuple[str, str]:
    onnx = os.path.join(MODEL_DIR, voice + ".onnx")
    cfg = onnx + ".json"
    if os.path.exists(onnx) and os.path.exists(cfg):
        return onnx, cfg
    os.makedirs(MODEL_DIR, exist_ok=True)
    rel = _hf_rel(voice)
    for url, dst in ((f"{VOICES_BASE}/{rel}.onnx", onnx), (f"{VOICES_BASE}/{rel}.onnx.json", cfg)):
        tmp = dst + ".part"
        urllib.request.urlretrieve(url, tmp)   # noqa: S310 — 固定可信镜像
        os.replace(tmp, dst)
    return onnx, cfg


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

    if not os.path.exists(PIPER_BIN):
        print(f"未找到 Piper 二进制（{PIPER_BIN}）：镜像需以 WITH_LOCAL_TTS=true 构建", file=sys.stderr)
        return 3
    try:
        onnx, cfg = _ensure_voice(voice)
    except Exception as exc:  # noqa: BLE001
        print(f"音色 {voice} 下载/加载失败：{exc}", file=sys.stderr)
        return 4

    proc = subprocess.run(
        [PIPER_BIN, "--model", onnx, "--config", cfg, "--output_file", out_path],
        input=text.encode("utf-8"), capture_output=True,
    )
    if proc.returncode != 0 or not os.path.exists(out_path):
        print(f"piper 合成失败（{proc.returncode}）：{proc.stderr.decode('utf-8', 'ignore')[:300]}", file=sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
