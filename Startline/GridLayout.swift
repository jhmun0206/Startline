//
//  GridLayout.swift
//  Startline
//
//  월간 그리드 한 주의 배치 계산.
//
//  칸마다 따로 그리면 여러 날에 걸친 것이 날마다 반복돼 보인다.
//  주 단위로 레인을 배정해 시작일부터 종료일까지 한 줄로 잇는다.
//
//  할 일과 일정은 **레인 밴드를 나눈다.** 할 일 막대를 더 얇게 그려
//  같은 칸 높이에 더 많이 들어가게 하고, 할 일 밴드를 위에 둔다.
//

import EventKit
import Foundation

/// 그리드에 놓이는 할 일 하나. 시작일부터 마감일까지 뻗는다.
nonisolated struct GridTaskItem {
    let resolved: ResolvedTask
    /// 막대가 시작하는 날 (보통 착수마감일).
    let startDay: Date
    /// 막대가 끝나는 날 (마감일). `startDay` 와 같으면 점 하나로 그린다.
    let endDay: Date
    /// 시작 시점이 지나 오늘 칸에 덧붙인 것인지.
    let isEcho: Bool

    var key: String { "\(resolved.id.uuidString)|\(isEcho ? "echo" : "main")" }
}

/// 그리드 막대 하나가 나타내는 것.
nonisolated enum GridItemKind {
    case event(DayEvent)
    case task(GridTaskItem)
}

/// 막대 굵기·간격·글자 크기.
///
/// **칸 크기에 따라 단계적으로 바뀐다.** 창을 넓혀도 값이 고정이면 여백만 늘고
/// 내용은 그대로라, 넓은 화면일수록 오히려 빈약해 보인다.
nonisolated struct GridMetrics {
    var eventBarHeight: CGFloat = 20
    /// 할 일은 더 얇게. 레인을 덜 먹어야 점선이 며칠씩 뻗어도 칸이 버틴다.
    var taskBarHeight: CGFloat = 16
    var spacing: CGFloat = 3
    var numberRowHeight: CGFloat = 23
    var titleFontSize: CGFloat = 12.5
    var dayNumberFontSize: CGFloat = 13.5
    /// 일정이 있을 때 일정 몫으로 남겨 두는 최소 레인 수.
    /// 할 일이 칸을 통째로 먹어 일정이 전부 `+N` 으로 밀리는 것을 막는다.
    var reservedEventLanes: Int = 2

    /// 칸 높이에 맞는 밀도를 고른다.
    ///
    /// 연속 스케일링은 창을 조금만 움직여도 글자가 흔들려 읽기 나쁘다. 세 단계로 끊는다.
    static func forRowHeight(_ height: CGFloat) -> GridMetrics {
        switch height {
        case ..<92:
            return GridMetrics(
                eventBarHeight: 16, taskBarHeight: 13, spacing: 2,
                numberRowHeight: 20, titleFontSize: 11.5, dayNumberFontSize: 12.5
            )
        case ..<140:
            return GridMetrics(
                eventBarHeight: 20, taskBarHeight: 16, spacing: 3,
                numberRowHeight: 23, titleFontSize: 12.5, dayNumberFontSize: 13.5
            )
        default:
            return GridMetrics(
                eventBarHeight: 24, taskBarHeight: 19, spacing: 4,
                numberRowHeight: 27, titleFontSize: 14, dayNumberFontSize: 15
            )
        }
    }
}

/// 한 주 안에서 막대 하나가 차지하는 자리.
nonisolated struct GridSegment: Identifiable {
    let id: String
    let kind: GridItemKind
    /// 주 안에서의 열 범위 (0 = 첫 요일).
    let startColumn: Int
    let endColumn: Int
    /// 칸 위쪽에서의 세로 위치와 굵기.
    let y: CGFloat
    let height: CGFloat
    let continuesBefore: Bool
    let continuesAfter: Bool

    var columnSpan: Int { endColumn - startColumn + 1 }
}

nonisolated struct WeekLayout {
    let segments: [GridSegment]
    /// 열 → 자리가 모자라 감춰진 개수.
    let overflowByColumn: [Int: Int]
    /// `+N` 을 그릴 세로 위치.
    let overflowY: CGFloat

    /// 한 주치 배치를 계산한다.
    static func build(
        days: [Date],
        dayEvents: [Date: [DayEvent]],
        tasks: [GridTaskItem],
        availableHeight: CGFloat,
        metrics: GridMetrics = GridMetrics(),
        calendar: Calendar
    ) -> WeekLayout {
        guard let weekStart = days.first, let weekEnd = days.last else {
            return WeekLayout(segments: [], overflowByColumn: [:], overflowY: 0)
        }

        let weekStartDay = calendar.startOfDay(for: weekStart)
        let weekEndDay = calendar.startOfDay(for: weekEnd)
        let body = max(0, availableHeight - metrics.numberRowHeight - 3)

        // ── 할 일 밴드 ──
        let taskItems = pendingTasks(
            tasks,
            days: days,
            weekStart: weekStartDay,
            weekEnd: weekEndDay,
            calendar: calendar
        )
        let taskLanes = assignLanes(taskItems)
        let taskStride = metrics.taskBarHeight + metrics.spacing

        // ── 일정 밴드 ──
        let eventItems = pendingEvents(
            days: days,
            dayEvents: dayEvents,
            weekStart: weekStartDay,
            weekEnd: weekEndDay,
            calendar: calendar
        )
        let eventLanes = assignLanes(eventItems)
        let eventStride = metrics.eventBarHeight + metrics.spacing

        // 일정이 있을 때만 그 몫을 남긴다. 할 일뿐이면 칸을 다 쓴다.
        // 할 일 막대가 더 얇으므로 같은 높이에 더 많이 들어간다.
        let eventLaneNeed = laneCount(eventLanes)
        let reserved = eventLaneNeed > 0
            ? CGFloat(min(eventLaneNeed, metrics.reservedEventLanes)) * eventStride
            : 0

        let taskCapacity = max(0, Int((body - reserved) / taskStride))
        let usedTaskLanes = min(laneCount(taskLanes), taskCapacity)
        let taskBandHeight = CGFloat(usedTaskLanes) * taskStride
        let eventCapacity = max(0, Int((body - taskBandHeight) / eventStride))

        var segments: [GridSegment] = []
        var overflow: [Int: Int] = [:]

        for (item, lane) in taskLanes {
            if lane < taskCapacity {
                segments.append(
                    GridSegment(
                        id: item.id,
                        kind: item.kind,
                        startColumn: item.startColumn,
                        endColumn: item.endColumn,
                        y: metrics.numberRowHeight + CGFloat(lane) * taskStride,
                        height: metrics.taskBarHeight,
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

        for (item, lane) in eventLanes {
            if lane < eventCapacity {
                segments.append(
                    GridSegment(
                        id: item.id,
                        kind: item.kind,
                        startColumn: item.startColumn,
                        endColumn: item.endColumn,
                        y: metrics.numberRowHeight + taskBandHeight + CGFloat(lane) * eventStride,
                        height: metrics.eventBarHeight,
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

        let overflowY = metrics.numberRowHeight
            + taskBandHeight
            + CGFloat(min(laneCount(eventLanes), eventCapacity)) * eventStride

        return WeekLayout(
            segments: segments,
            overflowByColumn: overflow,
            overflowY: overflowY
        )
    }

    // MARK: - 레인 배정

    private struct PendingItem {
        let id: String
        let kind: GridItemKind
        let startColumn: Int
        let endColumn: Int
        let continuesBefore: Bool
        let continuesAfter: Bool
        let sortKey: String

        func overlaps(_ other: PendingItem) -> Bool {
            startColumn <= other.endColumn && other.startColumn <= endColumn
        }
    }

    /// 긴 것부터 자리를 잡아야 짧은 것들이 빈틈에 들어간다.
    private static func assignLanes(_ items: [PendingItem]) -> [(item: PendingItem, lane: Int)] {
        let sorted = items.sorted { lhs, rhs in
            let lspan = lhs.endColumn - lhs.startColumn
            let rspan = rhs.endColumn - rhs.startColumn
            if lspan != rspan { return lspan > rspan }
            if lhs.startColumn != rhs.startColumn { return lhs.startColumn < rhs.startColumn }
            return lhs.sortKey < rhs.sortKey
        }

        var placed: [(item: PendingItem, lane: Int)] = []
        for item in sorted {
            var lane = 0
            while placed.contains(where: { $0.lane == lane && $0.item.overlaps(item) }) {
                lane += 1
            }
            placed.append((item, lane))
        }
        return placed
    }

    private static func laneCount(_ placed: [(item: PendingItem, lane: Int)]) -> Int {
        (placed.map(\.lane).max().map { $0 + 1 }) ?? 0
    }

    // MARK: - 수집

    private static func pendingTasks(
        _ tasks: [GridTaskItem],
        days: [Date],
        weekStart: Date,
        weekEnd: Date,
        calendar: Calendar
    ) -> [PendingItem] {
        tasks.compactMap { item in
            let start = calendar.startOfDay(for: item.startDay)
            let end = calendar.startOfDay(for: max(item.endDay, item.startDay))

            // 이 주와 겹치지 않으면 뺀다.
            guard start <= weekEnd, end >= weekStart else { return nil }

            let visibleStart = max(start, weekStart)
            let visibleEnd = min(end, weekEnd)

            guard let startColumn = column(of: visibleStart, days: days, calendar: calendar),
                  let endColumn = column(of: visibleEnd, days: days, calendar: calendar)
            else { return nil }

            return PendingItem(
                id: "task|\(item.key)",
                kind: .task(item),
                startColumn: startColumn,
                endColumn: endColumn,
                continuesBefore: start < weekStart,
                continuesAfter: end > weekEnd,
                sortKey: item.resolved.task.title
            )
        }
    }

    private static func pendingEvents(
        days: [Date],
        dayEvents: [Date: [DayEvent]],
        weekStart: Date,
        weekEnd: Date,
        calendar: Calendar
    ) -> [PendingItem] {
        var items: [PendingItem] = []
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
                        continuesBefore: start.map { $0 < weekStart } ?? false,
                        continuesAfter: end.map { $0 > weekEnd } ?? false,
                        sortKey: dayEvent.id
                    )
                )
            }
        }
        return items
    }

    private static func column(of day: Date, days: [Date], calendar: Calendar) -> Int? {
        days.firstIndex { calendar.isDate($0, inSameDayAs: day) }
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
