#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


TOOL_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_ROOT))

from diarize_chunked import core_ranges
from finalize_stage4 import apply_feedback


class SpeakerAttributionContractTests(unittest.TestCase):
    def test_chunk_ranges_cover_duration_without_tiny_tail(self) -> None:
        ranges = core_ranges(596.2, 120.0)
        self.assertEqual(ranges[0][0], 0.0)
        self.assertEqual(ranges[-1][1], 596.2)
        self.assertGreaterEqual(ranges[-1][1] - ranges[-1][0], 30.0)
        self.assertEqual([right for _, right in ranges[:-1]], [left for left, _ in ranges[1:]])

    def test_demo_anchor_manifest_has_two_example_people(self) -> None:
        anchors = json.loads(
            (TOOL_ROOT / "anchors-DEMO.json").read_text(encoding="utf-8")
        )
        self.assertEqual([person["name"] for person in anchors["persons"]], ["我", "示例发言人乙"])
        self.assertTrue(all(len(person["anchors"]) >= 2 for person in anchors["persons"]))
        self.assertTrue(all(anchor["end"] - anchor["start"] >= 1.0 for person in anchors["persons"] for anchor in person["anchors"]))

    def test_matcher_accepts_session_scoped_additional_confirmed_people(self) -> None:
        source = (TOOL_ROOT / "open_set_match.py").read_text(encoding="utf-8")
        self.assertIn("at least two unique people", source)
        self.assertIn('run_manifest["anchors"]["allowed_confirmed_persons"]', source)

    def test_matcher_exposes_only_three_identity_states(self) -> None:
        source = (TOOL_ROOT / "open_set_match.py").read_text(encoding="utf-8")
        self.assertIn('{"confirmed_person", "model_candidate", "unconfirmed"}', source)
        self.assertIn("No nearest-name fallback", source)

    def test_review_file_names_are_anonymous(self) -> None:
        source = (TOOL_ROOT / "build_review_packs.py").read_text(encoding="utf-8")
        self.assertIn('f"U{cluster_index:03d}-{example_index}.wav"', source)
        self.assertIn('f"B{index:03d}.wav"', source)

    def test_stage4_feedback_changes_only_the_exact_segment(self) -> None:
        timeline = [
            {
                "id": "seg_0001",
                "audio_file": "audio-0001.wav",
                "start": 1.0,
                "end": 2.0,
                "meeting_start": 1.0,
                "identity_status": "model_candidate",
                "confirmed_person": None,
                "attribution_reason": "open_set_gate_not_met",
                "identity_evidence": {"method": "model"},
            },
            {
                "id": "seg_0001",
                "audio_file": "audio-0002.wav",
                "start": 1.0,
                "end": 2.0,
                "meeting_start": 601.0,
                "identity_status": "unconfirmed",
                "confirmed_person": None,
                "attribution_reason": "too_short_for_voiceprint",
                "identity_evidence": {"method": "model"},
            },
        ]
        feedback = {
            "confirmed_at": "2026-07-17T00:00:00+08:00",
            "confirmation_source": "test",
        }
        item = {
            "review_id": "S001",
            "audio_file": "audio-0001.wav",
            "segment_id": "seg_0001",
            "start": 1.0,
            "end": 2.0,
            "meeting_start": 1.0,
            "confirmed_name": "示例发言人丙",
            "file": "clip.wav",
            "file_sha256": "a" * 64,
            "clip_duration_seconds": 1.0,
        }
        with tempfile.TemporaryDirectory() as directory:
            feedback_path = Path(directory) / "feedback.json"
            feedback_path.write_text(json.dumps(feedback), encoding="utf-8")
            result, applications, changed = apply_feedback(
                timeline,
                feedback,
                feedback_path,
                [item],
                {"我", "示例发言人乙", "示例发言人丙"},
            )
        self.assertEqual(changed, {0})
        self.assertEqual(result[0]["confirmed_person"], "示例发言人丙")
        self.assertEqual(result[0]["attribution_reason"], "human_review_confirmation")
        self.assertEqual(result[1], timeline[1])
        self.assertEqual(applications[0]["review_id"], "S001")


if __name__ == "__main__":
    unittest.main()
