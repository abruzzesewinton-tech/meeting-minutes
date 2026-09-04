#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


PROTOCOL = "meeting-voice-review/v1"
ITEM_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
QUESTION_ID = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
BANNED_KEYS = {
    "expected",
    "expected_answer",
    "system_answer",
    "system_candidate",
    "candidate_name",
    "candidate_score",
    "score",
}
ASSET = Path(__file__).resolve().parents[1] / "assets" / "review-page" / "index.html"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def require_text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value.strip()


def reject_banned_keys(value: Any, location: str = "spec") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in BANNED_KEYS:
                raise ValueError(f"{location} contains forbidden key: {key}")
            reject_banned_keys(child, f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_banned_keys(child, f"{location}[{index}]")


def validate_spec(spec: dict[str, Any]) -> None:
    if spec.get("schema_version") != 1:
        raise ValueError("schema_version must be 1")
    if spec.get("protocol") != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    for field in ("task_id", "meeting_id", "review_kind", "title", "instructions"):
        require_text(spec.get(field), field)
    reject_banned_keys(spec)

    questions = spec.get("questions")
    if not isinstance(questions, list) or not questions:
        raise ValueError("questions must be a non-empty list")
    seen_questions: set[str] = set()
    for index, question in enumerate(questions):
        if not isinstance(question, dict):
            raise ValueError(f"questions[{index}] must be an object")
        qid = require_text(question.get("id"), f"questions[{index}].id")
        if not QUESTION_ID.fullmatch(qid):
            raise ValueError(f"invalid question id: {qid}")
        if qid in seen_questions:
            raise ValueError(f"duplicate question id: {qid}")
        seen_questions.add(qid)
        require_text(question.get("prompt"), f"questions[{index}].prompt")
        if not isinstance(question.get("required", True), bool):
            raise ValueError(f"questions[{index}].required must be boolean")
        choices = question.get("choices")
        if not isinstance(choices, list) or len(choices) < 2:
            raise ValueError(f"questions[{index}].choices must contain at least 2 choices")
        seen_values: set[str] = set()
        for choice_index, choice in enumerate(choices):
            if not isinstance(choice, dict):
                raise ValueError(f"questions[{index}].choices[{choice_index}] must be an object")
            value = require_text(choice.get("value"), "choice.value")
            require_text(choice.get("label"), "choice.label")
            if value in seen_values:
                raise ValueError(f"duplicate choice value {value} in question {qid}")
            seen_values.add(value)

    items = spec.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("items must be a non-empty list")
    seen_items: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"items[{index}] must be an object")
        item_id = require_text(item.get("id"), f"items[{index}].id")
        if not ITEM_ID.fullmatch(item_id):
            raise ValueError(f"invalid item id: {item_id}")
        if item_id in seen_items:
            raise ValueError(f"duplicate item id: {item_id}")
        seen_items.add(item_id)
        require_text(item.get("topic"), f"items[{index}].topic")
        has_clip = isinstance(item.get("audio"), str) and item["audio"].strip()
        has_source = isinstance(item.get("source_audio"), str) and item["source_audio"].strip()
        if has_clip == has_source:
            raise ValueError(f"item {item_id} must provide exactly one of audio or source_audio")
        if has_source:
            start = item.get("start")
            end = item.get("end")
            if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
                raise ValueError(f"item {item_id} start/end must be numbers")
            if start < 0 or end <= start:
                raise ValueError(f"item {item_id} has invalid start/end")


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def probe_duration(path: Path) -> float:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return round(float(result.stdout.strip()), 6)


def render_clip(item: dict[str, Any], destination: Path) -> dict[str, Any]:
    if item.get("audio"):
        source = Path(item["audio"]).expanduser().resolve()
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ]
        source_details = {
            "kind": "existing_clip",
            "path": str(source),
            "sha256": sha256(source),
        }
    else:
        source = Path(item["source_audio"]).expanduser().resolve()
        start = float(item["start"])
        end = float(item["end"])
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{start:.6f}",
            "-t",
            f"{end - start:.6f}",
            "-i",
            str(source),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ]
        source_details = {
            "kind": "source_span",
            "path": str(source),
            "sha256": sha256(source),
            "start": start,
            "end": end,
        }
    if not source.is_file():
        raise FileNotFoundError(source)
    run(command)
    duration = probe_duration(destination)
    if duration <= 0:
        raise ValueError(f"generated clip is empty: {destination}")
    return {
        "audio": f"clips/{destination.name}",
        "sha256": sha256(destination),
        "duration_seconds": duration,
        "source": source_details,
    }


def artifact_entry(root: Path, path: Path) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a standard offline meeting voice-review pack.")
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise RuntimeError("ffmpeg and ffprobe are required")
    if not ASSET.is_file():
        raise FileNotFoundError(ASSET)

    spec_path = args.spec.expanduser().resolve()
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    validate_spec(spec)

    output = args.output.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        raise FileExistsError(f"output directory is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    clips_dir = output / "clips"
    clips_dir.mkdir(exist_ok=True)

    generated_items = []
    for item in spec["items"]:
        destination = clips_dir / f"{item['id']}.wav"
        clip = render_clip(item, destination)
        generated_items.append(
            {
                "id": item["id"],
                "topic": item["topic"],
                **({"context": item["context"]} if item.get("context") else {}),
                **({"source_segments": item["source_segments"]} if item.get("source_segments") else {}),
                **clip,
            }
        )

    questions = []
    for question in spec["questions"]:
        questions.append(
            {
                "id": question["id"],
                "prompt": question["prompt"],
                "required": question.get("required", True),
                "choices": [
                    {
                        "value": choice["value"],
                        "label": choice["label"],
                        **({"help": choice["help"]} if choice.get("help") else {}),
                    }
                    for choice in question["choices"]
                ],
            }
        )

    manifest = {
        "schema_version": 1,
        "protocol": PROTOCOL,
        "template_version": 1,
        "task_id": spec["task_id"],
        "meeting_id": spec["meeting_id"],
        "review_kind": spec["review_kind"],
        "title": spec["title"],
        "instructions": spec["instructions"],
        "questions": questions,
        "items": generated_items,
        "source_spec": {
            "path": str(spec_path),
            "sha256": sha256(spec_path),
        },
        "boundaries": {
            "blind_review": True,
            "answers_prefilled": False,
            "system_candidates_in_page": False,
            "participant_list_is_not_identity_proof": True,
            "do_not_assign_by_elimination": True,
        },
    }
    manifest_path = output / "review-manifest.json"
    write_json(manifest_path, manifest)
    manifest_sha = sha256(manifest_path)

    visible_pack = {
        "schema_version": 1,
        "protocol": PROTOCOL,
        "task_id": spec["task_id"],
        "meeting_id": spec["meeting_id"],
        "review_kind": spec["review_kind"],
        "title": spec["title"],
        "instructions": spec["instructions"],
        "review_manifest_sha256": manifest_sha,
        "questions": questions,
        "items": [
            {
                "id": item["id"],
                "topic": item["topic"],
                **({"context": item["context"]} if item.get("context") else {}),
                "audio": item["audio"],
            }
            for item in generated_items
        ],
    }
    data_path = output / "review-data.js"
    data_path.write_text(
        "window.MEETING_REVIEW_PACK = "
        + json.dumps(visible_pack, ensure_ascii=False, separators=(",", ":"))
        + ";\n",
        encoding="utf-8",
    )
    index_path = output / "index.html"
    shutil.copyfile(ASSET, index_path)

    artifact_paths = [index_path, data_path, manifest_path, *sorted(clips_dir.glob("*.wav"))]
    artifact_manifest = {
        "schema_version": 1,
        "protocol": PROTOCOL,
        "review_manifest_sha256": manifest_sha,
        "artifacts": [artifact_entry(output, path) for path in artifact_paths],
    }
    write_json(output / "artifact-manifest.json", artifact_manifest)

    print(
        json.dumps(
            {
                "result": "created",
                "output": str(output),
                "entry": str(index_path),
                "review_manifest_sha256": manifest_sha,
                "items": len(generated_items),
                "questions": len(questions),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise
