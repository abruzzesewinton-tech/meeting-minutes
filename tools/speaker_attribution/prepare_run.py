#!/usr/bin/env python3
"""Create and validate a session-scoped, immutable-input run manifest."""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import soundfile as sf

from speaker_utils import sha256_file


EXPECTED_AUDIO_SHA256 = {
    "audio-0001.wav": "0000000000000000000000000000000000000000000000000000000000000000",
    "audio-0002.wav": "0000000000000000000000000000000000000000000000000000000000000000",
    "audio-0003.wav": "0000000000000000000000000000000000000000000000000000000000000000",
    "audio-0004.wav": "0000000000000000000000000000000000000000000000000000000000000000",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-dir", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--moss-model", required=True, type=Path)
    parser.add_argument("--moss-tool-root", required=True, type=Path)
    parser.add_argument("--campplus-model", required=True, type=Path)
    parser.add_argument("--campplus-tool-root", required=True, type=Path)
    parser.add_argument("--anchor-manifest", required=True, type=Path)
    parser.add_argument("--chunk-seconds", type=float, default=120.0)
    parser.add_argument("--padding-seconds", type=float, default=3.0)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--dtype", default="fp16")
    parser.add_argument("--max-new-tokens", type=int, default=2048)
    return parser.parse_args()


def git_revision(path: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def main() -> None:
    args = parse_args()
    if args.output_root.exists() and any(args.output_root.iterdir()):
        raise SystemExit(f"output root must be new or empty: {args.output_root}")
    session = json.loads((args.session_dir / "session.json").read_text(encoding="utf-8"))
    if session.get("id") != "DEMO-SESSION":
        raise SystemExit(f"unexpected session id: {session.get('id')}")
    if [item.get("file") for item in session.get("segments", [])] != list(EXPECTED_AUDIO_SHA256):
        raise SystemExit("session audio list differs from locked four-file input")

    audio_files = []
    cumulative_offset = 0.0
    for name, expected_sha in EXPECTED_AUDIO_SHA256.items():
        path = args.session_dir / name
        actual_sha = sha256_file(path)
        if actual_sha != expected_sha:
            raise SystemExit(f"SHA mismatch for {name}: {actual_sha}")
        info = sf.info(path)
        duration = float(info.frames / info.samplerate)
        audio_files.append({
            "name": name,
            "path": str(path),
            "bytes": path.stat().st_size,
            "sha256": actual_sha,
            "sample_rate": info.samplerate,
            "channels": info.channels,
            "duration_seconds": duration,
            "meeting_offset_seconds": cumulative_offset,
        })
        cumulative_offset += duration

    tool_dir = Path(__file__).resolve().parent
    script_files = sorted(
        path for path in tool_dir.glob("*.py") if path.name != "__init__.py"
    )
    anchor_manifest = json.loads(args.anchor_manifest.read_text(encoding="utf-8"))
    confirmed_persons = [person["name"] for person in anchor_manifest["persons"]]
    expected_persons = ["我", "示例发言人乙", "示例发言人丙"]
    if len(confirmed_persons) < 2 or len(set(confirmed_persons)) != len(confirmed_persons):
        raise SystemExit(f"anchor manifest must contain at least two unique people: {confirmed_persons}")
    unexpected_persons = sorted(set(confirmed_persons) - set(expected_persons))
    if unexpected_persons:
        raise SystemExit(f"anchor manifest contains unexpected people: {unexpected_persons}")

    manifest = {
        "contract_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "local_only": True,
        "network_allowed": False,
        "session_id": session["id"],
        "session_json": {
            "path": str(args.session_dir / "session.json"),
            "sha256": sha256_file(args.session_dir / "session.json"),
        },
        "audio_files": audio_files,
        "total_duration_seconds": cumulative_offset,
        "models": {
            "moss": {
                "path": str(args.moss_model),
                "revision": args.moss_model.name,
                "tool_root": str(args.moss_tool_root),
                "tool_revision": git_revision(args.moss_tool_root),
            },
            "campplus": {
                "path": str(args.campplus_model),
                "sha256": sha256_file(args.campplus_model),
                "model_revision": "v1.0.0",
                "tool_root": str(args.campplus_tool_root),
                "tool_revision": git_revision(args.campplus_tool_root),
            },
        },
        "anchors": {
            "path": str(args.anchor_manifest),
            "sha256": sha256_file(args.anchor_manifest),
            "allowed_confirmed_persons": confirmed_persons,
            "missing_confirmed_persons": [
                name for name in expected_persons if name not in confirmed_persons
            ],
        },
        "scripts": {str(path.relative_to(tool_dir)): sha256_file(path) for path in script_files},
        "parameters": {
            "audio_first": 1,
            "audio_last": 4,
            "chunk_seconds": args.chunk_seconds,
            "padding_seconds": args.padding_seconds,
            "device": args.device,
            "dtype": args.dtype,
            "max_new_tokens": args.max_new_tokens,
            "identity_states": ["confirmed_person", "model_candidate", "unconfirmed"],
            "open_set_min_score": 0.55,
            "open_set_min_margin": 0.08,
        },
        "output_root": str(args.output_root),
        "cache_key": sha256_file(args.session_dir / "session.json") + ":" + ":".join(
            item["sha256"] for item in audio_files
        ),
    }
    args.output_root.mkdir(parents=True, exist_ok=False)
    (args.output_root / "run-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({
        "session_id": manifest["session_id"],
        "audio_count": len(audio_files),
        "total_duration_seconds": cumulative_offset,
        "cache_key": manifest["cache_key"],
        "output_root": str(args.output_root),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
