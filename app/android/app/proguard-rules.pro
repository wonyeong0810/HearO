# ---- ONNX Runtime (경보음 감지) ----
# R8 이 ORT 내부 클래스를 지우면 릴리스 빌드에서만 경보 감지가 죽는다.
# 디버그에서는 멀쩡하다가 배포 후에 안 울리는 최악의 형태로 나타나므로 반드시 유지한다.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# ---- flutter_local_notifications ----
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

# ---- 백그라운드 경보 감지 서비스 ----
-keep class com.pravera.flutter_foreground_task.** { *; }

# ---- Flutter ----
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
