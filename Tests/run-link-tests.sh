#!/bin/bash
#
# 일정·할 일 연결 회귀 테스트
#
# 앱 소스를 **그대로** 컴파일해서 돌린다. 사본이 아니라 앱이 쓰는 바로 그 코드다.
# 로직을 고치면 이 테스트도 함께 고쳐야 통과한다 — 그게 목적이다.
#
# 실행:  ./Tests/run-link-tests.sh
#

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/startline-link-tests"
BIN="$WORK/link_tests"

rm -rf "$WORK"
mkdir -p "$WORK"

# 검증 대상. 실제 앱 소스만 들어간다.
SOURCES=(
  "$ROOT/Startline/ManagedTask.swift"
  "$ROOT/Startline/CalendarManager.swift"
  "$ROOT/Startline/TaskResolution.swift"
  "$ROOT/Startline/TaskLinkPolicy.swift"
  "$ROOT/Startline/FeatureFlags.swift"
  "$ROOT/Startline/GridSelection.swift"
  "$ROOT/Startline/GridLayout.swift"
  "$ROOT/Tests/EventGroupingTests.swift"
  "$ROOT/Tests/GridTaskPlacementTests.swift"
  "$ROOT/Tests/RiskMissedTests.swift"
  "$ROOT/Tests/LinkIntegrityTests.swift"
)

# 앱 타겟과 같은 조건으로 맞춘다. (project.pbxproj 기준)
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="$(uname -m)-apple-macosx14.6"

# 앱 타겟을 실제로 빌드한다.
#
# `swiftc` 한 방으로는 놓치는 것이 있다. `import` 는 파일 범위인데, 아래 링크 빌드는
# 파일들을 함께 보므로 한 파일의 import 가 다른 파일을 덮어주는 것처럼 통과해 버린다.
# 실제로 `import OSLog` 누락을 그렇게 놓쳤고, Xcode 빌드가 잡았다.
# 그래서 진짜 타겟 빌드를 검증 단계에 넣는다. (`--no-app-build` 로 건너뛸 수 있다)
if [ "${1:-}" != "--no-app-build" ]; then
  echo "앱 타겟 빌드 중…"
  if ! xcodebuild -scheme Startline -destination 'platform=macOS' build \
        > "$WORK/xcodebuild.log" 2>&1; then
    echo "✗ 앱 빌드 실패"
    grep -E "error:" "$WORK/xcodebuild.log" | sort -u | head -20
    exit 2
  fi
  # 컴파일 경고만 센다. 툴체인이 뱉는 메시지(AppIntents 등)는 코드와 무관하다.
  APP_WARNINGS=$(grep -E "\.swift:[0-9]+:[0-9]+: warning:" "$WORK/xcodebuild.log" | sort -u | wc -l | tr -d ' ')
  echo "앱 빌드 성공 (경고 ${APP_WARNINGS}건)"
  echo
fi

echo "빌드 중…"
if ! swiftc -o "$BIN" "${SOURCES[@]}" \
      -sdk "$SDK" -target "$TARGET" \
      -swift-version 5 \
      -default-isolation MainActor \
      -warnings-as-errors \
      2> "$WORK/build.log"; then
  echo "✗ 빌드 실패"
  cat "$WORK/build.log"
  exit 2
fi
if [ -s "$WORK/build.log" ]; then cat "$WORK/build.log"; fi
echo "빌드 성공 (경고 0건)"
echo

# ── 1. 로직 시나리오 ─────────────────────────────────────────
"$BIN" --logic
LOGIC=$?

# ── 2. 저장 영속성 (kill -9) ─────────────────────────────────
#
# 정상 종료로는 검증되지 않는다. SwiftData 는 기본이 지연 저장이라
# 프로세스를 강제로 죽여야 "정말 디스크까지 내려갔는지"를 알 수 있다.
#
# 사용자의 실제 App Group 스토어는 건드리지 않는다. 임시 위치를 쓴다.
STORE="$WORK/persist.store"

run_then_kill() {
  local mode="$1" marker="$2" label="$3"
  rm -f "$marker"
  "$BIN" "$mode" "$STORE" "$marker" &
  local pid=$!

  # 저장이 끝났다는 표식을 기다린다.
  local waited=0
  while [ ! -f "$marker" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "✗ $label 단계가 저장 전에 죽었다"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -gt 300 ]; then
      echo "✗ $label 단계가 30초 안에 저장하지 못했다"
      kill -9 "$pid" 2>/dev/null
      return 1
    fi
  done

  # 정상 종료를 주지 않는다. 강제 종료.
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "  · $label 저장 직후 kill -9 (pid $pid)"
  return 0
}

echo
echo "── 저장 영속성 (kill -9)"
PERSIST=0
run_then_kill --persist-write "$WORK/wrote" "연결 생성" || PERSIST=1
"$BIN" --persist-verify "$STORE" "연결 생성" || PERSIST=1

run_then_kill --persist-move "$WORK/moved" "부모 이동" || PERSIST=1
"$BIN" --persist-verify "$STORE" "부모 이동" || PERSIST=1

echo
echo "════════════════════════════════════════════════════════════"
if [ "$LOGIC" -eq 0 ] && [ "$PERSIST" -eq 0 ]; then
  echo "일정·할 일 연결 회귀 테스트 — 전부 통과"
  exit 0
fi
echo "일정·할 일 연결 회귀 테스트 — 실패 있음 (로직 $LOGIC / 영속성 $PERSIST)"
exit 1
