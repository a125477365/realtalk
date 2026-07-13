"""Make speech-to-speech 0.2.10 use its installed qwentts.cpp GGML runtime on CPU.

Upstream exposes faster-qwen3-tts but does not yet forward its backend option from
the CLI.  Keeping this small compatibility shim local avoids the CUDA-only torch
path and makes the selected Q4 model work on CPU.  CUDA keeps the upstream path.
"""
from __future__ import annotations

import os
from pathlib import Path
from urllib.request import urlretrieve


if os.getenv("SPEECH_S2S_PROCESS") == "1" and os.getenv("SPEECH_DEVICE", "cpu").lower() == "cpu":
    from speech_to_speech.TTS.qwen3_tts_handler import Qwen3TTSHandler

    def _setup_qwentts_cpp(self, model_name, dtype, attn_implementation):
        from faster_qwen3_tts import FasterQwen3TTS

        # qwentts.cpp 内部 hf_hub_download 在 hf-mirror.com 对该第三方 GGUF 仓库的
        # metadata 请求不兼容。直接走与 ASR/LLM 相同的 resolve 下载，随后显式传本地路径。
        stems = {
            "Qwen/Qwen3-TTS-12Hz-0.6B-Base": "qwen-talker-0.6b-base",
            "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice": "qwen-talker-0.6b-customvoice",
            "Qwen/Qwen3-TTS-12Hz-1.7B-Base": "qwen-talker-1.7b-base",
            "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice": "qwen-talker-1.7b-customvoice",
            "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign": "qwen-talker-1.7b-voicedesign",
        }
        quant = os.getenv("SPEECH_TTS_QUANT", "Q4_K_M").upper()
        quant = {"Q4": "Q4_K_M", "Q8": "Q8_0", "FP32": "F32"}.get(quant, quant)
        stem = stems.get(model_name)
        if not stem:
            raise ValueError(f"不支持的 Qwen3-TTS 模型：{model_name}")
        model_dir = Path(os.getenv("MODELS_DIR", "/models")) / "qwen3-tts-gguf"
        model_dir.mkdir(parents=True, exist_ok=True)
        filenames = (f"{stem}-{quant}.gguf", f"qwen-tokenizer-12hz-{quant}.gguf")
        base = (os.getenv("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
        paths: list[Path] = []
        for filename in filenames:
            path = model_dir / filename
            if not path.exists() or path.stat().st_size == 0:
                tmp = path.with_suffix(path.suffix + ".part")
                urlretrieve(f"{base}/Serveurperso/Qwen3-TTS-GGUF/resolve/main/{filename}", tmp)  # noqa: S310
                tmp.replace(path)
            paths.append(path)

        self.dtype = dtype
        self.model = FasterQwen3TTS.from_pretrained(
            model_name,
            device="cpu",
            backend="ggml",
            quant=os.getenv("SPEECH_TTS_QUANT", "Q4_K_M"),
            gguf_talker_path=paths[0],
            gguf_codec_path=paths[1],
            cache_dir=os.path.join(os.getenv("MODELS_DIR", "/models"), "huggingface", "hub"),
            qwentts_use_fa=False,
        )

    Qwen3TTSHandler._setup_faster = _setup_qwentts_cpp
