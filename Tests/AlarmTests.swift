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
