#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


STAGES = [
    "source_frozen",
    "asr",
    "diarization",
    "identity_review",
    "transcript",
    "key_claim_review",
    "minutes",
    "delivery",
]
REQUIRED_EVIDENCE = {
    "asr": {"transcript", "validation"},
    "diarization": {"timeline", "validation"},
    "identity_review": {"review_manifest", "human_response", "validation"},
    "transcript": {"readable_transcript", "validation"},
    "key_claim_review": {"review_manifest", "human_response", "validation"},
    "minutes": {"minutes", "evidence_index", "validation"},
    "delivery": {"final_manifest", "validation"},
}


def now() -> str:
    return datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_evidence(values: list[str]) -> dict[str, Path]:
    evidence: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"evidence must use name=path: {value}")
        name, raw_path = value.split("=", 1)
        if not name or name in evidence:
            raise ValueError(f"invalid or duplicate evidence name: {name}")
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(path)
        evidence[name] = path
    return evidence


def validation_passes(path: Path) -> bool:
    value = json.loads(path.read_text(encoding="utf-8"))
    return (
        value.get("result") == "pass"
        or value.get("status") == "pass"
        or value.get("pass") is True
    )


def command_init(args: argparse.Namespace) -> int:
    spec_path = args.spec.expanduser().resolve()
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    for field in ("task_id", "meeting_id", "session_id", "topic", "participants", "source_audio"):
        if field not in spec:
            raise ValueError(f"workflow spec missing {field}")
    if not isinstance(spec["participants"], list) or not spec["participants"]:
        raise ValueError("participants must be a non-empty list")
    if not isinstance(spec["source_audio"], list) or not spec["source_audio"]:
        raise ValueError("source_audio must be a non-empty list")

    state_path = args.state.expanduser().resolve()
    if state_path.exists():
        raise FileExistsError(state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True)

    sources = []
    for raw_path in spec["source_audio"]:
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(path)
        sources.append(
            {
                "path": str(path),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
        )

    stages = {
        stage: {
            "status": "complete" if stage == "source_frozen" else "pending",
            "completed_at": now() if stage == "source_frozen" else None,
            "evidence": {"source_audio": sources} if stage == "source_frozen" else {},
        }
        for stage in STAGES
    }
    state = {
        "schema_version": 1,
        "protocol": "meeting-minutes-workflow/v1",
        "task_id": spec["task_id"],
        "meeting_id": spec["meeting_id"],
        "session_id": spec["session_id"],
        "topic": spec["topic"],
        "participants": spec["participants"],
        "created_at": now(),
        "updated_at": now(),
        "source_spec": {"path": str(spec_path), "sha256": sha256(spec_path)},
        "stages": stages,
        "current_stage": "asr",
        "maturity": "processing",
    }
    write_json(state_path, state)
    print(json.dumps({"result": "initialized", "state": str(state_path), "current_stage": "asr"}, ensure_ascii=False, indent=2))
    return 0


def command_advance(args: argparse.Namespace) -> int:
    state_path = args.state.expanduser().resolve()
    state = json.loads(state_path.read_text(encoding="utf-8"))
    stage = args.stage
    if stage not in REQUIRED_EVIDENCE:
        raise ValueError(f"stage cannot be advanced directly: {stage}")
    stage_index = STAGES.index(stage)
    previous = STAGES[stage_index - 1]
    if state["stages"][previous]["status"] != "complete":
        raise ValueError(f"previous stage is not complete: {previous}")
    if state["stages"][stage]["status"] == "complete":
        raise ValueError(f"stage is already complete: {stage}")

    evidence = parse_evidence(args.evidence)
    required = REQUIRED_EVIDENCE[stage]
    missing = required - set(evidence)
    extra = set(evidence) - required
    if missing:
        raise ValueError(f"missing evidence: {sorted(missing)}")
    if extra:
        raise ValueError(f"unexpected evidence: {sorted(extra)}")
    if not validation_passes(evidence["validation"]):
        raise ValueError("validation artifact does not report pass")

    recorded = {
        name: {
            "path": str(path),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }
        for name, path in sorted(evidence.items())
    }
    state["stages"][stage] = {
        "status": "complete",
        "completed_at": now(),
        "evidence": recorded,
    }
    next_stage = STAGES[stage_index + 1] if stage_index + 1 < len(STAGES) else None
    state["current_stage"] = next_stage
    state["updated_at"] = now()
    if stage == "identity_review" or stage == "key_claim_review":
        state["maturity"] = "processing"
    if stage == "minutes":
        state["maturity"] = "review_candidate"
    if stage == "delivery":
        state["maturity"] = "internal_final"
    write_json(state_path, state)
    print(
        json.dumps(
            {
                "result": "advanced",
                "stage": stage,
                "next_stage": next_stage,
                "maturity": state["maturity"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def command_status(args: argparse.Namespace) -> int:
    state = json.loads(args.state.expanduser().resolve().read_text(encoding="utf-8"))
    summary = {
        "task_id": state["task_id"],
        "meeting_id": state["meeting_id"],
        "current_stage": state["current_stage"],
        "maturity": state["maturity"],
        "stages": {name: data["status"] for name, data in state["stages"].items()},
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Control evidence-gated meeting-minutes workflow state.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init = subparsers.add_parser("init")
    init.add_argument("--spec", required=True, type=Path)
    init.add_argument("--state", required=True, type=Path)
    init.set_defaults(func=command_init)

    advance = subparsers.add_parser("advance")
    advance.add_argument("--state", required=True, type=Path)
    advance.add_argument("--stage", required=True, choices=STAGES[1:])
    advance.add_argument("--evidence", action="append", default=[], help="name=path")
    advance.set_defaults(func=command_advance)

    status = subparsers.add_parser("status")
    status.add_argument("--state", required=True, type=Path)
    status.set_defaults(func=command_status)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise
