#!/usr/bin/env python3
"""Run MOSS diarization in padded chunks and restore per-file timestamps."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import soundfile as sf

from moss_transcribe_diarize.app.model_runner import ModelRunner
from moss_transcribe_diarize.inference_utils import DEFAULT_PROMPT
from moss_transcribe_diarize.subtitle import SubtitleSegment, export_json, export_srt, subtitle_segments_from_transcript


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-dir", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--first", type=int, default=1)
    parser.add_argument("--last", type=int, default=4)
    parser.add_argument("--chunk-seconds", type=float, default=120.0)
    parser.add_argument("--padding-seconds", type=float, default=3.0)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--dtype", default="fp16")
    parser.add_argument("--max-new-tokens", type=int, default=2048)
    return parser.parse_args()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def core_ranges(duration: float, size: float, minimum_tail: float = 30.0) -> list[tuple[float, float]]:
    edges = [0.0]
    cursor = size
    while cursor < duration:
        edges.append(cursor)
        cursor += size
    edges.append(duration)
    if len(edges) >= 3 and edges[-1] - edges[-2] < minimum_tail:
        edges.pop(-2)
    return list(zip(edges, edges[1:]))


def main() -> None:
    args = parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True)
    status_path = args.output_root / "diarization-status.json"
    status = {
        "state": "running",
        "model": str(args.model),
        "device": args.device,
        "dtype": args.dtype,
        "chunk_seconds": args.chunk_seconds,
        "padding_seconds": args.padding_seconds,
        "audio_files": {},
    }
    write_json(status_path, status)
    runner = ModelRunner(args.model, device=args.device, dtype=args.dtype)

    for number in range(args.first, args.last + 1):
        key = f"audio-{number:04d}"
        audio_path = args.audio_dir / f"{key}.wav"
        audio, sample_rate = sf.read(audio_path, dtype="float32", always_2d=True)
        duration = len(audio) / sample_rate
        ranges = core_ranges(duration, args.chunk_seconds)
        result_dir = args.output_root / key
        chunks_dir = result_dir / "chunks"
        chunks_dir.mkdir(parents=True, exist_ok=True)
        status["audio_files"][key] = {
            "state": "running", "duration": duration,
            "chunks_total": len(ranges), "chunks_complete": 0,
        }
        write_json(status_path, status)
        print(f"[{key}] start duration={duration:.2f}s chunks={len(ranges)}", flush=True)

        combined: list[SubtitleSegment] = []
        raw_parts = []
        chunk_summaries = []
        for chunk_index, (core_start, core_end) in enumerate(ranges, start=1):
            chunk_dir = chunks_dir / f"chunk-{chunk_index:02d}"
            chunk_dir.mkdir(exist_ok=True)
            audio_start = max(0.0, core_start - args.padding_seconds)
            audio_end = min(duration, core_end + args.padding_seconds)
            chunk_audio = chunk_dir / "audio.wav"
            local_segments_path = chunk_dir / "segments-local.json"
            chunk_summary_path = chunk_dir / "run-summary.json"
            if not (local_segments_path.exists() and chunk_summary_path.exists()):
                first_sample = round(audio_start * sample_rate)
                last_sample = round(audio_end * sample_rate)
                sf.write(chunk_audio, audio[first_sample:last_sample], sample_rate, subtype="PCM_16")
                print(f"[{key} chunk {chunk_index}/{len(ranges)}] start", flush=True)
                last_notice = 0.0

                def progress(stage: str, fraction: float, generated_tokens: int | None) -> None:
                    nonlocal last_notice
                    now = time.monotonic()
                    if now - last_notice >= 15 or stage == "loading_model":
                        token_text = "" if generated_tokens is None else f" tokens={generated_tokens}"
                        print(f"[{key} chunk {chunk_index}] {stage} {fraction:.1%}{token_text}", flush=True)
                        last_notice = now

                result = runner.transcribe(
                    chunk_audio, prompt=DEFAULT_PROMPT, max_length=131072,
                    max_new_tokens=args.max_new_tokens, decoding="greedy", status_callback=progress,
                )
                local_segments = subtitle_segments_from_transcript(result.text, postprocess=False)
                (chunk_dir / "raw_transcript.txt").write_text(result.text, encoding="utf-8")
                local_segments_path.write_text(export_json(local_segments), encoding="utf-8")
                chunk_summary = {
                    "core_start": core_start, "core_end": core_end,
                    "audio_start": audio_start, "audio_end": audio_end,
                    "local_segment_count": len(local_segments),
                    "transcription": {key: value for key, value in result.to_dict().items() if key != "text"},
                }
                write_json(chunk_summary_path, chunk_summary)
                print(f"[{key} chunk {chunk_index}] complete segments={len(local_segments)}", flush=True)
            else:
                local_segments = [
                    SubtitleSegment.from_dict(item)
                    for item in json.loads(local_segments_path.read_text(encoding="utf-8"))
                ]
                chunk_summary = json.loads(chunk_summary_path.read_text(encoding="utf-8"))
                print(f"[{key} chunk {chunk_index}] reuse", flush=True)

            raw_parts.append(
                f"# chunk {chunk_index} core={core_start:.2f}-{core_end:.2f}\n"
                + (chunk_dir / "raw_transcript.txt").read_text(encoding="utf-8")
            )
            chunk_summaries.append(chunk_summary)
            for local in local_segments:
                global_start = audio_start + local.start
                global_end = audio_start + local.end
                midpoint = (global_start + global_end) / 2
                is_last = chunk_index == len(ranges)
                if midpoint < core_start or (midpoint >= core_end and not is_last):
                    continue
                combined.append(SubtitleSegment(
                    id="", start=global_start, end=min(duration, global_end),
                    speaker=f"C{chunk_index:02d}-{local.speaker}", text=local.text,
                ))
            status["audio_files"][key]["chunks_complete"] = chunk_index
            write_json(status_path, status)

        combined.sort(key=lambda item: (item.start, item.end))
        for index, item in enumerate(combined, start=1):
            item.id = f"seg_{index:04d}"
        (result_dir / "raw_transcript_by_chunk.txt").write_text("\n\n".join(raw_parts) + "\n", encoding="utf-8")
        (result_dir / "segments.json").write_text(export_json(combined), encoding="utf-8")
        (result_dir / "subtitle.srt").write_text(export_srt(combined, show_speaker=True), encoding="utf-8-sig")
        last_end = combined[-1].end if combined else 0.0
        summary = {
            "state": "complete", "audio": str(audio_path), "duration": duration,
            "chunk_count": len(ranges), "segment_count": len(combined),
            "last_end": last_end, "coverage_ratio": last_end / duration if duration else 0.0,
            "chunks": chunk_summaries,
        }
        write_json(result_dir / "run-summary.json", summary)
        status["audio_files"][key] = summary
        write_json(status_path, status)
        print(f"[{key}] complete segments={len(combined)} last_end={last_end:.2f}s", flush=True)

    status["state"] = "complete"
    write_json(status_path, status)
    print("[batch] complete", flush=True)


if __name__ == "__main__":
    main()
