#!/usr/bin/env python3
"""Open-set CAM++ matching against only explicitly confirmed local anchors."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from speaker_utils import VoiceEncoder, cosine, load_audio, normalized, sha256_file


ALLOWED_STATES = {"confirmed_person", "model_candidate", "unconfirmed"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-dir", required=True, type=Path)
    parser.add_argument("--diarization-root", required=True, type=Path)
    parser.add_argument("--run-manifest", required=True, type=Path)
    parser.add_argument("--anchor-manifest", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--tool-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--first", type=int, default=1)
    parser.add_argument("--last", type=int, default=4)
    parser.add_argument("--min-score", type=float, default=0.55)
    parser.add_argument("--min-margin", type=float, default=0.08)
    return parser.parse_args()


def percentile(values: list[float], level: float, fallback: float) -> float:
    return float(np.percentile(values, level)) if values else fallback


def build_profiles(encoder: VoiceEncoder, anchor_manifest: dict) -> tuple[dict, dict]:
    allowed_names = [person["name"] for person in anchor_manifest["persons"]]
    if len(allowed_names) < 2 or len(set(allowed_names)) != len(allowed_names):
        raise SystemExit(f"anchor allowlist must contain at least two unique people; got {allowed_names}")
    vectors_by_name: dict[str, list[dict]] = defaultdict(list)
    audio_cache = {}
    for person in anchor_manifest["persons"]:
        for anchor in person["anchors"]:
            audio_path = Path(anchor["audio"])
            if audio_path not in audio_cache:
                audio_cache[audio_path] = load_audio(audio_path)
            waveform, sample_rate = audio_cache[audio_path]
            if anchor["end"] - anchor["start"] < 1.0:
                raise SystemExit(f"anchor too short: {person['name']} {anchor}")
            vectors_by_name[person["name"]].append({
                "vector": encoder.encode_interval(
                    waveform, sample_rate, anchor["start"], anchor["end"]
                ),
                "source": anchor,
            })
    if any(len(vectors_by_name[name]) < 2 for name in allowed_names):
        raise SystemExit("each confirmed person must have at least two anchors")
    centroids = {
        name: normalized(np.mean([item["vector"] for item in items], axis=0))
        for name, items in vectors_by_name.items()
    }
    return vectors_by_name, centroids


def calibrate(vectors_by_name: dict, centroids: dict, min_score: float, min_margin: float) -> dict:
    holdout = []
    for name, items in vectors_by_name.items():
        for index, anchor in enumerate(items):
            own = [item["vector"] for other_index, item in enumerate(items) if other_index != index]
            own_center = normalized(np.mean(own, axis=0))
            scores = {
                candidate: cosine(anchor["vector"], own_center if candidate == name else center)
                for candidate, center in centroids.items()
            }
            ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
            holdout.append({
                "name": name,
                "predicted": ranked[0][0],
                "correct": ranked[0][0] == name,
                "own_score": scores[name],
                "impostor_score": max(score for candidate, score in scores.items() if candidate != name),
                "margin": ranked[0][1] - ranked[1][1],
                "source": anchor["source"].get("evidence"),
            })
    correct = [item for item in holdout if item["correct"]]
    score_threshold = max(
        min_score,
        percentile([item["own_score"] for item in correct], 10, min_score),
        percentile([item["impostor_score"] for item in holdout], 95, min_score),
    )
    margin_threshold = max(
        min_margin,
        percentile([item["margin"] for item in correct], 10, min_margin),
    )
    return {
        "anchor_counts": {name: len(items) for name, items in vectors_by_name.items()},
        "holdout_count": len(holdout),
        "holdout_correct": len(correct),
        "holdout_accuracy": len(correct) / len(holdout) if holdout else 0.0,
        "score_threshold": score_threshold,
        "margin_threshold": margin_threshold,
        "hard_min_score": min_score,
        "hard_min_margin": min_margin,
        "holdout": holdout,
    }


def main() -> None:
    args = parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True)
    run_manifest = json.loads(args.run_manifest.read_text(encoding="utf-8"))
    anchor_manifest = json.loads(args.anchor_manifest.read_text(encoding="utf-8"))
    if run_manifest["anchors"]["sha256"] != sha256_file(args.anchor_manifest):
        raise SystemExit("anchor manifest differs from locked run manifest")
    encoder = VoiceEncoder(args.tool_root, args.model)
    vectors_by_name, centroids = build_profiles(encoder, anchor_manifest)
    calibration = calibrate(vectors_by_name, centroids, args.min_score, args.min_margin)
    calibration["device"] = str(encoder.device)
    calibration["open_set_policy"] = (
        "No nearest-name fallback: only score+margin+cluster-consistency gates may confirm; "
        "all other candidates remain model_candidate or unconfirmed."
    )
    (args.output_root / "calibration.json").write_text(
        json.dumps(calibration, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        f"[calibration] anchors={calibration['anchor_counts']} "
        f"accuracy={calibration['holdout_accuracy']:.1%} "
        f"score>={calibration['score_threshold']:.4f} "
        f"margin>={calibration['margin_threshold']:.4f}", flush=True,
    )

    manifest_audio = {item["name"]: item for item in run_manifest["audio_files"]}
    timeline = []
    per_file_summaries = []
    for number in range(args.first, args.last + 1):
        audio_name = f"audio-{number:04d}.wav"
        audio_key = audio_name.removesuffix(".wav")
        segments_path = args.diarization_root / audio_key / "segments.json"
        segments = json.loads(segments_path.read_text(encoding="utf-8"))
        waveform, sample_rate = load_audio(args.audio_dir / audio_name)
        vectors = {}
        records = []
        for index, item in enumerate(segments, start=1):
            duration = item["end"] - item["start"]
            base = {
                **item,
                "audio_file": audio_name,
                "audio_number": number,
                "duration": duration,
                "meeting_start": manifest_audio[audio_name]["meeting_offset_seconds"] + item["start"],
                "meeting_end": manifest_audio[audio_name]["meeting_offset_seconds"] + item["end"],
            }
            if duration < 0.5:
                records.append({
                    **base, "identity_status": "unconfirmed", "confirmed_person": None,
                    "model_candidate": None, "attribution_reason": "too_short_for_voiceprint",
                })
                continue
            vector = encoder.encode_interval(
                waveform, sample_rate, item["start"], item["end"]
            )
            vectors[item["id"]] = vector
            scores = sorted(
                ((name, cosine(vector, center)) for name, center in centroids.items()),
                key=lambda pair: pair[1], reverse=True,
            )
            top_name, top_score = scores[0]
            margin = scores[0][1] - scores[1][1]
            high = (
                duration >= 1.2
                and top_score >= calibration["score_threshold"]
                and margin >= calibration["margin_threshold"]
            )
            records.append({
                **base,
                "identity_status": "confirmed_person" if high else "model_candidate",
                "confirmed_person": top_name if high else None,
                "model_candidate": {"name": top_name, "score": top_score, "margin": margin},
                "scores": dict(scores),
                "attribution_reason": "strong_individual_voiceprint" if high else "open_set_gate_not_met",
            })
            if index % 50 == 0:
                print(f"[{audio_key}] embedded {index}/{len(segments)}", flush=True)

        grouped = defaultdict(list)
        for record in records:
            if record["id"] in vectors and record["duration"] >= 1.0:
                grouped[record["speaker"]].append(record)
        label_map = {}
        for label, items in grouped.items():
            center = normalized(np.mean([vectors[item["id"]] for item in items], axis=0))
            scores = sorted(
                ((name, cosine(center, profile)) for name, profile in centroids.items()),
                key=lambda pair: pair[1], reverse=True,
            )
            strong_votes = Counter(
                item["confirmed_person"] for item in items if item["identity_status"] == "confirmed_person"
            )
            vote_name, vote_count = strong_votes.most_common(1)[0] if strong_votes else (None, 0)
            vote_share = vote_count / sum(strong_votes.values()) if strong_votes else 0.0
            margin = scores[0][1] - scores[1][1]
            high = (
                scores[0][1] >= calibration["score_threshold"]
                and margin >= calibration["margin_threshold"]
                and vote_name == scores[0][0]
                and vote_share >= 0.70
                and vote_count >= 2
            )
            label_map[label] = {
                "model_candidate": scores[0][0], "score": scores[0][1], "margin": margin,
                "confirmed_person": scores[0][0] if high else None,
                "strong_vote_count": sum(strong_votes.values()), "vote_share": vote_share,
                "record_count": len(items), "cluster_gate_met": high,
            }

        for record in records:
            context = label_map.get(record["speaker"])
            if record["identity_status"] == "confirmed_person":
                if context and context["cluster_gate_met"] and context["confirmed_person"] != record["confirmed_person"]:
                    record["identity_status"] = "model_candidate"
                    record["confirmed_person"] = None
                    record["attribution_reason"] = "individual_cluster_conflict"
            elif record["identity_status"] == "model_candidate" and context and context["cluster_gate_met"]:
                record["identity_status"] = "confirmed_person"
                record["confirmed_person"] = context["confirmed_person"]
                record["attribution_reason"] = "strong_cluster_voiceprint"
            if record["identity_status"] not in ALLOWED_STATES:
                raise AssertionError(record["identity_status"])
            record["identity_evidence"] = {
                "method": "CAM++ open-set local match",
                "anchor_manifest_sha256": run_manifest["anchors"]["sha256"],
                "score_threshold": calibration["score_threshold"],
                "margin_threshold": calibration["margin_threshold"],
                "cluster": context,
            }

        out_dir = args.output_root / audio_key
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "speaker-attributed-segments.json").write_text(
            json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        (out_dir / "local-cluster-map.json").write_text(
            json.dumps(label_map, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        state_counts = Counter(item["identity_status"] for item in records)
        duration_by_state = defaultdict(float)
        for item in records:
            duration_by_state[item["identity_status"]] += item["duration"]
        summary = {
            "audio_file": audio_name, "record_count": len(records),
            "state_counts": dict(state_counts),
            "duration_by_state_seconds": dict(duration_by_state),
            "confirmed_person_counts": dict(Counter(
                item["confirmed_person"] for item in records if item["confirmed_person"]
            )),
        }
        (out_dir / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        per_file_summaries.append(summary)
        timeline.extend(records)
        print(f"[{audio_key}] {json.dumps(summary, ensure_ascii=False)}", flush=True)

    timeline.sort(key=lambda item: (item["meeting_start"], item["meeting_end"]))
    state_counts = Counter(item["identity_status"] for item in timeline)
    duration_by_state = defaultdict(float)
    confirmed_by_person = Counter()
    for item in timeline:
        duration_by_state[item["identity_status"]] += item["duration"]
        if item["confirmed_person"]:
            confirmed_by_person[item["confirmed_person"]] += 1
    voiced_duration = sum(item["duration"] for item in timeline)
    summary = {
        "session_id": run_manifest["session_id"],
        "record_count": len(timeline),
        "voiced_duration_seconds": voiced_duration,
        "state_counts": dict(state_counts),
        "duration_by_state_seconds": dict(duration_by_state),
        "confirmed_duration_ratio": duration_by_state["confirmed_person"] / voiced_duration if voiced_duration else 0.0,
        "unconfirmed_record_count": len(timeline) - state_counts["confirmed_person"],
        "confirmed_by_person": dict(confirmed_by_person),
        "confirmed_person_allowlist": run_manifest["anchors"]["allowed_confirmed_persons"],
        "explicitly_missing_anchor": run_manifest["anchors"]["missing_confirmed_persons"],
        "per_file": per_file_summaries,
    }
    (args.output_root / "speaker-timeline.json").write_text(
        json.dumps(timeline, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output_root / "speaker-attribution-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
