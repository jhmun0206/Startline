//
//  GridTaskPlacementTests.swift
//  Startline — 그리드 할 일 배치 회귀 테스트
//
//  「오늘 메아리」는 시작 시점을 놓친 할 일을 오늘 칸에도 띄우는 장치다.
//  놓치면 안 되니 눈앞에 두자는 것이다.
//
//  그 생략 조건이 두 번 문제를 냈다.
//
//    `start != today`          — 오늘을 지나는 막대 위에 메아리를 덧그렸다. (0dd8a36)
//    `start <= today <= end`   — 마감이 지나 오늘이 막대 **뒤**에 있으면 못 걸러,
//                                옆 칸에 메아리가 붙어 막대가 끊어져 보였다. (BL-050)
//
//  둘 다 「오늘이 막대의 어디에 있나」를 따진 것이 잘못이었다. 메아리의 목적은
//  **같은 줄에 이미 보이는가**이지 막대와 오늘의 위치 관계가 아니다.
//
//  `GridTaskPlacement.items` 는 순수 함수라 실행 없이 확인할 수 있다.
//

import Foundation

/// 배치 검증용 할 일. 실제 모델을 그대로 쓴다.
func placementTask(
    _ title: String,
    startDeadline: Date,
    dueAt: Date,
    status: TaskStatus
) -> ResolvedTask {
    let task = ManagedTask(title: title, dueAt: dueAt)
    task.status = status
    return ResolvedTask(
        task: task,
        effectiveDueAt: dueAt,
        startDeadline: startDeadline,
        judgment: nil,
        parentTitle: nil,
        parentStart: nil
    )
}

private let placementFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM/dd"
    f.calendar = cal
    return f
}()

private func span(_ item: GridTaskItem) -> String {
    "\(placementFormatter.string(from: item.startDay))~\(placementFormatter.string(from: item.endDay))"
}

func testGridTaskPlacement() {
    report.begin("그리드 할 일 배치 — 오늘 메아리")

    // 실제 앱과 같은 방식으로 9월 그리드의 날짜 범위를 얻는다.
    let september = date(2026, 9, 1)
    let days = CalendarManager.gridDays(for: september, calendar: cal)
    guard let gridStart = days.first, let gridEnd = days.last else {
        report.check("그리드 날짜를 얻음", false)
        return
    }
    report.check(
        "9월 그리드 범위 \(placementFormatter.string(from: gridStart))~\(placementFormatter.string(from: gridEnd)) (\(days.count)일)",
        days.count % 7 == 0
    )

    // 아래 검사는 **플래그를 켠 상태**(`showsEcho: true`)를 본다.
    //
    // 메아리는 지금 꺼져 있지만(`FeatureFlags.todayEcho == false`) 코드는 남아 있다.
    // 켠 상태를 검증해 두지 않으면 나중에 되살릴 때 **이미 깨져 있을 수 있다.**
    // 끈 상태는 이 함수 뒤에서 따로 본다.
    func place(
        startDeadline: Date,
        dueAt: Date,
        now: Date,
        status: TaskStatus = .notStarted,
        showsSpan: Bool = true,
        showsEcho: Bool = true,
        gridStart: Date = gridStart,
        gridEnd: Date = gridEnd
    ) -> [GridTaskItem] {
        GridTaskPlacement.items(
            for: [placementTask("검증", startDeadline: startDeadline, dueAt: dueAt, status: status)],
            gridStart: gridStart,
            gridEnd: gridEnd,
            now: now,
            showsSpan: showsSpan,
            showsEcho: showsEcho,
            calendar: cal
        )
    }

    // ── a. 이번 사례 — 마감이 지나 오늘이 막대 뒤에 있다 (BL-050)
    let a = place(startDeadline: date(2026, 9, 7, 19), dueAt: date(2026, 9, 8, 19), now: date(2026, 9, 9, 12))
    report.equal("a) 마감 지남·같은 주 행 → 막대 1개", a.count, 1)
    report.equal("a) 구간은 09/07~09/08 그대로", a.first.map(span), "09/07~09/08")
    report.check("a) 메아리 없음", !a.contains { $0.isEcho })

    // ── b. 오늘이 막대 안 (0dd8a36 이 없앤 증상 — 되살아나면 안 된다)
    let b = place(startDeadline: date(2026, 9, 7, 19), dueAt: date(2026, 9, 11, 19), now: date(2026, 9, 9, 12))
    report.equal("b) 오늘이 막대 안 → 막대 1개", b.count, 1)
    report.equal("b) 구간 09/07~09/11", b.first.map(span), "09/07~09/11")
    report.check("b) 메아리 없음 (0dd8a36 회귀 방지)", !b.contains { $0.isEcho })

    // 0dd8a36 이 보고받은 그 값 그대로 — 9/7 착수, 9/9 마감, 오늘 9/8
    let original = place(startDeadline: date(2026, 9, 7, 9), dueAt: date(2026, 9, 9, 9), now: date(2026, 9, 8, 12))
    report.equal("0dd8a36 원래 증상 → 막대 1개", original.count, 1)
    report.check("0dd8a36 원래 증상 → 메아리 없음", !original.contains { $0.isEcho })

    // ── c. 본 막대가 다른 주 행 → 메아리가 살아 있어야 한다
    //
    // 요청서의 08-20 은 9월 그리드(08/30 시작) 밖이라 본 막대 자체가 안 그려진다.
    // 그 경우와, 그리드 안의 다른 주 행인 경우를 나눠서 본다.
    let cOutside = place(startDeadline: date(2026, 8, 20, 9), dueAt: date(2026, 8, 21, 9), now: date(2026, 9, 9, 12))
    report.equal("c1) 본 막대가 그리드 밖 → 메아리만 1개", cOutside.count, 1)
    report.check("c1) 그 1개가 메아리", cOutside.first?.isEcho == true)
    report.equal("c1) 메아리는 오늘 하루", cOutside.first.map(span), "09/09~09/09")

    let cInside = place(startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9), now: date(2026, 9, 9, 12))
    report.equal("c2) 그리드 안 다른 주 행 → 막대 2개", cInside.count, 2)
    report.equal("c2) 본 막대 09/01~09/02", cInside.first { !$0.isEcho }.map(span), "09/01~09/02")
    report.equal("c2) 메아리 09/09", cInside.first { $0.isEcho }.map(span), "09/09~09/09")
    report.check(
        "c2) 키가 main/echo 로 갈림",
        Set(cInside.map(\.key)).count == 2
            && cInside.contains { $0.key.hasSuffix("main") }
            && cInside.contains { $0.key.hasSuffix("echo") }
    )

    // ── d. 완료 → 메아리 없음
    let d = place(startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9), now: date(2026, 9, 9, 12), status: .done)
    report.equal("d) 완료 → 막대 1개", d.count, 1)
    report.check("d) 완료 → 메아리 없음", !d.contains { $0.isEcho })

    // 시작한 것도 메아리를 띄우지 않는다 (조건은 .notStarted 뿐)
    let started = place(startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9), now: date(2026, 9, 9, 12), status: .inProgress)
    report.check("d') 진행 중 → 메아리 없음", !started.contains { $0.isEcho })

    // ── e. 주 경계에 걸친 본 막대 — 오늘의 주 행에 일부만 걸친다
    //
    // 9월 그리드는 08/30 부터 7일씩 끊긴다 → 오늘(09/09)의 줄은 09/06~09/12.
    // 09/05~09/07 막대는 앞 줄에서 시작해 오늘의 줄로 이어진다.
    let e = place(startDeadline: date(2026, 9, 5, 9), dueAt: date(2026, 9, 7, 9), now: date(2026, 9, 9, 12))
    report.equal("e) 주 경계 걸침 → 막대 1개", e.count, 1)
    report.check("e) 주 경계 걸침 → 메아리 없음 (같은 줄에 보임)", !e.contains { $0.isEcho })

    // 그 막대가 오늘의 줄에서 실제로 그려지는지, continuesBefore 와 어긋나지 않는지
    let todayRow = Array(days[7..<14])
    let layout = WeekLayout.build(
        days: todayRow,
        dayEvents: [:],
        tasks: e,
        availableHeight: 400,
        calendar: cal
    )
    let bars = layout.segments
    report.equal("e) 오늘의 줄에 막대가 1개 그려짐", bars.count, 1)
    report.check("e) 앞 줄에서 이어져 온 것으로 표시됨", bars.first?.continuesBefore == true)
    report.check("e) 뒤로는 이어지지 않음", bars.first?.continuesAfter == false)

    // 앞 줄에도 같은 막대가 이어져 그려진다 (한 항목이 두 줄에 나뉘어 보이는 정상 동작)
    let previousRow = Array(days[0..<7])
    let previousBars = WeekLayout.build(
        days: previousRow, dayEvents: [:], tasks: e, availableHeight: 400, calendar: cal
    ).segments
    report.equal("e) 앞 줄에도 이어짐", previousBars.count, 1)
    report.check("e) 앞 줄은 뒤로 이어짐 표시", previousBars.first?.continuesAfter == true)

    // ── f. 오늘이 표시 범위 밖 (다른 달을 보고 있다)
    let december = date(2026, 12, 1)
    let decemberDays = CalendarManager.gridDays(for: december, calendar: cal)
    let f = place(
        startDeadline: date(2026, 12, 7, 9),
        dueAt: date(2026, 12, 8, 9),
        now: date(2026, 9, 9, 12),
        gridStart: decemberDays.first!,
        gridEnd: decemberDays.last!
    )
    report.check("f) 오늘이 범위 밖 → 메아리 없음", !f.contains { $0.isEcho })
    report.equal("f) 본 막대는 그대로", f.count, 1)

    // ── 점선 표시를 끈 상태에서도 같은 규칙
    let noSpan = place(
        startDeadline: date(2026, 9, 7, 19), dueAt: date(2026, 9, 8, 19),
        now: date(2026, 9, 9, 12), showsSpan: false
    )
    report.equal("점선 끔 → 막대 1개", noSpan.count, 1)
    report.equal("점선 끔 → 시작 지점만", noSpan.first.map(span), "09/07~09/07")
    report.check("점선 끔 → 같은 줄이므로 메아리 없음", !noSpan.contains { $0.isEcho })

    // ── 플래그를 끈 상태 (지금 출하되는 동작)
    report.begin("오늘 메아리 — 플래그 끈 상태")

    report.check(
        "출하 기본값이 꺼짐 (FeatureFlags.todayEcho == false)",
        FeatureFlags.todayEcho == false
    )

    // 켰을 때 메아리가 나던 두 경우가 꺼졌을 때 어떻게 되는지.
    // c1 — 본 막대가 그리드 밖. 켜면 메아리만 1개, 끄면 아무것도 없다.
    let c1Off = place(
        startDeadline: date(2026, 8, 20, 9), dueAt: date(2026, 8, 21, 9),
        now: date(2026, 9, 9, 12), showsEcho: false
    )
    report.equal("c1) 그리드 밖 + 플래그 끔 → 막대 0개", c1Off.count, 0)

    // c2 — 그리드 안 다른 주 행. 켜면 2개, 끄면 본 막대 1개만.
    let c2Off = place(
        startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9),
        now: date(2026, 9, 9, 12), showsEcho: false
    )
    report.equal("c2) 다른 주 행 + 플래그 끔 → 막대 1개", c2Off.count, 1)
    report.check("c2) 남은 것은 본 막대", c2Off.first?.isEcho == false)
    report.equal("c2) 본 막대 구간은 그대로 09/01~09/02", c2Off.first.map(span), "09/01~09/02")

    // 본 막대 계산은 플래그와 무관하다 — 켜든 끄든 같아야 한다.
    let onMain = place(
        startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9),
        now: date(2026, 9, 9, 12), showsEcho: true
    ).filter { !$0.isEcho }
    report.equal("본 막대는 플래그와 무관", onMain.map(span), c2Off.map(span))

    // 메아리가 애초에 안 나던 경우들은 플래그를 꺼도 그대로다.
    let aOff = place(
        startDeadline: date(2026, 9, 7, 19), dueAt: date(2026, 9, 8, 19),
        now: date(2026, 9, 9, 12), showsEcho: false
    )
    report.equal("a) 같은 주 행 + 플래그 끔 → 막대 1개 (변화 없음)", aOff.count, 1)
    report.equal("a) 구간 그대로", aOff.first.map(span), "09/07~09/08")

    // 끈 상태에서는 어떤 입력으로도 메아리가 나오지 않는다.
    let everyCase: [[GridTaskItem]] = [
        place(startDeadline: date(2026, 8, 20, 9), dueAt: date(2026, 8, 21, 9), now: date(2026, 9, 9, 12), showsEcho: false),
        place(startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9), now: date(2026, 9, 9, 12), showsEcho: false),
        place(startDeadline: date(2026, 9, 7, 19), dueAt: date(2026, 9, 8, 19), now: date(2026, 9, 9, 12), showsEcho: false),
        place(startDeadline: date(2026, 9, 5, 9), dueAt: date(2026, 9, 7, 9), now: date(2026, 9, 9, 12), showsEcho: false),
        place(startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9), now: date(2026, 9, 9, 12), showsEcho: false, gridStart: gridStart, gridEnd: gridEnd)
    ]
    report.check(
        "끈 상태에서는 어떤 입력으로도 메아리가 없다",
        everyCase.allSatisfy { items in !items.contains { $0.isEcho } }
    )

    // isEcho·키 체계는 남아 있어야 한다 — 플래그를 켜면 즉시 돌아온다.
    let keyed = place(
        startDeadline: date(2026, 9, 1, 9), dueAt: date(2026, 9, 2, 9),
        now: date(2026, 9, 9, 12), showsEcho: true
    )
    report.check(
        "켜면 |main / |echo 키 체계가 그대로 살아 있다",
        keyed.contains { $0.key.hasSuffix("main") } && keyed.contains { $0.key.hasSuffix("echo") }
    )
}
