//
//  StartMomentTextTests.swift
//  Startline — 착수 시점 표시 회귀 테스트 (명세서 5.4)
//
//  **마감과 다른 날에 시작해야 하는 일은 날짜까지만 말한다.**
//  12시간짜리 작업의 시작 시각을 분 단위로 말하는 것은 거짓 정밀도다.
//  앱이 실제로 아는 것은 「오늘 시작해야 한다」까지고, 그 이상은 지어내는 것이다.
//
//  문구를 만드는 곳이 네 군데로 흩어져 있었다 — 우측 패널 행, 할 일 시트 안내,
//  호버 미리보기, 알림. 한 곳으로 모았고, 여기서 그 한 곳을 검사한다.
//

import Foundation

func testStartMomentText() {
    report.begin("착수 시점 표시")

    let now = date(2026, 9, 22, 10, 0)   // 오늘 = 9월 22일 (화)

    func short(_ start: Date, _ due: Date?) -> String {
        StartMomentText.short(startDeadline: start, effectiveDueAt: due, now: now, calendar: cal)
    }
    func sentence(_ start: Date, _ due: Date?) -> String {
        StartMomentText.sentence(startDeadline: start, effectiveDueAt: due, now: now, calendar: cal)
    }

    // ── 같은 날 (3시간 / 마감 23:59) → 시각까지. 지금 그대로.
    let sameDayDue = date(2026, 9, 27, 23, 59)
    let sameDayStart = sameDayDue.addingTimeInterval(-3 * 3600)      // 9/27 20:59
    report.equal("같은 날 — 시각까지", short(sameDayStart, sameDayDue), "9월 27일 (일) 오후 8:59에 시작")
    report.equal(
        "같은 날 — 문장",
        sentence(sameDayStart, sameDayDue),
        "9월 27일 (일) 오후 8:59에 시작해야 해요"
    )

    // ── 다른 날, 하루 차이 (24시간 / 마감 9/8 19:00 → 착수 9/7 19:00)
    let d1Due = date(2026, 9, 8, 19, 0)
    let d1Start = d1Due.addingTimeInterval(-24 * 3600)
    report.equal("하루 차이 — 날짜만", short(d1Start, d1Due), "9월 7일 (월)에 시작")
    report.equal("하루 차이 — 문장", sentence(d1Start, d1Due), "9월 7일 (월)에 시작해야 해요")
    report.check("하루 차이 — 시각이 사라졌다", !short(d1Start, d1Due).contains(":"))

    // ── 다른 날, 여러 날 차이 (72시간 → 3일 전)
    let d3Due = date(2026, 10, 10, 16, 0)
    let d3Start = d3Due.addingTimeInterval(-72 * 3600)               // 10/7 16:00
    report.equal("3일 차이 — 날짜만", short(d3Start, d3Due), "10월 7일 (수)에 시작")
    report.check("3일 차이 — 시각이 없다", !short(d3Start, d3Due).contains(":"))

    // ── 오늘이 착수일
    //
    // 요청서의 「12시간 / 마감 내일 16:00 → 착수 오늘 04:00」은 산수가 맞지 않는다.
    // 16:00 − 12h = **같은 날** 04:00 이다. 하루를 넘기려면 36시간이 필요하다.
    // 그래서 여기서는 36시간으로 둔다. 같은 날 새벽에 떨어지는 경우는 아래에 따로 있다.
    let todayDue = date(2026, 9, 23, 16, 0)
    let todayStart = todayDue.addingTimeInterval(-36 * 3600)         // 9/22 04:00
    report.equal("오늘 — 「오늘」로 말한다", short(todayStart, todayDue), "오늘 시작")
    report.equal("오늘 — 문장", sentence(todayStart, todayDue), "오늘 시작해야 해요")
    report.check("오늘 — 새벽 4시가 새어나오지 않는다", !short(todayStart, todayDue).contains(":"))
    report.check("오늘 — 「오늘에」가 아니다", !short(todayStart, todayDue).contains("오늘에"))

    // ── 내일이 착수일
    let tomorrowDue = date(2026, 9, 24, 16, 0)
    let tomorrowStart = tomorrowDue.addingTimeInterval(-36 * 3600)   // 9/23 04:00
    report.equal("내일 — 「내일」로 말한다", short(tomorrowStart, tomorrowDue), "내일 시작")
    report.check("내일 — 「내일에」가 아니다", !short(tomorrowStart, tomorrowDue).contains("내일에"))

    // ── LeadTime.fixed 로 만든 항목도 같은 규칙을 탄다
    //
    // 두 경로의 출력 형태가 같아야 한다. 예전에는 한쪽만 시:분이 붙어 따로 놀았다.
    let fixedDue = date(2026, 9, 30, 14, 0)

    let day0 = ManagedTask(title: "당일", dueAt: fixedDue, leadTime: .fixed(days: 0))
    let day0Start = day0.startDeadline(effectiveDueAt: fixedDue, calendar: cal)!
    report.check("fixed(0) — 마감과 같은 날", cal.isDate(day0Start, inSameDayAs: fixedDue))
    report.equal("fixed(0) — 시각까지", short(day0Start, fixedDue), "9월 30일 (수) 오후 2:00에 시작")

    let day3 = ManagedTask(title: "3일 전", dueAt: fixedDue, leadTime: .fixed(days: 3))
    let day3Start = day3.startDeadline(effectiveDueAt: fixedDue, calendar: cal)!
    report.check("fixed(3) — 마감과 다른 날", !cal.isDate(day3Start, inSameDayAs: fixedDue))
    report.equal("fixed(3) — 날짜만", short(day3Start, fixedDue), "9월 27일 (일)에 시작")
    // 「시작」의 「시」에 걸리지 않도록 시각 표기 자체를 본다.
    for mark in ["오전", "오후", ":"] {
        report.check("fixed(3) — 「\(mark)」 시각 표기가 붙지 않는다", !short(day3Start, fixedDue).contains(mark))
    }

    // ── 리드타임 none → 착수 시점 자체가 없다
    let noLead = ManagedTask(title: "없음", dueAt: fixedDue, leadTime: .none)
    report.check(
        "리드타임 none — 착수 시점이 없다",
        noLead.startDeadline(effectiveDueAt: fixedDue, calendar: cal) == nil
    )

    // ── 자정 경계 (마감 00:30, 소요 1시간 → 착수가 전날 23:30)
    let midnightDue = date(2026, 9, 25, 0, 30)
    let midnightStart = midnightDue.addingTimeInterval(-3600)        // 9/24 23:30
    report.check("자정 경계 — 착수가 전날로 넘어간다", !cal.isDate(midnightStart, inSameDayAs: midnightDue))
    report.equal("자정 경계 — 날짜만", short(midnightStart, midnightDue), "9월 24일 (목)에 시작")

    // 마감 자체가 없으면 같은 날 판정을 할 수 없다 → 날짜만
    report.equal("마감 없음 — 날짜만", short(d1Start, nil), "9월 7일 (월)에 시작")

    // 알림 시각 검사는 Tests/AlarmTests.swift 로 옮겼다. 9시 규칙(`notifyMoment`)은
    // 알림 1단계화(BL-067)로 걷어냈다. 이 파일은 화면 표시 문구만 본다.
}
