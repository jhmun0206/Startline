//
//  SnoozeTests.swift
//  Startline — 「30분 미루기」를 저장한다 (BL-072)
//
//  예전에는 미룬 사실을 저장하지 않아, 앱에서 무엇이든 저장해 알림을 다시 예약하면
//  미룬 알림이 지워졌다. 이제 `snoozedUntil` 에 남고, 스케줄러가 그 시각으로 예약한다.
//

import Foundation

func testSnooze() {
    report.begin("30분 미루기 (BL-072)")

    let now = date(2026, 10, 10, 11, 24)
    let due = date(2026, 10, 12, 19, 0)

    func resolved(_ t: ManagedTask) -> ResolvedTask {
        ResolvedTask(task: t, effectiveDueAt: t.dueAt,
                     startDeadline: t.startDeadline(effectiveDueAt: t.dueAt, calendar: cal),
                     judgment: nil, parentTitle: nil, parentStart: nil)
    }
    func plan(_ ts: [ManagedTask]) -> [PlannedNotification] {
        NotificationScheduler.plan(for: ts.map(resolved), now: now, limit: .max, calendar: cal)
    }

    // ── 미룬 시각으로 예약된다 — 다른 할 일과 함께 다시 예약해도
    let snoozed = ManagedTask(title: "미룬 것", dueAt: due, leadTime: .fixed(days: 3))
    snoozed.snoozedUntil = now.addingTimeInterval(30 * 60)                  // 11:54
    let other = ManagedTask(title: "다른 것", dueAt: due, leadTime: .fixedHours(3))
    let p = plan([other, snoozed])
    let mine = p.first { $0.taskID == snoozed.id }
    report.equal("다른 할 일과 다시 예약해도 미룬 알림이 남는다", mine?.fireDate, date(2026, 10, 10, 11, 54))
    report.check("식별자는 원래 것 그대로 (|snoozed 꼬리 없음)", mine?.identifier.hasSuffix("|start") == true)
    report.equal("다른 할 일은 원래 시각", p.first { $0.taskID == other.id }?.fireDate, date(2026, 10, 12, 16, 0))

    // ── 지난 미룸은 무시하고 원래 시각을 본다
    let stale = ManagedTask(title: "지난 미룸", dueAt: due, leadTime: .fixedHours(3))
    stale.snoozedUntil = now.addingTimeInterval(-60)
    report.equal("지난 미룸 → 원래 시각", plan([stale]).first?.fireDate, date(2026, 10, 12, 16, 0))

    // ── 마감을 넘겨 미뤄도 막지 않는다 (원칙 1)
    let nearDue = date(2026, 10, 10, 11, 40)
    let late = ManagedTask(title: "마감 넘김", dueAt: nearDue, leadTime: .fixedHours(1))
    late.snoozedUntil = now.addingTimeInterval(30 * 60)                     // 11:54 > 마감 11:40
    report.equal("마감을 넘겨 미뤄도 예약된다", plan([late]).first?.fireDate, date(2026, 10, 10, 11, 54))

    // ── 완료하면 미룸이 지워지고 예약도 없다
    let done = ManagedTask(title: "완료", dueAt: due, leadTime: .fixed(days: 1))
    done.snoozedUntil = now.addingTimeInterval(30 * 60)
    done.markDone()
    report.check("완료 → snoozedUntil 지움", done.snoozedUntil == nil)
    report.check("완료 → 예약 없음", plan([done]).isEmpty)

    // ── 사용자가 마감·알림을 바꾸면 지운다. 제목만 바꾸면 남긴다
    func edited(_ change: (ManagedTask) -> Void, attached: Bool = false) -> Bool {
        let t = attached
            ? ManagedTask(title: "t", parentEventID: "evt", parentOccurrenceDate: due,
                          offsetFromParent: -86400, lastKnownDueAt: due.addingTimeInterval(-86400))
            : ManagedTask(title: "t", dueAt: due, leadTime: .fixed(days: 1))
        t.snoozedUntil = now.addingTimeInterval(30 * 60)
        let before = t.alarmInputs
        change(t)
        t.clearSnoozeIfAlarmChanged(from: before)
        return t.snoozedUntil == nil
    }
    report.check("제목만 바꿈 → 남는다", !edited { $0.title = "새 제목" })
    report.check("마감 바꿈 → 지운다", edited { $0.dueAt = due.addingTimeInterval(3600) })
    report.check("알림 바꿈 → 지운다", edited { $0.leadTime = .fixedHours(3) })
    report.check("딸린 할 일의 「며칠 전」 바꿈 → 지운다", edited({ $0.offsetFromParent = -2 * 86400 }, attached: true))
    report.check("딸린 할 일의 마감 사본만 바뀜(부모 이동) → 남는다",
                 !edited({ $0.dueAt = due.addingTimeInterval(7200) }, attached: true))
}
