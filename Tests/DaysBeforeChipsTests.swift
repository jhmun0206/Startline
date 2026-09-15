//
//  DaysBeforeChipsTests.swift
//  Startline — 「며칠 전까지」 칩 회귀 테스트
//
//  위아래 화살표(스테퍼)를 칩으로 바꿨다. **저장되는 값의 의미는 바뀌지 않아야 한다.**
//  칩으로 고른 값이 스테퍼로 같은 값을 만들었을 때와 다른 데이터를 만들면
//  기존 할 일의 마감이 조용히 옮겨진다.
//
//  그리고 칩에 없는 값(예: 5일 전)을 불러왔을 때 **가까운 칩으로 바뀌면 안 된다.**
//  사용자 입력을 임의로 변형하지 않는다. (원칙 1)
//

import Foundation

/// 앱이 「며칠 전」을 오프셋으로 바꾸는 식. `EventEditorView`·`TaskEditorView` 양쪽이 같다.
private func offset(daysBefore: Int) -> TimeInterval {
    -TimeInterval(daysBefore) * 24 * 60 * 60
}

/// 저장된 오프셋을 화면의 「며칠 전」으로 되돌리는 식. (`TaskEditorView.load`)
private func daysBefore(offset: TimeInterval) -> Int {
    max(0, Int((-offset / (24 * 60 * 60)).rounded()))
}

func testDaysBeforeChips() {
    report.begin("「며칠 전까지」 칩")

    // ── 칩으로 고른 값 == 스테퍼로 같은 값을 만들었을 때
    //
    // 두 UI 가 같은 식을 쓰므로, 같은 정수를 주면 같은 오프셋이 나와야 한다.
    for days in [0, 1, 3, 7, 5, 14, 365] {
        report.equal(
            "\(days)일 전 → 오프셋",
            offset(daysBefore: days),
            -TimeInterval(days) * 86400
        )
        report.equal(
            "\(days)일 전 → 저장했다 불러와도 그대로",
            daysBefore(offset: offset(daysBefore: days)),
            days
        )
    }

    // 당일(0)은 오프셋 0 이다. nil 로 뭉개지지 않는다.
    report.equal("당일 → 오프셋 0", offset(daysBefore: 0), 0)

    // ── 칩 구성
    report.equal("칩으로 내놓는 값", DaysBeforeChips.presets, [0, 1, 3, 7])
    report.equal("0 의 라벨", DaysBeforeChips.label(for: 0), "당일")
    report.equal("1 의 라벨", DaysBeforeChips.label(for: 1), "1일 전")
    report.equal("3 의 라벨", DaysBeforeChips.label(for: 3), "3일 전")
    report.equal("7 의 라벨", DaysBeforeChips.label(for: 7), "1주 전")

    // ── 칩에 없는 값은 「직접」이 받는다. **값을 바꾸지 않는다.**
    for days in [0, 1, 3, 7] {
        report.check("\(days)일 전은 칩에 있다 → 직접 아님", !DaysBeforeChips.needsCustom(for: days))
    }
    for days in [2, 4, 5, 6, 10, 14, 30, 365] {
        report.check("\(days)일 전은 칩에 없다 → 직접", DaysBeforeChips.needsCustom(for: days))
    }

    // 5일 전을 불러오면 「직접」이 켜지고 값은 5 그대로다 — 3이나 7로 끌어당기지 않는다.
    let loaded = daysBefore(offset: -5 * 86400)
    report.equal("5일 전을 불러오면 값은 5", loaded, 5)
    report.check("5일 전은 「직접」으로 열린다", DaysBeforeChips.needsCustom(for: loaded))
    report.check(
        "가까운 칩(3 또는 7)으로 바뀌지 않는다",
        loaded != 3 && loaded != 7
    )

    // ── 실효마감 계산이 그대로인지 — 부모 시작 + 오프셋
    let parentStart = date(2026, 9, 20, 19, 0)
    for days in [0, 1, 3, 5, 7] {
        let task = ManagedTask(
            title: "준비",
            parentEventID: "evt",
            parentOccurrenceDate: parentStart,
            offsetFromParent: offset(daysBefore: days),
            lastKnownDueAt: nil
        )
        report.equal(
            "\(days)일 전 → 실효마감",
            task.effectiveDueAt(parentStart: parentStart),
            cal.date(byAdding: .day, value: -days, to: parentStart)
        )
    }

    // ── 왕복: 저장 → 불러오기 → 저장. 값이 흔들리면 안 된다.
    for days in [0, 1, 2, 3, 5, 7, 14, 100] {
        let first = offset(daysBefore: days)
        let restored = daysBefore(offset: first)
        let second = offset(daysBefore: restored)
        report.equal("\(days)일 전 왕복 후에도 같은 오프셋", second, first)
    }
}
