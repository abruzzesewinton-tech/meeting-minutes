#!/usr/bin/env python3
"""Apply exact human-review confirmations to a three-state speaker timeline."""

from __future__ import annotations

import argparse
import copy
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from speaker_utils import sha256_file


IDENTITY_STATES = {"confirmed_person", "model_candidate", "unconfirmed"}
EVIDENCE_LINK = re.compile(
    r"\[audio-\d{4}\.wav\]\(\./audio-\d{4}\.wav\) "
    r"\d{2}:\d{2}\.\d{2}–\d{2}:\d{2}\.\d{2}"
)
AUDIO_REFERENCE = re.compile(
    r"\[(audio-\d{4}\.wav)\]\(\./\1\) "
    r"(\d{2}):(\d{2})\.(\d{2})–(\d{2}):(\d{2})\.(\d{2})"
)
SEGMENT_REFERENCE = re.compile(r"`(seg_\d{4})`")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def same_number(left: Any, right: Any, tolerance: float = 1e-6) -> bool:
    return abs(float(left) - float(right)) <= tolerance


def validate_feedback(
    review_manifest_path: Path,
    feedback_path: Path,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    review_manifest = read_json(review_manifest_path)
    feedback = read_json(feedback_path)
    checks: list[dict[str, Any]] = []

    manifest_sha = sha256_file(review_manifest_path)
    checks.append(
        {
            "check": "review_manifest_sha_matches_feedback",
            "pass": manifest_sha == feedback["review_manifest_sha256"],
            "expected": feedback["review_manifest_sha256"],
            "actual": manifest_sha,
        }
    )
    checks.append(
        {
            "check": "session_id_matches",
            "pass": feedback["session_id"] == review_manifest["session_id"],
            "expected": review_manifest["session_id"],
            "actual": feedback["session_id"],
        }
    )

    review_by_id = {item["review_id"]: item for item in review_manifest["items"]}
    matched_feedback: list[dict[str, Any]] = []
    for item in feedback["items"]:
        review_id = item["review_id"]
        source = review_by_id.get(review_id)
        fields_match = source is not None and all(
            item.get(field) == source.get(field)
            for field in ("file", "file_sha256", "audio_file", "segment_id")
        )
        times_match = source is not None and all(
            same_number(item[field], source[field])
            for field in ("clip_duration_seconds", "start", "end", "meeting_start")
        )
        clip_path = (review_manifest_path.parent / item["file"]).resolve()
        clip_sha = sha256_file(clip_path) if clip_path.is_file() else None
        clip_matches = clip_sha == item["file_sha256"]
        valid_confirmation = (
            item.get("identity_status") == "confirmed_person"
            and item.get("evidence_type") == "human_confirmation"
            and bool(item.get("confirmed_name"))
            and item.get("overlap_greater_than_0_2_seconds") is False
            and item.get("use_as_topic_evidence") is True
        )
        passed = fields_match and times_match and clip_matches and valid_confirmation
        checks.append(
            {
                "check": f"feedback_item_{review_id}",
                "pass": passed,
                "fields_match": fields_match,
                "times_match": times_match,
                "clip_sha_matches": clip_matches,
                "valid_confirmation": valid_confirmation,
                "clip_path": str(clip_path),
                "clip_sha256": clip_sha,
            }
        )
        if passed:
            matched_feedback.append(item)

    if not all(check["pass"] for check in checks):
        failed = [check["check"] for check in checks if not check["pass"]]
        raise ValueError(f"feedback validation failed: {', '.join(failed)}")
    return feedback, matched_feedback, checks


def apply_feedback(
    timeline: list[dict[str, Any]],
    feedback: dict[str, Any],
    feedback_path: Path,
    items: list[dict[str, Any]],
    allowed_people: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], set[int]]:
    result = copy.deepcopy(timeline)
    applications: list[dict[str, Any]] = []
    changed_indexes: set[int] = set()
    feedback_sha = sha256_file(feedback_path)

    for item in items:
        confirmed_name = item["confirmed_name"]
        if confirmed_name not in allowed_people:
            raise ValueError(f"confirmed name is outside allowlist: {confirmed_name}")
        matches = [
            index
            for index, record in enumerate(result)
            if record["audio_file"] == item["audio_file"]
            and record["id"] == item["segment_id"]
            and same_number(record["start"], item["start"])
            and same_number(record["end"], item["end"])
            and same_number(record["meeting_start"], item["meeting_start"])
        ]
        if len(matches) != 1:
            raise ValueError(
                f"expected one timeline match for {item['review_id']}, got {len(matches)}"
            )
        index = matches[0]
        record = result[index]
        previous = {
            "identity_status": record["identity_status"],
            "confirmed_person": record.get("confirmed_person"),
            "attribution_reason": record.get("attribution_reason"),
            "identity_evidence": copy.deepcopy(record.get("identity_evidence")),
        }
        record["identity_status"] = "confirmed_person"
        record["confirmed_person"] = confirmed_name
        record["attribution_reason"] = "human_review_confirmation"
        record["identity_evidence"] = {
            "method": "human confirmation from anonymous local review clip",
            "review_id": item["review_id"],
            "confirmed_at": feedback["confirmed_at"],
            "confirmation_source": feedback["confirmation_source"],
            "feedback_path": str(feedback_path),
            "feedback_sha256": feedback_sha,
            "review_clip": item["file"],
            "review_clip_sha256": item["file_sha256"],
            "review_clip_duration_seconds": item["clip_duration_seconds"],
            "overlap_greater_than_0_2_seconds": False,
            "scope": "exact source segment only; no adjacent-segment or cluster expansion",
            "previous_model_attribution": previous,
        }
        changed_indexes.add(index)
        applications.append(
            {
                "review_id": item["review_id"],
                "audio_file": item["audio_file"],
                "segment_id": item["segment_id"],
                "start": item["start"],
                "end": item["end"],
                "meeting_start": item["meeting_start"],
                "confirmed_name": confirmed_name,
                "timeline_index": index,
                "previous_identity_status": previous["identity_status"],
                "new_identity_status": record["identity_status"],
            }
        )
    return result, applications, changed_indexes


def summarize(
    session_id: str,
    timeline: list[dict[str, Any]],
    allowed_people: list[str],
) -> dict[str, Any]:
    state_counts: Counter[str] = Counter()
    duration_by_state: defaultdict[str, float] = defaultdict(float)
    confirmed_by_person: Counter[str] = Counter()
    per_file_records: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)

    for record in timeline:
        state = record["identity_status"]
        state_counts[state] += 1
        duration_by_state[state] += float(record["duration"])
        per_file_records[record["audio_file"]].append(record)
        if state == "confirmed_person":
            confirmed_by_person[record["confirmed_person"]] += 1

    voiced_duration = sum(duration_by_state.values())
    per_file = []
    for audio_file in sorted(per_file_records):
        records = per_file_records[audio_file]
        file_states: Counter[str] = Counter(record["identity_status"] for record in records)
        file_durations: defaultdict[str, float] = defaultdict(float)
        file_people: Counter[str] = Counter()
        for record in records:
            file_durations[record["identity_status"]] += float(record["duration"])
            if record["identity_status"] == "confirmed_person":
                file_people[record["confirmed_person"]] += 1
        per_file.append(
            {
                "audio_file": audio_file,
                "record_count": len(records),
                "state_counts": dict(file_states),
                "duration_by_state_seconds": dict(file_durations),
                "confirmed_person_counts": dict(file_people),
            }
        )

    confirmed_duration = duration_by_state["confirmed_person"]
    return {
        "session_id": session_id,
        "record_count": len(timeline),
        "voiced_duration_seconds": voiced_duration,
        "state_counts": dict(state_counts),
        "duration_by_state_seconds": dict(duration_by_state),
        "confirmed_duration_ratio": confirmed_duration / voiced_duration,
        "unconfirmed_record_count": (
            state_counts["model_candidate"] + state_counts["unconfirmed"]
        ),
        "confirmed_by_person": dict(confirmed_by_person),
        "confirmed_person_allowlist": allowed_people,
        "explicitly_missing_anchor": [],
        "per_file": per_file,
    }


def validate_timeline(
    source: list[dict[str, Any]],
    result: list[dict[str, Any]],
    changed_indexes: set[int],
    allowed_people: set[str],
    audio_by_name: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    untouched_equal = sum(
        1
        for index, (before, after) in enumerate(zip(source, result, strict=True))
        if index not in changed_indexes and before == after
    )
    untouched_expected = len(source) - len(changed_indexes)
    state_contract = all(record["identity_status"] in IDENTITY_STATES for record in result)
    identity_contract = all(
        (
            record["identity_status"] == "confirmed_person"
            and record.get("confirmed_person") in allowed_people
        )
        or (
            record["identity_status"] != "confirmed_person"
            and record.get("confirmed_person") is None
        )
        for record in result
    )
    time_bounds = all(
        0 <= float(record["start"]) <= float(record["end"])
        <= float(audio_by_name[record["audio_file"]]["duration_seconds"]) + 1e-6
        for record in result
    )
    meeting_monotonic = all(
        float(left["meeting_start"]) <= float(right["meeting_start"])
        for left, right in zip(result, result[1:])
    )
    return [
        {
            "check": "record_count_unchanged",
            "pass": len(source) == len(result),
            "expected": len(source),
            "actual": len(result),
        },
        {
            "check": "only_exact_feedback_records_changed",
            "pass": untouched_equal == untouched_expected,
            "expected_untouched": untouched_expected,
            "actual_untouched_equal": untouched_equal,
        },
        {"check": "three_state_contract", "pass": state_contract},
        {"check": "confirmed_name_contract", "pass": identity_contract},
        {"check": "audio_time_bounds", "pass": time_bounds},
        {"check": "meeting_time_monotonic", "pass": meeting_monotonic},
    ]


def reference_seconds(minutes: str, seconds: str, centiseconds: str) -> float:
    return int(minutes) * 60 + int(seconds) + int(centiseconds) / 100


def validate_minutes(
    path: Path | None,
    timeline: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    if path is None:
        return []
    text = path.read_text(encoding="utf-8")
    required_phrases = [
        "纪要状态：`review_candidate`",
        "## 证据口径",
        "### 我",
        "### 示例发言人丙",
        "### 示例发言人乙",
        "## 未确认说话人",
        "不建立责任归属",
        "原话证据",
        "模型归纳",
        "人工确认",
    ]
    evidence_lines = []
    reference_failures = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        audio_references = list(AUDIO_REFERENCE.finditer(line))
        if not audio_references:
            continue
        segment_ids = set(SEGMENT_REFERENCE.findall(line))
        matched_segment_ids: set[str] = set()
        line_matches = []
        for reference in audio_references:
            audio_file = reference.group(1)
            start = reference_seconds(*reference.groups()[1:4])
            end = reference_seconds(*reference.groups()[4:7])
            matches = [
                record
                for record in timeline
                if record["audio_file"] == audio_file
                and record["id"] in segment_ids
                and record["identity_status"] == "confirmed_person"
                and float(record["start"]) >= start - 0.021
                and float(record["end"]) <= end + 0.021
            ]
            matched_segment_ids.update(record["id"] for record in matches)
            line_matches.append(
                {
                    "audio_file": audio_file,
                    "start": start,
                    "end": end,
                    "matched_segments": [record["id"] for record in matches],
                }
            )
            if not matches:
                reference_failures.append(
                    {
                        "line": line_number,
                        "reason": "audio/time reference has no confirmed cited segment",
                        "audio_file": audio_file,
                        "start": start,
                        "end": end,
                        "cited_segments": sorted(segment_ids),
                    }
                )
        missing_segments = sorted(segment_ids - matched_segment_ids)
        if missing_segments:
            reference_failures.append(
                {
                    "line": line_number,
                    "reason": "cited segment is outside every linked audio/time range",
                    "missing_segments": missing_segments,
                }
            )
        evidence_lines.append(
            {
                "line": line_number,
                "cited_segments": sorted(segment_ids),
                "references": line_matches,
            }
        )

    return [
        {
            "check": "minutes_required_structure",
            "pass": all(phrase in text for phrase in required_phrases),
            "required_phrases": required_phrases,
        },
        {
            "check": "minutes_has_timestamped_audio_links",
            "pass": len(EVIDENCE_LINK.findall(text)) >= 10,
            "audio_link_count": len(EVIDENCE_LINK.findall(text)),
            "minimum": 10,
        },
        {
            "check": "minutes_evidence_references_resolve",
            "pass": not reference_failures,
            "evidence_line_count": len(evidence_lines),
            "failures": reference_failures,
        },
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-timeline", type=Path, required=True)
    parser.add_argument("--source-summary", type=Path, required=True)
    parser.add_argument("--source-run-manifest", type=Path, required=True)
    parser.add_argument("--review-manifest", type=Path, required=True)
    parser.add_argument("--human-feedback", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--minutes-candidate", type=Path)
    parser.add_argument("--superseded-minutes", type=Path, required=True)
    parser.add_argument("--superseded-minutes-sha256", required=True)
    args = parser.parse_args()

    source_timeline = read_json(args.source_timeline)
    source_summary = read_json(args.source_summary)
    run_manifest = read_json(args.source_run_manifest)
    feedback, feedback_items, feedback_checks = validate_feedback(
        args.review_manifest, args.human_feedback
    )
    allowed_people = source_summary["confirmed_person_allowlist"]
    result, applications, changed_indexes = apply_feedback(
        source_timeline,
        feedback,
        args.human_feedback,
        feedback_items,
        set(allowed_people),
    )

    audio_checks = []
    audio_by_name = {item["name"]: item for item in run_manifest["audio_files"]}
    for audio in run_manifest["audio_files"]:
        current_sha = sha256_file(Path(audio["path"]))
        audio_checks.append(
            {
                "check": f"original_audio_sha_{audio['name']}",
                "pass": current_sha == audio["sha256"],
                "expected": audio["sha256"],
                "actual": current_sha,
            }
        )

    timeline_checks = validate_timeline(
        source_timeline,
        result,
        changed_indexes,
        set(allowed_people),
        audio_by_name,
    )
    summary = summarize(run_manifest["session_id"], result, allowed_people)

    output_timeline = args.output_root / "matching" / "speaker-timeline.json"
    output_summary = args.output_root / "matching" / "speaker-attribution-summary.json"
    evidence_copy = args.output_root / "human-evidence" / "human-review-feedback.json"
    write_json(output_timeline, result)
    write_json(output_summary, summary)
    write_json(evidence_copy, feedback)

    superseded_sha = sha256_file(args.superseded_minutes)
    artifact_checks = [
        {
            "check": "superseded_minutes_unchanged",
            "pass": superseded_sha == args.superseded_minutes_sha256,
            "expected": args.superseded_minutes_sha256,
            "actual": superseded_sha,
        },
        {
            "check": "feedback_copy_exact_json",
            "pass": read_json(evidence_copy) == feedback,
        },
    ]
    minutes_checks = validate_minutes(args.minutes_candidate, result)
    all_checks = feedback_checks + audio_checks + timeline_checks + artifact_checks + minutes_checks
    status = "pass" if all(check["pass"] for check in all_checks) else "fail"

    evidence_manifest = {
        "schema_version": 1,
        "session_id": run_manifest["session_id"],
        "source_run": str(args.source_run_manifest.parent),
        "source_files": {
            "timeline": {
                "path": str(args.source_timeline),
                "sha256": sha256_file(args.source_timeline),
            },
            "summary": {
                "path": str(args.source_summary),
                "sha256": sha256_file(args.source_summary),
            },
            "run_manifest": {
                "path": str(args.source_run_manifest),
                "sha256": sha256_file(args.source_run_manifest),
            },
            "review_manifest": {
                "path": str(args.review_manifest),
                "sha256": sha256_file(args.review_manifest),
            },
            "human_feedback": {
                "path": str(args.human_feedback),
                "sha256": sha256_file(args.human_feedback),
            },
        },
        "applications": applications,
        "scope": "exact reviewed segments only; no adjacent or cluster expansion",
        "outputs": {
            "timeline": {
                "path": str(output_timeline),
                "sha256": sha256_file(output_timeline),
            },
            "summary": {
                "path": str(output_summary),
                "sha256": sha256_file(output_summary),
            },
            "human_feedback_copy": {
                "path": str(evidence_copy),
                "sha256": sha256_file(evidence_copy),
            },
        },
    }
    if args.minutes_candidate is not None:
        evidence_manifest["outputs"]["minutes_candidate"] = {
            "path": str(args.minutes_candidate),
            "sha256": sha256_file(args.minutes_candidate),
        }
    write_json(args.output_root / "evidence-manifest.json", evidence_manifest)

    validation = {
        "schema_version": 1,
        "session_id": run_manifest["session_id"],
        "status": status,
        "acceptance_state": "waiting_role" if status == "pass" and minutes_checks else "running",
        "checks": all_checks,
        "metrics": summary,
        "human_review_applications": applications,
        "candidate_path": str(args.minutes_candidate) if args.minutes_candidate else None,
        "boundary": (
            "Technical candidate gate only. Independent QA and durable-owner acceptance "
            "are still required before replacing the superseded minutes."
        ),
    }
    write_json(args.output_root / "stage4-validation.json", validation)
    if status != "pass":
        failed = [check["check"] for check in all_checks if not check["pass"]]
        raise SystemExit(f"stage-4 validation failed: {', '.join(failed)}")


if __name__ == "__main__":
    main()
