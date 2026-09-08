//
//  CalendarManager.swift
//  Startline
//
//  EventKit 연동 — 권한 요청 및 임의 월 범위의 일정 조회.
//  명세서 Phase 1 「EventKit 권한 + 일정 읽기」
//

import EventKit
import Foundation
import Observation

nonisolated extension Locale {
    /// 화면 표시 문자열에 쓰는 고정 로케일.
    /// 시스템 캘린더 설정(주 시작 요일 등)은 그대로 따르되, 문자열만 한국어로 고정한다.
    static let startlineDisplay = Locale(identifier: "ko_KR")
}

/// 앱 내부에서 다루는 캘린더 접근 권한 상태.
/// EKAuthorizationStatus 를 3가지로 축약한다.
enum CalendarAccessState {
    /// 아직 시스템 권한 팝업을 띄운 적 없음.
    case notDetermined
    /// 사용자가 거부했거나 기기 정책으로 제한됨. 시스템 설정에서만 복구 가능.
    case denied
    /// 전체 접근 승인.
    case authorized
}

/// 그리드 요일 머리글 한 칸. `weekday` 는 Calendar 기준(1 = 일요일).
struct WeekdayHeader: Identifiable {
    let column: Int
    let weekday: Int
    let symbol: String

    var id: Int { column }
}

/// 하루에 표시할 일정 한 건.
///
/// 같은 일정이 여러 캘린더에 중복 등록된 경우(예: 공휴일, 생일)를 한 건으로 묶는다.
/// 묶는 기준은 같은 날 안에서 `종일 여부 + 시작시각 + 제목` 이 모두 같은 것.
nonisolated struct DayEvent: Identifiable {
    let id: String
    /// 묶인 원본 일정들. 최소 1건이며 캘린더명 순으로 정렬돼 있다.
    let events: [EKEvent]

    /// 대표 일정. 제목·시각·색상은 이 값을 쓴다.
    var primary: EKEvent { events[0] }

    /// 두 개 이상의 캘린더에 중복 등록된 일정인지.
    var isDuplicated: Bool { events.count > 1 }

    /// 이 일정이 등록된 캘린더 이름들 (중복 제거, 등장 순).
    var calendarTitles: [String] {
        var seen = Set<String>()
        return events.compactMap { event in
            let title = event.calendar?.title ?? "(캘린더 없음)"
            return seen.insert(title).inserted ? title : nil
        }
    }

    /// 이 막대가 가리키는 **회차**들의 키.
    ///
    /// 반복 일정은 회차가 달라도 `eventIdentifier` 가 같다. 식별자만으로 판정하면
    /// 한 회차를 골랐을 때 모든 회차가 함께 걸린다. 시작시각을 붙여 회차를 가른다.
    var occurrenceKeys: [String] {
        events.compactMap { event in
            guard let id = event.eventIdentifier, let start = event.startDate else { return nil }
            return DayEvent.occurrenceKey(eventID: id, start: start)
        }
    }

    nonisolated static func occurrenceKey(eventID: String, start: Date) -> String {
        "\(eventID)|\(start.timeIntervalSinceReferenceDate)"
    }

    /// 중복 판정 키. 상태를 읽지 않으므로 액터 격리에서 벗어나 있다.
    nonisolated static func groupingKey(for event: EKEvent) -> String {
        let start = event.startDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(event.isAllDay)|\(start)|\(event.title ?? "")"
    }
}

@Observable
final class CalendarManager {

    // MARK: - 공개 상태

    private(set) var accessState: CalendarAccessState = .notDetermined

    /// 접근 가능한 전체 캘린더 (이름 + 소스명 표시용).
    private(set) var calendars: [EKCalendar] = []

    /// 화면에서 숨긴 캘린더. 앱을 껐다 켜도 유지된다.
    private(set) var hiddenCalendarIDs: Set<String> = []

    /// 그리드에 할 일을 보여줄지. 기본값은 켜짐.
    private(set) var showsTasks = true

    /// 할 일을 시작일부터 마감일까지 점선으로 이을지.
    /// 점선이 며칠씩 뻗으면 레인이 빨리 차므로 끌 수 있게 둔다.
    private(set) var showsTaskSpan = true

    /// 그리드가 표시 중인 달. 항상 그 달 1일 00:00.
    private(set) var displayedMonth: Date

    /// 우측 상세 패널이 보여줄 날짜.
    var selectedDate: Date


    /// 권한 요청 중 에러가 발생한 경우의 메시지.
    private(set) var errorMessage: String?

    /// 외부 캘린더 변경을 반영할 때마다 하나씩 오른다.
    ///
    /// 뷰는 이 값이 바뀌는 것을 보고 후속 정리(`TaskLinkMaintenance.sync`)를 돌린다.
    /// 정리 작업은 SwiftData에 쓰기를 하므로 화면을 그리는 도중에 실행되면 안 된다.
    /// 토큰을 한 단계 두어, 쓰기가 뷰 본문이 아니라 변경 감지 액션에서 일어나게 한다.
    private(set) var storeChangeToken = 0

    // MARK: - 내부

    private let eventStore = EKEventStore()

    /// 부모 일정 조회 캐시. (명세서 7.4 — 매번 EventKit을 때리지 않는다)
    ///
    /// 관찰 대상에서 빼둔다. 화면을 그리는 도중에 조회가 일어나도 뷰 갱신을 유발하지 않아야 하고,
    /// 캐시 자체는 화면에 보이는 상태가 아니다. 값에 `nil` 을 담아 "찾지 못함"도 캐시한다.
    @ObservationIgnored private var parentEventCache: [String: EKEvent?] = [:]

    /// `.EKEventStoreChanged` 관찰자.
    @ObservationIgnored private var storeChangeObserver: NSObjectProtocol?

    /// 디바운스용. 직전에 예약된 갱신을 취소하고 마지막 것만 실행한다.
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    /// 달 → (날짜 → 그 날 표시할 일정). 스크롤로 달을 오갈 때 같은 달을 다시 읽지 않는다.
    ///
    /// 관찰 대상에서 뺀다. 읽는 도중에 채워지는 값이라 뷰 갱신을 유발하면 안 된다.
    /// 대신 캐시가 비워질 때 `dataRevision` 을 올려 화면이 다시 그려지게 한다. (BL-008)
    @ObservationIgnored private var monthCache: [Date: [Date: [DayEvent]]] = [:]

    /// 캐시를 비울 때마다 오른다. 뷰는 이 값을 보고 다시 그린다.
    private(set) var dataRevision = 0

    private static let hiddenCalendarsKey = "startline.hiddenCalendarIDs"
    private static let showsTasksKey = "startline.showsTasks"
    private static let showsTaskSpanKey = "startline.showsTaskSpan"

    /// 뷰에서도 같은 기준으로 날짜를 계산하도록 공개한다.
    let calendar: Calendar

    init(calendar: Calendar = .current, now: Date = Date()) {
        var calendar = calendar
        // 주 시작 요일 같은 시스템 설정은 유지하고, 요일·월 이름만 한국어로 고정한다.
        calendar.locale = .startlineDisplay
        self.calendar = calendar

        self.displayedMonth = Self.startOfMonth(for: now, calendar: calendar)
        self.selectedDate = calendar.startOfDay(for: now)

        hiddenCalendarIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.hiddenCalendarsKey) ?? []
        )
        // 저장된 적이 없으면 켜짐이 기본이다.
        showsTasks = UserDefaults.standard.object(forKey: Self.showsTasksKey) as? Bool ?? true
        showsTaskSpan = UserDefaults.standard.object(forKey: Self.showsTaskSpanKey) as? Bool ?? true

        refreshAccessState()
        if accessState == .authorized {
            loadCalendarsAndEvents()
        }
        startObservingStoreChanges()
    }

    deinit {
        pendingReload?.cancel()
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
    }

    // MARK: - 외부 변경 감지 (BL-006, BL-020)

    /// 캘린더 앱이나 구글에서 일정이 바뀌면 EventKit이 알려준다.
    /// 이걸 구독하지 않으면 앱을 켜둔 동안 화면이 낡은 채로 남고,
    /// 삭제·이동된 일정을 기준으로 잘못된 착수마감이 계산된다.
    private func startObservingStoreChanges() {
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReload()
        }
    }

    /// 한 번의 편집에도 알림이 여러 번 몰려 오므로 마지막 것만 처리한다.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.applyExternalChange() }
        }
    }

    /// 표시 중인 범위를 다시 읽고, 뷰가 후속 정리를 하도록 토큰을 올린다.
    private func applyExternalChange() {
        guard accessState == .authorized else { return }
        loadCalendars()
        invalidateEventCache()
        storeChangeToken &+= 1
    }

    // MARK: - 권한

    /// 시스템에 기록된 현재 권한 상태를 읽어 축약형으로 반영한다.
    func refreshAccessState() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            accessState = .notDetermined
        case .fullAccess:
            accessState = .authorized
        case .denied, .restricted:
            accessState = .denied
        case .writeOnly:
            // 일정을 읽을 수 없으므로 앱 입장에서는 거부와 동일하다.
            accessState = .denied
        @unknown default:
            accessState = .denied
        }
    }

    /// 전체 접근 권한을 요청한다. 승인되면 캘린더/일정까지 이어서 로드한다.
    @MainActor
    func requestAccess() async {
        errorMessage = nil
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            accessState = granted ? .authorized : .denied
            if granted {
                loadCalendarsAndEvents()
            }
        } catch {
            errorMessage = error.localizedDescription
            refreshAccessState()
        }
    }

    // MARK: - 월 이동

    /// 표시 월을 바꾸고 해당 그리드 범위의 일정을 다시 읽는다.
    func setDisplayedMonth(_ date: Date) {
        displayedMonth = Self.startOfMonth(for: date, calendar: calendar)

        // 선택 날짜가 새 달 밖이면 그 달 1일로 옮긴다.
        // 단 오늘이 새 달 안이면 오늘을 선택한다.
        if !isInDisplayedMonth(selectedDate) {
            let today = calendar.startOfDay(for: Date())
            selectedDate = isInDisplayedMonth(today) ? today : displayedMonth
        }

    }

    func goToPreviousMonth() {
        guard let previous = calendar.date(byAdding: .month, value: -1, to: displayedMonth) else { return }
        setDisplayedMonth(previous)
    }

    func goToNextMonth() {
        guard let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) else { return }
        setDisplayedMonth(next)
    }

    func goToToday() {
        let today = Date()
        setDisplayedMonth(today)
        selectedDate = calendar.startOfDay(for: today)
    }

    func isInDisplayedMonth(_ date: Date) -> Bool {
        calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
    }

    /// 캘린더 목록을 다시 읽고 일정 캐시를 비운다.
    func loadCalendarsAndEvents() {
        loadCalendars()
        invalidateEventCache()
    }

    private func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
            .sorted { lhs, rhs in
                // 소스별로 묶은 뒤 캘린더명 정렬.
                if lhs.source.title != rhs.source.title {
                    return lhs.source.title < rhs.source.title
                }
                return lhs.title < rhs.title
            }
    }

    /// 읽어둔 일정을 모두 버린다. 다음 조회 때 다시 읽는다.
    private func invalidateEventCache() {
        monthCache.removeAll()
        parentEventCache.removeAll()
        dataRevision &+= 1
    }

    // MARK: - 캘린더 필터

    /// 이 캘린더를 화면에 보여줄지.
    func isVisible(_ calendar: EKCalendar) -> Bool {
        !hiddenCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func setVisible(_ isVisible: Bool, for calendar: EKCalendar) {
        if isVisible {
            hiddenCalendarIDs.remove(calendar.calendarIdentifier)
        } else {
            hiddenCalendarIDs.insert(calendar.calendarIdentifier)
        }
        persistHiddenCalendars()
    }

    func showAllCalendars() {
        hiddenCalendarIDs.removeAll()
        persistHiddenCalendars()
    }

    func hideAllCalendars() {
        hiddenCalendarIDs = Set(calendars.map(\.calendarIdentifier))
        persistHiddenCalendars()
    }

    func setShowsTasks(_ isVisible: Bool) {
        showsTasks = isVisible
        UserDefaults.standard.set(isVisible, forKey: Self.showsTasksKey)
    }

    func setShowsTaskSpan(_ isVisible: Bool) {
        showsTaskSpan = isVisible
        UserDefaults.standard.set(isVisible, forKey: Self.showsTaskSpanKey)
    }

    private func persistHiddenCalendars() {
        UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: Self.hiddenCalendarsKey)
        invalidateEventCache()
    }

    // MARK: - 조회

    /// 한 달 그리드 범위의 일정을 날짜별로. 같은 달을 두 번 읽지 않는다.
    ///
    /// 스냅 스크롤은 달을 빠르게 오가므로 캐시가 없으면 매번 EventKit을 때리게 된다. (BL-008)
    func dayEvents(forMonth month: Date) -> [Date: [DayEvent]] {
        let key = Self.startOfMonth(for: month, calendar: calendar)
        if let cached = monthCache[key] { return cached }

        let built = buildDayEvents(forMonth: key)
        monthCache[key] = built
        return built
    }

    /// 특정 날짜에 표시할 일정 (캘린더 간 중복 제거, 숨긴 캘린더 제외).
    func events(on date: Date) -> [DayEvent] {
        dayEvents(forMonth: date)[calendar.startOfDay(for: date)] ?? []
    }

    private func buildDayEvents(forMonth month: Date) -> [Date: [DayEvent]] {
        guard accessState == .authorized else { return [:] }

        let days = Self.gridDays(for: month, calendar: calendar)
        guard let first = days.first,
              let last = days.last,
              let dayAfter = calendar.date(byAdding: .day, value: 1, to: last)
        else { return [:] }

        let end = dayAfter.addingTimeInterval(-1)

        // calendars: nil → 접근 가능한 전체. 숨김 처리는 읽은 뒤에 거른다.
        let predicate = eventStore.predicateForEvents(withStart: first, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { event in
                guard let calendar = event.calendar else { return true }
                return isVisible(calendar)
            }
            .sorted(by: Self.isOrderedBefore)

        return bucketByDay(events, rangeStart: first, rangeEnd: end)
    }

    /// 임의 범위의 일정을 시간순으로 읽어 온다. 그리드 캐시를 건드리지 않는다.
    ///
    /// 여러 캘린더에 중복 등록된 같은 일정은 한 건으로 줄인다. (그리드와 같은 기준)
    ///
    /// **같은 캘린더 안의 별개 일정은 줄이지 않는다.** 예전에는 제목·시각만 보고 걸러서
    /// 같은 이름의 일정 둘 중 하나는 부모로 **고를 수조차 없었다.** (BL-048)
    /// 그리드와 같은 `groupDuplicates` 를 써서 판정이 어긋나지 않게 한다.
    func fetchEvents(from start: Date, to end: Date) -> [EKEvent] {
        guard accessState == .authorized else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        let visible = eventStore.events(matching: predicate)
            .filter { event in
                guard let calendar = event.calendar else { return true }
                return isVisible(calendar)
            }
            .sorted(by: Self.isOrderedChronologically)

        return Self.groupDuplicates(visible).map(\.primary)
    }

    /// 부모로 고를 수 있는 일정 후보.
    func candidateEvents(around date: Date, daysBefore: Int = 7, daysAfter: Int = 60) -> [EKEvent] {
        let anchor = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -daysBefore, to: anchor),
              let end = calendar.date(byAdding: .day, value: daysAfter, to: anchor)
        else { return [] }
        return fetchEvents(from: start, to: end)
    }

    /// 미니 캘린더용 — 한 달 그리드 범위의 원본 일정을 날짜별로.
    func eventsByDay(forMonth month: Date) -> [Date: [EKEvent]] {
        dayEvents(forMonth: month).mapValues { $0.map(\.primary) }
    }

    // MARK: - 일정 쓰기

    /// 일정 생성·수정·삭제 중 생긴 문제. 조용히 넘기지 않고 화면에 그대로 알린다.
    enum WriteError: LocalizedError {
        case notAuthorized
        case noWritableCalendar
        case readOnly(calendarTitle: String)
        case emptyTitle
        case invalidTimeRange
        case saveFailed(String)
        case deleteFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "캘린더 접근 권한이 없어 저장할 수 없어요."
            case .noWritableCalendar:
                return "새 일정을 넣을 수 있는 캘린더가 없어요. 시스템 설정에서 캘린더 계정을 확인해 주세요."
            case .readOnly(let title):
                return "‘\(title)’은 읽기 전용이라 여기에는 저장할 수 없어요."
            case .emptyTitle:
                return "제목을 입력해 주세요."
            case .invalidTimeRange:
                return "끝나는 시각이 시작하는 시각보다 빨라요."
            case .saveFailed(let reason):
                return "저장하지 못했어요. \(reason)"
            case .deleteFailed(let reason):
                return "삭제하지 못했어요. \(reason)"
            }
        }
    }

    /// 새 일정을 넣을 수 있는 캘린더들.
    /// 구독 캘린더(공휴일 등)와 생일 캘린더는 내용을 고칠 수 없으므로 빠진다.
    var writableCalendars: [EKCalendar] {
        calendars.filter(\.allowsContentModifications)
    }

    /// 기본으로 고를 캘린더.
    var defaultWritableCalendar: EKCalendar? {
        eventStore.defaultCalendarForNewEvents.flatMap { candidate in
            candidate.allowsContentModifications ? candidate : nil
        } ?? writableCalendars.first
    }

    /// 이 일정을 고칠 수 있는지. 구독·생일 캘린더의 일정은 읽기 전용이다.
    nonisolated func isEditable(_ event: EKEvent) -> Bool {
        event.calendar?.allowsContentModifications ?? false
    }

    /// 일정을 만든다.
    @discardableResult
    func createEvent(
        title: String,
        calendar targetCalendar: EKCalendar,
        start: Date,
        end: Date,
        isAllDay: Bool
    ) throws -> EKEvent {
        guard accessState == .authorized else { throw WriteError.notAuthorized }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw WriteError.emptyTitle }
        guard targetCalendar.allowsContentModifications else {
            throw WriteError.readOnly(calendarTitle: targetCalendar.title)
        }
        guard end >= start else { throw WriteError.invalidTimeRange }

        let event = EKEvent(eventStore: eventStore)
        event.title = trimmed
        event.calendar = targetCalendar
        event.isAllDay = isAllDay
        event.startDate = start
        event.endDate = end

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw WriteError.saveFailed(error.localizedDescription)
        }

        reloadAfterWrite()
        return event
    }

    /// 기존 일정을 고친다.
    func updateEvent(
        _ event: EKEvent,
        title: String,
        calendar targetCalendar: EKCalendar,
        start: Date,
        end: Date,
        isAllDay: Bool,
        span: EKSpan
    ) throws {
        guard accessState == .authorized else { throw WriteError.notAuthorized }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw WriteError.emptyTitle }
        guard isEditable(event) else {
            throw WriteError.readOnly(calendarTitle: event.calendar?.title ?? "이 캘린더")
        }
        guard targetCalendar.allowsContentModifications else {
            throw WriteError.readOnly(calendarTitle: targetCalendar.title)
        }
        guard end >= start else { throw WriteError.invalidTimeRange }

        event.title = trimmed
        event.calendar = targetCalendar
        event.isAllDay = isAllDay
        event.startDate = start
        event.endDate = end

        do {
            try eventStore.save(event, span: span, commit: true)
        } catch {
            throw WriteError.saveFailed(error.localizedDescription)
        }

        reloadAfterWrite()
    }

    /// 일정을 지운다. 되돌릴 수 없고 연결된 계정과 다른 기기에도 전파된다.
    func deleteEvent(_ event: EKEvent, span: EKSpan) throws {
        guard accessState == .authorized else { throw WriteError.notAuthorized }
        guard isEditable(event) else {
            throw WriteError.readOnly(calendarTitle: event.calendar?.title ?? "이 캘린더")
        }

        do {
            try eventStore.remove(event, span: span, commit: true)
        } catch {
            throw WriteError.deleteFailed(error.localizedDescription)
        }

        reloadAfterWrite()
    }

    /// 쓰기 직후에는 변경 알림을 기다리지 않고 바로 다시 읽는다.
    private func reloadAfterWrite() {
        loadCalendars()
        invalidateEventCache()
        storeChangeToken &+= 1
    }

    // MARK: - 부모 일정 조회 (명세서 7.4)

    /// 할 일에 붙은 부모 일정을 찾는다. 결과는 다음 일정 로드 때까지 캐시된다.
    ///
    /// - Parameters:
    ///   - id: `EKEvent.eventIdentifier`
    ///   - occurrenceDate: 반복 일정일 때 특정할 회차의 원래 시작시각.
    /// - Returns: 부모 일정. 삭제됐으면 `nil`.
    func parentEvent(id: String, occurrenceDate: Date?) -> EKEvent? {
        guard accessState == .authorized else { return nil }

        let key = "\(id)|\(occurrenceDate?.timeIntervalSinceReferenceDate ?? 0)"
        if let cached = parentEventCache[key] { return cached }

        let resolved = lookUpParentEvent(id: id, occurrenceDate: occurrenceDate)
        parentEventCache[key] = resolved
        return resolved
    }

    private func lookUpParentEvent(id: String, occurrenceDate: Date?) -> EKEvent? {
        // 단일 일정은 식별자 조회로 끝난다. 일정이 옮겨졌어도 새 시작시각이 그대로 나온다.
        let base = eventStore.event(withIdentifier: id)

        // 반복 일정은 식별자가 회차 간에 같으므로, 저장해 둔 회차 시각 주변을 훑어 특정한다.
        guard let occurrenceDate, base?.hasRecurrenceRules == true else { return base }

        let window: TimeInterval = 45 * 24 * 60 * 60
        let predicate = eventStore.predicateForEvents(
            withStart: occurrenceDate.addingTimeInterval(-window),
            end: occurrenceDate.addingTimeInterval(window),
            calendars: nil
        )

        // 회차가 옮겨졌을 수 있으므로 원래 시각에 가장 가까운 회차를 고른다.
        let occurrences = eventStore.events(matching: predicate)
            .filter { $0.eventIdentifier == id }

        return occurrences.min {
            let l = abs(($0.startDate ?? .distantPast).timeIntervalSince(occurrenceDate))
            let r = abs(($1.startDate ?? .distantPast).timeIntervalSince(occurrenceDate))
            return l < r
        } ?? base
    }

    // MARK: - 그리드 날짜 계산

    /// 표시 월을 덮는 주 단위 날짜 배열. 앞뒤로 인접 달의 날짜가 채워진다.
    /// 주 수는 달에 맞춰 4~6주로 달라진다.
    func gridDays() -> [Date] {
        Self.gridDays(for: displayedMonth, calendar: calendar)
    }

    static func gridDays(for month: Date, calendar: Calendar) -> [Date] {
        let monthStart = startOfMonth(for: month, calendar: calendar)
        guard let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count
        else { return [] }

        // 그 주의 첫 요일까지 앞으로 당긴 시작점.
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart)
        else { return [] }

        // 앞 채움 + 이번 달 일수를 7의 배수로 올림.
        let total = Int(ceil(Double(leading + dayCount) / 7.0)) * 7

        return (0..<total).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
    }

    /// 그리드 열 순서에 맞춘 요일 머리글.
    func weekdayHeaders() -> [WeekdayHeader] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return (0..<symbols.count).map { index in
            let position = (index + offset) % symbols.count
            return WeekdayHeader(column: index, weekday: position + 1, symbol: symbols[position])
        }
    }

    static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    // MARK: - 일자별 분류

    /// 여러 날에 걸친 일정을 각 날짜 버킷에 모두 넣고, 날짜별로 중복을 묶는다.
    private func bucketByDay(
        _ events: [EKEvent],
        rangeStart: Date,
        rangeEnd: Date
    ) -> [Date: [DayEvent]] {
        var raw: [Date: [EKEvent]] = [:]

        for event in events {
            guard let start = event.startDate else { continue }
            var end = event.endDate ?? start

            // 자정에 정확히 끝나는 일정이 다음 날까지 번지지 않도록 한다.
            // (예: 22:00 ~ 다음날 00:00 은 시작일 하루짜리로 본다.)
            if !event.isAllDay, end > start, end == calendar.startOfDay(for: end) {
                end = end.addingTimeInterval(-1)
            }

            var day = calendar.startOfDay(for: max(start, rangeStart))
            let lastDay = calendar.startOfDay(for: min(end, rangeEnd))

            while day <= lastDay {
                raw[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        return raw.mapValues { Self.groupDuplicates($0.sorted(by: Self.isOrderedBefore)) }
    }

    /// 같은 일정이 **여러 캘린더에** 등록된 경우를 한 건으로 묶는다.
    /// 입력 순서를 유지하므로 정렬된 배열을 넘겨야 한다.
    ///
    /// **한 묶음에 한 캘린더는 최대 하나만 기여한다.** 이게 핵심 규칙이다.
    ///
    /// 예전에는 `종일여부 + 시작시각 + 제목` 만 보고 묶었다. 그러다 보니 사용자가
    /// 같은 캘린더에 같은 이름·시각으로 만든 **별개의 일정까지** 한 건으로 합쳐졌다.
    /// 화면에는 하나로 보이는데 실제로는 둘이라, 삭제를 눌러도 대표 일정 하나만
    /// 지워지고 나머지는 손댈 방법이 없었다. (BL-048)
    ///
    /// 묶기의 목적은 공휴일·생일처럼 **여러 캘린더에 중복 등록된 같은 일정**을
    /// 한 줄로 보여주는 것이지, 사용자가 실제로 만든 일정을 감추는 것이 아니다.
    ///
    /// - 「하이루」 2개 (둘 다 직장) → 직장이 이미 찼으므로 **묶음 2개** = 각각 표시
    /// - 「추석」 2개 (직장 + 개인) → 서로 다른 캘린더이므로 **묶음 1개** = 종전대로
    nonisolated static func groupDuplicates(_ events: [EKEvent]) -> [DayEvent] {
        var order: [String] = []
        var buckets: [String: [[EKEvent]]] = [:]

        for event in events {
            let key = DayEvent.groupingKey(for: event)
            if buckets[key] == nil { order.append(key) }

            let calendarID = event.calendar?.calendarIdentifier
            var candidates = buckets[key] ?? []

            // 그 캘린더가 아직 안 들어간 묶음을 찾는다. 없으면 새 묶음을 연다.
            if let index = candidates.firstIndex(where: { bucket in
                !bucket.contains { $0.calendar?.calendarIdentifier == calendarID }
            }) {
                candidates[index].append(event)
            } else {
                candidates.append([event])
            }
            buckets[key] = candidates
        }

        return order.flatMap { key -> [DayEvent] in
            (buckets[key] ?? []).enumerated().compactMap { index, bucket in
                guard !bucket.isEmpty else { return nil }
                // 대표 일정이 매번 같도록 캘린더명으로 정렬한다.
                let sorted = bucket.sorted { ($0.calendar?.title ?? "") < ($1.calendar?.title ?? "") }
                // 묶음이 갈라졌으므로 키만으로는 더 이상 구별되지 않는다.
                // 대표 일정의 식별자를 붙인다. 여러 날에 걸친 일정도 날마다 같은 값이 나온다.
                // 아직 저장되지 않은 일정은 식별자가 없으므로 묶음 순번으로 물러선다.
                let suffix = sorted[0].eventIdentifier ?? "순번\(index)"
                return DayEvent(id: "\(key)#\(suffix)", events: sorted)
            }
        }
    }

    /// **하루 안에서의** 정렬. 종일 일정 우선, 그 다음 시작시각, 그 다음 제목.
    ///
    /// 여러 날에 걸친 목록에는 쓰지 않는다. 종일 여부를 먼저 보므로
    /// 다른 달의 종일 일정이 이번 달 시간 일정보다 앞서게 된다.
    /// 그런 목록에는 `isOrderedChronologically` 를 쓴다.
    ///
    /// 상태를 읽지 않는 순수 비교 함수다. `sorted(by:)` 에 함수 자체를 넘기려면
    /// 액터 격리에서 벗어나 있어야 한다.
    nonisolated private static func isOrderedBefore(_ lhs: EKEvent, _ rhs: EKEvent) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }

        let l = lhs.startDate ?? .distantFuture
        let r = rhs.startDate ?? .distantFuture
        if l != r { return l < r }

        return (lhs.title ?? "") < (rhs.title ?? "")
    }

    /// **여러 날에 걸친 목록**의 정렬. 시작시각이 먼저다.
    nonisolated static func isOrderedChronologically(_ lhs: EKEvent, _ rhs: EKEvent) -> Bool {
        let l = lhs.startDate ?? .distantFuture
        let r = rhs.startDate ?? .distantFuture
        if l != r { return l < r }
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        return (lhs.title ?? "") < (rhs.title ?? "")
    }
}
