//
//  EventGroupingTests.swift
//  Startline — 일정 중복 묶기 회귀 테스트
//
//  묶기의 목적은 공휴일·생일처럼 **여러 캘린더에 중복 등록된 같은 일정**을 한 줄로
//  보여주는 것이다. 사용자가 실제로 만든 일정을 감추는 것이 아니다.
//
//  예전에는 `종일여부 + 시작시각 + 제목` 만 보고 묶어서, 같은 캘린더에 같은 이름·시각으로
//  만든 별개의 일정까지 합쳐졌다. 화면에는 하나로 보이는데 실제로는 둘이라
//  삭제를 눌러도 대표 하나만 지워지고 나머지는 손댈 방법이 없었다. (BL-048)
//
//  BL-005 는 「서로 다른 일정을 같은 것으로 잘못 묶지 말라」는 결정이다.
//  이 규칙은 판정을 **더 엄격하게** 만드는 것이므로 BL-005 와 같은 방향이다.
//

import EventKit
import Foundation

/// 저장하지 않고 메모리에만 만드는 일정. 캘린더 권한이 없어도 된다.
enum EventFactory {
    static let store = EKEventStore()

    static func calendar(_ title: String) -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        return calendar
    }

    static func event(_ title: String, at start: Date, in calendar: EKCalendar, isAllDay: Bool = false) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.isAllDay = isAllDay
        event.calendar = calendar
        return event
    }
}

func testEventGrouping() {
    report.begin("일정 중복 묶기")

    let work = EventFactory.calendar("직장")
    let personal = EventFactory.calendar("개인")
    let at = date(2026, 9, 10, 14, 0)

    // 같은 캘린더에 동일 제목·시각 일정 2개 → 각각 별개로 표시
    let a = EventFactory.event("하이루", at: at, in: work)
    let b = EventFactory.event("하이루", at: at, in: work)
    let sameCalendar = CalendarManager.groupDuplicates([a, b])

    report.equal("같은 캘린더의 동명 일정 2개 → 묶음 2개", sameCalendar.count, 2)
    report.check(
        "각 묶음이 1건씩만 담음",
        sameCalendar.allSatisfy { $0.events.count == 1 }
    )
    // 아래 검사는 묶음이 2개일 때만 뜻이 있다. 개수가 틀리면 그 사실만 알리고 넘어간다 —
    // 인덱스로 들어가면 테스트가 크래시로 끝나 원인이 안 보인다.
    if sameCalendar.count == 2 {
        report.check("두 묶음의 id 가 서로 다름", sameCalendar[0].id != sameCalendar[1].id)
        report.check(
            "묶음마다 서로 다른 실제 일정을 가리킴",
            sameCalendar[0].primary !== sameCalendar[1].primary
        )
        report.equal("캘린더명이 한 번만 나옴", sameCalendar[0].calendarTitles, ["직장"])
    } else {
        report.check("두 묶음의 id 가 서로 다름", false, "묶음이 \(sameCalendar.count)개")
        report.check("묶음마다 서로 다른 실제 일정을 가리킴", false, "묶음이 \(sameCalendar.count)개")
        report.check("캘린더명이 한 번만 나옴", false, "묶음이 \(sameCalendar.count)개")
    }
    report.check("중복 표시가 아님", sameCalendar.allSatisfy { !$0.isDuplicated })

    // 서로 다른 캘린더의 공휴일 → 여전히 하나로 묶임
    let holidayA = EventFactory.event("추석", at: at, in: work, isAllDay: true)
    let holidayB = EventFactory.event("추석", at: at, in: personal, isAllDay: true)
    let holidays = CalendarManager.groupDuplicates([holidayA, holidayB])

    report.equal("다른 캘린더의 같은 공휴일 → 묶음 1개", holidays.count, 1)
    report.equal("묶음에 2건이 담김", holidays.first?.events.count, 2)
    report.check("중복 표시가 켜짐", holidays.first?.isDuplicated == true)
    report.equal("캘린더명 두 개가 나옴", holidays.first?.calendarTitles, ["개인", "직장"])

    // 삭제 대상이 묶음 전체인지 — 확인창에 쓰이는 개수
    report.equal("공휴일 묶음의 삭제 대상 개수", holidays.first?.events.count, 2)
    report.equal("동명 일정 묶음의 삭제 대상 개수", sameCalendar.first?.events.count, 1)

    // BL-005 — 제목이 다르면 절대 묶이지 않는다
    let chuseok = EventFactory.event("추석", at: at, in: work, isAllDay: true)
    let chuseokHoliday = EventFactory.event("추석 연휴", at: at, in: personal, isAllDay: true)
    report.equal(
        "「추석」과 「추석 연휴」는 다른 일정 (BL-005)",
        CalendarManager.groupDuplicates([chuseok, chuseokHoliday]).count,
        2
    )

    // 섞인 경우 — 직장 2건 + 개인 1건
    let mixed = CalendarManager.groupDuplicates([
        EventFactory.event("회의", at: at, in: work),
        EventFactory.event("회의", at: at, in: work),
        EventFactory.event("회의", at: at, in: personal)
    ])
    report.equal("직장 2 + 개인 1 → 묶음 2개", mixed.count, 2)
    report.equal("첫 묶음은 두 캘린더가 묶임", mixed.first?.events.count, 2)
    report.equal("둘째 묶음은 남은 1건", mixed.last?.events.count, 1)
    report.check(
        "같은 캘린더가 한 묶음에 두 번 들어가지 않음",
        mixed.allSatisfy { group in
            let ids = group.events.compactMap { $0.calendar?.calendarIdentifier }
            return Set(ids).count == ids.count
        }
    )

    // 시각이 다르면 묶이지 않는다
    report.equal(
        "시각이 다르면 별개",
        CalendarManager.groupDuplicates([
            EventFactory.event("점심", at: at, in: work),
            EventFactory.event("점심", at: at.addingTimeInterval(3600), in: work)
        ]).count,
        2
    )

    // 종일 여부가 다르면 묶이지 않는다
    report.equal(
        "종일 여부가 다르면 별개",
        CalendarManager.groupDuplicates([
            EventFactory.event("워크숍", at: at, in: work, isAllDay: true),
            EventFactory.event("워크숍", at: at, in: personal, isAllDay: false)
        ]).count,
        2
    )
}
