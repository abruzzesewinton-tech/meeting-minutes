#!/usr/bin/env python3
"""Create anonymous review clips for unknown and model-confirmed clusters."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeline", required=True, type=Path)
    parser.add_argument("--audio-dir", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    return parser.parse_args()


def overlap(left: dict, right: dict) -> float:
    return max(0.0, min(left["end"], right["end"]) - max(left["start"], right["start"]))


def normalized_clip(clip: np.ndarray) -> np.ndarray:
    rms = float(np.sqrt(np.mean(np.square(clip)) + 1e-12))
    clip = clip * min(10 ** (18 / 20), 0.1 / max(rms, 1e-6))
    peak = float(np.max(np.abs(clip)))
    return clip * (0.89 / peak) if peak > 0.89 else clip


def clean_candidates(items: list[dict], all_rows: list[dict]) -> list[dict]:
    clean = []
    for item in items:
        if item["duration"] < 1.0 or item["duration"] > 10.0:
            continue
        if len(item.get("text", "").strip("，。！？、,.!? ")) <= 3:
            continue
        contaminated = any(
            other["audio_file"] == item["audio_file"]
            and other["id"] != item["id"]
            and overlap(item, other) > 0.20
            for other in all_rows
        )
        if not contaminated:
            clean.append(item)
    candidates = clean or [item for item in items if item["duration"] >= 0.75]
    return sorted(candidates, key=lambda item: item["duration"], reverse=True)


def choose_diverse(items: list[dict], count: int) -> list[dict]:
    if not items:
        return []
    chosen = [items[0]]
    for candidate in sorted(items[1:], key=lambda item: item["start"]):
        if all(abs(candidate["start"] - item["start"]) >= 5.0 for item in chosen):
            chosen.append(candidate)
        if len(chosen) >= count:
            break
    return chosen


def write_clip(item: dict, audio_cache: dict, audio_dir: Path, output: Path) -> None:
    audio_name = item["audio_file"]
    if audio_name not in audio_cache:
        audio_cache[audio_name] = sf.read(audio_dir / audio_name, dtype="float32", always_2d=True)
    audio, sample_rate = audio_cache[audio_name]
    start = max(0.0, item["start"] - 0.12)
    end = min(len(audio) / sample_rate, item["end"] + 0.12)
    if end - start > 7.0:
        center = (start + end) / 2
        start, end = center - 3.5, center + 3.5
    clip = audio[round(start * sample_rate):round(end * sample_rate)].copy()
    sf.write(output, normalized_clip(clip), sample_rate, subtype="PCM_16")


def main() -> None:
    args = parse_args()
    rows = json.loads(args.timeline.read_text(encoding="utf-8"))
    unknown_dir = args.output_root / "unknown-clusters"
    blind_dir = args.output_root / "confirmed-blind-check"
    unknown_dir.mkdir(parents=True, exist_ok=True)
    blind_dir.mkdir(parents=True, exist_ok=True)
    audio_cache = {}

    unknown_groups = defaultdict(list)
    confirmed_groups = defaultdict(list)
    excluded_low_value_unknown = []
    for row in rows:
        key = (row["audio_file"], row["speaker"])
        if row["identity_status"] == "confirmed_person":
            confirmed_groups[(row["audio_file"], row["speaker"], row["confirmed_person"])].append(row)
        elif row["duration"] >= 0.75 and len(row.get("text", "").strip("，。！？、,.!? ")) > 3:
            unknown_groups[key].append(row)
        else:
            excluded_low_value_unknown.append(row)

    unknown_manifest = {
        "cluster_count": len(unknown_groups),
        "excluded_low_value_record_count": len(excluded_low_value_unknown),
        "clusters": [],
    }
    unknown_number = 0
    for cluster_index, (key, items) in enumerate(
        sorted(unknown_groups.items(), key=lambda pair: sum(item["duration"] for item in pair[1]), reverse=True),
        start=1,
    ):
        candidates = clean_candidates(items, rows)
        examples = choose_diverse(candidates or [max(items, key=lambda item: item["duration"])], 3)
        example_records = []
        for example_index, item in enumerate(examples, start=1):
            unknown_number += 1
            file_name = f"U{cluster_index:03d}-{example_index}.wav"
            write_clip(item, audio_cache, args.audio_dir, unknown_dir / file_name)
            example_records.append({
                "file": file_name, "audio_file": item["audio_file"], "id": item["id"],
                "start": item["start"], "end": item["end"], "meeting_start": item["meeting_start"],
                "text": item["text"], "identity_status": item["identity_status"],
                "model_candidate": item.get("model_candidate"),
            })
        unknown_manifest["clusters"].append({
            "review_cluster": f"U{cluster_index:03d}",
            "audio_file": key[0], "temporary_speaker": key[1],
            "record_count": len(items), "duration_seconds": sum(item["duration"] for item in items),
            "representative_clip_count": len(example_records), "examples": example_records,
        })
    unknown_manifest["representative_clip_count"] = unknown_number
    unknown_manifest["clusters_with_representative"] = sum(
        bool(item["examples"]) for item in unknown_manifest["clusters"]
    )
    (unknown_dir / "review-manifest.json").write_text(
        json.dumps(unknown_manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (unknown_dir / "试听说明.md").write_text(
        "# 未确认声音复核\n\n"
        "- 文件名不含姓名；每个 U 编号代表同一音频块中的同一临时声音簇。\n"
        "- 每簇提供 1–3 个尽量干净的代表片段；若听到多人或无法判断，请直接标记。\n"
        "- 参会名单不能作为排除法证据。\n",
        encoding="utf-8",
    )

    blind_manifest = {"group_count": len(confirmed_groups), "groups": []}
    answer_key = []
    for index, (key, items) in enumerate(sorted(confirmed_groups.items()), start=1):
        candidates = clean_candidates(items, rows)
        chosen = candidates[0] if candidates else max(items, key=lambda item: item["duration"])
        file_name = f"B{index:03d}.wav"
        write_clip(chosen, audio_cache, args.audio_dir, blind_dir / file_name)
        blind_manifest["groups"].append({
            "blind_id": f"B{index:03d}", "file": file_name,
            "audio_file": chosen["audio_file"], "temporary_speaker": chosen["speaker"],
            "start": chosen["start"], "end": chosen["end"], "meeting_start": chosen["meeting_start"],
        })
        answer_key.append({
            "blind_id": f"B{index:03d}", "confirmed_person": key[2],
            "source_record_id": chosen["id"], "attribution_reason": chosen["attribution_reason"],
            "identity_evidence": chosen["identity_evidence"],
        })
    (blind_dir / "blind-manifest.json").write_text(
        json.dumps(blind_manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (blind_dir / "answer-key.json").write_text(
        json.dumps(answer_key, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (blind_dir / "试听说明.md").write_text(
        "# 已归名组盲听抽检\n\n"
        "- 每个 B 编号对应一个被模型归到已知姓名的临时声音组，文件名不展示姓名。\n"
        "- 请先独立记录听到的人，再由系统维护者对照 answer-key.json。\n",
        encoding="utf-8",
    )
    print(json.dumps({
        "unknown_cluster_count": len(unknown_groups),
        "unknown_representative_clips": unknown_number,
        "confirmed_group_count": len(confirmed_groups),
        "blind_check_clips": len(answer_key),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
