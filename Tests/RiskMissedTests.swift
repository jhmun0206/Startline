//
//  RiskMissedTests.swift
//  Startline — 「위험」과 「놓침」 분류 회귀 테스트 (명세서 9.4)
//
//    위험 = 시작할 때가 지났는데 아직 손대지 않음   → 배너 + 그리드 막대 + 알림
//    놓침 = 마감까지 지났는데 아직 끝내지 않음      → 「기한 지난 할 일」 섹션
//
//  **두 집합이 겹치면 같은 항목이 화면 두 곳에 동시에 나온다.** 그 일이 없도록
//  판정식을 `ResolvedTask` 한 곳에 모았고, 여기서 겹치지 않는 것을 매번 확인한다.
//
//  같은 데이터를 두 곳에서 다르게 판정하면 언젠가 어긋난다 —
//  실제로 그리드와 우측 패널이 서로 다른 비교자를 써서 정렬이 어긋난 적이 있다.
//

import Foundation

/// 분류 검증용 할 일. 실효마감과 소요시간을 주면 착수마감은 실제 코드가 계산한다.
private func classified(
    _ title: String,
    dueAt: Date?,
    duration: TimeInterval?,
    status: TaskStatus,
    leadTime: LeadTime = .durationBased,
    parentTitle: String? = nil
) -> ResolvedTask {
    let task = ManagedTask(title: title, dueAt: dueAt, estimatedDuration: duration, leadTime: leadTime)
    task.status = status
    return ResolvedTask(
        task: task,
        effectiveDueAt: dueAt,
        startDeadline: task.startDeadline(effectiveDueAt: dueAt, calendar: cal),
        judgment: task.judgment(effectiveDueAt: dueAt, now: Date(), calendar: cal),
        parentTitle: parentTitle,
        parentStart: nil
    )
}

func testRiskAndMissed() {
    report.begin("위험·놓침 분류 (명세서 9.4)")

    let now = date(2026, 9, 14, 12, 0)
    let day: TimeInterval = 24 * 60 * 60

    func check(
        _ name: String,
        _ resolved: ResolvedTask,
        risk: Bool,
        missed: Bool,
        banner: Bool
    ) {
        report.equal("\(name) — 위험", resolved.isAtRisk(now: now), risk)
        report.equal("\(name) — 놓침", resolved.isMissed(now: now), missed)
        report.equal("\(name) — 배너", resolved.isTodaysStart(now: now, calendar: cal), banner)
        // 두 집합은 절대 겹치지 않는다.
        report.check(
            "\(name) — 위험과 놓침이 겹치지 않음",
            !(resolved.isAtRisk(now: now) && resolved.isMissed(now: now))
        )
    }

    // 착수 지남 · 마감 안 지남 · 미시작 → 위험
    check(
        "착수 지남·마감 남음·미시작",
        classified("A", dueAt: date(2026, 9, 20, 18, 0), duration: 10 * day, status: .notStarted),
        risk: true, missed: false, banner: true
    )

    // 마감 지남 · 미완료 → 놓침 (배너에서 빠진다)
    check(
        "마감 지남·미시작",
        classified("B", dueAt: date(2026, 9, 10, 18, 0), duration: 3600, status: .notStarted),
        risk: false, missed: true, banner: false
    )

    // 마감 지남 · 진행 중 → 놓침 (끝내지 않았으므로)
    check(
        "마감 지남·진행 중",
        classified("C", dueAt: date(2026, 9, 10, 18, 0), duration: 3600, status: .inProgress),
        risk: false, missed: true, banner: false
    )

    // 마감 지남 · 완료 → 어느 쪽도 아님
    check(
        "마감 지남·완료",
        classified("D", dueAt: date(2026, 9, 10, 18, 0), duration: 3600, status: .done),
        risk: false, missed: false, banner: false
    )

    // 오늘이 착수마감 → 위험은 아니고(아직 안 지남) 배너에는 들어온다
    let startsToday = classified(
        "E", dueAt: date(2026, 9, 14, 20, 0), duration: 3600, status: .notStarted
    )
    check("오늘이 시작일·아직 시각 전", startsToday, risk: false, missed: false, banner: true)

    // 오늘이 착수마감이고 그 시각도 지남 → 위험 + 배너
    check(
        "오늘이 시작일·시각 지남",
        classified("F", dueAt: date(2026, 9, 15, 9, 0), duration: 24 * 3600, status: .notStarted),
        risk: true, missed: false, banner: true
    )

    // 완료했고 오늘이 시작일 → 배너에는 들어온다 (「다 마쳤어요」를 가르기 위해)
    check(
        "오늘이 시작일·완료",
        classified("G", dueAt: date(2026, 9, 14, 20, 0), duration: 3600, status: .done),
        risk: false, missed: false, banner: true
    )

    // ── 경계값: 실효마감이 **오늘**인 미완료 항목
    //
    // 지난 것이 아니므로 놓침이 아니어야 한다. 날짜만 비교하면 여기서 틀린다.
    check(
        "마감이 오늘·아직 시각 전·미시작",
        classified("H", dueAt: date(2026, 9, 14, 18, 0), duration: 3600, status: .notStarted),
        risk: false, missed: false, banner: true
    )
    check(
        "마감이 오늘·시각 지남·미시작",
        classified("I", dueAt: date(2026, 9, 14, 9, 0), duration: 3600, status: .notStarted),
        risk: false, missed: true, banner: false
    )
    report.check(
        "마감이 오늘이어도 시각 전이면 놓침이 아님",
        !classified("H2", dueAt: date(2026, 9, 14, 18, 0), duration: 3600, status: .notStarted)
            .isMissed(now: now)
    )

    // ── 부모 일정이 있어 실효마감이 상대값으로 계산되는 항목
    let parentStart = date(2026, 9, 16, 19, 0)
    let attached = ManagedTask(
        title: "졸프 주제 선정하기",
        parentEventID: "evt.jolpro",
        parentOccurrenceDate: parentStart,
        offsetFromParent: -2 * day,
        lastKnownDueAt: parentStart.addingTimeInterval(-2 * day),
        estimatedDuration: 24 * 3600
    )
    let attachedDue = attached.effectiveDueAt(parentStart: parentStart)
    let attachedResolved = ResolvedTask(
        task: attached,
        effectiveDueAt: attachedDue,
        startDeadline: attached.startDeadline(effectiveDueAt: attachedDue, calendar: cal),
        judgment: nil,
        parentTitle: "[졸프] 전체 미팅",
        parentStart: parentStart
    )
    report.equal("부모 기준 실효마감 = 부모 시작 − 2일", attachedDue, date(2026, 9, 14, 19, 0))
    check("부모 딸림·마감 오늘 저녁", attachedResolved, risk: true, missed: false, banner: true)

    // 부모가 옮겨져 마감이 과거가 되면 놓침으로 넘어간다
    let movedStart = date(2026, 9, 10, 19, 0)
    let movedDue = attached.effectiveDueAt(parentStart: movedStart)
    let movedResolved = ResolvedTask(
        task: attached,
        effectiveDueAt: movedDue,
        startDeadline: attached.startDeadline(effectiveDueAt: movedDue, calendar: cal),
        judgment: nil,
        parentTitle: "[졸프] 전체 미팅",
        parentStart: movedStart
    )
    check("부모 딸림·부모가 과거로 옮겨짐", movedResolved, risk: false, missed: true, banner: false)

    // ── 리드타임이 .none 이라 착수마감이 없는 항목
    let noLead = classified(
        "J", dueAt: date(2026, 9, 10, 18, 0), duration: 3600,
        status: .notStarted, leadTime: .none
    )
    report.check("리드타임 없음 — 착수마감이 없다", noLead.startDeadline == nil)
    // 시작 시점이 없으니 위험도 배너도 아니다. 그러나 **마감은 지났으므로 놓침이다.**
    check("리드타임 없음·마감 지남", noLead, risk: false, missed: true, banner: false)

    let noLeadFuture = classified(
        "K", dueAt: date(2026, 9, 20, 18, 0), duration: 3600,
        status: .notStarted, leadTime: .none
    )
    check("리드타임 없음·마감 남음", noLeadFuture, risk: false, missed: false, banner: false)

    // 마감 자체가 없는 항목은 어느 쪽도 아니다
    check(
        "마감 없음",
        classified("L", dueAt: nil, duration: 3600, status: .notStarted),
        risk: false, missed: false, banner: false
    )

    // ── 정렬: 오래 지난 것이 위
    let missedList = [
        classified("최근", dueAt: date(2026, 9, 13, 9, 0), duration: 3600, status: .notStarted),
        classified("가장 오래", dueAt: date(2026, 8, 1, 9, 0), duration: 3600, status: .notStarted),
        classified("중간", dueAt: date(2026, 9, 1, 9, 0), duration: 3600, status: .notStarted)
    ]
    .filter { $0.isMissed(now: now) }
    .sorted { ($0.effectiveDueAt ?? .distantPast) < ($1.effectiveDueAt ?? .distantPast) }

    report.equal("놓침 3건 모두 분류됨", missedList.count, 3)
    report.equal(
        "오래 지난 것이 위",
        missedList.map(\.task.title),
        ["가장 오래", "중간", "최근"]
    )

    // ── 배너가 세는 개수 — 바꾸기 전과 후
    //
    // 예전 조건은 마감을 보지 않아 **마감까지 지난 일까지 「오늘 시작할 일」로 셌다.**
    let mixed = [
        classified("오늘 시작", dueAt: date(2026, 9, 15, 9, 0), duration: 24 * 3600, status: .notStarted),
        classified("시작 놓침·마감 남음", dueAt: date(2026, 9, 20, 18, 0), duration: 10 * day, status: .notStarted),
        classified("마감까지 지남", dueAt: date(2026, 9, 5, 18, 0), duration: 3600, status: .notStarted),
        classified("마감 지남·진행 중", dueAt: date(2026, 9, 3, 18, 0), duration: 3600, status: .inProgress),
        classified("완료", dueAt: date(2026, 9, 14, 20, 0), duration: 3600, status: .done)
    ]

    /// 바꾸기 전 조건을 그대로 옮긴 것. 비교용이며 앱은 더 이상 쓰지 않는다.
    func oldBannerRule(_ resolved: ResolvedTask) -> Bool {
        guard let startDeadline = resolved.startDeadline else { return false }
        if cal.isDate(startDeadline, inSameDayAs: now) { return true }
        return resolved.task.status == .notStarted && startDeadline < now
    }

    let before = mixed.filter(oldBannerRule).filter { $0.task.status != .done }
    let after = mixed
        .filter { $0.isTodaysStart(now: now, calendar: cal) }
        .filter { $0.task.status != .done }

    // 옛 조건도 늦은 항목 분기에 `.notStarted` 를 요구했다. 그래서 「마감 지남·진행 중」은
    // 바꾸기 전에도 배너에 없었다. 이번 변경으로 실제로 빠지는 것은 **미시작인데 마감까지
    // 지난 항목** 하나뿐이다.
    report.equal("배너 — 바꾸기 전 개수", before.count, 3)
    report.equal("배너 — 바꾼 뒤 개수", after.count, 2)
    report.equal(
        "빠진 것은 미시작·마감까지 지난 항목뿐",
        Set(before.map(\.task.title)).subtracting(after.map(\.task.title)),
        ["마감까지 지남"]
    )
    report.check(
        "진행 중·마감 지남은 바꾸기 전에도 배너에 없었다",
        !before.contains { $0.task.title == "마감 지남·진행 중" }
    )
    report.check(
        "빠진 둘은 「기한 지난 할 일」이 받는다",
        mixed.filter { $0.isMissed(now: now) }.map(\.task.title).sorted()
            == ["마감 지남·진행 중", "마감까지 지남"]
    )

    // 완료한 것도 세는 대상에는 들어온다 — 「다 마쳤어요」와 「원래 없었다」를 가르기 위해
    report.check(
        "완료 항목은 세는 대상에 남는다",
        mixed.filter { $0.isTodaysStart(now: now, calendar: cal) }
            .contains { $0.task.title == "완료" }
    )
}
