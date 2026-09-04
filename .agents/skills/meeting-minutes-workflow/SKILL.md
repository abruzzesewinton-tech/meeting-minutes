---
name: meeting-minutes-workflow
description: Standardize the local meeting-minutes workflow, including frozen audio intake, ASR and diarization evidence, reusable human voice-review pages, conservative speaker attribution, readable transcripts, key-claim review, minutes, PDF delivery, and gate-based acceptance. Use for meeting recordings, speaker identity or clip-quality review packs, “谁说了什么” minutes, or requests to package and validate the meeting workflow.
---

# Meeting Minutes Workflow

Use one evidence-bound workflow per meeting. Keep audio local unless the user explicitly authorizes upload.

## Start

1. Read the project `THREAD_STATE.md`, `DECISIONS.md`, and `OPEN_LOOPS.md`.
2. Freeze source audio identity, duration, meeting context, participants, and output root.
3. Initialize `workflow-state.json` with `scripts/workflowctl.py init`.
4. Reuse valid ASR or diarization artifacts when source identity is unchanged. Do not rerun merely to normalize packaging.

Read `references/workflow-contract.md` before advancing a formal meeting beyond a content draft.

## Create Human Voice Review

Never handwrite a meeting-specific review page.

1. Create a review spec following `references/review-protocol.md`.
2. Run `scripts/create_review_pack.py --spec <spec.json> --output <new-directory>`.
3. Run `scripts/validate_review_pack.py <review-directory>`.
4. Give the user the generated `index.html`.
5. Validate the returned JSON with `scripts/validate_review_response.py`.

The standard page supports:

- speaker identity;
- clean single-voice quality;
- identity plus quality for anonymous clusters;
- key-claim speaker attribution;
- custom single-choice questions.

All packs use `meeting-voice-review/v1` and return:

```json
{
  "schema_version": 1,
  "protocol": "meeting-voice-review/v1",
  "task_id": "TASK-...",
  "meeting_id": "MM-...",
  "review_kind": "key_claim_speaker",
  "review_manifest_sha256": "...",
  "answers": {
    "K001": {
      "speaker": "姓名"
    }
  }
}
```

## Attribution Gates

- Do not place system answers, candidate names, scores, or expected labels in the review page.
- Treat participant lists as allowed choices, not proof of identity.
- Do not assign by elimination.
- Keep overlap, short speech, noise, and weak evidence unconfirmed.
- A clean reviewed clip confirms that clip. It does not automatically promote a whole cluster.
- Representative key-claim review supports the reviewed claim. It does not make every timeline record manually confirmed.

## User-Readable Outputs

- Display confirmed names only when the attribution gate passes.
- Display all other content as `未确认发言人`.
- Keep model candidates and scores only in internal JSON.
- Do not show `候选：姓名` in readable transcripts, minutes, or PDFs.
- Keep original model text and provenance unchanged.

## Formal Delivery

Advance workflow stages only with `scripts/workflowctl.py advance`.

Formal named minutes require:

1. frozen source;
2. validated ASR;
3. validated diarization;
4. validated identity review;
5. readable transcript;
6. validated key-claim speaker review;
7. minutes plus evidence index;
8. final manifest and delivery validation.

A content-only draft may be produced earlier, but label it `review_candidate / speaker_attribution_pending`.

For PDF delivery, also use the PDF skill and render every page before delivery.

## Stop Conditions

Stop without promotion when:

- source identity changes;
- review response is incomplete or does not match the manifest hash;
- a cluster shows overmerge risk;
- a named commitment lacks human-reviewed speaker evidence;
- readable output leaks candidate names;
- a validation artifact does not report pass.

Do not install, download models, upload audio, change default runtime, or send files externally without explicit authorization.
