# Meeting Workflow Contract

## Purpose

Provide one repeatable control path from local audio to evidence-backed meeting minutes. Model runners remain replaceable adapters; stage identity, review protocol, gates, and outputs stay stable.

## Standard Layout

```text
sessions/<session-id>/
  workflow-spec.json
  workflow-state.json
  source/
  transcript/
  diarization/
  speaker-attribution/
  review/
    identity-v1/
    key-claims-v1/
  minutes/
  output/
```

Do not copy source audio merely for layout consistency. Record absolute source paths and SHA256 in `workflow-state.json`.

## Stages

| Stage | Required evidence | Formal gate |
| --- | --- | --- |
| `source_frozen` | source audio SHA, duration, participants | exact source identity |
| `asr` | transcript JSON, validation JSON | complete coverage, no failed chunk |
| `diarization` | anonymous timeline, validation JSON | ordered, in bounds, no forced names |
| `identity_review` | review manifest, human response, validation JSON | response bound to manifest SHA |
| `transcript` | readable transcript, validation JSON | candidates hidden, unconfirmed retained |
| `key_claim_review` | review manifest, human response, validation JSON | every formal named claim covered |
| `minutes` | minutes, evidence index, validation JSON | decisions, proposals, actions separated |
| `delivery` | final manifest, validation JSON | artifact hashes and visual checks pass |

`workflowctl.py` refuses a stage when the previous stage is incomplete or its validation artifact is not pass.

## Maturity

- `processing`: source or model stages incomplete.
- `waiting_user`: a validated review pack awaits a response.
- `review_candidate`: content is readable but speaker or business acceptance remains open.
- `internal_final`: required speaker and content gates pass; no external release implied.

## Evidence Semantics

- `confirmed_person`: sufficient current-meeting evidence for display name.
- `model_candidate`: internal hint only.
- `unconfirmed`: display as `未确认发言人`.
- `human_confirmed_representative_audio`: supports the reviewed claim or cluster sample only.

Never describe model-assisted timeline attribution as sentence-by-sentence human confirmation.

## Decision Language

- Keep proposals as proposals.
- Keep open questions as open questions.
- Record actions only when an owner accepts or the meeting explicitly assigns them.
- Use `待确认` when owner or deadline is absent.

## Runtime Boundary

The workflow package does not authorize ASR, MOSS, CAM++, local LLM, installation, model download, upload, external send, or default-flow changes. Each runtime action follows the active task authorization.
