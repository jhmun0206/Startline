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

/// 그리드 바깥 여백. **여러 곳이 같은 값을 써야 열이 맞으므로 한곳에 둔다.**
///
/// 요일 머리글과 날짜 그리드가 다른 값을 쓰면 열이 어긋난다.
/// 좌표를 날짜로 바꿀 때도 이 값을 손으로 빼면 여백을 바꾸는 순간 조용히 틀어진다.
/// 그래서 좌표 변환은 여백을 뺀 **본문 좌표계**에서 한다. (`GridHitTest`)
nonisolated enum GridInsets {
    static let horizontal: CGFloat = 20
    static let bottom: CGFloat = 20
    /// 막대 좌우 안쪽 여백.
    static let barInset: CGFloat = 2
}

/// 그리드 본문 좌표를 행·열로 바꾼다.
///
/// 순수 함수라 창 크기·주 수·해상도를 바꿔 가며 검증할 수 있다.
/// **좌표는 여백을 뺀 본문 기준이다.** 뷰에서는 named 좌표계로 그 기준을 만든다.
nonisolated enum GridHitTest {

    static let columnCount = 7

    /// - Parameters:
    ///   - point: 그리드 본문 좌표.
    ///   - size: 그리드 본문 크기.
    ///   - weekCount: 이 달의 주 수 (4~6).
    ///   - clamped: 범위를 벗어난 좌표를 가장 가까운 칸으로 당길지.
    ///     드래그를 시작할 때는 `false`(그리드 밖에서 시작하면 무시),
    ///     끄는 도중에는 `true`(가장자리를 넘어가도 계속 따라오게).
    static func cell(
        at point: CGPoint,
        in size: CGSize,
        weekCount: Int,
        clamped: Bool = false
    ) -> (row: Int, column: Int)? {
        guard weekCount > 0, size.width > 0, size.height > 0 else { return nil }

        let inside = point.x >= 0 && point.y >= 0
            && point.x < size.width && point.y < size.height
        guard inside || clamped else { return nil }

        let x = min(max(point.x, 0), size.width - 0.001)
        let y = min(max(point.y, 0), size.height - 0.001)

        let columnWidth = size.width / CGFloat(columnCount)
        let rowHeight = size.height / CGFloat(weekCount)

        let column = min(max(Int(x / columnWidth), 0), columnCount - 1)
        let row = min(max(Int(y / rowHeight), 0), weekCount - 1)
        return (row, column)
    }

    /// 좌표가 가리키는 날짜. `days` 는 그리드에 놓인 날짜 전체(주 × 7).
    static func date(
        at point: CGPoint,
        in size: CGSize,
        days: [Date],
        clamped: Bool = false
    ) -> Date? {
        let weekCount = days.count / columnCount
        guard weekCount > 0, days.count % columnCount == 0 else { return nil }
        guard let cell = cell(at: point, in: size, weekCount: weekCount, clamped: clamped)
        else { return nil }

        let index = cell.row * columnCount + cell.column
        guard days.indices.contains(index) else { return nil }
        return days[index]
    }
}

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

/// 아직 저장되지 않은 일정이 차지할 자리.
nonisolated struct DraftRangeItem {
    let startDay: Date
    let endDay: Date
}

/// 할 일을 그리드 날짜에 배정한다.
///
/// 순수 함수라 오늘 날짜·표시 범위를 바꿔 가며 검증할 수 있다.
nonisolated enum GridTaskPlacement {

    /// - Parameters:
    ///   - tasks: 계산이 끝난 할 일 전체.
    ///   - gridStart / gridEnd: 그리드에 놓인 첫 날과 마지막 날.
    ///   - showsSpan: 착수일부터 마감일까지 점선으로 이을지.
    static func items(
        for tasks: [ResolvedTask],
        gridStart: Date,
        gridEnd: Date,
        now: Date,
        showsSpan: Bool,
        calendar: Calendar
    ) -> [GridTaskItem] {
        let rangeStart = calendar.startOfDay(for: gridStart)
        let rangeEnd = calendar.startOfDay(for: gridEnd)
        let today = calendar.startOfDay(for: now)

        // 오늘이 놓인 **주 행**의 처음과 끝. 오늘이 표시 범위 밖이면 `nil`.
        //
        // 그리드는 첫 날부터 7일씩 끊어 한 줄을 만든다. (`MonthGridView` 의 `chunked(into: 7)`)
        // 달력의 주 번호가 아니라 **화면에 그려진 줄**을 기준으로 삼아야
        // 「같은 줄에 보이는가」와 판정이 어긋나지 않는다.
        let todayRow: ClosedRange<Date>? = {
            guard today >= rangeStart, today <= rangeEnd else { return nil }
            let offset = calendar.dateComponents([.day], from: rangeStart, to: today).day ?? 0
            guard let rowStart = calendar.date(byAdding: .day, value: (offset / 7) * 7, to: rangeStart),
                  let rowEnd = calendar.date(byAdding: .day, value: 6, to: rowStart)
            else { return nil }
            return rowStart...rowEnd
        }()

        var items: [GridTaskItem] = []

        for resolved in tasks {
            guard let due = resolved.effectiveDueAt.map({ calendar.startOfDay(for: $0) })
            else { continue }

            // 착수마감이 없으면(리드타임 없음) 마감일에 점 하나.
            let start = resolved.startDeadline.map { calendar.startOfDay(for: $0) } ?? due
            // 점선 표시를 끄면 시작 지점만 남긴다.
            let end = showsSpan ? max(start, due) : start

            if start <= rangeEnd, end >= rangeStart {
                items.append(
                    GridTaskItem(resolved: resolved, startDay: start, endDay: end, isEcho: false)
                )
            }

            // 시작 시점이 지났는데 아직 시작하지 않았으면 오늘 칸에도 띄운다 — 놓치면 안 되므로.
            //
            // **본 막대가 오늘과 같은 주 행에 이미 보이면 띄우지 않는다.**
            //
            // 메아리의 목적은 「놓치면 안 되니 오늘 칸에도 보이게」다. 본 막대가 같은 줄에
            // 이미 있으면 그 목적은 달성돼 있고, 메아리는 중복일 뿐이다.
            //
            // 예전에는 `start <= today && today <= end` 로, **오늘이 막대 안에 있을 때만**
            // 걸렀다. 마감이 이미 지나 오늘이 막대 **뒤**에 있으면 걸러지지 않아,
            // 바로 옆 칸에 메아리가 붙어 하나의 막대가 끊어진 것처럼 보였다. (BL-050)
            // 오늘이 막대 안인지 뒤인지는 메아리의 목적과 무관한 구분이었다.
            //
            // 새 조건은 옛 조건을 포함한다 — 오늘이 막대 안에 있으면 그 막대는 반드시
            // 오늘의 주 행에 걸치므로, `0dd8a36` 이 없앤 증상도 그대로 막힌다.
            let mainBarShowsInTodayRow = todayRow.map { row in
                start <= row.upperBound && end >= row.lowerBound
            } ?? false

            if resolved.task.status == .notStarted,
               let startDeadline = resolved.startDeadline,
               startDeadline < now,
               !mainBarShowsInTodayRow,
               todayRow != nil {
                items.append(
                    GridTaskItem(resolved: resolved, startDay: today, endDay: today, isEcho: true)
                )
            }
        }

        return items
    }
}

/// 그리드 막대 하나가 나타내는 것.
nonisolated enum GridItemKind {
    case event(DayEvent)
    case task(GridTaskItem)
    /// 드래그 중이거나 시트가 떠 있는 동안 보여주는 임시 일정.
    case draft(DraftRangeItem)
}

/// 막대 굵기·간격·글자 크기.
///
/// **칸 크기에 따라 단계적으로 바뀐다.** 창을 넓혀도 값이 고정이면 여백만 늘고
/// 내용은 그대로라, 넓은 화면일수록 오히려 빈약해 보인다.
nonisolated struct GridMetrics {
    var eventBarHeight: CGFloat = 14
    var taskBarHeight: CGFloat = 14
    var spacing: CGFloat = 3
    var numberRowHeight: CGFloat = 23
    var titleFontSize: CGFloat = 11
    var dayNumberFontSize: CGFloat = 13
    /// 할 일이 있을 때 할 일 몫으로 남겨 두는 최소 레인 수.
    /// 일정이 칸을 다 채워 할 일이 전부 `+N` 으로 밀리는 것을 막는다.
    var reservedTaskLanes: Int = 2

    /// 칸 높이에 맞는 밀도를 고른다.
    ///
    /// 연속 스케일링은 창을 조금만 움직여도 글자가 흔들려 읽기 나쁘다. 세 단계로 끊는다.
    static func forRowHeight(_ height: CGFloat) -> GridMetrics {
        switch height {
        case ..<92:
            return GridMetrics(
                eventBarHeight: 11, taskBarHeight: 11, spacing: 2,
                numberRowHeight: 20, titleFontSize: 10, dayNumberFontSize: 12
            )
        case ..<140:
            return GridMetrics(
                eventBarHeight: 14, taskBarHeight: 14, spacing: 3,
                numberRowHeight: 23, titleFontSize: 11, dayNumberFontSize: 13
            )
        default:
            return GridMetrics(
                eventBarHeight: 17, taskBarHeight: 17, spacing: 4,
                numberRowHeight: 27, titleFontSize: 12.5, dayNumberFontSize: 14
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

    /// 주 안 좌표에 놓인 막대. 없으면 `nil`.
    ///
    /// - Parameters:
    ///   - column: 주 안에서의 열 (0 = 첫 요일).
    ///   - y: 주 행 위쪽에서의 세로 위치.
    func segment(atColumn column: Int, y: CGFloat) -> GridSegment? {
        segments.first { segment in
            segment.startColumn <= column
                && column <= segment.endColumn
                && y >= segment.y
                && y < segment.y + segment.height
        }
    }

    /// 한 주치 배치를 계산한다.
    ///
    /// **일정은 위에서부터, 할 일은 아래에서부터 채운다.**
    ///
    /// 할 일 개수는 날마다 크게 변하고 일정은 상대적으로 안정적이다.
    /// 변동이 큰 쪽을 위에 두면, 하루에 할 일이 몇 개 생겼다는 이유로
    /// 그 주 전체의 일정이 아래로 밀린다. 그래서 변동이 큰 쪽을 아래로 보낸다.
    ///
    /// 「할 일을 먼저 보여준다」는 목적은 우측 패널 「오늘 시작」 블록이 맡는다.
    static func build(
        days: [Date],
        dayEvents: [Date: [DayEvent]],
        tasks: [GridTaskItem],
        draft: DraftRangeItem? = nil,
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

        let taskItems = pendingTasks(
            tasks,
            days: days,
            weekStart: weekStartDay,
            weekEnd: weekEndDay,
            calendar: calendar
        )
        let taskLanes = assignLanes(taskItems)
        let taskStride = metrics.taskBarHeight + metrics.spacing

        var eventItems = pendingEvents(
            days: days,
            dayEvents: dayEvents,
            weekStart: weekStartDay,
            weekEnd: weekEndDay,
            calendar: calendar
        )
        // 임시 막대도 실제 일정과 같은 레인 규칙을 따른다. 자리가 자연스러워야
        // 저장했을 때 막대가 튀지 않는다.
        if let draft, let item = pendingDraft(
            draft, days: days, weekStart: weekStartDay, weekEnd: weekEndDay, calendar: calendar
        ) {
            eventItems.append(item)
        }
        let eventLanes = assignLanes(eventItems)
        let eventStride = metrics.eventBarHeight + metrics.spacing

        // 할 일이 있으면 그 몫을 남긴다. 할 일이 없으면 일정이 칸을 다 쓴다.
        let taskLaneNeed = laneCount(taskLanes)
        let reserved = taskLaneNeed > 0
            ? CGFloat(min(taskLaneNeed, metrics.reservedTaskLanes)) * taskStride
            : 0

        let eventCapacity = max(0, Int((body - reserved) / eventStride))
        let usedEventLanes = min(laneCount(eventLanes), eventCapacity)
        let eventBandHeight = CGFloat(usedEventLanes) * eventStride
        // 둘이 만나는 지점까지가 할 일 몫이다.
        let taskCapacity = max(0, Int((body - eventBandHeight) / taskStride))

        let bodyTop = metrics.numberRowHeight
        let bodyBottom = metrics.numberRowHeight + body

        var segments: [GridSegment] = []
        var overflow: [Int: Int] = [:]

        // 일정 — 위에서부터
        for (item, lane) in eventLanes {
            if lane < eventCapacity {
                segments.append(
                    GridSegment(
                        id: item.id,
                        kind: item.kind,
                        startColumn: item.startColumn,
                        endColumn: item.endColumn,
                        y: bodyTop + CGFloat(lane) * eventStride,
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

        // 할 일 — 아래에서부터. 레인 0이 맨 아래 줄이다.
        for (item, lane) in taskLanes {
            if lane < taskCapacity {
                segments.append(
                    GridSegment(
                        id: item.id,
                        kind: item.kind,
                        startColumn: item.startColumn,
                        endColumn: item.endColumn,
                        y: bodyBottom - CGFloat(lane + 1) * taskStride + metrics.spacing,
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

        // 둘이 만나는 지점에 「+N」을 놓는다.
        let overflowY = bodyTop + eventBandHeight

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

        // ── 같은 자리를 다툴 때의 순서 ──
        // 우측 패널과 같은 규칙이어야 한다. 종일 먼저, 그 다음 시작시각, 그 다음 제목.
        let isAllDay: Bool
        let start: Date
        let title: String

        func overlaps(_ other: PendingItem) -> Bool {
            startColumn <= other.endColumn && other.startColumn <= endColumn
        }

        /// 문자열 하나로 뭉치지 않는다. `"false|…" < "true|…"` 처럼
        /// 사전순이 의도와 반대로 뒤집히는 일이 생긴다.
        func isOrderedBefore(_ other: PendingItem) -> Bool {
            if isAllDay != other.isAllDay { return isAllDay }
            if start != other.start { return start < other.start }
            return title < other.title
        }
    }

    /// 긴 것부터 자리를 잡아야 짧은 것들이 빈틈에 들어간다.
    private static func assignLanes(_ items: [PendingItem]) -> [(item: PendingItem, lane: Int)] {
        let sorted = items.sorted { lhs, rhs in
            let lspan = lhs.endColumn - lhs.startColumn
            let rspan = rhs.endColumn - rhs.startColumn
            if lspan != rspan { return lspan > rspan }
            if lhs.startColumn != rhs.startColumn { return lhs.startColumn < rhs.startColumn }
            return lhs.isOrderedBefore(rhs)
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
                isAllDay: false,
                start: item.resolved.startDeadline ?? item.resolved.effectiveDueAt ?? item.startDay,
                title: item.resolved.task.title
            )
        }
    }

    private static func pendingDraft(
        _ draft: DraftRangeItem,
        days: [Date],
        weekStart: Date,
        weekEnd: Date,
        calendar: Calendar
    ) -> PendingItem? {
        let start = calendar.startOfDay(for: draft.startDay)
        let end = calendar.startOfDay(for: max(draft.endDay, draft.startDay))
        guard start <= weekEnd, end >= weekStart else { return nil }

        guard let startColumn = column(of: max(start, weekStart), days: days, calendar: calendar),
              let endColumn = column(of: min(end, weekEnd), days: days, calendar: calendar)
        else { return nil }

        return PendingItem(
            id: "draft",
            kind: .draft(draft),
            startColumn: startColumn,
            endColumn: endColumn,
            continuesBefore: start < weekStart,
            continuesAfter: end > weekEnd,
            // 같은 길이면 먼저 자리를 잡아 위쪽 레인에 놓이게 한다.
            isAllDay: true,
            start: .distantPast,
            title: ""
        )
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
                        isAllDay: event.isAllDay,
                        start: event.startDate ?? .distantFuture,
                        title: event.title ?? ""
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
