# 온디바이스 모델 자산

경보음 감지에 쓰는 모델이 들어 있습니다. Google YAMNet 을 쓰다가, 한국 경보음을
직접 학습시킨 모델로 바꿨습니다.

| 파일 | 크기 | 용도 |
|---|---|---|
| `emergency_sound.onnx` | 21MB | 파형 → 로짓. 로그멜 전처리까지 그래프 안에 들어 있음 |
| `emergency_sound_metadata.json` | 1KB | 클래스 이름과 입력 규격 |

## 모델

- 구조: EfficientAT `mn10_as` (MobileNetV3 계열, AudioSet 사전학습) 파인튜닝, 420만 파라미터
- 학습 데이터: AI Hub 「자연 및 인공적 발생 非언어적 소리 데이터」(dataSetSn=644)
- 입력: **32kHz mono float32, 4초 = 128000 샘플**, `[batch, 128000]`
- 출력: `[batch, 5]` 로짓 (softmax 는 앱에서)
- 클래스: `background`, `fire_alarm`, `civil_defense_siren`,
  `emergency_vehicle_siren`, `general_alarm`

전처리(preemphasis → STFT → Kaldi 멜뱅크 → log → 정규화)를 **ONNX 그래프 안에**
넣었습니다. Dart 쪽에 멜 스펙트로그램을 다시 구현하면 창 함수나 필터뱅크 정의가
미세하게 어긋나고, 그러면 "모델은 멀쩡한데 앱에서만 성능이 나쁜" 형태의 버그가
됩니다. 앱은 원시 파형만 넣으면 됩니다.

## 다시 만들기

학습 프로젝트는 이 저장소 밖에 있습니다
(`korean_emergency_sound_ai`). 체크포인트에서 앱용 ONNX 를 다시 뽑으려면:

```bash
cd <korean_emergency_sound_ai>
python scripts/export_onnx_for_app.py
# → artifacts/export_v4_5class/emergency_sound.onnx
```

이 스크립트는 내보낸 뒤 **PyTorch 와 onnxruntime 의 출력이 일치하는지 직접
검증합니다.** 통과하지 못하면 실패로 끝납니다. 여기서 안 잡으면 앱에서 잡아야
하는데, 앱에서는 원인을 알 수 없습니다.

`torch.stft` 는 ONNX 로 내보낼 수 없어(complex 미지원) STFT 를 고정 가중치
conv1d 로 다시 썼습니다. 수학적으로 같은 연산이고, 결과 그래프가
Conv/MatMul/Log 같은 기본 연산만 쓰므로 모바일 런타임에서 확실히 돕니다.
동등성은 스크립트가 원본 프론트엔드와 직접 비교해 확인합니다
(마지막 측정: 로짓 차이 9.3e-06).

새로 내보낸 뒤 이 디렉터리에 복사하세요.

```
cp artifacts/export_v4_5class/emergency_sound.onnx app/assets/models/
cp artifacts/export_v4_5class/metadata.json \
   app/assets/models/emergency_sound_metadata.json
```

## 클래스 순서

예전에는 `alarm_detector.dart` 가 클래스 **인덱스**를 하드코딩해서, 모델을 새로
받을 때마다 사람이 눈으로 검증해야 했습니다. 지금은 `metadata.json` 의
`class_names` 를 읽어 **이름으로** 매핑하고, 모르는 이름이 나오면 로드 자체를
실패시킵니다. 인덱스가 밀려 화재경보 자리에 다른 소리가 들어오는 일은 구조적으로
막혀 있습니다.

클래스를 새로 추가했다면 `AlarmDetector._alertTypeFor` 에 매핑을 추가해야 하고,
안 하면 앱이 모델을 못 불러옵니다 — 조용히 틀리는 것보다 낫습니다.

## 성능 (측정값)

독립 평가 — 학습에 쓰지 않은 한국 공식 음원(행정안전부·지자체 민방위 훈련 음원,
경찰차/구급차/소방차 사이렌)과 ESC-50 2.67시간 배경 소음 기준.

| | 값 |
|---|---|
| 경보 4종 재현율 (연속 4창, 확률 0.6) | 100% |
| 배경 오발령 | 2.67시간 중 **0건** |
| 알람시계 → 화재경보 오승격 | 0% |
| 추론 지연 | 4초 창당 8.5ms (PC, 2스레드) / **20.7ms** (Android 에뮬레이터 x86_64) |

기기에서도 확인했습니다 (`integration_test/alarm_model_test.dart`, Android 15
에뮬레이터). 학습에 쓰지 않은 공식 음원을 실제 ONNX 세션에 넣은 결과:

| 입력 | 판정 |
|---|---|
| 민방위 공습경보 파상음 (국민안전24) | `civil_defense_siren` 100% |
| 구급차 사이렌 | `emergency_vehicle_siren` 100% |
| 핑크 노이즈 | `background` 100% |

0.5초마다 한 창을 처리하면 되므로 20.7ms 는 예산의 4% 다. 마이크부터 추론까지
전체 경로를 60초 돌렸을 때 CPU 11.5%, 오류 0건, 밀려서 건너뛴 창 0개였다.

**0건은 "시간당 0회"가 아닙니다.** 2.67시간에서 0건이면 95% 상한이 시간당 약
1.1회입니다. 더 좁히려면 더 긴 배경 녹음이 필요합니다.

한계도 적어 둡니다.

- `fire_alarm` 은 **독립 검증이 없습니다.** 시험 성적(19/19)은 전부 AI Hub 644
  안에서 나온 것이고, 한국 화재경보기 실녹음을 따로 구하지 못했습니다.
  국내 화재경보 음향은 NFTC 203 이 90dB@1m 만 규정하고 파형은 정하지 않아
  기종별 편차가 큽니다 — 미국 NFPA 72 의 Temporal-3 같은 공통 규격이 없습니다.
- 학습 표본이 작습니다 (`fire_alarm` 193, `general_alarm` 226 클립).
  AudioSet 사전학습 덕에 일반화가 되지만, 처음 보는 기종에서의 성능은
  측정된 적이 없습니다.

## 마이크 규격

앱은 마이크를 **24kHz** 로 엽니다 (백엔드 전사 계약). 모델은 32kHz 를 원하므로
`AudioCapture` 가 선형보간으로 올려 먹입니다. 24kHz 는 12kHz 위를 담지 못하고
모델은 15kHz 까지 보도록 학습됐지만, 실제로 재 보니 차이가 없었습니다 —
창 단위 예측 일치 99.1%, 발령 결과 동일. 경보음의 정보는 전부 저역에 있습니다.

## 플랫폼 요구사항

`flutter_onnxruntime` 이 요구합니다.

- **iOS 16 이상** (`Runner.xcodeproj` 의 `IPHONEOS_DEPLOYMENT_TARGET` 을 16.0 으로
  올려 두었습니다. iPhone 8 이후 기기입니다.)
- macOS 14 이상
- Android: `proguard-rules.pro` 에 `-keep class ai.onnxruntime.** { *; }` 필요
  (설정되어 있습니다). minSdk 24 그대로.

## 폰트

`app/assets/fonts/` 에 Pretendard 를 넣어야 합니다
(<https://github.com/orioncactus/pretendard> · OFL 라이선스).

```
Pretendard-Regular.otf
Pretendard-Medium.otf
Pretendard-Bold.otf
Pretendard-ExtraBold.otf
```

폰트를 넣지 않으면 시스템 기본 글꼴로 대체되어 동작은 하지만, 한국어 자막의
굵기 대비가 약해져 저시력 사용자의 가독성이 떨어집니다.
