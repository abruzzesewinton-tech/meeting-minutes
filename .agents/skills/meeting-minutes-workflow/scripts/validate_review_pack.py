#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


PROTOCOL = "meeting-voice-review/v1"
BANNED_VISIBLE_KEYS = {
    "expected",
    "expected_answer",
    "system_answer",
    "system_candidate",
    "candidate_name",
    "candidate_score",
    "score",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_banned(value: Any, location: str = "visible_pack") -> list[str]:
    problems = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key in BANNED_VISIBLE_KEYS:
                problems.append(f"{location}.{key}")
            problems.extend(find_banned(child, f"{location}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            problems.extend(find_banned(child, f"{location}[{index}]"))
    return problems


def load_visible_data(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8").strip()
    prefix = "window.MEETING_REVIEW_PACK = "
    if not text.startswith(prefix) or not text.endswith(";"):
        raise ValueError("review-data.js has invalid wrapper")
    return json.loads(text[len(prefix) : -1])


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a standard meeting voice-review pack.")
    parser.add_argument("pack", type=Path)
    parser.add_argument("--write", type=Path)
    args = parser.parse_args()

    root = args.pack.expanduser().resolve()
    errors: list[str] = []
    required = [
        root / "index.html",
        root / "review-data.js",
        root / "review-manifest.json",
        root / "artifact-manifest.json",
    ]
    for path in required:
        if not path.is_file():
            errors.append(f"missing {path.name}")
    if errors:
        result = {"result": "fail", "errors": errors}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1

    manifest = json.loads((root / "review-manifest.json").read_text(encoding="utf-8"))
    artifact_manifest = json.loads((root / "artifact-manifest.json").read_text(encoding="utf-8"))
    visible = load_visible_data(root / "review-data.js")
    manifest_sha = sha256(root / "review-manifest.json")

    if manifest.get("protocol") != PROTOCOL:
        errors.append("manifest protocol mismatch")
    if visible.get("protocol") != PROTOCOL:
        errors.append("visible protocol mismatch")
    if visible.get("review_manifest_sha256") != manifest_sha:
        errors.append("visible manifest SHA mismatch")
    if artifact_manifest.get("review_manifest_sha256") != manifest_sha:
        errors.append("artifact manifest SHA mismatch")
    for field in ("task_id", "meeting_id", "review_kind"):
        if visible.get(field) != manifest.get(field):
            errors.append(f"visible {field} mismatch")

    banned = find_banned(visible)
    if banned:
        errors.append("visible data contains forbidden keys: " + ", ".join(banned))
    index_text = (root / "index.html").read_text(encoding="utf-8")
    if 'input type="radio"' not in index_text or "review-data.js" not in index_text:
        errors.append("index.html is not the standard review UI")
    if re_contains_prefill(index_text):
        errors.append("index.html contains prefilled checked answers")

    item_ids = [item.get("id") for item in manifest.get("items", [])]
    if not item_ids or len(item_ids) != len(set(item_ids)):
        errors.append("manifest item ids are empty or duplicated")
    visible_ids = [item.get("id") for item in visible.get("items", [])]
    if visible_ids != item_ids:
        errors.append("visible item order differs from manifest")
    for item in manifest.get("items", []):
        clip = root / item.get("audio", "")
        if not clip.is_file():
            errors.append(f"missing clip {item.get('id')}")
            continue
        if sha256(clip) != item.get("sha256"):
            errors.append(f"clip SHA mismatch {item.get('id')}")
        if not isinstance(item.get("duration_seconds"), (int, float)) or item["duration_seconds"] <= 0:
            errors.append(f"invalid duration {item.get('id')}")

    declared = artifact_manifest.get("artifacts", [])
    declared_paths = {entry.get("path"): entry for entry in declared}
    for relative, entry in declared_paths.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"missing declared artifact {relative}")
            continue
        if sha256(path) != entry.get("sha256"):
            errors.append(f"artifact SHA mismatch {relative}")
        if path.stat().st_size != entry.get("bytes"):
            errors.append(f"artifact byte count mismatch {relative}")

    result = {
        "result": "pass" if not errors else "fail",
        "protocol": PROTOCOL,
        "review_manifest_sha256": manifest_sha,
        "items": len(item_ids),
        "questions": len(manifest.get("questions", [])),
        "artifacts": len(declared_paths),
        "errors": errors,
    }
    if args.write:
        args.write.expanduser().resolve().write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if not errors else 1


def re_contains_prefill(text: str) -> bool:
    return bool(re.search(r"<input\b[^>]*\schecked(?:\s|=|>)", text, flags=re.IGNORECASE))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise
