#!/bin/bash
#
# 실제 스토어를 **읽기만 해서** 지금 할 일들이 어떻게 분류되는지 표로 보여준다.
#
# 「기한 지난 할 일」 섹션이 숨겨진 것인지 아예 없는 것인지 화면으로는 구분되지 않는다.
# 이 도구가 그것을 가른다.
#
# **앱 스토어에 아무것도 쓰지 않는다.** 임시 사본을 만들어 그것만 읽는다.
#
# 실행:  ./Tests/classify-store.sh
#
set -uo pipefail

STORE="$HOME/Library/Group Containers/group.com.ericmun.startline/Startline.store"
[ -f "$STORE" ] || { echo "스토어를 찾지 못했다: $STORE"; exit 1; }

# -wal 에 최신 내용이 들어 있다. 앱을 정상 종료해도 합쳐지지 않으므로 세 파일을 함께 복사한다.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$STORE" "$WORK/s.store"
[ -f "$STORE-wal" ] && cp "$STORE-wal" "$WORK/s.store-wal"
[ -f "$STORE-shm" ] && cp "$STORE-shm" "$WORK/s.store-shm"

NOW=$(date +%s)
echo "기준 시각: $(date '+%Y-%m-%d %H:%M')"
echo

sqlite3 -readonly "$WORK/s.store" <<SQL
.mode column
.headers on
.width 32 18 8 10
SELECT
  substr(ZTITLE, 1, 30)                                            AS "제목",
  CASE WHEN ZDUEAT IS NULL THEN '(없음)'
       ELSE datetime(ZDUEAT + 978307200, 'unixepoch', 'localtime')
  END                                                              AS "실효마감",
  ZSTATUS                                                          AS "상태",
  CASE
    WHEN ZSTATUS = 'done'                                THEN '해당 없음'
    WHEN ZDUEAT IS NULL                                  THEN '해당 없음'
    WHEN ZDUEAT + 978307200 < $NOW                       THEN '놓침'
    ELSE '해당 없음'
  END                                                              AS "분류"
FROM ZMANAGEDTASK
ORDER BY ZDUEAT;
SQL

echo
MISSED=$(sqlite3 -readonly "$WORK/s.store" \
  "SELECT COUNT(*) FROM ZMANAGEDTASK
   WHERE ZSTATUS != 'done' AND ZDUEAT IS NOT NULL AND ZDUEAT + 978307200 < $NOW;")

if [ "$MISSED" -eq 0 ]; then
  echo "→ 기한 지난 할 일 0건. **「기한 지난 할 일」 섹션은 숨겨지는 것이 정상이다.**"
else
  echo "→ 기한 지난 할 일 ${MISSED}건. 우측 패널 맨 아래에 섹션이 보여야 한다."
fi

echo
echo "※ 「위험」은 착수마감 기준이라 소요시간·리드타임까지 계산해야 한다."
echo "   그 계산은 앱 코드에 있으므로 여기서는 마감 기준인 「놓침」만 가른다."
echo "   위험·놓침 판정식 자체는 ./Tests/run-link-tests.sh 가 검증한다."
