"""高级会员 MP3 转写管线。

流程：上传保存 → ffmpeg 按 10 分钟分段（无 ffmpeg 时整文件单次提交）→
OpenAI 兼容 /audio/transcriptions 逐段转写 → 清洗 + 涉政过滤 → 写入 transcripts →
大模型生成场景保存 → 删除音频文件。
"""
from __future__ import annotations

import asyncio
import shutil
import subprocess
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx

from .ark_client import generate_scenario
from .schemas import TranscriptItem
from .settings import settings
from .storage import clean_transcript_items, db

# 单段提交给 ASR 的大小上限（多数 whisper 接口限 25MB）
_ASR_CHUNK_LIMIT_BYTES = 24 * 1024 * 1024
_SEGMENT_SECONDS = 600


def resolve_asr_config() -> dict[str, Any]:
    # mode 与本地命令由部署（env / setup.sh）控制，管理台不可改；
    # 云端服务的 base_url / api_key / model 允许管理台在线配置。
    overrides = db.get_app_settings_map(["asr_base_url", "asr_api_key", "asr_model"])
    return {
        "mode": settings.asr_mode,
        "base_url": overrides.get("asr_base_url") or settings.asr_base_url,
        "api_key": overrides.get("asr_api_key") or settings.asr_api_key,
        "model": overrides.get("asr_model") or settings.asr_model,
        "local_command": settings.asr_local_command,
        "dev_mode": settings.asr_dev_mode,
    }


def asr_configured() -> bool:
    config = resolve_asr_config()
    if config["dev_mode"]:
        return True
    if config["mode"] == "local":
        return bool(config["local_command"])
    return bool(config["base_url"] and config["api_key"])


def _ffmpeg_path() -> str | None:
    return shutil.which("ffmpeg")


def _probe_duration_seconds(path: Path) -> float | None:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return None
    try:
        out = subprocess.run(
            [ffprobe, "-v", "quiet", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=60,
        )
        return float(out.stdout.strip())
    except Exception:
        return None


def _split_audio(path: Path, workdir: Path) -> list[Path]:
    """大文件用 ffmpeg 切成 10 分钟 MP3 段；小文件或无 ffmpeg 时原样返回。"""
    if path.stat().st_size <= _ASR_CHUNK_LIMIT_BYTES:
        return [path]
    ffmpeg = _ffmpeg_path()
    if not ffmpeg:
        raise RuntimeError("音频超过 24MB 且服务器未安装 ffmpeg，无法分段转写")
    pattern = workdir / "seg_%04d.mp3"
    subprocess.run(
        [ffmpeg, "-y", "-v", "quiet", "-i", str(path), "-f", "segment",
         "-segment_time", str(_SEGMENT_SECONDS), "-c:a", "libmp3lame", "-b:a", "64k", str(pattern)],
        check=True, timeout=3600,
    )
    segments = sorted(workdir.glob("seg_*.mp3"))
    if not segments:
        raise RuntimeError("ffmpeg 分段失败")
    return segments


async def _transcribe_chunk(client: httpx.AsyncClient, config: dict[str, Any], path: Path) -> str:
    with path.open("rb") as fh:
        response = await client.post(
            config["base_url"].rstrip("/") + "/audio/transcriptions",
            headers={"Authorization": f"Bearer {config['api_key']}"},
            data={"model": config["model"], "language": "zh", "response_format": "json"},
            files={"file": (path.name, fh, "audio/mpeg")},
        )
    response.raise_for_status()
    return str(response.json().get("text", "")).strip()


def _transcribe_local(config: dict[str, Any], path: Path, workdir: Path) -> str:
    """用服务器本地命令行工具转写。命令模板支持 {input}/{dir}，
    文本优先取 stdout；若 stdout 为空则读取 {dir} 下生成的 .txt。"""
    template = config["local_command"]
    if not template:
        raise RuntimeError("本地转写命令未配置")
    cmd = template.replace("{input}", str(path)).replace("{dir}", str(workdir))
    proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=settings.audio_max_seconds + 600)
    if proc.returncode != 0:
        raise RuntimeError(f"本地转写命令失败（{proc.returncode}）：{(proc.stderr or proc.stdout)[:300]}")
    text = proc.stdout.strip()
    if text:
        return text
    txts = sorted(workdir.glob("*.txt"))
    if txts:
        return "\n".join(p.read_text(encoding="utf-8", errors="ignore").strip() for p in txts)
    raise RuntimeError("本地转写未产生文本输出")


async def transcribe_file(path: Path) -> str:
    config = resolve_asr_config()
    is_cloud_ready = bool(config["base_url"] and config["api_key"])
    is_local_ready = bool(config["mode"] == "local" and config["local_command"])

    if config["dev_mode"] and not is_cloud_ready and not is_local_ready:
        # 开发模式：无 ASR 服务时返回示例文本，保证管线可端到端联调
        return "今天上午我们开了项目例会。这个版本周五之前要提测。测试环境今天下午给你。辛苦大家了。"

    workdir = path.parent / f"{path.stem}_segs"
    workdir.mkdir(exist_ok=True)
    try:
        if config["mode"] == "local":
            if not is_local_ready:
                raise RuntimeError("本地转写命令未配置，请在管理台「系统设置 → 语音转写」中配置")
            # 本地工具自行处理整段音频，无需切片
            return await asyncio.to_thread(_transcribe_local, config, path, workdir)

        if not is_cloud_ready:
            raise RuntimeError("语音转写服务未配置，请在管理台「系统设置」中配置 ASR")
        segments = await asyncio.to_thread(_split_audio, path, workdir)
        texts: list[str] = []
        async with httpx.AsyncClient(timeout=httpx.Timeout(600, connect=30)) as client:
            for segment in segments:
                texts.append(await _transcribe_chunk(client, config, segment))
        return "\n".join(text for text in texts if text)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _text_to_items(text: str, base_time: datetime) -> list[TranscriptItem]:
    items: list[TranscriptItem] = []
    offset = 0
    for line in text.replace("。", "。\n").splitlines():
        line = line.strip()
        if not line:
            continue
        items.append(
            TranscriptItem(
                id=str(uuid.uuid4()),
                timestamp=base_time + timedelta(seconds=offset),
                text=line[:4000],
            )
        )
        offset += 5
    return items


async def process_audio_job(job_id: str, user_id: str, path: Path) -> None:
    """后台处理一个音频任务；任何失败都会把状态与原因写回任务表。"""
    try:
        db.update_audio_job(job_id, "transcribing")
        duration = await asyncio.to_thread(_probe_duration_seconds, path)
        if duration and duration > settings.audio_max_seconds:
            raise RuntimeError(f"音频时长 {duration / 3600:.1f} 小时，超过 {settings.audio_max_seconds // 3600} 小时上限")

        text = await transcribe_file(path)
        now = datetime.now(timezone.utc)
        # 与 App 文字上传同一条清洗链路：噪声剔除 + 涉政内容过滤
        items = clean_transcript_items(_text_to_items(text, now))
        if not items:
            raise RuntimeError("转写结果为空或全部被内容过滤，未生成场景")
        db.insert_transcripts(user_id, items)

        db.update_audio_job(job_id, "generating", transcript_chars=sum(len(item.text) for item in items))
        scenario = await generate_scenario(items, user_id=user_id)
        saved = db.create_scenario(user_id, now, now, scenario)
        db.update_audio_job(job_id, "completed", scene_id=saved.scene_id)
    except Exception as exc:  # noqa: BLE001 — 必须把失败原因落库
        db.update_audio_job(job_id, "failed", error=str(exc))
    finally:
        path.unlink(missing_ok=True)


# ============================================================
# 分布式：入口节点把文件转发给某个 worker 节点处理
# ============================================================

def worker_nodes() -> list[str]:
    raw = db.get_app_setting_str("audio_worker_nodes") or settings.audio_worker_nodes or ""
    return [n.strip().rstrip("/") for n in raw.split(",") if n.strip()]


def _pick_worker(nodes: list[str], user_id: str) -> str:
    """按用户哈希稳定选节点：同一用户的任务总落在同一 worker。"""
    import hashlib

    idx = int(hashlib.sha256(user_id.encode()).hexdigest(), 16) % len(nodes)
    return nodes[idx]


async def dispatch_or_process(job_id: str, user_id: str, path: Path) -> None:
    """有 worker 节点则转发给它处理（共享数据库，结果各节点可见）；否则本机处理。"""
    nodes = worker_nodes()
    if not nodes:
        await process_audio_job(job_id, user_id, path)
        return

    target = _pick_worker(nodes, user_id)
    token = settings.internal_token or ""
    try:
        db.update_audio_job(job_id, "transcribing")  # 标记已派发
        async with httpx.AsyncClient(timeout=httpx.Timeout(1800, connect=30)) as client:
            with path.open("rb") as fh:
                resp = await client.post(
                    target + "/audio/internal/ingest",
                    params={"job_id": job_id, "user_id": user_id},
                    headers={"X-Internal-Token": token},
                    files={"file": (path.name, fh, "audio/mpeg")},
                )
            resp.raise_for_status()
    except Exception as exc:  # noqa: BLE001 — 转发失败兜底为本机处理，避免任务卡死
        db.update_audio_job(job_id, "transcribing", error=f"转发到 {target} 失败，改由本机处理：{str(exc)[:200]}")
        await process_audio_job(job_id, user_id, path)
        return
    # 转发成功，本机不再保留文件（worker 已落盘处理）
    path.unlink(missing_ok=True)
