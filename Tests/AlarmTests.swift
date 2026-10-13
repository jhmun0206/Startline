//
//  AlarmTests.swift
//  Startline — 할 일 알림 (BL-067)
//
//  **알림 시각 = 마감 − 사용자가 고른 오프셋. 앱이 보정하지 않는다.**
//  할 일당 알림은 하나다. 예고(−1일)·위험(+1시간)·아침 9시 이동을 걷어냈다.
//
//  원칙 1 — 이미 저장된 할 일의 알림 시각은 저장값에서 계산한 그대로여야 한다.
//  실제 스토어에 30분(1800초)짜리 소요시간이 2건 있다. 그 모양을 그대로 고정한다.
//

import Foundation

func testAlarms() {
    report.begin("할 일 알림 — 1단계 (BL-067)")

    let now = date(2026, 10, 8, 12, 0)

    func resolved(_ task: ManagedTask, due: Date, status: TaskStatus = .notStarted) -> ResolvedTask {
        task.status = status
        return ResolvedTask(
            task: task,
            effectiveDueAt: due,
            startDeadline: task.startDeadline(effectiveDueAt: due, calendar: cal),
            judgment: nil,
            parentTitle: nil,
            parentStart: nil
        )
    }
    func plan(_ items: [ResolvedTask]) -> [PlannedNotification] {
        NotificationScheduler.plan(for: items, now: now, limit: .max, calendar: cal)
    }

    // ── 할 일당 하나
    let due = date(2026, 10, 20, 19, 0)
    let one = plan([resolved(ManagedTask(title: "하나", dueAt: due, estimatedDuration: 3 * 3600), due: due)])
    report.equal("할 일당 알림 1개", one.count, 1)
    report.check("식별자 꼬리는 start", one.first?.identifier.hasSuffix("|start") == true)

    // ── 저장값 그대로 — 실제 스토어의 30분짜리 소요시간 2건과 같은 모양
    for (label, d) in [("30분 소요 ①", date(2026, 10, 15, 23, 59)), ("30분 소요 ②", date(2026, 10, 18, 9, 0))] {
        let t = ManagedTask(title: label, dueAt: d, estimatedDuration: 1800)
        let p = plan([resolved(t, due: d)])
        report.equal("\(label) — 마감 − 30분 그대로", p.first?.fireDate, d.addingTimeInterval(-1800))
    }

    // ── 리드타임 종류별: 알림 = startDeadline 그대로 (보정 없음)
    let cases: [(String, ManagedTask)] = [
        ("소요 24시간", ManagedTask(title: "a", dueAt: due, estimatedDuration: 86400)),
        ("1일 전", ManagedTask(title: "b", dueAt: due, leadTime: .fixed(days: 1))),
        ("3시간 전", ManagedTask(title: "c", dueAt: due, leadTime: .fixedHours(3))),
        ("0일 전(마감 시각)", ManagedTask(title: "d", dueAt: due, leadTime: .fixed(days: 0)))
    ]
    for (label, t) in cases {
        let r = resolved(t, due: due)
        let p = plan([r])
        report.equal("\(label) — 알림 = 저장값에서 계산한 시점", p.first?.fireDate, r.startDeadline)
        report.check("\(label) — 마감보다 늦지 않다", (p.first?.fireDate ?? .distantFuture) <= due)
    }

    // 「알림 없음」이면 예약하지 않는다
    report.check("알림 없음 → 예약 없음",
                 plan([resolved(ManagedTask(title: "e", dueAt: due, leadTime: .none), due: due)]).isEmpty)

    // ── 9시 이동을 걷어냈다 — 마감과 다른 날이어도 계산된 시각에 울린다
    //
    // 예전(bdc9328)에는 마감과 다른 날이면 그날 아침 9시로 옮겼다. 이 사례에서 예전 알림은
    // 10월 19일 09:00 이었고 이제는 10월 19일 19:00 이다. 앱의 보정을 걷어낸 의도된 변화다.
    // (지금 실제 스토어의 미완료 할 일은 알림 없음 1건뿐이라 이 변화가 닿는 데이터는 없다)
    let dayBefore = resolved(ManagedTask(title: "f", dueAt: due, estimatedDuration: 86400), due: due)
    report.equal("다른 날이어도 보정 없음 — 10/19 19:00", plan([dayBefore]).first?.fireDate, date(2026, 10, 19, 19, 0))

    // ── 지난 시각·완료는 예약하지 않는다
    let pastDue = date(2026, 10, 8, 12, 30)
    report.check("이미 지난 알림 시각 → 예약 없음",
                 plan([resolved(ManagedTask(title: "g", dueAt: pastDue, estimatedDuration: 3600), due: pastDue)]).isEmpty)
    report.check("완료 → 예약 없음",
                 plan([resolved(ManagedTask(title: "h", dueAt: due, estimatedDuration: 3600), due: due, status: .done)]).isEmpty)

    // ── 문구 — 사실(마감)만 말한다
    report.equal("제목", NotificationScheduler.headline, "시작할 시간이에요")
    let body = NotificationScheduler.message(
        title: "보고서 초안", parentTitle: "[졸프] 전체 미팅", effectiveDueAt: date(2026, 10, 11, 19, 0), calendar: cal
    )
    report.equal("본문", body, "‘보고서 초안’ ([졸프] 전체 미팅) — 마감 10월 11일 (일) 오후 7:00")
    for word in ["착수", "리드타임", "마감시각", "지금 시작해야", "맞출 수"] {
        report.check("본문에 「\(word)」가 없다", !body.contains(word))
    }

    // ── 식별자에서 할 일 ID 되찾기 — 미룬 알림·예전 단계 알림에서도 버튼이 동작해야 한다
    let id = UUID()
    for suffix in ["start", "start|snoozed", "advance", "risk"] {
        report.equal("「startline|ID|\(suffix)」 → ID", PlannedNotification.taskID(from: "startline|\(id.uuidString)|\(suffix)"), id)
    }
    report.check("남의 알림 → 없음", PlannedNotification.taskID(from: "startline.test.\(id.uuidString)") == nil)
}

// MARK: - 시작 알림 칩 (커밋 4·4b, BL-065)

func testStartAlarmInput() {
    report.begin("시작 알림 칩 (StartAlarmInput)")

    // ── 기본값과 원탭 프리셋
    report.equal("기본값 3시간", StartAlarmInput.default.leadTime, .fixedHours(3))
    report.equal("프리셋 다섯 개", StartAlarmInput.presets.count, 5)
    report.equal("[30분]", StartAlarmInput(choice: .preset(.minutes, 30)).leadTime, .fixedMinutes(30))
    report.equal("[1시간]", StartAlarmInput(choice: .preset(.hours, 1)).leadTime, .fixedHours(1))
    report.equal("[1일]", StartAlarmInput(choice: .preset(.days, 1)).leadTime, .fixed(days: 1))
    report.equal("[3일]", StartAlarmInput(choice: .preset(.days, 3)).leadTime, .fixed(days: 3))
    report.equal("[없음]", StartAlarmInput(choice: .none).leadTime, LeadTime.none)

    // ── [직접] = 숫자 + 단위
    report.equal("[직접] 45분", StartAlarmInput(choice: .custom, customValue: 45, customUnit: .minutes).leadTime, .fixedMinutes(45))
    report.equal("[직접] 5시간", StartAlarmInput(choice: .custom, customValue: 5, customUnit: .hours).leadTime, .fixedHours(5))
    report.equal("[직접] 7일", StartAlarmInput(choice: .custom, customValue: 7, customUnit: .days).leadTime, .fixed(days: 7))
    report.equal("[직접] 0일 = 마감 시각", StartAlarmInput(choice: .custom, customValue: 0, customUnit: .days).leadTime, .fixed(days: 0))

    // ── 범위 — 벗어나면 저장값이 없고 이유가 나온다 (저장 버튼이 꺼진다)
    for (unit, bad) in [(StartAlarmInput.Unit.minutes, 0), (.minutes, 1441), (.hours, 0), (.hours, 73), (.days, -1), (.days, 366)] {
        let input = StartAlarmInput(choice: .custom, customValue: bad, customUnit: unit)
        report.check("[직접] \(bad)\(unit.label) → 저장 불가", input.leadTime == nil && input.invalidReason != nil)
    }
    report.check("범위 안이면 이유 없음", StartAlarmInput(choice: .custom, customValue: 72, customUnit: .hours).invalidReason == nil)
    // [직접]을 고르지 않았으면 입력칸 값은 따지지 않는다
    report.check("프리셋이면 입력칸 값은 무시", StartAlarmInput(choice: .preset(.days, 1), customValue: 999).invalidReason == nil)

    // ── 불러오기 — 가까운 칩으로 바꾸지 않는다 (원칙 1)
    func load(_ lead: LeadTime, _ duration: TimeInterval? = nil) -> StartAlarmInput {
        StartAlarmInput.from(leadTime: lead, estimatedDuration: duration)
    }
    report.equal("3일 → [3일]", load(.fixed(days: 3)).choice, .preset(.days, 3))
    report.equal("30분 → [30분]", load(.fixedMinutes(30)).choice, .preset(.minutes, 30))
    report.equal("3시간 → [3시간]", load(.fixedHours(3)).choice, .preset(.hours, 3))
    report.equal("7일(예전 「1주 전」) → [직접]", load(.fixed(days: 7)).choice, .custom)
    report.equal("7일 → 값 그대로", load(.fixed(days: 7)).leadTime, .fixed(days: 7))
    report.equal("2일 → [직접] 2일", load(.fixed(days: 2)).leadTime, .fixed(days: 2))
    report.equal("0일 → [직접] 0일", load(.fixed(days: 0)).leadTime, .fixed(days: 0))
    report.equal("5시간 → [직접] 5시간", load(.fixedHours(5)).leadTime, .fixedHours(5))
    report.equal("45분 → [직접] 45분", load(.fixedMinutes(45)).leadTime, .fixedMinutes(45))
    report.equal("없음 → [없음]", load(.none).choice, .none)

    let legacy = load(.durationBased, 30 * 60)
    report.equal("옛 소요 30분 → 「기존 값」 칩", legacy.choice, .legacy)
    report.equal("옛 소요 30분 → 라벨", legacy.legacyLabel, "30분 전 (기존 값)")
    report.equal("옛 소요 30분 → 저장값 그대로", legacy.leadTime, .durationBased)
    report.equal("옛 소요 1시간 30분 → 라벨", load(.durationBased, 90 * 60).legacyLabel, "1시간 30분 전 (기존 값)")
    report.equal("옛 소요 없음 → 알림 없었음 → [없음]", load(.durationBased, nil).choice, .none)

    // 다른 칩을 골랐다가 「기존 값」으로 돌아오면 원래 값
    var toggled = legacy
    toggled.choice = .preset(.days, 1)
    report.equal("다른 칩 → 그 값", toggled.leadTime, .fixed(days: 1))
    toggled.choice = .legacy
    report.equal("「기존 값」으로 돌아옴 → 원래 값", toggled.leadTime, .durationBased)

    // ── 저장 표현 왕복 — 새 종류(N분 전)가 스토어 표현을 거쳐도 그대로
    let minutesTask = ManagedTask(title: "분", dueAt: date(2026, 10, 11, 9, 0), leadTime: .fixedMinutes(30))
    report.equal("N분 전 저장 종류", minutesTask.leadTimeKind, .fixedMinutes)
    report.equal("N분 전 왕복", minutesTask.leadTime, .fixedMinutes(30))

    // ── 알림 시각 계산
    let due = date(2026, 10, 11, 23, 59)
    func alarm(_ lead: LeadTime) -> Date? {
        ManagedTask(title: "t", dueAt: due, leadTime: lead).startDeadline(effectiveDueAt: due, calendar: cal)
    }
    report.equal("30분 전", alarm(.fixedMinutes(30)), due.addingTimeInterval(-1800))
    report.equal("3시간 전", alarm(.fixedHours(3)), due.addingTimeInterval(-3 * 3600))
    report.equal("1일 전 = 정확히 24시간 전 (BL-022)", alarm(.fixed(days: 1)), due.addingTimeInterval(-86_400))

    // 옛 소요시간 데이터의 알림 시각은 바뀌지 않는다 (원칙 1)
    let old = ManagedTask(title: "옛 30분", dueAt: due, estimatedDuration: 1800)
    report.equal("옛 30분 소요 → 마감 30분 전 그대로", old.startDeadline(effectiveDueAt: due, calendar: cal), due.addingTimeInterval(-1800))

    // 기본값(3시간)이면 오늘 23:59 마감도 처음부터 지난 시각이 되지 않는다
    let now = date(2026, 10, 10, 15, 0)
    let todayDue = date(2026, 10, 10, 23, 59)
    let defaultAlarm = ManagedTask(title: "오늘", dueAt: todayDue, leadTime: StartAlarmInput.default.leadTime!)
        .startDeadline(effectiveDueAt: todayDue, calendar: cal)
    report.check("기본값 — 오늘 23:59 마감이면 알림은 아직 안 지났다", (defaultAlarm ?? now) > now)

    // ── 미리보기 한 줄
    report.equal("미리보기", StartAlarmInput.preview(alarmAt: date(2026, 10, 10, 20, 59), now: now, calendar: cal),
                 "10월 10일 (토) 오후 8:59에 알림이 울려요")
    report.equal("이미 지났으면 알리되 막지 않음", StartAlarmInput.preview(alarmAt: date(2026, 10, 10, 9, 0), now: now, calendar: cal),
                 "알림 시각이 이미 지났어요")
    report.check("알림 없음 → 줄 숨김", StartAlarmInput.preview(alarmAt: nil, now: now, calendar: cal) == nil)
}
