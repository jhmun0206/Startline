//
//  PanelTextTests.swift
//  Startline — 할 일 행 회색 줄과 배너 (커밋 3d)
//

import Foundation

func testPanelText() {
    let now = date(2026, 10, 10, 15, 0)   // 토요일 오후 3시

    // ── 할 일 행 회색 줄 — 시각만, 상태어 없음
    report.begin("할 일 행 회색 줄 (TaskTimeText)")

    func detail(due: Date?, alarm: Date?, missed: Bool = false) -> String {
        TaskTimeText.detail(effectiveDueAt: due, alarmAt: alarm, isMissed: missed, now: now, calendar: cal)
    }

    report.equal("오늘·내일", detail(due: date(2026, 10, 11, 19, 0), alarm: date(2026, 10, 10, 19, 0)),
                 "마감 내일 저녁 7시 · 알림 오늘 저녁 7시")
    report.equal("다른 날", detail(due: date(2026, 10, 15, 9, 30), alarm: date(2026, 10, 13, 9, 30)),
                 "마감 10월 15일 (목) 아침 9시 30분 · 알림 10월 13일 (화) 아침 9시 30분")
    report.equal("알림 없음", detail(due: date(2026, 10, 11, 19, 0), alarm: nil), "마감 내일 저녁 7시")
    report.equal("기한 지남 — 알림은 말하지 않음",
                 detail(due: date(2026, 10, 8, 19, 0), alarm: date(2026, 10, 7, 19, 0), missed: true),
                 "10월 8일 (목) 저녁 7시까지였어요")
    report.equal("기한 지남·오늘", detail(due: date(2026, 10, 10, 9, 0), alarm: nil, missed: true),
                 "오늘 아침 9시까지였어요")
    report.equal("마감 없음", detail(due: nil, alarm: nil), "마감 없음")

    // 예전 소요시간 데이터 — 알림 시각은 마감 − 소요시간으로 해석한 값, 같은 형식
    let legacy = ManagedTask(title: "예전", dueAt: date(2026, 10, 11, 19, 0), estimatedDuration: 1800)
    let legacyAlarm = legacy.startDeadline(effectiveDueAt: legacy.dueAt, calendar: cal)
    report.equal("예전 30분 소요 → 알림 30분 전", detail(due: legacy.dueAt, alarm: legacyAlarm),
                 "마감 내일 저녁 7시 · 알림 내일 저녁 6시 30분")

    // 상태어·소요시간·내부 용어가 나오지 않는다 — 배지와 같은 말을 반복하지 않는다
    let samples = [
        detail(due: date(2026, 10, 11, 19, 0), alarm: date(2026, 10, 10, 19, 0)),
        detail(due: date(2026, 10, 8, 19, 0), alarm: nil, missed: true),
        detail(due: legacy.dueAt, alarm: legacyAlarm)
    ]
    for word in ["오늘 시작", "늦음", "걸림", "착수", "리드타임", "여유"] {
        report.check("「\(word)」가 없다", samples.allSatisfy { !$0.contains(word) })
    }

    // ── 배너
    report.begin("배너 — 기한 지난 할 일도 센다")

    func task(_ title: String, due: Date, lead: LeadTime, done: Bool = false) -> ResolvedTask {
        let t = ManagedTask(title: title, dueAt: due, leadTime: lead)
        if done { t.markDone() }
        return ResolvedTask(task: t, effectiveDueAt: due,
                            startDeadline: t.startDeadline(effectiveDueAt: due, calendar: cal),
                            judgment: nil, parentTitle: nil, parentStart: nil)
    }
    func banner(_ ts: [ResolvedTask]) -> TodayBanner { TodayBanner.state(tasks: ts, now: now, calendar: cal) }

    let today = task("오늘 몫", due: date(2026, 10, 11, 19, 0), lead: .fixed(days: 1))   // 알림 오늘 19시
    let missed = task("기한 지남", due: date(2026, 10, 9, 19, 0), lead: .fixed(days: 1))
    let todayDone = task("오늘 몫", due: date(2026, 10, 11, 19, 0), lead: .fixed(days: 1), done: true)
    let missedDone = task("기한 지남", due: date(2026, 10, 9, 19, 0), lead: .fixed(days: 1), done: true)

    report.equal("① 오늘 몫 남음", banner([today, missed]), .remaining(1))
    report.equal("② 오늘 몫 0 · 기한 지남 있음", banner([todayDone, missed]), .missed(1))
    report.equal("② 문구", TodayBanner.missed(2).message, "기한 지난 할 일이 2개 있어요")
    report.equal("② → ③ 기한 지난 것도 완료하면 다 마쳤어요", banner([todayDone, missedDone]), .allDone)
    report.equal("오늘 몫이 원래 없고 기한 지남만 → ②", banner([missed]), .missed(1))
    report.equal("오늘 몫이 원래 없고 기한 지남을 완료 → 0개예요", banner([missedDone]), .none)
    report.equal("아무것도 없음 → 0개예요", banner([]), .none)
}
