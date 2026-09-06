//
//  GridLayout.swift
//  Startline
//
//  월간 그리드 한 주의 배치 계산.
//
//  칸마다 따로 그리면 여러 날에 걸친 일정이 날마다 반복돼 보인다.
//  주 단위로 레인을 배정해 시작일부터 종료일까지 한 줄로 잇는다.
//

import EventKit
import Foundation

/// 그리드 막대 하나가 나타내는 것.
nonisolated enum GridItemKind {
    case event(DayEvent)
    /// 할 일. 그리드에는 **마감일이 아니라 시작일**에 놓인다.
    case task(ResolvedTask)
}

/// 한 주 안에서 막대 하나가 차지하는 자리.
nonisolated struct GridSegment: Identifiable {
    let id: String
    let kind: GridItemKind
    /// 주 안에서의 열 범위 (0 = 첫 요일).
    let startColumn: Int
    let endColumn: Int
    /// 위에서 몇 번째 줄에 놓이는지.
    let lane: Int
    /// 이 주 이전부터 이어져 오는지.
    let continuesBefore: Bool
    /// 이 주 다음으로 이어지는지.
    let continuesAfter: Bool

    var columnSpan: Int { endColumn - startColumn + 1 }
}

nonisolated struct WeekLayout {
    let segments: [GridSegment]
    /// 열 → 자리가 모자라 감춰진 개수.
    let overflowByColumn: [Int: Int]

    /// 한 주치 배치를 계산한다.
    ///
    /// - Parameters:
    ///   - days: 그 주의 7일.
    ///   - dayEvents: 날짜별 일정.
    ///   - dayTasks: 날짜별 할 일.
    ///   - capacity: 한 칸에 들어가는 막대 줄 수.
    static func build(
        days: [Date],
        dayEvents: [Date: [DayEvent]],
        dayTasks: [Date: [ResolvedTask]],
        capacity: Int,
        calendar: Calendar
    ) -> WeekLayout {
        guard let weekStart = days.first, let weekEnd = days.last else {
            return WeekLayout(segments: [], overflowByColumn: [:])
        }

        var placed: [(item: PendingItem, lane: Int)] = []
        var pending = collect(
            days: days,
            dayEvents: dayEvents,
            dayTasks: dayTasks,
            weekStart: weekStart,
            weekEnd: weekEnd,
            calendar: calendar
        )

        // 긴 것부터 자리를 잡아야 짧은 것들이 빈틈에 들어간다.
        pending.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let lspan = lhs.endColumn - lhs.startColumn
            let rspan = rhs.endColumn - rhs.startColumn
            if lspan != rspan { return lspan > rspan }
            if lhs.startColumn != rhs.startColumn { return lhs.startColumn < rhs.startColumn }
            return lhs.id < rhs.id
        }

        // 겹치지 않는 가장 위쪽 레인에 배정한다.
        for item in pending {
            var lane = 0
            while placed.contains(where: { $0.lane == lane && $0.item.overlaps(item) }) {
                lane += 1
            }
            placed.append((item, lane))
        }

        var segments: [GridSegment] = []
        var overflow: [Int: Int] = [:]

        for (item, lane) in placed {
            if lane < capacity {
                segments.append(
                    GridSegment(
                        id: item.id,
                        kind: item.kind,
                        startColumn: item.startColumn,
                        endColumn: item.endColumn,
                        lane: lane,
                        continuesBefore: item.continuesBefore,
                        continuesAfter: item.continuesAfter
                    )
                )
            } else {
                for column in item.startColumn...item.endColumn {
                    overflow[column, default: 0] += 1
                }
            }
        }

        return WeekLayout(segments: segments, overflowByColumn: overflow)
    }

    // MARK: - 수집

    private struct PendingItem {
        let id: String
        let kind: GridItemKind
        let startColumn: Int
        let endColumn: Int
        let continuesBefore: Bool
        let continuesAfter: Bool
        /// 낮을수록 위. 할 일을 일정보다 위에 둔다 — 이 앱의 차별점이 착수일이다.
        let priority: Int

        func overlaps(_ other: PendingItem) -> Bool {
            startColumn <= other.endColumn && other.startColumn <= endColumn
        }
    }

    private static func collect(
        days: [Date],
        dayEvents: [Date: [DayEvent]],
        dayTasks: [Date: [ResolvedTask]],
        weekStart: Date,
        weekEnd: Date,
        calendar: Calendar
    ) -> [PendingItem] {
        var items: [PendingItem] = []

        // 할 일 — 하루짜리다.
        for (column, day) in days.enumerated() {
            for resolved in dayTasks[calendar.startOfDay(for: day)] ?? [] {
                items.append(
                    PendingItem(
                        id: "task|\(resolved.id.uuidString)|\(column)",
                        kind: .task(resolved),
                        startColumn: column,
                        endColumn: column,
                        continuesBefore: false,
                        continuesAfter: false,
                        priority: 0
                    )
                )
            }
        }

        // 일정 — 같은 일정이 여러 날에 나타나므로 주 안에서 한 번만 모은다.
        var seen = Set<String>()
        for (column, day) in days.enumerated() {
            for dayEvent in dayEvents[calendar.startOfDay(for: day)] ?? [] {
                guard seen.insert(dayEvent.id).inserted else { continue }

                let span = columnSpan(
                    for: dayEvent,
                    days: days,
                    dayEvents: dayEvents,
                    fallbackColumn: column,
                    calendar: calendar
                )

                let event = dayEvent.primary
                let start = event.startDate.map { calendar.startOfDay(for: $0) }
                let end = adjustedEnd(of: event, calendar: calendar)
                    .map { calendar.startOfDay(for: $0) }

                items.append(
                    PendingItem(
                        id: "event|\(dayEvent.id)",
                        kind: .event(dayEvent),
                        startColumn: span.start,
                        endColumn: span.end,
                        continuesBefore: start.map { $0 < calendar.startOfDay(for: weekStart) } ?? false,
                        continuesAfter: end.map { $0 > calendar.startOfDay(for: weekEnd) } ?? false,
                        priority: 1
                    )
                )
            }
        }

        return items
    }

    /// 이 주 안에서 그 일정이 놓이는 열 범위.
    private static func columnSpan(
        for dayEvent: DayEvent,
        days: [Date],
        dayEvents: [Date: [DayEvent]],
        fallbackColumn: Int,
        calendar: Calendar
    ) -> (start: Int, end: Int) {
        var columns: [Int] = []
        for (column, day) in days.enumerated() {
            let bucket = dayEvents[calendar.startOfDay(for: day)] ?? []
            if bucket.contains(where: { $0.id == dayEvent.id }) {
                columns.append(column)
            }
        }
        guard let first = columns.first, let last = columns.last else {
            return (fallbackColumn, fallbackColumn)
        }
        return (first, last)
    }

    /// 자정에 정확히 끝나는 일정이 다음 날까지 번지지 않게 한다.
    static func adjustedEnd(of event: EKEvent, calendar: Calendar) -> Date? {
        guard let start = event.startDate else { return nil }
        var end = event.endDate ?? start
        if !event.isAllDay, end > start, end == calendar.startOfDay(for: end) {
            end = end.addingTimeInterval(-1)
        }
        return end
    }
}
