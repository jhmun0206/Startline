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
    report.equal("예전 30분 소요 → 알림 30분 전 (같은 날이라 날짜어는 마감에만)", detail(due: legacy.dueAt, alarm: legacyAlarm),
                 "마감 내일 저녁 7시 · 알림 저녁 6시 30분")

    // ── 같은 날이면 날짜어는 마감 쪽에만 (3e)
    report.equal("같은 날 오늘", detail(due: date(2026, 10, 10, 16, 15), alarm: date(2026, 10, 10, 16, 10)),
                 "마감 오늘 오후 4시 15분 · 알림 오후 4시 10분")
    report.equal("같은 날 먼 날짜", detail(due: date(2026, 10, 20, 9, 0), alarm: date(2026, 10, 20, 6, 0)),
                 "마감 10월 20일 (화) 아침 9시 · 알림 아침 6시")

    // ── 완료한 할 일은 마감만
    let done = TaskTimeText.line(effectiveDueAt: date(2026, 10, 11, 19, 0), alarmAt: date(2026, 10, 10, 19, 0),
                                 isMissed: false, isCompleted: true, now: now, calendar: cal)
    report.equal("완료 → 마감만", done.plain, "마감 내일 저녁 7시")
    report.check("완료 → 알림 조각 없음", done.alarm == nil)

    // ── 두 조각으로 나뉜다 (화면이 다르게 칠할 수 있게)
    let split = TaskTimeText.line(effectiveDueAt: date(2026, 10, 11, 19, 0), alarmAt: date(2026, 10, 10, 19, 0),
                                  isMissed: false, now: now, calendar: cal)
    report.equal("마감 조각", split.due, "마감 내일 저녁 7시")
    report.equal("알림 조각", split.alarm, "알림 오늘 저녁 7시")

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

    // ── 목록 순서 — 우측 패널과 그리드가 같은 규칙 (3e)
    report.begin("할 일 순서 (ResolvedTask.listOrder)")

    func item(_ title: String, due: Date?, done: Bool = false) -> ResolvedTask {
        let t = ManagedTask(title: title, dueAt: due, leadTime: .fixed(days: 1))
        if done { t.markDone() }
        return ResolvedTask(task: t, effectiveDueAt: due,
                            startDeadline: t.startDeadline(effectiveDueAt: due, calendar: cal),
                            judgment: nil, parentTitle: nil, parentStart: nil)
    }
    let list = [
        item("완료·이른 마감", due: date(2026, 10, 11, 9, 0), done: true),
        item("미완료·늦은 마감", due: date(2026, 10, 14, 9, 0)),
        item("완료·늦은 마감", due: date(2026, 10, 13, 9, 0), done: true),
        item("미완료·이른 마감", due: date(2026, 10, 12, 9, 0)),
        item("미완료·마감 없음", due: nil)
    ]
    report.equal("미완료 먼저, 그 안에서 마감 빠른 순, 완료는 아래",
                 list.sorted { ResolvedTask.listOrder($0, $1) }.map(\.task.title),
                 ["미완료·이른 마감", "미완료·늦은 마감", "미완료·마감 없음", "완료·이른 마감", "완료·늦은 마감"])

    // 체크 직후 1초 동안은 바뀌기 전 값으로 줄을 세운다 — 자리를 지킨다
    let justChecked = item("방금 체크", due: date(2026, 10, 11, 12, 0), done: true)
    let held = [justChecked, item("다른 미완료", due: date(2026, 10, 12, 9, 0))]
        .sorted { ResolvedTask.listOrder($0, $1, isCompleted: { $0.task.title == "방금 체크" ? false : $0.task.isCompleted }) }
    report.equal("1초 동안은 원래 자리 (미완료로 취급)", held.first?.task.title, "방금 체크")
    let released = [justChecked, item("다른 미완료", due: date(2026, 10, 12, 9, 0))]
        .sorted { ResolvedTask.listOrder($0, $1) }
    report.equal("1초 뒤에는 아래로", released.last?.task.title, "방금 체크")

    // 그리드도 같은 기준 — 한 칸에 겹친 같은 길이 막대는 미완료 먼저, 그 다음 마감 순
    let days = CalendarManager.gridDays(for: date(2026, 10, 1), calendar: cal)
    let week = Array(days[7..<14])                     // 10/4 ~ 10/10 이 아닌 다음 줄
    let target = week[3]
    func gridItem(_ title: String, dueHour: Int, done: Bool) -> GridTaskItem {
        let due = cal.date(bySettingHour: dueHour, minute: 0, second: 0, of: target)!
        let r = item(title, due: due, done: done)
        return GridTaskItem(resolved: r, startDay: target, endDay: target, isEcho: false)
    }
    let layout = WeekLayout.build(
        days: week, dayEvents: [:],
        tasks: [gridItem("완료 9시", dueHour: 9, done: true), gridItem("미완료 18시", dueHour: 18, done: false),
                gridItem("미완료 10시", dueHour: 10, done: false)],
        availableHeight: 400, calendar: cal
    )
    // 할 일은 아래에서 위로 쌓는다 — 먼저 오는 것이 맨 아래(가장 큰 y)다.
    let bottomUp = layout.segments.sorted { $0.y > $1.y }.compactMap { seg -> String? in
        if case .task(let t) = seg.kind { return t.resolved.task.title }
        return nil
    }
    report.equal("그리드 — 아래부터 패널과 같은 순서", bottomUp, ["미완료 10시", "미완료 18시", "완료 9시"])
}
