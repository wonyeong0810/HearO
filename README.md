# HearO

> 감정이 담긴 실시간 자막으로 청각장애인의 일상 소통을 돕는 보조 어플

말의 **내용**만이 아니라 **누가**, **어떤 감정으로**, **얼마나 크게** 말했는지까지
화면으로 전달합니다. 화재경보·사이렌 같은 위급한 소리는 온디바이스로 감지해
진동과 전체화면 경고로 즉시 알립니다.

---

## 목차

- [핵심 설계 결정](#핵심-설계-결정)
- [아키텍처](#아키텍처)
- [빠른 시작](#빠른-시작)
- [API 키 발급](#api-키-발급)
- [프로젝트 구조](#프로젝트-구조)
- [실시간 자막 프로토콜](#실시간-자막-프로토콜)
- [접근성 원칙](#접근성-원칙)
- [개인정보 처리 원칙](#개인정보-처리-원칙)
- [테스트](#테스트)
- [배포](#배포)
- [비용](#비용)
- [알려진 한계](#알려진-한계)

---

## 핵심 설계 결정

### 1. STT — 왜 두 트랙인가

기획서는 "실시간 자막"과 "화자 분리"를 함께 요구합니다. 그런데 **OpenAI 는 이
둘을 한 API 로 제공하지 않습니다.**

| 모델 | 실시간 스트리밍 | 화자 분리 |
|---|:---:|:---:|
| `gpt-live-transcribe` | ✅ WebSocket 델타 | ❌ |
| `gpt-4o-transcribe-diarize` | ❌ 파일 전용 | ✅ |

그래서 **하나의 마이크 입력을 두 트랙으로 갈라** 흘려보내고, 결과를 화면에서
합칩니다.

```
마이크 PCM16 24kHz
   │
   ├─▶ 트랙 1  Realtime WS ─────▶ 즉시 자막 (~300ms, 화자 미정 = 회색)
   │                                  │
   │                                  ├─▶ 운율 분석 ─▶ 글자 크기 + 임시 감정
   │                                  └─▶ LLM 분류  ─▶ 감정 확정 (patch)
   │
   └─▶ 트랙 2  창 버퍼(12초) ──▶ diarize API ──▶ 화자 확정 (patch)
```

자막 한 줄은 **세 단계**로 완성됩니다.

1. 잠정 텍스트 (계속 바뀜, 기울임)
2. 확정 텍스트 + 운율 기반 글자 크기·임시 감정 — **여기서 이미 읽을 수 있음**
3. 화자 색상 확정 + 감정 확정

어느 단계가 실패해도 앞 단계까지는 남습니다. 화자분리 API 가 죽어도 자막은
계속 흐릅니다. 이게 이 구조를 택한 이유입니다.

### 2. 화자 정체성 유지

diarize 모델은 **요청 사이에 화자를 기억하지 않습니다.** 12초 창을 연달아
올리면 매번 "A", "B" 를 새로 배정하므로, 3번째 창의 A 가 1번째 창의 A 와 같은
사람이라는 보장이 없습니다. 대화 도중 자막 색이 뒤바뀌면 오히려 혼란만 줍니다.

세 겹으로 막습니다.

1. **참조 클립 고정** (주력) — 화자별로 깨끗한 2~8초 구간을 잡아 두었다가
   이후 요청에 `known_speaker_references` 로 동봉합니다. 그러면 모델이 우리가
   정한 이름(S1, S2…)을 그대로 돌려줍니다. *모델 제약: 최대 4명*
2. **겹침 대조** — 창 사이 2초 겹침 구간의 발화를 시간·텍스트로 대조해 이어붙입니다.
3. **소거법** — 앞의 둘로도 안 붙은 라벨이 정확히 하나 남고, 이번 창의 화자 수가
   기존과 같을 때만 남은 화자에 배정합니다. 조건이 하나라도 어긋나면 새 화자를
   만듭니다 — *같은 사람을 두 색으로 쪼개는 것보다, 다른 사람을 한 색으로 합치는
   쪽이 사용자에게 더 해롭기 때문입니다.*

### 3. 감정 — 하이브리드인 이유

| 신호 | 얻는 것 | 한계 |
|---|---|---|
| 운율 (온디바이스 계산) | 음량·피치·발화속도. **지연 0**, 네트워크 불필요 | "알겠어"가 체념인지 수긍인지 모름 |
| 텍스트 (LLM) | 문맥·반어법 | 왕복 지연 |

둘을 합칩니다. 운율 판정이 **먼저** 화면에 뜨고, LLM 판정이 도착하면 덮어씁니다.
LLM 호출이 실패해도 감정 표시가 사라지지 않습니다.

여기 쓰는 LLM 은 **STT 와 다른 제공자**입니다 (`EMOTION_*` 설정, 기본값
DeepSeek V4 Flash). 실시간 전사와 화자분리는 OpenAI 고유 기능이라 옮길 수
없지만, 감정 분류는 평범한 chat completions 라 더 싸고 빠른 모델을 쓸 수
있습니다. `EMOTION_BASE_URL` / `EMOTION_MODEL` 두 줄만 바꾸면 제공자가 바뀝니다.

두 가지가 이 경로에 박혀 있습니다.

- **사고(thinking) 모드는 끕니다** (`EMOTION_DISABLE_THINKING`). DeepSeek V4 는
  기본이 켜짐이라, 그대로 두면 첫 토큰까지 수 초가 걸려 타임아웃을 매번 넘기고
  감정이 전부 운율 추정으로 떨어집니다. 화면에는 감정이 계속 표시되므로 **눈으로는
  고장을 알아챌 수 없는** 종류의 고장입니다.
- **응답 형식은 `json_object`** 입니다. DeepSeek 은 strict `json_schema` 를 받지
  않으므로 형식 보장이 API 에서 프롬프트로 내려왔습니다. 그만큼 파서를 방어적으로
  짰고(코드펜스·앞뒤 설명·배열만 오는 경우·모르는 톤 값), 못 읽으면 운율 폴백으로
  내려갑니다. 빈 응답이나 파싱 실패가 연속 3회면 서킷브레이커가 호출을 끊습니다 —
  고장난 제공자를 계속 다시 부르면 돈만 나갑니다.

화면이 어떻게 나오는지는 **말하지 않고도** 볼 수 있습니다. 실시간 자막 화면의
"예시로 먼저 보기"가 예시 대화를 재생합니다 — 마이크 권한도, 인터넷도, 백엔드도
필요 없습니다. 이 앱의 사용자는 소리를 못 듣고, 옆에서 말해 줄 사람이 늘 있는
것도 아닙니다. 그러면 화면 표현을 실제 대화 중에 처음 겪게 되는데, 그때는
대화를 따라가느라 화면을 뜯어볼 여유가 없습니다.

대본(`lib/features/live/demo_script.dart`)은 예시 문장이 아니라 **미리보기의
커버리지**입니다. 감정 6종, 신뢰도 세 구간(표시 안 함 / 약한 문구 / 움직임까지),
판정 근거 두 가지, 말의 세기 범위, 화자가 늦게 확정되는 줄을 모두 지나갑니다.
빠진 게 생기면 `test/demo_script_test.dart` 가 걸러 냅니다 — 이 테스트는 대본이
**실제로 나올 수 없는 조합**(운율 단독 판정인데 신뢰도가 0.6 초과이거나 `화남`)
을 쓰지 않는지도 함께 봅니다. 미리보기가 거짓을 가르치면 안 됩니다.

특히 **운율만으로는 절대 `화남`을 판정하지 않습니다.** 시끄러운 카페에서는
누구나 크게 말합니다. 소리가 크다는 이유로 "화남"을 띄우면 사용자가 상대의
감정을 완전히 오해하게 됩니다 — 실제로 해가 되는 오류라 테스트로 못박아 두었습니다
(`test_emotion.py::test_never_returns_angry_from_prosody_alone`).

### 3-1. 화면은 감정을 단정하지 않습니다

임계값으로 *얼마나* 표시할지는 정할 수 있지만, 그것만으로는 사용자가 이 표시를
**사실로 읽는 것**을 막지 못합니다. 화면에 `화남`이라고 뜨면 그건 주장입니다.
실제로는 목소리와 문장에서 나온 추정이고, 개인차에 크게 흔들립니다 — 원래
목소리가 큰 사람, 사투리, 신나서 흥분한 사람, 말투 특성이 다른 사람(자폐
스펙트럼 등), 문화·연령에 따른 표현 차이.

그리고 이 앱의 사용자는 **판정을 검증할 방법이 없습니다.** 들리는 사람이라면
"화남"이 떠도 목소리를 직접 듣고 아니라고 판단하지만, 여기서는 화면이 유일한
통로입니다. 그래서 네 겹으로 추정임을 드러냅니다.

| 겹 | 방법 | 예 |
|---|---|---|
| 어휘 | 감정이 아니라 **말투**를 말한다 | `화남` → `화난 말투` |
| 문장 | 관찰의 보고임을 드러낸다 | `화난 말투로 들림` |
| 확신 | 근거가 약하면 문구부터 약해진다 | `화난 말투일 수도` + 배경 채우지 않음 |
| 근거 | 배지를 누르면 왜 그렇게 봤는지 나온다 | 확신 정도 · 무엇을 봤는지 · 빗나가는 경우 |

세 번째 겹이 필요한 이유는, 예전에는 확신의 정도가 **색 진하기와 움직임으로만**
나타났기 때문입니다. 둘 다 옆에 비교할 자막이 있어야 읽히는 신호이고, 흑백·
색각이상·저시력 환경에서는 사라집니다. 한 줄만 보고도 알 수 있어야 합니다.

네 번째 겹을 위해 백엔드가 판정과 함께 **근거**(`tone_basis`)를 보냅니다.
`voice`(운율만) 와 `voice_text`(운율+문장)를 구분하는데, 사용자가 걱정하는 오판은
대부분 전자에서 나옵니다 — 사투리도 평소 목소리 크기도 말 빠르기도 전부 운율에
그대로 섞여 들어오기 때문입니다. 근거는 **모르면 약한 쪽으로** 떨어집니다.
부풀려 말하면 사용자가 과신합니다.

첫 세션에는 화면 위에 한 번 안내가 뜨고(기기에 저장, 닫으면 다시 안 뜸),
목록·통계처럼 줄마다 근거를 붙일 수 없는 화면에는 헤더에서 한 번 밝힙니다.

### 4. 경보 감지는 온디바이스

화재경보를 네트워크 상태에 걸어 둘 수 없습니다. 지하실에서도, 비행기 모드에서도,
서버가 죽었을 때도 울려야 합니다. **한국 경보음으로 직접 학습시킨 모델**을 앱에
내장해 완전 오프라인으로 동작합니다.

처음에는 Google YAMNet 을 썼지만 한국 민방위 경보를 잘 잡지 못했습니다 —
AudioSet 의 `Civil defense siren` 은 미국식 웨일링 사이렌 중심입니다. 지금은
AI Hub 「자연 및 인공적 발생 非언어적 소리 데이터」로 EfficientAT `mn10_as`
(AudioSet 사전학습, 420만 파라미터)를 파인튜닝한 5클래스 모델을 씁니다.
파형 → 로짓 전체가 하나의 ONNX 안에 있어 앱은 32kHz 파형만 넣습니다
([`app/assets/models/README.md`](app/assets/models/README.md)).

오탐은 세 겹으로 억제합니다: 확률 임계값 + 연속 창 요구 + 쿨다운. 실제로 재 보니
진짜 경보는 최소 8창(4초) 이어지고 오탐은 3창을 넘지 못해 둘이 겹치지 않습니다.
그래서 연속 창 수로 가릅니다 — 심각도 3은 6창, 나머지는 4창. **심각도가 높을수록
더 엄격하게** 잡는 건 직관과 반대인데, 창 수를 8까지 올려도 재현율이 100% 로
유지되어 비용이 없는 반면 잘못 뜬 대피 지시는 피해가 가장 크기 때문입니다.

독립 평가(학습에 안 쓴 공식 음원 + ESC-50 2.67시간): 경보 4종 재현율 100%,
배경 오발령 0건, 알람시계를 화재경보로 승격하는 오류 0%.
0건은 "시간당 0회"가 아니라 95% 상한 시간당 약 1.1회라는 뜻입니다.

---

## 아키텍처

```
┌─────────────────────── Flutter 앱 ────────────────────────┐
│                                                            │
│  AudioCapture (마이크 1개 → 2 소비자)                       │
│    ├─ 24kHz PCM16  ──────────▶ WebSocket ──▶ 백엔드         │
│    └─ 32kHz 4초 창 ──▶ ONNX 경보 모델 ──▶ 경보 (오프라인)   │
│                                                            │
│  Riverpod · go_router · flutter_secure_storage             │
└───────────────────────────┬────────────────────────────────┘
                            │ REST + WebSocket
┌───────────────────────────▼────────────────────────────────┐
│                     FastAPI 백엔드                          │
│                                                            │
│  LivePipeline ── RealtimeTranscriber ──▶ OpenAI Realtime WS │
│       │       ├─ WindowBuffer → DiarizeClient ──▶ OpenAI    │
│       │       ├─ SpeakerRegistry (정체성 유지)              │
│       │       └─ EmotionClassifier ──▶ DeepSeek             │
│                                                            │
│  SQLAlchemy 2.0(async) · Alembic · Redis · structlog        │
└───────────────────┬───────────────────┬────────────────────┘
                    │                   │
              PostgreSQL 16          Redis 7
           (대화·자막·경보)      (레이트리밋·WS티켓·토큰폐기)
```

---

## 빠른 시작

### 사전 요구사항

- Docker + Docker Compose
- Flutter 3.24+ (검증 환경: **3.44.0 / Dart 3.12.0**)
- Android SDK 34 이상 + JDK 17 이상 (Android Studio 번들 JBR 21 권장)
- Python 3.12+ (백엔드를 로컬에서 직접 돌릴 때만)

```bash
flutter doctor    # "No issues found!" 가 나와야 합니다
```

> **실기기를 쓰세요.** 이 앱은 마이크·진동·손전등을 모두 씁니다. Android
> 에뮬레이터는 마이크 입력이 불안정하고 진동·손전등이 아예 없어서, 핵심 기능인
> 경보 감지를 검증할 수 없습니다. USB 디버깅을 켠 실제 안드로이드 폰을 연결하세요.

### 1. 백엔드

```bash
git clone <repo> && cd HearO

cp .env.example .env
# .env 를 열어 <FILL_ME> 세 곳을 채웁니다:
#   OPENAI_API_KEY, POSTGRES_PASSWORD, JWT_SECRET_KEY
#
# JWT_SECRET_KEY 생성:
python -c "import secrets; print(secrets.token_hex(32))"

docker compose up -d --build    # db + redis + api + worker (마이그레이션 자동 적용)
```

API 문서: <http://localhost:8000/docs>

> **`make` 가 있으면** `make up` 한 줄로 됩니다. Windows 에는 기본 설치되어
> 있지 않으므로, 이 문서는 `make` 없이도 되는 명령을 함께 적었습니다.
> `make help` 로 전체 목록을 볼 수 있습니다.

| 목적 | make | 직접 실행 |
|---|---|---|
| 스택 기동 | `make up` | `docker compose up -d --build` |
| 정지 | `make down` | `docker compose down` |
| 로그 | `make logs` | `docker compose logs -f api worker` |
| 백엔드 테스트 | `make test-backend` | `cd backend && .venv/Scripts/python -m pytest` |
| 앱 테스트 | `make test-app` | `cd app && flutter test` |

### 2. 앱

```bash
cd app

# 경보음 모델은 assets/models/ 에 들어 있습니다 (내려받을 것 없음).
# 다시 만드는 방법은 assets/models/README.md 참고.

flutter pub get

# 실기기 (권장) — PC 의 LAN IP 를 넣으세요. ipconfig 로 확인합니다.
flutter run \
  --dart-define=API_BASE_URL=http://192.168.0.10:8000 \
  --dart-define=WS_BASE_URL=ws://192.168.0.10:8000

# Android 에뮬레이터라면 10.0.2.2 가 호스트 PC 를 가리킵니다
#   --dart-define=API_BASE_URL=http://10.0.2.2:8000
# iOS 시뮬레이터라면
#   --dart-define=API_BASE_URL=http://localhost:8000
```

Android 9(API 28)부터 평문 HTTP 가 기본 차단이라, 로컬 백엔드에 붙으려면 예외가
필요합니다. `android/app/src/debug/` 에 **디버그 빌드 전용** 예외를 넣어 두었고
허용 대상은 `10.0.2.2` / `localhost` / `127.0.0.1` 뿐입니다. 릴리스 빌드에는
병합되지 않으므로 운영에서는 여전히 `https://` / `wss://` 만 통합니다.

### 3. Android 에뮬레이터에서 돌리기

에뮬레이터가 없다면 먼저 만들어야 합니다. `sdkmanager` 는 JDK 17+ 를 요구하는데
PATH 에 JDK 8 이 잡혀 있으면 실패하므로 `JAVA_HOME` 을 지정하세요.

```bash
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"   # JDK 21
SDK="$LOCALAPPDATA/Android/Sdk"

"$SDK/cmdline-tools/latest/bin/sdkmanager.bat" \
  "emulator" "system-images;android-35;google_apis;x86_64"

"$SDK/cmdline-tools/latest/bin/avdmanager.bat" create avd \
  -n hearo_test -k "system-images;android-35;google_apis;x86_64" -d pixel_6

# ~/.android/avd/hearo_test.avd/config.ini 에서 올려 두면 편합니다
#   hw.ramSize=4096   vm.heapSize=512   hw.keyboard=yes   hw.gpu.mode=host

"$SDK/emulator/emulator.exe" -avd hearo_test -allow-host-audio
```

앱은 `10.0.2.2:8000` 이 기본값이라 별도 `--dart-define` 없이 붙습니다.

> **에뮬레이터로는 경보음 감지를 끝까지 확인할 수 없습니다.** 가상 마이크는
> 호스트의 녹음 장치를 그대로 받아 오는데, 호스트에 마이크가 없으면 계속
> 무음이 들어옵니다. 모델이 제대로 도는지는 아래 integration test 로 확인하고,
> 마이크 경로는 실기기에서 보세요.

### 앱 테스트

```bash
cd app
flutter test          # 단위 테스트 (오디오 파이프라인 · 경보 디바운스)

# 기기에서 실제 ONNX 모델 확인 — 마이크 없이 한국 공식 음원을 직접 먹인다
REF=<korean_emergency_sound_ai>/data/korean_reference_audio/reference \
  scripts/push_alarm_fixtures.sh
flutter test integration_test/alarm_model_test.dart -d <기기ID>
```

integration test 가 필요한 이유는 ONNX Runtime 이 네이티브 라이브러리라서입니다.
호스트에서 도는 `flutter test` 에는 올라오지 않으므로, "PC 에서는 맞는데 폰에서
틀린" 경우를 단위 테스트로는 못 잡습니다.

> `flutter test integration_test/...` 는 테스트를 진입점으로 하는 APK 를 만들어
> `build/app/outputs/flutter-apk/app-debug.apk` 를 덮어씁니다. 그 뒤에 그 APK 를
> 설치하면 UI 가 없는 테스트 바이너리가 뜨니, 앱을 다시 깔 때는
> `flutter build apk --debug` 를 먼저 실행하세요.

### Android 빌드 설정에 대해

`android/build.gradle.kts` 에 서브프로젝트 일괄 오버라이드가 들어 있습니다.
없애면 빌드가 깨지므로 그대로 두세요.

| 오버라이드 | 이유 |
|---|---|
| `jvmTarget = 17` (전 플러그인) | 일부 플러그인이 Java 8 / Kotlin 21 로 어긋나 있어 "Inconsistent JVM-target" 으로 빌드 실패 |
| `compileSdkVersion(36)` (전 플러그인) | 구형 플러그인이 `compileSdk 33` 에 묶여 있는데 최신 androidx 가 34+ 를 요구 |
| `isCoreLibraryDesugaringEnabled` (app) | `flutter_local_notifications` 18.x 의 `java.time` 백포트 요구 |
| `proguard-rules.pro` 의 ONNX Runtime keep | R8 이 `ai.onnxruntime` 클래스를 지우면 **릴리스 빌드에서만** 경보 감지가 죽는다 |

마지막 항목이 특히 중요합니다 — 디버그에서는 멀쩡하다가 배포 후에 경보가 안
울리는, 가장 나쁜 형태로 나타납니다.

### iOS 최소 버전

`flutter_onnxruntime` 이 iOS 16 이상을 요구해 `IPHONEOS_DEPLOYMENT_TARGET` 을
13.0 → 16.0 으로 올렸습니다. iPhone 8 이후 기기입니다.

---

## API 키 발급

**앱에는 API 키가 들어가지 않습니다.** 모든 외부 API 호출은 백엔드가 하고, 앱은
우리 서버하고만 통신합니다. (클라이언트에 키를 넣으면 APK 를 뜯어 누구나 꺼내
쓸 수 있습니다.)

| 변수 | 필수 | 발급처 | 비고 |
|---|:---:|---|---|
| `OPENAI_API_KEY` | ✅ | <https://platform.openai.com/api-keys> | STT 전용. Realtime 접근 권한 필요 |
| `EMOTION_API_KEY` | ✅ | <https://platform.deepseek.com/api_keys> | 감정·톤 분류 전용 (기본 DeepSeek) |
| `POSTGRES_PASSWORD` | ✅ | 직접 정함 | |
| `JWT_SECRET_KEY` | ✅ | `python -c "import secrets; print(secrets.token_hex(32))"` | |
| `FIREBASE_CREDENTIALS_PATH` | ❌ | Firebase Console → 서비스 계정 | 푸시 알림용. 경보는 온디바이스라 없어도 동작 |
| `SENTRY_DSN` | ❌ | <https://sentry.io> | 에러 리포팅 |

키는 **두 개**입니다. STT(실시간 전사·화자분리)는 OpenAI 고유 기능이라 옮길 수
없고, 감정 분류는 더 싸고 빠른 모델로 뺐습니다.

### OpenAI 설정 확인

1. **Realtime API 접근** — Settings → Limits 에서 `gpt-live-transcribe` 사용
   가능 여부를 확인하세요. 조직 단위로 열려 있어야 합니다.
2. **모델 은퇴 주의** — `.env` 의 `OPENAI_REALTIME_MODEL` /
   `OPENAI_DIARIZE_MODEL` 로 모델을 핀 고정해 두었습니다.
   `whisper-1`, `gpt-4o-transcribe`(2025-03-20) 계열은 2026-06 은퇴했으므로
   사용하지 않습니다.

로컬에서는 키를 넣지 않아도 서버가 부팅됩니다(경고 로그와 함께).
`OPENAI_API_KEY` 가 없으면 실시간 자막이 동작하지 않고, `EMOTION_API_KEY` 가
없으면 감정이 운율 추정으로만 판정됩니다(화면 표시는 그대로라 눈으로는 구분되지
않습니다 — `/health/ready` 의 `emotion` 항목으로 확인하세요).
**`ENVIRONMENT=production` 에서는 둘 다 없으면 부팅이 거부됩니다.**

---

## 프로젝트 구조

```
HearO/
├── backend/
│   ├── app/
│   │   ├── core/          설정·로깅·보안(JWT/Argon2)·미들웨어·Redis
│   │   ├── db/            SQLAlchemy 모델
│   │   ├── schemas/       Pydantic 요청/응답
│   │   ├── api/v1/        auth · sessions · alerts · settings · live(WS)
│   │   ├── services/
│   │   │   ├── audio/     WAV·창버퍼·타임라인·프로소디 분석
│   │   │   ├── stt/       Realtime · diarize · 화자 레지스트리 · 파이프라인
│   │   │   ├── emotion/   운율 + LLM 하이브리드 분류기
│   │   │   └── repositories/
│   │   └── workers/       보관주기 자동삭제
│   ├── alembic/           마이그레이션
│   └── tests/             160 tests
│
└── app/
    ├── lib/
    │   ├── core/          테마(접근성)·감정 스타일·라우터·DI·환경설정
    │   ├── data/          API·WS·토큰저장·오디오캡처·경보음 감지
    │   ├── domain/        엔티티
    │   └── features/
    │       ├── live/      실시간 자막 (화자 색상·감정 애니메이션·글자 크기)
    │       ├── alert/     경보 감지·전체화면 경고·기록
    │       ├── history/   기록·검색·필터·즐겨찾기
    │       ├── settings/  설정·통계
    │       └── auth/
    ├── assets/models/     경보음 감지 ONNX + 메타데이터
    └── test/
```

모델 **학습** 코드는 이 저장소에 없습니다. 별도 프로젝트
(`korean_emergency_sound_ai`)에서 학습하고, 내보낸 ONNX 만 앱에 넣습니다.
학습 파이프라인과 데이터셋(수십 GB)이 앱 저장소에 섞이면 체크아웃만 무거워집니다.

---

## 실시간 자막 프로토콜

```
1. POST /api/v1/sessions              → session_id
2. POST /api/v1/auth/ws-ticket        → ticket (60초 1회용)
3. WS   /api/v1/live/{id}/ws?ticket=  → 접속
4. 바이너리 프레임으로 PCM16(24kHz mono) 전송
```

> **왜 티켓인가**: WebSocket 은 커스텀 헤더를 못 붙이는 클라이언트가 많아
> 쿼리스트링으로 인증해야 합니다. 액세스 토큰을 URL 에 실으면 프록시와 서버
> 로그에 그대로 남으므로, 60초짜리 1회용 티켓을 대신 씁니다. (Redis `GETDEL`
> 로 원자적으로 소모되어 재사용이 불가능합니다.)

### 서버 → 클라이언트 이벤트

| 이벤트 | 의미 |
|---|---|
| `caption.partial` | 잠정 텍스트 (계속 바뀜) |
| `caption.final` | 확정 텍스트 + 세기 + 임시 감정 (`tone_basis: voice`) |
| `caption.updated` | 화자 확정 / 감정 확정 (기존 줄을 patch, `tone_basis` 동봉) |
| `speaker.added` | 새 화자 등장 (색상 범례 갱신) |
| `status` | `reconnecting` 등 연결 상태 |
| `error` | 오류 (자막은 계속될 수 있음) |
| `session.ended` | 종료 요약 |

### 클라이언트 → 서버

| 메시지 | 용도 |
|---|---|
| 바이너리 | PCM16 오디오 |
| `{"type":"stop"}` | 정상 종료 (마지막 자막까지 저장) |
| `{"type":"ping"}` | 연결 유지 |
| `{"type":"rename_speaker","key":"S1","name":"엄마"}` | 화자 이름 |
| `{"type":"recolor_speaker","key":"S1","color":"#FF0000"}` | 화자 색상 |

### 종료 코드

| 코드 | 의미 |
|---|---|
| 4001 | 티켓 무효/만료 |
| 4004 | 세션 없음 |
| 4029 | 동시 세션 초과 |
| 4408 | 오디오 무입력 타임아웃 |
| 4409 | 최대 녹음 시간 도달 |

---

## 접근성 원칙

이 앱의 사용자에게 **화면은 유일한 정보 통로**입니다. 그래서 다음을 규칙으로
지켰습니다.

- **색만으로 정보를 전달하지 않습니다.** 화자는 색 + 이름표, 감정은 색 + 아이콘 +
  움직임 + 한국어 라벨. 색각이상 사용자와 흑백 환경에서도 읽힙니다.
- **화자 팔레트는 색각이상에서도 구분되도록** 명도까지 벌려 놓았습니다.
- **고대비 모드**는 Material 의 자동 대비 계산에 맡기지 않고 배색을 직접
  못박았습니다 (저시력 사용자에게는 이게 앱을 쓸 수 있느냐를 가릅니다).
- **감정을 단정하지 않습니다.** `화남` 이 아니라 `화난 말투로 들림` 이라고 적고,
  배지를 누르면 무엇을 근거로 판단했는지와 어떤 경우에 빗나가는지가 나옵니다.
  사용자가 이 표시를 얼마나 믿을지 스스로 정할 수 있어야 합니다 (위 3-1).
- **감정 표현은 신뢰도에 비례**합니다. 0.35 미만이면 아예 표시하지 않고,
  0.6 미만이면 문구 자체가 약해집니다(`…일 수도`) — 틀린 감정을 자신 있게
  보여주는 것이 안 보여주는 것보다 해롭습니다.
- **깜빡임은 3Hz 이하**입니다 (WCAG 2.3.1, 광과민성 발작 방지).
- 시스템 **"동작 줄이기"** 설정을 존중해 애니메이션을 끕니다.
- 시스템 글꼴 확대를 따르되 상한(1.6배)을 둡니다 — 무제한이면 버튼 레이블이
  잘려 오히려 못 쓰게 됩니다.
- 터치 목표는 최소 48dp, 주요 버튼은 52~64dp.
- 스크린리더용 `Semantics` 를 자막·경보·레벨미터에 붙였습니다 (청각+시각
  중복장애 사용자).

---

## 개인정보 처리 원칙

대화 전문을 다루는 앱이므로 다음을 지킵니다.

- **원본 오디오를 저장하지 않습니다.** 전사가 끝나면 버퍼는 폐기됩니다.
- **화자 참조 클립(성문 = 생체정보)은 DB 에 남기지 않습니다.** 라이브 세션이
  살아있는 동안만 메모리에 두고, 종료 시 `discard_references()` 로 즉시 지웁니다.
  대가로 화자 라벨은 세션 안에서만 유효합니다 — 의도된 트레이드오프입니다.
- 저장되는 것은 **텍스트·타임스탬프·감정 라벨·운율 수치**뿐입니다.
- 토큰은 Keychain / EncryptedSharedPreferences 에 넣습니다.
- 로그에서 비밀번호·토큰·오디오 필드는 자동으로 마스킹됩니다.
- 위치 수집은 **기본 꺼짐**이며 설정에서 명시적으로 켜야 합니다.
- 자동 삭제는 **즐겨찾기한 대화와 미확인 경보를 건드리지 않습니다.**
- 계정 삭제 시 모든 기록이 CASCADE 로 즉시 삭제됩니다.

---

## 테스트

```bash
make test-backend   # 160 tests
make test-app
make lint           # ruff + mypy(strict) + dart analyze
```

DB 를 쓰는 테스트는 실제 PostgreSQL 이 필요합니다. SQLite 로 대체하지 않는
이유는 스키마가 pg_trgm 인덱스·네이티브 ENUM·PGUUID·부분 인덱스를 쓰기 때문입니다
— SQLite 에서 통과한 테스트는 운영 동작을 보장하지 못합니다. DB 가 없으면
해당 테스트만 skip 되고 순수 로직 테스트는 그대로 돕니다.

```bash
# 테스트 DB 준비
docker compose exec db createdb -U hearo hearo_test
```

---

## 배포

### 관리형 PostgreSQL 사용 시

`pg_trgm` 확장이 필요합니다 (한국어 부분일치 검색). 슈퍼유저 권한이 없으면
마이그레이션이 실패하므로 미리 만들어 두세요.

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

### 운영 환경 체크리스트

`.env` 에서 아래를 반드시 바꾸세요. **틀리면 부팅 시점에 죽습니다** —
런타임에 조용히 잘못 동작하는 것보다 낫기 때문입니다.

```env
ENVIRONMENT=production
DEBUG=false                      # true 면 부팅 거부
ALLOWED_HOSTS=api.example.com    # "*" 면 부팅 거부
JWT_SECRET_KEY=<64자 hex>        # 32자 미만이면 부팅 거부
LOG_JSON=true
```

운영 모드에서는 `/docs`, `/redoc`, `/openapi.json` 이 자동으로 닫힙니다.

### 헬스체크

| 경로 | 용도 |
|---|---|
| `/health/live` | livenessProbe — 의존성을 보지 않음 |
| `/health/ready` | readinessProbe — DB/Redis 확인 |

둘을 나눈 이유: DB 가 잠깐 흔들릴 때 오케스트레이터가 멀쩡한 프로세스를
재시작해 장애를 키우는 걸 막기 위해서입니다. Redis 장애는 degrade 로 버팁니다.

### 앱 빌드

```bash
make build-apk   # Android
make build-ipa   # iOS
```

---

## 비용

사용자 1명이 **하루 1시간** 자막을 켠다고 가정할 때:

| 항목 | 단가 | 하루 | 월 |
|---|---|---|---|
| `gpt-live-transcribe` | $0.017/분 | $1.02 | ~$31 |
| `gpt-4o-transcribe-diarize` | $2.5/1M 입력 토큰 | ~$0.15 | ~$5 |
| `deepseek-v4-flash` (감정) | $0.14 / 1M 입력 · $0.28 / 1M 출력 | ~$0.01 미만 | ~$0.2 |

**비용을 줄이는 장치들이 이미 들어 있습니다.**

- 무음 창은 diarize API 를 호출하지 않습니다 (`SILENCE_THRESHOLD_DBFS`)
- 감정 분류는 최대 8건씩 묶어 호출합니다
- 4자 미만 발화는 LLM 에 묻지 않습니다
- 감정 LLM 이 연속 3회 실패하면 30초간 호출을 끊습니다 (서킷브레이커)
- 사용자당 동시 세션 제한 (`MAX_CONCURRENT_LIVE_SESSIONS_PER_USER`)
- 무입력 2분 / 최대 4시간 자동 종료 — 앱이 백그라운드에서 죽었는데 연결만
  남아 요금이 계속 나가는 상황을 막습니다

`DIARIZE_WINDOW_SECONDS` 를 늘리면 diarize 비용이 줄지만 화자 라벨이 늦게
붙습니다.

---

## 알려진 한계

정직하게 적어 둡니다.

1. **화자 라벨은 세션 안에서만 유효합니다.** 성문을 영구 저장하지 않기로 한
   결정의 대가입니다. 어제의 "화자 A"와 오늘의 "화자 A"는 다른 사람일 수 있습니다.
2. **참조 클립은 최대 4명**까지입니다 (OpenAI 제약). 5명 이상이 참여하는 대화에서는
   5번째 화자부터 겹침 대조에만 의존하므로 라벨이 흔들릴 수 있습니다.
3. **화자 전환이 한 발화 안에서 일어나면** 그 줄은 가장 많이 겹친 화자로 표시됩니다.
   실시간 트랙과 diarize 트랙의 발화 경계가 다르기 때문입니다.
4. **화재경보에는 독립 검증이 없습니다.** 시험 성적(19/19)이 전부 학습에 쓴
   AI Hub 644 안에서 나왔고, 한국 화재경보기 실녹음을 따로 구하지 못했습니다.
   국내 기준(NFTC 203)이 90dB@1m 만 규정하고 파형은 정하지 않아 기종별 편차가
   큽니다. 실제 건물에서의 검증이 배포 전 남은 숙제입니다.
5. **배경 오발령 "0건"은 시간당 0회가 아닙니다.** 2.67시간 측정에서 0건이므로
   95% 상한이 시간당 약 1.1회입니다. 더 좁히려면 더 긴 배경 녹음이 필요합니다.
6. **경보 감지는 앱이 실행 중일 때만** 동작합니다. 완전 종료 상태에서의 감지는
   포그라운드 서비스 설정이 추가로 필요합니다.
7. 한국어 검색은 `pg_trgm` 부분일치입니다. 형태소 분석기(예: mecab-ko)를 붙이면
   "먹었어요/먹다"를 이어줄 수 있지만, 인프라 요구사항이 커집니다.

---

## 라이선스

내부 프로젝트. 경보음 모델의 백본인 EfficientAT 는 MIT, Pretendard 는 OFL 입니다.
