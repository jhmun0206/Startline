//
//  CalendarManager.swift
//  Startline
//
//  EventKit 연동 — 권한 요청 및 이번 달 일정 조회.
//  명세서 Phase 1 「EventKit 권한 + 일정 읽기」
//

import EventKit
import Foundation
import Observation

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

@Observable
final class CalendarManager {

    // MARK: - 공개 상태

    private(set) var accessState: CalendarAccessState = .notDetermined

    /// 접근 가능한 전체 캘린더 (이름 + 소스명 표시용).
    private(set) var calendars: [EKCalendar] = []

    /// 이번 달 1일 00:00 ~ 말일 23:59:59 범위의 일정. 시작시각 오름차순.
    private(set) var events: [EKEvent] = []

    /// 권한 요청 중 에러가 발생한 경우의 메시지.
    private(set) var errorMessage: String?

    // MARK: - 내부

    private let eventStore = EKEventStore()

    init() {
        refreshAccessState()
        if accessState == .authorized {
            loadCalendarsAndEvents()
        }
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

    // MARK: - 조회

    /// 접근 가능한 캘린더 목록과 이번 달 일정을 다시 읽는다.
    func loadCalendarsAndEvents() {
        loadCalendars()
        loadEventsForCurrentMonth()
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

    private func loadEventsForCurrentMonth() {
        guard let range = Self.currentMonthRange() else {
            events = []
            return
        }

        // calendars: nil → 접근 가능한 전체 캘린더 대상.
        let predicate = eventStore.predicateForEvents(
            withStart: range.start,
            end: range.end,
            calendars: nil
        )

        events = eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                let l = lhs.startDate ?? .distantFuture
                let r = rhs.startDate ?? .distantFuture
                if l != r { return l < r }
                return (lhs.title ?? "") < (rhs.title ?? "")
            }
    }

    // MARK: - 날짜 계산

    /// 이번 달 1일 00:00 부터 다음 달 1일 00:00 직전까지.
    static func currentMonthRange(
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (start: Date, end: Date)? {
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let start = calendar.date(from: components),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: start)
        else { return nil }

        // 말일 23:59:59 까지 포함하도록 다음 달 1일 직전으로 끝점을 잡는다.
        let end = nextMonth.addingTimeInterval(-1)
        return (start, end)
    }
}
