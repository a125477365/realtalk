#!/bin/sh
set -eu

# speech-to-speech 是 VAD -> STT -> LLM -> TTS 的原生实时编排器。它通过本容器网络
# 回调聚合器的 Chat Completions，因此 REST、场景生成、实时通道真实共用同一份 GGUF LLM。
exec speech-to-speech \
  --mode realtime \
  --device "${SPEECH_DEVICE:-cpu}" \
  --num_pipelines "${SPEECH_S2S_PIPELINES:-1}" \
  --stt faster-whisper \
  --faster_whisper_stt_model_name "/models/faster-whisper-${SPEECH_ASR_MODEL:-small}" \
  --faster_whisper_stt_device "${SPEECH_DEVICE:-cpu}" \
  --faster_whisper_stt_compute_type "${SPEECH_S2S_ASR_COMPUTE_TYPE:-int8}" \
  --faster_whisper_stt_gen_language "${SPEECH_S2S_ASR_LANGUAGE:-auto}" \
  --llm_backend chat-completions \
  --model_name "${SPEECH_S2S_LLM_MODEL:-local}" \
  --responses_api_base_url "${SPEECH_S2S_LLM_BASE_URL:-http://speech:9100/v1}" \
  --responses_api_api_key "${SPEECH_S2S_LLM_API_KEY:-local}" \
  --responses_api_stream \
  --tts qwen3 \
  --qwen3_tts_model_name "${SPEECH_S2S_TTS_MODEL:-Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice}" \
  --qwen3_tts_device "${SPEECH_DEVICE:-cpu}" \
  --qwen3_tts_dtype "${SPEECH_S2S_TTS_DTYPE:-float32}" \
  --qwen3_tts_backend "${SPEECH_S2S_TTS_BACKEND:-ggml}" \
  --qwen3_tts_speaker "${SPEECH_S2S_TTS_SPEAKER:-Aiden}" \
  --qwen3_tts_language "${SPEECH_S2S_TTS_LANGUAGE:-auto}" \
  --qwen3_tts_non_streaming_mode false \
  --enable_live_transcription \
  --live_transcription_min_silence_ms "${SPEECH_S2S_MIN_SILENCE_MS:-500}" \
  --ws_host 0.0.0.0 \
  --ws_port 8765
