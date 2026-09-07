/// 빌드 시점 설정.
///
/// 값은 `--dart-define` 으로 주입한다. 앱에는 API 키가 들어가지 않는다 —
/// OpenAI 호출은 전부 백엔드가 하고, 앱은 우리 서버하고만 통신한다.
/// (클라이언트에 OpenAI 키를 넣으면 APK 를 뜯어 누구나 꺼내 쓸 수 있다.)
///
/// 예시:
///   flutter run \
///     --dart-define=API_BASE_URL=https://api.hearo.example.com \
///     --dart-define=WS_BASE_URL=wss://api.hearo.example.com
class Env {
  const Env._();

  /// REST API 주소.
  ///
  /// 기본값은 Android 에뮬레이터에서 호스트 PC 를 가리키는 10.0.2.2 다.
  /// iOS 시뮬레이터라면 http://localhost:8000 으로 바꿔 주입해야 한다.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://10.0.2.2:8000',
  );

  /// 오디오 규격. 백엔드의 AUDIO_SAMPLE_RATE 와 반드시 일치해야 한다.
  /// 어긋나면 전사가 통째로 깨지는 것이 아니라 미묘하게 나빠져서, 원인을
  /// 찾기가 매우 어렵다.
  static const int sampleRate = 24000;
  static const int channels = 1;

  /// 서버로 오디오를 밀어 보내는 주기. 짧을수록 자막이 빨라지지만
  /// WebSocket 프레임 수가 늘어난다. 100ms 가 지연과 부하의 타협점.
  static const Duration audioChunkInterval = Duration(milliseconds: 100);

  /// 경보음 감지 모델(`assets/models/emergency_sound.onnx`)의 입력 규격.
  /// 모델이 정한 값이라 임의로 바꿀 수 없다 —
  /// `assets/models/emergency_sound_metadata.json` 의 `input` 과 일치해야 한다.
  static const int alarmSampleRate = 32000;
  static const int alarmWindowSamples = 32000 * 4; // 4초 = 128000 샘플

  /// 감지 창을 얼마나 촘촘히 밀어 넣을지. 0.5초 간격은 측정으로 정한 값이고,
  /// 디바운스 연속 창 수(`AlarmDetector.requiredFrames`)가 이 간격을 전제로
  /// 잡혀 있다. 하나만 바꾸면 안 되고 둘을 함께 다시 재야 한다.
  static const int alarmHopSamples = 16000; // 0.5초

  static const bool isProduction =
      bool.fromEnvironment('dart.vm.product', defaultValue: false);

  /// 로컬 개발용 http 주소를 쓰고 있는지. 운영 빌드에서 이러면 경고한다.
  static bool get usingInsecureTransport =>
      apiBaseUrl.startsWith('http://') || wsBaseUrl.startsWith('ws://');
}
