# 체험 모드 대본

`script.json` 을 여기 두면 "예시로 먼저 보기"가 그 대본으로 돌아간다.
없으면 앱에 내장된 기본 대본을 쓴다.

이 디렉터리의 `script.json` 은 저장소에 올라가지 않는다. 외부 영상이나 녹음에서
받아 적은 대사는 각자 기기에만 둔다.

형식:

```json
[
  {
    "startMs": 3500,
    "endMs": 6200,
    "speaker": "A",
    "text": "대사",
    "tone": "neutral",
    "toneConfidence": 0.55,
    "intensity": 0.5,
    "toneBasis": "voice"
  }
]
```

- `startMs` / `endMs` — 체험 시작 기준 밀리초
- `speaker` — 목소리마다 다른 글자. 처음 등장하는 화자는 자동으로 늦게 확정된다
- `tone` — calm | excited | angry | happy | sad | neutral
- `toneConfidence` — 0~1. 0.35 미만이면 말투를 표시하지 않는다
- `intensity` — 0~1. 글자 크기
- `toneBasis` — voice | voice_text

`voice` 인 줄은 `angry` 가 될 수 없고 `toneConfidence` 가 0.6 을 넘을 수 없다.
실제 시스템이 만들 수 없는 조합이라 그대로 두면 미리보기가 거짓을 가르친다.
어긋난 값은 불러올 때 자동으로 맞춘다.
