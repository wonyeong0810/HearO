package com.hearo.app

import io.flutter.embedding.android.FlutterActivity

// 패키지는 android/app/build.gradle.kts 의 namespace(com.hearo.app) 와 같아야 한다.
// 어긋나면 AndroidManifest 의 ".MainActivity" 가 풀리지 않아 앱이 실행 즉시
// ClassNotFoundException 으로 죽는다. 빌드는 멀쩡히 성공하므로 CI 로는 안 잡힌다.
class MainActivity : FlutterActivity()
