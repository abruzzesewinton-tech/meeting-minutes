#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


PROTOCOL = "meeting-voice-review/v1"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and normalize a meeting voice-review response.")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--response", required=True, type=Path)
    parser.add_argument("--normalized-output", type=Path)
    parser.add_argument("--validation-output", type=Path)
    args = parser.parse_args()

    manifest_path = args.manifest.expanduser().resolve()
    response_path = args.response.expanduser().resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    response = json.loads(response_path.read_text(encoding="utf-8"))
    errors: list[str] = []

    expected_header = {
        "schema_version": 1,
        "protocol": PROTOCOL,
        "task_id": manifest.get("task_id"),
        "meeting_id": manifest.get("meeting_id"),
        "review_kind": manifest.get("review_kind"),
        "review_manifest_sha256": sha256(manifest_path),
    }
    for field, expected in expected_header.items():
        if response.get(field) != expected:
            errors.append(f"{field} mismatch")

    answers = response.get("answers")
    if not isinstance(answers, dict):
        errors.append("answers must be an object")
        answers = {}
    expected_items = {item["id"] for item in manifest.get("items", [])}
    actual_items = set(answers)
    for item_id in sorted(expected_items - actual_items):
        errors.append(f"missing item {item_id}")
    for item_id in sorted(actual_items - expected_items):
        errors.append(f"extra item {item_id}")

    questions = {question["id"]: question for question in manifest.get("questions", [])}
    normalized_answers: dict[str, dict[str, Any]] = {}
    for item in manifest.get("items", []):
        item_id = item["id"]
        values = answers.get(item_id, {})
        if not isinstance(values, dict):
            errors.append(f"{item_id} answer must be an object")
            values = {}
        normalized_answers[item_id] = {}
        actual_questions = set(values)
        expected_questions = set(questions)
        for qid in sorted(actual_questions - expected_questions):
            errors.append(f"{item_id} has extra question {qid}")
        for qid, question in questions.items():
            value = values.get(qid)
            if value is None or value == "":
                if question.get("required", True):
                    errors.append(f"{item_id}/{qid} is required")
                continue
            allowed = {choice["value"] for choice in question["choices"]}
            if value not in allowed:
                errors.append(f"{item_id}/{qid} has invalid value {value!r}")
                continue
            normalized_answers[item_id][qid] = value

    normalized = {**expected_header, "answers": normalized_answers}
    validation = {
        "result": "pass" if not errors else "fail",
        "protocol": PROTOCOL,
        "manifest": str(manifest_path),
        "manifest_sha256": expected_header["review_manifest_sha256"],
        "response": str(response_path),
        "response_sha256": sha256(response_path),
        "items": len(expected_items),
        "questions": len(questions),
        "errors": errors,
    }
    if args.normalized_output and not errors:
        args.normalized_output.expanduser().resolve().write_text(
            json.dumps(normalized, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    if args.validation_output:
        args.validation_output.expanduser().resolve().write_text(
            json.dumps(validation, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(validation, ensure_ascii=False, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise
