"""Make speech-to-speech 0.2.10 use its installed qwentts.cpp GGML runtime on CPU.

Upstream exposes faster-qwen3-tts but does not yet forward its backend option from
the CLI.  Keeping this small compatibility shim local avoids the CUDA-only torch
path and makes the selected Q4 model work on CPU.  CUDA keeps the upstream path.
"""
from __future__ import annotations

import os


if os.getenv("SPEECH_S2S_PROCESS") == "1" and os.getenv("SPEECH_DEVICE", "cpu").lower() == "cpu":
    from speech_to_speech.TTS.qwen3_tts_handler import Qwen3TTSHandler

    def _setup_qwentts_cpp(self, model_name, dtype, attn_implementation):
        from faster_qwen3_tts import FasterQwen3TTS

        self.dtype = dtype
        self.model = FasterQwen3TTS.from_pretrained(
            model_name,
            device="cpu",
            backend="ggml",
            quant=os.getenv("SPEECH_TTS_QUANT", "Q4_K_M"),
            cache_dir=os.path.join(os.getenv("MODELS_DIR", "/models"), "huggingface", "hub"),
            qwentts_use_fa=False,
        )

    Qwen3TTSHandler._setup_faster = _setup_qwentts_cpp
