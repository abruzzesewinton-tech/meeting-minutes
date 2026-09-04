# Standard Voice Review Protocol

## Review Spec

Create UTF-8 JSON:

```json
{
  "schema_version": 1,
  "protocol": "meeting-voice-review/v1",
  "task_id": "TASK-2026-07-25-example",
  "meeting_id": "MM-20260725-100000",
  "review_kind": "key_claim_speaker",
  "title": "关键观点说话人复核",
  "instructions": "选择承担实质观点的主要发言人。",
  "questions": [
    {
      "id": "speaker",
      "prompt": "主要发言人",
      "required": true,
      "choices": [
        {"value": "张三", "label": "张三"},
        {"value": "李四", "label": "李四"},
        {"value": "multiple_substantive_speakers", "label": "多人均有实质发言"},
        {"value": "uncertain", "label": "无法判断"}
      ]
    }
  ],
  "items": [
    {
      "id": "K001",
      "topic": "核心结论一",
      "source_audio": "/absolute/audio.wav",
      "start": 12.5,
      "end": 20.0
    }
  ]
}
```

An item may instead provide `"audio": "/absolute/existing-clip.wav"`.

## Dual-Question Pack

For anonymous cluster review, use both questions:

```json
[
  {
    "id": "speaker",
    "prompt": "这段主要是谁",
    "required": true,
    "choices": [
      {"value": "张三", "label": "张三"},
      {"value": "uncertain", "label": "无法判断"}
    ]
  },
  {
    "id": "quality",
    "prompt": "片段内是否只有一个人声",
    "required": true,
    "choices": [
      {"value": "clean_single_voice", "label": "只有这一人声"},
      {"value": "contains_other_voice", "label": "含其他人声"},
      {"value": "too_noisy_or_unclear", "label": "嘈杂或听不清"}
    ]
  }
]
```

Do not ask for one cluster-level name when individual clips may contain different people.

## Generated Pack

```text
review-directory/
  index.html
  review-data.js
  review-manifest.json
  artifact-manifest.json
  clips/
```

The HTML is immutable standard UI. `review-data.js` contains only user-visible prompts and choices. It must not contain expected answers, system candidates, scores, or hidden names.

## Response Rules

- Every item must answer every required question.
- No extra item or question is accepted.
- Values must exactly match manifest choices.
- `review_manifest_sha256` must match the generated pack.
- Validate and normalize the response before applying it to attribution.

## Suggested Review Kinds

- `speaker_identity`
- `voice_cleanliness`
- `anonymous_cluster`
- `key_claim_speaker`
- `custom_single_choice`
