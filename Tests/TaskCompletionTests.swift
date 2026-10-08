//
//  TaskCompletionTests.swift
//  Startline — 할 일 상태를 완료 / 미완료 둘로 읽는다 (BL-066)
//
//  예전에는 판정마다 `== .notStarted` 를 따로 봐서, 「지금 시작」으로 진행 중이 된 할 일은
//  **배지도 알림도 사라졌다.** 손만 대 놓고 끝내지 못한 일이 조용해지는 버그였다.
//  이제 모든 판정이 `isCompleted` 하나만 본다.
//

import Foundation

func testTaskCompletion() {
    report.begin("완료 / 미완료 (BL-066)")

    let now = date(2026, 10, 8, 12, 0)

    func make(_ status: TaskStatus, due: Date, duration: TimeInterval = 3600) -> ResolvedTask {
        let task = ManagedTask(title: "\(status)", dueAt: due, estimatedDuration: duration)
        task.status = status
        return ResolvedTask(
            task: task,
            effectiveDueAt: due,
            startDeadline: task.startDeadline(effectiveDueAt: due, calendar: cal),
            judgment: task.judgment(effectiveDueAt: due, now: now, calendar: cal),
            parentTitle: nil,
            parentStart: nil
        )
    }

    // ── 저장값 네 가지가 둘로 읽힌다
    for (status, done) in [(TaskStatus.notStarted, false), (.inProgress, false), (.missed, false), (.done, true)] {
        let task = ManagedTask(title: "x", dueAt: now)
        task.status = status
        report.equal("\(status) → isCompleted", task.isCompleted, done)
    }

    // ── 진행 중이 미시작과 똑같이 판정된다
    let future = date(2026, 10, 10, 18, 0)     // 착수 지남·마감 남음 (소요 3일)
    let past = date(2026, 10, 5, 18, 0)        // 마감 지남
    for status in [TaskStatus.notStarted, .inProgress, .missed] {
        let atRisk = make(status, due: future, duration: 3 * 86400)
        report.check("\(status) — 위험 판정", atRisk.isAtRisk(now: now))
        report.check("\(status) — 배지가 붙는다", atRisk.judgment != nil)
        report.check("\(status) — 배너에 센다", atRisk.isTodaysStart(now: now, calendar: cal))

        let missed = make(status, due: past)
        report.check("\(status) — 마감 지나면 놓침", missed.isMissed(now: now))
    }

    // ── 완료는 어느 쪽에도 들지 않는다
    let doneRisk = make(.done, due: future, duration: 3 * 86400)
    report.check("완료 — 위험 아님", !doneRisk.isAtRisk(now: now))
    report.check("완료 — 배지 없음", doneRisk.judgment == nil)
    report.check("완료 — 놓침 아님", !make(.done, due: past).isMissed(now: now))

    // ── 버그 수정 — 진행 중 할 일도 알림이 예약된다
    let alarmDue = date(2026, 10, 20, 18, 0)
    for status in [TaskStatus.notStarted, .inProgress] {
        let planned = NotificationScheduler.plan(
            for: [make(status, due: alarmDue)], now: now, limit: .max, calendar: cal
        )
        report.check("\(status) — 알림이 예약된다", !planned.isEmpty)
    }
    let donePlanned = NotificationScheduler.plan(
        for: [make(.done, due: alarmDue)], now: now, limit: .max, calendar: cal
    )
    report.check("완료 — 알림 없음", donePlanned.isEmpty)
}
