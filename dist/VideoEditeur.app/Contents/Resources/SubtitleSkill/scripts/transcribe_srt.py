#!/usr/bin/env python3
"""
生成精确时间戳的 SRT 字幕文件。
默认使用 MLX Whisper（Metal GPU 加速），兜底 faster-whisper（CPU）。

用法：
    python3 transcribe_srt.py <音频文件> [--output <输出SRT路径>] [--engine <mlx|faster>] [--language <语言>]

参数：
    音频文件        mp3/wav/m4a 等音频文件路径
    --output       输出 SRT 文件路径（默认：与音频同名 .srt）
    --engine       转写引擎（默认 mlx，可选 faster）
    --language     语言代码（默认自动检测，可指定 en/zh/ja 等）
    --max-line-ms  单条字幕最大时长毫秒数（默认 6000，超过则按词拆分）
"""

import argparse
import os
import sys
from pathlib import Path


def format_timestamp(seconds: float) -> str:
    """秒数转 SRT 时间戳格式 HH:MM:SS,mmm"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds - int(seconds)) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


# 句末标点（强边界：一句话结束）
SENTENCE_END = ".?!。？！…"
# 次级标点（长句兜底时的软切点）
SOFT_BREAK = ",;:，；：、"


class _PseudoWord:
    """没有词级时间戳的 segment 退化成单个伪 word"""
    def __init__(self, start, end, text):
        self.start = start
        self.end = end
        self.word = text


def _flush(words):
    """把一串 word 收成一个字幕段；空文本返回 None"""
    text = "".join(w.word for w in words).strip()
    if not text:
        return None
    return {"start": words[0].start, "end": words[-1].end, "text": text}


def _find_soft_cut(words):
    """从后往前找最靠后的次级标点位置（返回该词索引），找不到返回 None"""
    for j in range(len(words) - 1, -1, -1):
        t = words[j].word.strip()
        if t and t[-1] in SOFT_BREAK:
            return j
    return None


def _find_pause_cut(words, min_gap=0.2):
    """长句无标点时的兜底：在句子后 2/3 段内找最大词间停顿处切（返回停顿前的词索引）。
    避免切出过短的头，也保证切点落在换气停顿而非词中间。找不到返回 None。"""
    best_gap, best_j = min_gap, None
    start = max(1, len(words) // 3)
    for j in range(start, len(words) - 1):
        gap = words[j + 1].start - words[j].end
        if gap > best_gap:
            best_gap, best_j = gap, j
    return best_j


def _postprocess(result):
    """清洗：丢弃无效/重复段、合并碎片、消除时间重叠"""
    cleaned = []
    for item in result:
        if item["end"] <= item["start"]:
            continue  # 丢弃无效时间戳（end <= start）
        if cleaned and item["text"] == cleaned[-1]["text"]:
            # 与前一段文本完全重复 → 延长前段，丢弃重复（Whisper 复读 artifact）
            cleaned[-1]["end"] = max(cleaned[-1]["end"], item["end"])
            continue
        cleaned.append(item)

    # 合并过短碎片（< 400ms 且少于 3 词）到前一段
    merged = []
    for item in cleaned:
        duration = item["end"] - item["start"]
        word_count = len(item["text"].split())
        if merged and duration < 0.4 and word_count < 3:
            merged[-1]["end"] = item["end"]
            merged[-1]["text"] += " " + item["text"]
        else:
            merged.append(item)

    # 消除相邻时间重叠（下一段 start 不早于上一段 end）
    for k in range(1, len(merged)):
        if merged[k]["start"] < merged[k - 1]["end"]:
            merged[k]["start"] = merged[k - 1]["end"]
        if merged[k]["end"] <= merged[k]["start"]:
            merged[k]["end"] = merged[k]["start"] + 0.3

    return merged


def merge_words_to_segments(segments, max_line_ms=6000, pause_ms=500, max_chars=80):
    """
    按「句子 + 停顿」切分字幕，让每条字幕尽量对应一个完整句子，
    起止时间 = 该句首词开口到末词收尾（精确对齐语音，说完正好换条）。

    切分信号（优先级从高到低）：
    1. 句末标点（. ? ! 。？！）→ 一句结束，立即切
    2. 词间停顿 >= pause_ms → 说话人换气/停顿，切
    3. 兜底：累计时长 >= max_line_ms 或字符数 >= max_chars
       → 在最近的次级标点处软切，没有则强制切（避免一条过长一行放不下）

    旧逻辑（照搬 Whisper segment）会把好几句挤一条、半句甩到下一条、
    超长时按时间在词中间硬剁；新逻辑以人话的句子为单位。
    """
    # 1) 把所有 segment 的 word 拉平成一个连续列表
    flat = []
    for seg in segments:
        words = seg.words if seg.words else []
        if not words:
            flat.append(_PseudoWord(seg.start, seg.end, seg.text))
        else:
            flat.extend(words)

    if not flat:
        return []

    # 2) 遍历 word，按句子边界 / 停顿 / 长度兜底切分
    result = []
    cur = []
    n = len(flat)
    for i, w in enumerate(flat):
        cur.append(w)
        wtext = w.word.strip()
        cur_text = "".join(x.word for x in cur).strip()
        cur_dur_ms = (w.end - cur[0].start) * 1000

        gap_ms = ((flat[i + 1].start - w.end) * 1000) if i + 1 < n else 0

        end_sentence = bool(wtext) and wtext[-1] in SENTENCE_END
        big_pause = gap_ms >= pause_ms
        too_long = cur_dur_ms >= max_line_ms or len(cur_text) >= max_chars

        if end_sentence or big_pause:
            seg_obj = _flush(cur)
            if seg_obj:
                result.append(seg_obj)
            cur = []
        elif too_long:
            cut = _find_soft_cut(cur)
            if cut is None or cut >= len(cur) - 1:
                cut = _find_pause_cut(cur)  # 无次级标点 → 退而求其次，在内部最大停顿处切
            if cut is not None and cut < len(cur) - 1:
                head, cur = cur[:cut + 1], cur[cut + 1:]
                seg_obj = _flush(head)
                if seg_obj:
                    result.append(seg_obj)
            else:
                seg_obj = _flush(cur)
                if seg_obj:
                    result.append(seg_obj)
                cur = []

    if cur:
        seg_obj = _flush(cur)
        if seg_obj:
            result.append(seg_obj)

    # 3) 清洗后处理
    return _postprocess(result)


def _is_metal_unavailable_error(error: Exception) -> bool:
    """Return True when MLX cannot access Metal from the current process."""
    message = str(error)
    return "No Metal device available" in message or "metal::load_device" in message


def _fill_empty_windows(segments, audio_path, kwargs, mlx_whisper, min_seconds=2.0):
    """Whisper 偶尔把整个 30 秒窗口判为空（常见于问句之后），导致中间一段没有字幕。
    对无文字/无词的长空段单独重转写该时间范围（不参考前文），用结果替换空段。"""
    empty = [i for i, seg in enumerate(segments)
             if not seg.get("text", "").strip() and not seg.get("words") and seg["end"] - seg["start"] >= min_seconds]
    if not empty:
        return segments
    from mlx_whisper.audio import load_audio, SAMPLE_RATE
    audio = load_audio(audio_path)
    filled = []
    for i, seg in enumerate(segments):
        if i not in empty:
            filled.append(seg)
            continue
        start = seg["start"]
        # 延伸到下一段开头，覆盖空窗口结束后、下一句之前的语音
        stop = segments[i + 1]["start"] if i + 1 < len(segments) else seg["end"] + 1.0
        print(f"补转写空白区间：{format_timestamp(start)} → {format_timestamp(stop)}", file=sys.stderr)
        piece = audio[int(start * SAMPLE_RATE):int(stop * SAMPLE_RATE)]
        retry = mlx_whisper.transcribe(piece, **dict(kwargs, condition_on_previous_text=False))
        for part in retry.get("segments", []):
            if not part.get("text", "").strip():
                continue
            part = dict(part, start=part["start"] + start, end=min(part["end"] + start, stop))
            part["words"] = [dict(w, start=w["start"] + start, end=min(w["end"] + start, stop)) for w in part.get("words", [])
                             if w["start"] + start < stop]
            filled.append(part)
    return filled


def _transcribe_mlx(audio_path: str, language: str = None):
    """MLX Whisper 转写（Metal GPU 加速，默认引擎）"""
    if os.environ.get("CODEX_SANDBOX") == "seatbelt":
        print("错误：当前 Codex 沙箱无法访问 Metal GPU。", file=sys.stderr)
        print("提示：请使用非沙箱/授权执行重跑同一命令以启用 MLX Whisper。", file=sys.stderr)
        return None

    try:
        import mlx_whisper
    except ImportError:
        print("错误：mlx-whisper 未安装，请运行：pip3 install --break-system-packages mlx-whisper",
              file=sys.stderr)
        return None
    except RuntimeError as exc:
        if _is_metal_unavailable_error(exc):
            print("错误：MLX Whisper 无法访问 Metal GPU。", file=sys.stderr)
            print("提示：在 Codex 中请使用非沙箱/授权执行重跑同一命令；普通沙箱可能隐藏 GPU。",
                  file=sys.stderr)
            return None
        raise

    print("转写引擎：MLX Whisper (Metal GPU)", file=sys.stderr)
    print(f"转写中：{audio_path}", file=sys.stderr)

    kwargs = {
        "path_or_hf_repo": "mlx-community/whisper-large-v3-turbo",
        "word_timestamps": True,
    }
    if language:
        kwargs["language"] = language

    try:
        result = mlx_whisper.transcribe(audio_path, **kwargs)
    except RuntimeError as exc:
        if _is_metal_unavailable_error(exc):
            print("错误：MLX Whisper 无法访问 Metal GPU。", file=sys.stderr)
            print("提示：在 Codex 中请使用非沙箱/授权执行重跑同一命令；普通沙箱可能隐藏 GPU。",
                  file=sys.stderr)
            return None
        raise

    lang = result.get("language", "unknown")
    print(f"检测语言：{lang}", file=sys.stderr)

    result["segments"] = _fill_empty_windows(result.get("segments", []), audio_path, kwargs, mlx_whisper)

    # 转换为与 faster-whisper 兼容的 segment 对象
    class Seg:
        def __init__(self, d):
            self.start = d["start"]
            self.end = d["end"]
            self.text = d.get("text", "")
            self.words = [Word(w) for w in d.get("words", [])]

    class Word:
        def __init__(self, d):
            self.start = d["start"]
            self.end = d["end"]
            self.word = d.get("word", "")

    return [Seg(s) for s in result.get("segments", [])]


def _transcribe_faster(audio_path: str, model_name: str, language: str = None):
    """faster-whisper 转写（CPU，兜底引擎）"""
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("错误：faster-whisper 未安装，请运行：pip3 install --break-system-packages faster-whisper",
              file=sys.stderr)
        return None

    print(f"转写引擎：faster-whisper (CPU), 模型：{model_name}", file=sys.stderr)
    model = WhisperModel(model_name, device="cpu", compute_type="int8")

    print(f"转写中：{audio_path}", file=sys.stderr)
    transcribe_kwargs = {"word_timestamps": True}
    if language:
        transcribe_kwargs["language"] = language

    segments_iter, info = model.transcribe(audio_path, **transcribe_kwargs)
    print(f"检测语言：{info.language}（置信度 {info.language_probability:.0%}）", file=sys.stderr)

    return list(segments_iter)


def transcribe_to_srt(audio_path: str, output_path: str, engine: str = "mlx",
                       model_name: str = "large-v3-turbo",
                       language: str = None, max_line_ms: int = 6000,
                       pause_ms: int = 500):
    """主函数：转写音频并输出 SRT。默认 MLX Whisper，失败自动降级 faster-whisper。"""

    segments = None

    if engine == "mlx":
        segments = _transcribe_mlx(audio_path, language)
        if segments is None:
            print("MLX Whisper 不可用，降级到 faster-whisper...", file=sys.stderr)
            segments = _transcribe_faster(audio_path, model_name, language)
    else:
        segments = _transcribe_faster(audio_path, model_name, language)
        if segments is None:
            print("faster-whisper 不可用，降级到 MLX Whisper...", file=sys.stderr)
            segments = _transcribe_mlx(audio_path, language)

    if segments is None:
        print("错误：没有可用的转写引擎", file=sys.stderr)
        sys.exit(1)

    # 合并为合理的字幕段
    srt_segments = merge_words_to_segments(segments, max_line_ms=max_line_ms, pause_ms=pause_ms)

    # 写入 SRT 文件
    with open(output_path, "w", encoding="utf-8") as f:
        for i, seg in enumerate(srt_segments, 1):
            f.write(f"{i}\n")
            f.write(f"{format_timestamp(seg['start'])} --> {format_timestamp(seg['end'])}\n")
            f.write(f"{seg['text']}\n\n")

    print(f"完成！共 {len(srt_segments)} 条字幕 → {output_path}", file=sys.stderr)
    return output_path


def main():
    parser = argparse.ArgumentParser(description="生成精确时间戳 SRT（默认 MLX Whisper）")
    parser.add_argument("audio", help="音频文件路径")
    parser.add_argument("--output", "-o", help="输出 SRT 路径（默认与音频同名）")
    parser.add_argument("--engine", "-e", default="mlx", choices=["mlx", "faster"],
                       help="转写引擎（默认 mlx，可选 faster）")
    parser.add_argument("--model", "-m", default="large-v3-turbo",
                       help="faster-whisper 模型（默认 large-v3-turbo）")
    parser.add_argument("--language", "-l", default=None,
                       help="语言代码（默认自动检测）")
    parser.add_argument("--max-line-ms", type=int, default=6000,
                       help="单条字幕最大时长毫秒数（默认 6000）")
    parser.add_argument("--pause-ms", type=int, default=500,
                       help="词间停顿超过此毫秒数则断句（默认 500）")

    args = parser.parse_args()

    audio_path = Path(args.audio)
    if not audio_path.exists():
        print(f"错误：文件不存在 {audio_path}", file=sys.stderr)
        sys.exit(1)

    output_path = args.output or str(audio_path.with_suffix(".srt"))

    transcribe_to_srt(
        str(audio_path),
        output_path,
        engine=args.engine,
        model_name=args.model,
        language=args.language,
        max_line_ms=args.max_line_ms,
        pause_ms=args.pause_ms,
    )


if __name__ == "__main__":
    main()
