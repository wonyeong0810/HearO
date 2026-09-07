#!/usr/bin/env bash
# integration_test/alarm_model_test.dart 가 쓸 음원을 기기로 밀어 넣는다.
#
# 음원을 앱 assets 에 넣지 않는 이유: 테스트용 3MB 를 배포 APK 에 얹을 이유가
# 없다. 기기의 앱 전용 외부 디렉터리에 두면 권한 없이 읽을 수 있고, 앱을
# 지우면 같이 사라진다.
#
# 사용법:
#   REF=<korean_emergency_sound_ai>/data/korean_reference_audio/reference \
#     app/scripts/push_alarm_fixtures.sh
set -euo pipefail

# Git Bash 는 /sdcard/... 를 윈도우 경로로 바꿔 버려서 adb 가 엉뚱한 곳을 본다.
export MSYS_NO_PATHCONV=1

REF="${REF:?공식 음원 디렉터리를 REF 로 지정하세요}"
FF="${FFMPEG:-ffmpeg}"
ADB="${ADB:-adb}"
# 앱 전용 외부 디렉터리는 쓰지 않는다 — integration test 가 앱을 다시 설치하면서
# 그 디렉터리를 통째로 지운다. /data/local/tmp 는 재설치를 타지 않는다.
DEST="/data/local/tmp/hearo_fixtures"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 모델 입력 규격 그대로 뽑는다 — 32kHz mono float32 raw.
# 앱에서 mp3 를 디코딩하지 않아도 되고, 디코더 차이로 결과가 흔들릴 일도 없다.
"$FF" -hide_banner -loglevel error -y \
  -i "$REF/국민안전24_민방공경보음_파상음.mp3" \
  -t 12 -ar 32000 -ac 1 -f f32le "$TMP/civil_defense.f32"

# 짧은 파일이라 반복해서 12초를 채운다. 실제로도 반복해 울리는 소리다.
"$FF" -hide_banner -loglevel error -y \
  -stream_loop 20 -i "$REF/구급차_사이렌_3분할/01_구급차_사이렌.mp3" \
  -t 12 -ar 32000 -ac 1 -f f32le "$TMP/emergency_vehicle.f32"

# 경보가 아닌 소리. 여기서 경보가 뜨면 오탐이다.
"$FF" -hide_banner -loglevel error -y \
  -f lavfi -i "anoisesrc=d=12:c=pink:a=0.15" \
  -ar 32000 -ac 1 -f f32le "$TMP/background.f32"

"$ADB" shell mkdir -p "$DEST"
for f in "$TMP"/*.f32; do
  "$ADB" push "$f" "$DEST/" >/dev/null
  echo "  → $(basename "$f")"
done
# 앱은 shell 과 다른 uid 로 돈다. 읽을 수 있게 열어 준다.
"$ADB" shell chmod 755 "$DEST"
"$ADB" shell chmod 644 "$DEST"/*.f32
echo "완료: $DEST"
