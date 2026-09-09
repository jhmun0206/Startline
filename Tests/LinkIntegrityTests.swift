//
//  LinkIntegrityTests.swift
//  Startline — 일정·할 일 연결 회귀 테스트
//
//  명세서 7장은 일정과 할 일의 연결을 "이 앱에서 두 번째로 중요한 개념"으로 규정한다.
//  여기가 깨지면 제품의 뿌리가 흔들린다.
//
//  이 파일이 생긴 계기는 실제 사고다. `parentEventID` 가 조용히 `NULL` 로 지워져
//  두 할 일의 연결이 사라졌고, **복구할 수 없었다.** (BL-045) 화면 오류가 아니라
//  DB에서 값이 없어진 것이라 눈으로는 알아챌 방법도 없었다.
//
//  그래서 이 테스트는 **실제 소스를 그대로 컴파일해서** 돌린다. 사본이나 흉내가 아니라
//  앱이 쓰는 바로 그 `ManagedTask` · `TaskLinkMaintenance` · `TaskLinkPolicy` 를 부른다.
//  로직을 고쳐도 테스트를 함께 고치지 않으면 곧바로 깨지도록 만든 것이다.
//
//  실행:  ./Tests/run-link-tests.sh
//

import Foundation
import SwiftData

// MARK: - 아주 작은 검증 도구

/// 통과·실패를 세는 곳. 테스트 프레임워크를 들이지 않는 이유는
/// 이 테스트가 앱 타겟 밖에서 `swiftc` 로만 돌아가야 하기 때문이다.
final class Report {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var section = ""

    func begin(_ title: String) {
        section = title
        print("\n── \(title)")
    }

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            let extra = detail()
            failures.append("[\(section)] \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            print("  ✗ \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "실제 \(actual) / 기대 \(expected)")
    }

    /// 종료 코드까지 결정한다. 실패가 하나라도 있으면 0이 아니다.
    func finish() -> Int32 {
        print("\n" + String(repeating: "═", count: 60))
        if failures.isEmpty {
            print("통과 \(passed)건 · 실패 0건")
            return 0
        }
        print("통과 \(passed)건 · 실패 \(failures.count)건")
        for failure in failures { print("  · \(failure)") }
        return 1
    }
}

let report = Report()

// MARK: - 가짜 캘린더

/// 캘린더 권한 없이 부모 조회를 흉내 내는 저장소.
///
/// `TaskLinkMaintenance.sync` 가 부모 조회를 **클로저로 받도록** 설계돼 있어서
/// EventKit 없이도 실제 로직을 그대로 돌릴 수 있다.
final class FakeCalendarStore {

    struct FakeEvent {
        var start: Date
        var calendarID: String = "cal.work"
        var isReadOnly: Bool = false
        /// 반복 일정일 때 살아 있는 회차. `저장된 회차 시각 → 현재 시각`.
        var occurrences: [Date: Date] = [:]
        var isRecurring: Bool { !occurrences.isEmpty }
    }

    var events: [String: FakeEvent] = [:]

    /// 조회가 몇 번 불렸는지. 반복 실행 시나리오에서 쓴다.
    private(set) var lookupCount = 0
    /// 이번 조회를 실패시킬지 정하는 규칙. 간헐적 실패 재현용.
    var failLookup: (Int) -> Bool = { _ in false }

    func reset() {
        lookupCount = 0
        failLookup = { _ in false }
    }

    /// `TaskLinkMaintenance.sync(tasks:parentStart:)` 에 그대로 넘길 수 있는 조회.
    func parentStart(for task: ManagedTask) -> Date? {
        lookupCount += 1
        if failLookup(lookupCount) { return nil }

        guard let id = task.parentEventID, let event = events[id] else { return nil }
        guard event.isRecurring else { return event.start }

        // 반복 일정은 저장해 둔 회차로 특정한다. 그 회차가 지워졌으면 못 찾는다.
        guard let occurrence = task.parentOccurrenceDate else { return event.start }
        return event.occurrences[occurrence]
    }
}

// MARK: - 날짜 도우미

let cal = Calendar(identifier: .gregorian)
let day: TimeInterval = 24 * 60 * 60

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
    var components = DateComponents()
    components.year = y; components.month = m; components.day = d
    components.hour = h; components.minute = min
    return cal.date(from: components)!
}

/// 연결된 할 일 하나를 만든다.
func makeAttached(
    _ title: String,
    parentID: String,
    occurrence: Date?,
    offset: TimeInterval,
    lastKnownDueAt: Date?
) -> ManagedTask {
    ManagedTask(
        title: title,
        parentEventID: parentID,
        parentOccurrenceDate: occurrence,
        offsetFromParent: offset,
        lastKnownDueAt: lastKnownDueAt,
        estimatedDuration: 3600
    )
}

// MARK: - 1. 기본 동작

func testBasics() {
    report.begin("기본 동작")

    let store = FakeCalendarStore()
    let meeting = date(2026, 9, 20, 19, 0)
    store.events["evt.meeting"] = .init(start: meeting)

    // 할 일을 일정에 연결 → 저장값 확인
    let offset = -2 * day
    let task = makeAttached(
        "졸프 주제 선정하기",
        parentID: "evt.meeting",
        occurrence: meeting,
        offset: offset,
        lastKnownDueAt: meeting.addingTimeInterval(offset)
    )

    report.check("연결하면 isAttached 가 참", task.isAttached)
    report.equal("parentEventID 저장", task.parentEventID, "evt.meeting")
    report.equal("parentOccurrenceDate 저장", task.parentOccurrenceDate, meeting)
    report.equal("offsetFromParent 저장", task.offsetFromParent, offset)
    report.equal(
        "실효마감 = 부모 시작 + offset",
        task.effectiveDueAt(parentStart: meeting),
        meeting.addingTimeInterval(offset)
    )

    // 부모 일정 이동 → 실효마감이 따라 이동, offset 은 불변
    let moved = meeting.addingTimeInterval(5 * day)
    store.events["evt.meeting"]?.start = moved
    let notices = TaskLinkMaintenance.sync(tasks: [task], parentStart: store.parentStart)

    report.equal("부모 이동 후에도 연결 유지", task.parentEventID, "evt.meeting")
    report.equal("부모 이동 후 offset 불변", task.offsetFromParent, offset)
    report.equal("부모 이동 → 마감 사본이 따라 이동", task.dueAt, moved.addingTimeInterval(offset))
    report.equal(
        "부모 이동 → 실효마감이 따라 이동",
        task.effectiveDueAt(parentStart: moved),
        moved.addingTimeInterval(offset)
    )
    report.check("부모 이동은 알림 대상이 아님", notices.isEmpty)

    // 부모 조회 실패 → 연결 보존, dueAt 폴백, 알림만 발생
    let lastKnown = task.dueAt
    store.events.removeValue(forKey: "evt.meeting")
    let failNotices = TaskLinkMaintenance.sync(tasks: [task], parentStart: store.parentStart)

    report.check("조회 실패 — 연결 보존 (parentEventID 살아 있음)", task.parentEventID == "evt.meeting")
    report.equal("조회 실패 — 회차 보존", task.parentOccurrenceDate, meeting)
    report.equal("조회 실패 — offset 보존", task.offsetFromParent, offset)
    report.equal("조회 실패 — dueAt 은 마지막 값 유지", task.dueAt, lastKnown)
    report.equal("조회 실패 — 실효마감은 dueAt 으로 폴백", task.effectiveDueAt(parentStart: nil), lastKnown)
    report.equal("조회 실패 — 알림 1건 발생", failNotices.count, 1)
    report.equal("알림에 할 일 제목이 담김", failNotices.first?.title, "졸프 주제 선정하기")

    // 부모가 다시 조회됨 → 자동 복귀
    store.events["evt.meeting"] = .init(start: moved)
    let backNotices = TaskLinkMaintenance.sync(tasks: [task], parentStart: store.parentStart)

    report.check("부모 복귀 — 알림 없음", backNotices.isEmpty)
    report.equal("부모 복귀 — 마감이 다시 부모 기준", task.dueAt, moved.addingTimeInterval(offset))
    report.equal(
        "부모 복귀 — 실효마감 정상",
        task.effectiveDueAt(parentStart: moved),
        moved.addingTimeInterval(offset)
    )
}

// MARK: - 2. 연결 해제는 사용자 의도일 때만

func testDetachOnlyByUser() {
    report.begin("연결 해제 판단 (TaskLinkPolicy)")

    let meeting = date(2026, 9, 20, 19, 0)
    let fixed = date(2026, 9, 15, 18, 0)

    // 「특정 날짜」를 골랐다 → 이때만 해제
    let detach = TaskLinkPolicy.decideOnSave(
        wantsAttachment: false,
        resolvedParentID: "evt.meeting",
        resolvedParentStart: meeting,
        offsetFromParent: -2 * day,
        fixedDueAt: fixed,
        effectiveDueAt: meeting.addingTimeInterval(-2 * day)
    )
    report.equal("「특정 날짜」 선택 → detach", detach, .detach(.userChoseFixedDate))

    // 「일정에 맞춰」인데 부모를 못 집었다 → 저장값을 건드리지 않는다
    let keep = TaskLinkPolicy.decideOnSave(
        wantsAttachment: true,
        resolvedParentID: nil,
        resolvedParentStart: nil,
        offsetFromParent: -2 * day,
        fixedDueAt: fixed,
        effectiveDueAt: nil
    )
    report.equal("부모 미해결 상태로 저장 → keepStored", keep, .keepStored(.parentUnresolved))

    // 부모를 집었다 → 연결
    let link = TaskLinkPolicy.decideOnSave(
        wantsAttachment: true,
        resolvedParentID: "evt.meeting",
        resolvedParentStart: meeting,
        offsetFromParent: -2 * day,
        fixedDueAt: fixed,
        effectiveDueAt: meeting.addingTimeInterval(-2 * day)
    )
    report.equal(
        "부모 확정 → link",
        link,
        .link(
            eventID: "evt.meeting",
            occurrenceDate: meeting,
            offset: -2 * day,
            dueAt: meeting.addingTimeInterval(-2 * day)
        )
    )

    // 실제 해제 동작
    let task = makeAttached(
        "자료 정리",
        parentID: "evt.meeting",
        occurrence: meeting,
        offset: -2 * day,
        lastKnownDueAt: meeting.addingTimeInterval(-2 * day)
    )
    task.detachFromParent(lastKnownDueAt: fixed, reason: .userChoseFixedDate)

    report.check("사용자 해제 — parentEventID 비워짐", task.parentEventID == nil)
    report.check("사용자 해제 — 회차 비워짐", task.parentOccurrenceDate == nil)
    report.check("사용자 해제 — offset 비워짐", task.offsetFromParent == nil)
    report.equal("사용자 해제 — 고른 날짜가 확정 마감", task.dueAt, fixed)
    report.check("사용자 해제 — 독립 할 일로 전환", !task.isAttached)

    // 해제된 할 일은 sync 대상이 아니다 (알림이 다시 뜨면 안 된다)
    let store = FakeCalendarStore()
    let notices = TaskLinkMaintenance.sync(tasks: [task], parentStart: store.parentStart)
    report.check("해제된 할 일은 sync 가 건드리지 않음", notices.isEmpty)
    report.equal("해제된 할 일의 마감 불변", task.dueAt, fixed)
}

// MARK: - 3. 대량 처리

func testBulk() {
    report.begin("대량 처리")

    let store = FakeCalendarStore()
    let meeting = date(2026, 10, 5, 14, 0)
    store.events["evt.big"] = .init(start: meeting)

    // 할 일 20개를 한 일정에 연결
    var tasks = (1...20).map { index in
        makeAttached(
            "준비 \(index)",
            parentID: "evt.big",
            occurrence: meeting,
            offset: -TimeInterval(index) * 3600,
            lastKnownDueAt: meeting.addingTimeInterval(-TimeInterval(index) * 3600)
        )
    }

    TaskLinkMaintenance.sync(tasks: tasks, parentStart: store.parentStart)
    report.equal("20개 전부 연결 유지", tasks.filter(\.isAttached).count, 20)
    report.check("20개 전부 같은 부모", tasks.allSatisfy { $0.parentEventID == "evt.big" })
    report.check(
        "20개 각자의 offset 이 뒤섞이지 않음",
        tasks.enumerated().allSatisfy { $0.element.offsetFromParent == -TimeInterval($0.offset + 1) * 3600 }
    )

    // 20개를 한 번에 삭제 → 부모 일정은 그대로 남는다
    let eventsBefore = Set(store.events.keys)
    let startBefore = store.events["evt.big"]?.start
    tasks.removeAll()
    TaskLinkMaintenance.sync(tasks: tasks, parentStart: store.parentStart)

    report.equal("할 일 20개 삭제 후에도 일정 존재", Set(store.events.keys), eventsBefore)
    report.equal("할 일 삭제가 일정 시각을 건드리지 않음", store.events["evt.big"]?.start, startBefore)

    // 일정 삭제 → 딸린 할 일 20개는 어떻게 되나
    var attached = (1...20).map { index in
        makeAttached(
            "후속 \(index)",
            parentID: "evt.big",
            occurrence: meeting,
            offset: -TimeInterval(index) * day,
            lastKnownDueAt: nil
        )
    }
    TaskLinkMaintenance.sync(tasks: attached, parentStart: store.parentStart)
    let confirmedDues = attached.map(\.dueAt)

    store.events.removeValue(forKey: "evt.big")
    let notices = TaskLinkMaintenance.sync(tasks: attached, parentStart: store.parentStart)

    report.equal("일정 삭제 — 할 일 20개 모두 살아 있음", attached.count, 20)
    report.equal("일정 삭제 — 알림 20건", notices.count, 20)
    report.equal(
        "일정 삭제 — 마지막 실효마감이 확정값으로 남음",
        attached.map(\.dueAt),
        confirmedDues
    )
    // 명세서 4.2 는 「독립 전환」을 규정하지만, 조회 실패와 실제 삭제를 가릴 수 없어
    // 연결을 보존하는 쪽으로 의도적으로 벗어나 있다. (BL-045 / BL-046)
    report.equal("일정 삭제 — 연결은 보존 (BL-046 의도적 편차)", attached.filter(\.isAttached).count, 20)
    report.check("일정 삭제 — 알림에 확정 마감이 실림", notices.allSatisfy { $0.confirmedDueAt != nil })

    attached.removeAll()

    // 여러 일정에 각각 할 일이 붙은 상태에서 하나만 삭제
    let a = date(2026, 11, 1, 10, 0)
    let b = date(2026, 11, 8, 10, 0)
    store.events["evt.a"] = .init(start: a)
    store.events["evt.b"] = .init(start: b)

    let tasksA = (1...5).map {
        makeAttached("A-\($0)", parentID: "evt.a", occurrence: a, offset: -day, lastKnownDueAt: nil)
    }
    let tasksB = (1...5).map {
        makeAttached("B-\($0)", parentID: "evt.b", occurrence: b, offset: -day, lastKnownDueAt: nil)
    }
    TaskLinkMaintenance.sync(tasks: tasksA + tasksB, parentStart: store.parentStart)
    let dueB = tasksB.map(\.dueAt)

    store.events.removeValue(forKey: "evt.a")
    let mixedNotices = TaskLinkMaintenance.sync(tasks: tasksA + tasksB, parentStart: store.parentStart)

    report.equal("일정 하나만 삭제 — 알림은 그 일정 할 일만", mixedNotices.count, 5)
    report.check(
        "일정 하나만 삭제 — 알림 대상이 A 뿐",
        mixedNotices.allSatisfy { $0.title.hasPrefix("A-") }
    )
    report.equal("남은 일정의 할 일 — 마감 그대로", tasksB.map(\.dueAt), dueB)
    report.check("남은 일정의 할 일 — 연결 그대로", tasksB.allSatisfy { $0.parentEventID == "evt.b" })
    report.check("삭제된 일정의 할 일도 연결 보존", tasksA.allSatisfy { $0.parentEventID == "evt.a" })
}

// MARK: - 4. 반복 실행 (EKEventStoreChanged 폭주 재현)

func testRepeatedSync() {
    report.begin("반복 실행")

    let store = FakeCalendarStore()
    let meeting = date(2026, 9, 25, 11, 0)
    store.events["evt.loop"] = .init(start: meeting)

    let offset = -3 * day
    let tasks = (1...5).map {
        makeAttached("반복 \($0)", parentID: "evt.loop", occurrence: meeting, offset: offset, lastKnownDueAt: nil)
    }

    // sync 100회 연속 — 캘린더 변경 알림이 연달아 오는 상황
    for _ in 1...100 {
        TaskLinkMaintenance.sync(tasks: tasks, parentStart: store.parentStart)
    }

    report.equal("100회 반복 후 연결 유지", tasks.filter(\.isAttached).count, 5)
    report.check("100회 반복 후 offset 불변", tasks.allSatisfy { $0.offsetFromParent == offset })
    report.check(
        "100회 반복 후 마감이 흔들리지 않음",
        tasks.allSatisfy { $0.dueAt == meeting.addingTimeInterval(offset) }
    )
    report.equal("조회가 실제로 500회 일어남", store.lookupCount, 500)

    // sync 도중 부모 조회가 간헐적으로 실패 — 3회에 한 번씩 못 찾는다
    store.reset()
    store.failLookup = { $0 % 3 == 0 }

    var noticeTotal = 0
    for _ in 1...100 {
        noticeTotal += TaskLinkMaintenance.sync(tasks: tasks, parentStart: store.parentStart).count
    }

    report.equal("간헐적 실패 — 연결이 하나도 안 지워짐", tasks.filter(\.isAttached).count, 5)
    report.check("간헐적 실패 — 부모 식별자 보존", tasks.allSatisfy { $0.parentEventID == "evt.loop" })
    report.check("간헐적 실패 — 회차 보존", tasks.allSatisfy { $0.parentOccurrenceDate == meeting })
    report.check("간헐적 실패 — offset 보존", tasks.allSatisfy { $0.offsetFromParent == offset })
    report.check(
        "간헐적 실패 — 마감이 마지막 정상값 유지",
        tasks.allSatisfy { $0.dueAt == meeting.addingTimeInterval(offset) }
    )
    report.check("간헐적 실패 — 실패한 만큼 알림은 발생", noticeTotal > 0, "알림 \(noticeTotal)건")
}

// MARK: - 5. 경계 조건

func testEdgeCases() {
    report.begin("경계 조건")

    let store = FakeCalendarStore()
    let meeting = date(2026, 12, 1, 15, 0)
    store.events["evt.edge"] = .init(start: meeting)

    // offset 0 — 당일까지
    let sameDay = makeAttached("당일", parentID: "evt.edge", occurrence: meeting, offset: 0, lastKnownDueAt: nil)
    TaskLinkMaintenance.sync(tasks: [sameDay], parentStart: store.parentStart)
    report.equal("offset 0 — 실효마감이 부모 시작과 같음", sameDay.effectiveDueAt(parentStart: meeting), meeting)
    report.equal("offset 0 — 마감 사본도 부모 시작", sameDay.dueAt, meeting)
    report.check("offset 0 — 연결 유지 (0 을 nil 로 착각하지 않음)", sameDay.isAttached)
    report.equal("offset 0 — offset 이 nil 로 뭉개지지 않음", sameDay.offsetFromParent, 0)

    // offset 365일 전
    let farOffset = -365 * day
    let far = makeAttached("장기", parentID: "evt.edge", occurrence: meeting, offset: farOffset, lastKnownDueAt: nil)
    TaskLinkMaintenance.sync(tasks: [far], parentStart: store.parentStart)
    report.equal("offset 365일 — 실효마감 정확", far.dueAt, meeting.addingTimeInterval(farOffset))
    report.equal("offset 365일 — offset 보존", far.offsetFromParent, farOffset)
    report.check("offset 365일 — 연결 유지", far.isAttached)

    // 반복 일정의 회차별 연결
    let first = date(2026, 9, 7, 10, 0)
    let second = date(2026, 9, 14, 10, 0)
    let third = date(2026, 9, 21, 10, 0)
    store.events["evt.weekly"] = .init(
        start: first,
        occurrences: [first: first, second: second, third: third]
    )

    let w1 = makeAttached("1회차 준비", parentID: "evt.weekly", occurrence: first, offset: -day, lastKnownDueAt: nil)
    let w2 = makeAttached("2회차 준비", parentID: "evt.weekly", occurrence: second, offset: -day, lastKnownDueAt: nil)
    let w3 = makeAttached("3회차 준비", parentID: "evt.weekly", occurrence: third, offset: -day, lastKnownDueAt: nil)
    TaskLinkMaintenance.sync(tasks: [w1, w2, w3], parentStart: store.parentStart)

    report.equal("반복 — 1회차 마감", w1.dueAt, first.addingTimeInterval(-day))
    report.equal("반복 — 2회차 마감", w2.dueAt, second.addingTimeInterval(-day))
    report.equal("반복 — 3회차 마감", w3.dueAt, third.addingTimeInterval(-day))
    report.check(
        "반복 — 회차 키가 서로 다름",
        Set([
            DayEvent.occurrenceKey(eventID: "evt.weekly", start: first),
            DayEvent.occurrenceKey(eventID: "evt.weekly", start: second),
            DayEvent.occurrenceKey(eventID: "evt.weekly", start: third)
        ]).count == 3
    )
    report.check(
        "반복 — 같은 식별자라도 회차가 섞이지 않음",
        w1.dueAt != w2.dueAt && w2.dueAt != w3.dueAt
    )

    // 반복 일정의 특정 회차만 삭제
    let dueBefore = (w1.dueAt, w3.dueAt)
    store.events["evt.weekly"]?.occurrences.removeValue(forKey: second)
    let occNotices = TaskLinkMaintenance.sync(tasks: [w1, w2, w3], parentStart: store.parentStart)

    report.equal("회차 삭제 — 알림은 그 회차 하나만", occNotices.count, 1)
    report.equal("회차 삭제 — 알림 대상이 2회차", occNotices.first?.title, "2회차 준비")
    report.check("회차 삭제 — 2회차 연결 보존", w2.parentEventID == "evt.weekly")
    report.equal("회차 삭제 — 2회차 회차값 보존", w2.parentOccurrenceDate, second)
    report.equal("회차 삭제 — 1회차 마감 무영향", w1.dueAt, dueBefore.0)
    report.equal("회차 삭제 — 3회차 마감 무영향", w3.dueAt, dueBefore.1)
    report.check("회차 삭제 — 1·3회차 연결 무영향", w1.isAttached && w3.isAttached)

    // 부모와 자식의 캘린더가 다를 때 / 부모가 읽기 전용일 때
    //
    // 연결은 캘린더에 대해 아무 조건도 걸지 않는다. 그 사실을 값으로 확인한다.
    let variants: [(String, FakeCalendarStore.FakeEvent)] = [
        ("같은 캘린더", .init(start: meeting, calendarID: "cal.work", isReadOnly: false)),
        ("다른 캘린더", .init(start: meeting, calendarID: "cal.personal", isReadOnly: false)),
        ("읽기 전용 캘린더", .init(start: meeting, calendarID: "cal.holidays", isReadOnly: true))
    ]

    for (label, event) in variants {
        let scoped = FakeCalendarStore()
        scoped.events["evt.cal"] = event
        let task = makeAttached("연락", parentID: "evt.cal", occurrence: meeting, offset: -day, lastKnownDueAt: nil)
        let notices = TaskLinkMaintenance.sync(tasks: [task], parentStart: scoped.parentStart)

        report.check("\(label) — 연결 유지", task.parentEventID == "evt.cal")
        report.equal("\(label) — 마감 계산 동일", task.dueAt, meeting.addingTimeInterval(-day))
        report.check("\(label) — 알림 없음", notices.isEmpty)
    }
}

// MARK: - 6. 저장 영속성 (kill -9)

/// 임시 위치에 스토어를 연다. **사용자의 실제 App Group 스토어는 절대 건드리지 않는다.**
func openContainer(at path: String) throws -> ModelContainer {
    let schema = Schema([ManagedTask.self])
    let configuration = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: path))
    return try ModelContainer(for: schema, configurations: [configuration])
}

let persistTitle = "kill -9 검증용 할 일"
let persistParentID = "evt.persist"
let persistMeeting = date(2026, 9, 30, 16, 0)
let persistOffset: TimeInterval = -2 * day
let persistMoved = persistMeeting.addingTimeInterval(4 * day)

func fetchPersisted(_ context: ModelContext) throws -> ManagedTask? {
    try context.fetch(FetchDescriptor<ManagedTask>()).first { $0.title == persistTitle }
}

/// 연결을 만들고 저장한 뒤, 밖에서 죽여 달라고 알린다.
func persistWrite(store: String, marker: String) throws {
    let context = ModelContext(try openContainer(at: store))
    let task = makeAttached(
        persistTitle,
        parentID: persistParentID,
        occurrence: persistMeeting,
        offset: persistOffset,
        lastKnownDueAt: persistMeeting.addingTimeInterval(persistOffset)
    )
    context.insert(task)
    try context.save()

    FileManager.default.createFile(atPath: marker, contents: Data("saved".utf8))
    // 정상 종료하지 않는다. 밖에서 kill -9 로 죽여야 진짜 검증이 된다.
    while true { Thread.sleep(forTimeInterval: 0.5) }
}

/// 부모가 옮겨진 것을 반영해 저장한 뒤, 밖에서 죽여 달라고 알린다.
func persistMove(store: String, marker: String) throws {
    let context = ModelContext(try openContainer(at: store))
    guard let task = try fetchPersisted(context) else {
        print("  ✗ 이동 단계에서 할 일을 찾지 못함")
        exit(1)
    }

    let fake = FakeCalendarStore()
    fake.events[persistParentID] = .init(start: persistMoved)
    TaskLinkMaintenance.sync(tasks: [task], parentStart: fake.parentStart)
    try context.save()

    FileManager.default.createFile(atPath: marker, contents: Data("moved".utf8))
    while true { Thread.sleep(forTimeInterval: 0.5) }
}

func persistVerify(store: String, stage: String) throws {
    report.begin("저장 영속성 — \(stage) 직후 kill -9")

    let context = ModelContext(try openContainer(at: store))
    guard let task = try fetchPersisted(context) else {
        report.check("재실행 시 할 일이 살아 있음", false, "스토어에서 찾지 못함")
        return
    }

    report.check("재실행 시 할 일이 살아 있음", true)
    report.equal("재실행 — parentEventID 유지", task.parentEventID, persistParentID)
    report.equal("재실행 — 회차 유지", task.parentOccurrenceDate, persistMeeting)
    report.equal("재실행 — offset 유지", task.offsetFromParent, persistOffset)
    report.check("재실행 — 연결 상태 유지", task.isAttached)

    if stage == "부모 이동" {
        report.equal("재실행 — 새 마감 반영", task.dueAt, persistMoved.addingTimeInterval(persistOffset))
        report.equal(
            "재실행 — 실효마감이 새 부모 기준",
            task.effectiveDueAt(parentStart: persistMoved),
            persistMoved.addingTimeInterval(persistOffset)
        )
    } else {
        report.equal("재실행 — 마감 유지", task.dueAt, persistMeeting.addingTimeInterval(persistOffset))
    }
}

// MARK: - 진입점

@main
enum LinkIntegrityTests {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.first ?? "--logic"

        do {
            switch mode {
            case "--persist-write":
                try persistWrite(store: arguments[1], marker: arguments[2])

            case "--persist-move":
                try persistMove(store: arguments[1], marker: arguments[2])

            case "--persist-verify":
                try persistVerify(store: arguments[1], stage: arguments[2])
                exit(report.finish())

            default:
                print("일정·할 일 연결 회귀 테스트")
                print(String(repeating: "═", count: 60))
                testBasics()
                testDetachOnlyByUser()
                testBulk()
                testRepeatedSync()
                testEdgeCases()
                testEventGrouping()
                testGridTaskPlacement()
                exit(report.finish())
            }
        } catch {
            print("\n✗ 테스트 실행 실패: \(error)")
            exit(2)
        }
    }
}
