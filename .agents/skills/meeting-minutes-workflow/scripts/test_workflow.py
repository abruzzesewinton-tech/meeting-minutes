#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CREATE = ROOT / "create_review_pack.py"
VALIDATE_PACK = ROOT / "validate_review_pack.py"
VALIDATE_RESPONSE = ROOT / "validate_review_response.py"
WORKFLOW = ROOT / "workflowctl.py"


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, *args],
        check=check,
        capture_output=True,
        text=True,
    )


class MeetingWorkflowTests(unittest.TestCase):
    def test_standard_review_pack_response_and_workflow_gates(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            audio = root / "source.wav"
            with wave.open(str(audio), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16000)
                output.writeframes(b"\x00\x00" * 16000 * 4)

            spec = {
                "schema_version": 1,
                "protocol": "meeting-voice-review/v1",
                "task_id": "TASK-TEST-001",
                "meeting_id": "MM-TEST-001",
                "review_kind": "anonymous_cluster",
                "title": "声线复核测试",
                "instructions": "逐段判断主要发言人和片段质量。",
                "questions": [
                    {
                        "id": "speaker",
                        "prompt": "主要发言人",
                        "required": True,
                        "choices": [
                            {"value": "甲", "label": "甲"},
                            {"value": "uncertain", "label": "无法判断"},
                        ],
                    },
                    {
                        "id": "quality",
                        "prompt": "片段质量",
                        "required": True,
                        "choices": [
                            {"value": "clean_single_voice", "label": "只有这一人声"},
                            {"value": "contains_other_voice", "label": "含其他人声"},
                        ],
                    },
                ],
                "items": [
                    {
                        "id": "A01",
                        "topic": "早段",
                        "source_audio": str(audio),
                        "start": 0.0,
                        "end": 1.5,
                    },
                    {
                        "id": "A02",
                        "topic": "晚段",
                        "source_audio": str(audio),
                        "start": 2.0,
                        "end": 4.0,
                    },
                ],
            }
            spec_path = root / "review-spec.json"
            write_json(spec_path, spec)
            pack = root / "pack"
            run(str(CREATE), "--spec", str(spec_path), "--output", str(pack))
            validation_path = pack / "validation.json"
            run(str(VALIDATE_PACK), str(pack), "--write", str(validation_path))
            validation = json.loads(validation_path.read_text(encoding="utf-8"))
            self.assertEqual(validation["result"], "pass")
            self.assertEqual(validation["items"], 2)
            self.assertEqual(validation["questions"], 2)
            self.assertNotIn("candidate_name", (pack / "review-data.js").read_text(encoding="utf-8"))

            manifest_path = pack / "review-manifest.json"
            response = {
                "schema_version": 1,
                "protocol": "meeting-voice-review/v1",
                "task_id": "TASK-TEST-001",
                "meeting_id": "MM-TEST-001",
                "review_kind": "anonymous_cluster",
                "review_manifest_sha256": sha256(manifest_path),
                "answers": {
                    "A01": {"speaker": "甲", "quality": "clean_single_voice"},
                    "A02": {"speaker": "uncertain", "quality": "contains_other_voice"},
                },
            }
            response_path = root / "response.json"
            normalized_path = root / "normalized.json"
            response_validation = root / "response-validation.json"
            write_json(response_path, response)
            run(
                str(VALIDATE_RESPONSE),
                "--manifest",
                str(manifest_path),
                "--response",
                str(response_path),
                "--normalized-output",
                str(normalized_path),
                "--validation-output",
                str(response_validation),
            )
            self.assertEqual(json.loads(response_validation.read_text())["result"], "pass")
            self.assertEqual(json.loads(normalized_path.read_text())["answers"], response["answers"])

            bad = dict(response)
            bad["review_manifest_sha256"] = "0" * 64
            bad_path = root / "bad-response.json"
            write_json(bad_path, bad)
            bad_run = run(
                str(VALIDATE_RESPONSE),
                "--manifest",
                str(manifest_path),
                "--response",
                str(bad_path),
                check=False,
            )
            self.assertNotEqual(bad_run.returncode, 0)
            self.assertIn("review_manifest_sha256 mismatch", bad_run.stdout)

            workflow_spec = {
                "task_id": "TASK-TEST-001",
                "meeting_id": "MM-TEST-001",
                "session_id": "TEST-SESSION",
                "topic": "测试会议",
                "participants": ["甲", "乙"],
                "source_audio": [str(audio)],
            }
            workflow_spec_path = root / "workflow-spec.json"
            state_path = root / "workflow-state.json"
            write_json(workflow_spec_path, workflow_spec)
            run(str(WORKFLOW), "init", "--spec", str(workflow_spec_path), "--state", str(state_path))

            artifact = root / "artifact.txt"
            artifact.write_text("artifact\n", encoding="utf-8")
            pass_validation = root / "pass.json"
            write_json(pass_validation, {"result": "pass"})
            stage_evidence = {
                "asr": {"transcript": artifact, "validation": pass_validation},
                "diarization": {"timeline": artifact, "validation": pass_validation},
                "identity_review": {
                    "review_manifest": manifest_path,
                    "human_response": normalized_path,
                    "validation": response_validation,
                },
                "transcript": {"readable_transcript": artifact, "validation": pass_validation},
                "key_claim_review": {
                    "review_manifest": manifest_path,
                    "human_response": normalized_path,
                    "validation": response_validation,
                },
                "minutes": {
                    "minutes": artifact,
                    "evidence_index": artifact,
                    "validation": pass_validation,
                },
                "delivery": {"final_manifest": artifact, "validation": pass_validation},
            }
            for stage, evidence in stage_evidence.items():
                command = [str(WORKFLOW), "advance", "--state", str(state_path), "--stage", stage]
                for name, path in evidence.items():
                    command.extend(["--evidence", f"{name}={path}"])
                run(*command)
            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(state["maturity"], "internal_final")
            self.assertTrue(all(value["status"] == "complete" for value in state["stages"].values()))


if __name__ == "__main__":
    unittest.main()
