//
//  MonthGridView.swift
//  Startline
//
//  명세서 5.1 좌측 — 월간 그리드.
//  일정을 점(dot)이 아니라 제목이 보이는 색상 바로 표시한다.
//  할 일은 **마감일이 아니라 시작일**에 놓는다. 이 앱의 차별점이 거기에 있다.
//

import Combine
import EventKit
import SwiftData
import SwiftUI
import UserNotifications

struct MonthGridView: View {
    let manager: CalendarManager
    let onOpenEvent: (DayEvent) -> Void
    let onAddOnDate: (Date) -> Void
    /// 드래그로 고른 기간으로 일정을 만들 때.
    let onAddRange: (Date, Date) -> Void
    let onOpenTask: (ResolvedTask) -> Void
    let scheduler: NotificationScheduler

    @Query private var allTasks: [ManagedTask]

    /// 판정이 시간에 따라 바뀌므로 주기적으로 갱신한다.
    @State private var now = Date()
    /// 드래그로 기간을 고르는 중.
    @State private var dragAnchor: Date?
    @State private var dragCurrent: Date?

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var calendar: Calendar { manager.calendar }

    var body: some View {
        VStack(spacing: 0) {
            MonthHeaderView(manager: manager, scheduler: scheduler)
            Divider()
            WeekdayHeaderView(headers: manager.weekdayHeaders())
            Divider()
            grid
        }
        .onReceive(clock) { now = $0 }
    }

    // MARK: - 그리드

    /// 표시 중인 한 달을 그린다.
    ///
    /// `manager.displayedMonth` 하나만 보고 그린다. 화면에 보이는 달과 머리글이
    /// 어긋날 수 없도록 기준을 하나로 유지한다. (BL-002 실패 원인)
    private var grid: some View {
        let month = manager.displayedMonth
        let days = CalendarManager.gridDays(for: month, calendar: calendar)
        let weeks = days.chunked(into: 7)
        let dayEvents = manager.dayEvents(forMonth: month)
        let tasks = manager.showsTasks ? taskItems(in: days) : []

        return VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                WeekRow(
                    manager: manager,
                    days: week,
                    dayEvents: dayEvents,
                    tasks: tasks,
                    now: now,
                    selectionRange: dragRange,
                    onSelect: { day in
                        manager.selectedDate = calendar.startOfDay(for: day)
                    },
                    onAdd: { day in
                        manager.selectedDate = calendar.startOfDay(for: day)
                        onAddOnDate(calendar.startOfDay(for: day))
                    },
                    onOpenEvent: onOpenEvent,
                    onOpenTask: onOpenTask
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .contentShape(Rectangle())
        .gesture(rangeDrag(weeks: weeks))
        .id(manager.dataRevision)
    }

    // MARK: - 드래그로 기간 고르기

    private var dragRange: ClosedRange<Date>? {
        guard let dragAnchor, let dragCurrent else { return nil }
        let lower = min(dragAnchor, dragCurrent)
        let upper = max(dragAnchor, dragCurrent)
        return lower...upper
    }

    private func rangeDrag(weeks: [[Date]]) -> some Gesture {
        // 최소 이동 거리를 두어 한 번 클릭·더블클릭과 부딪히지 않게 한다.
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard let anchor = date(at: value.startLocation, weeks: weeks) else { return }
                dragAnchor = anchor
                dragCurrent = date(at: value.location, weeks: weeks) ?? anchor
            }
            .onEnded { _ in
                defer {
                    dragAnchor = nil
                    dragCurrent = nil
                }
                guard let range = dragRange, range.lowerBound != range.upperBound else { return }
                manager.selectedDate = range.lowerBound
                onAddRange(range.lowerBound, range.upperBound)
            }
    }

    /// 그리드 안 좌표가 어느 날짜인지. 여백을 뺀 뒤 행·열로 나눈다.
    private func date(at point: CGPoint, weeks: [[Date]]) -> Date? {
        guard !weeks.isEmpty, gridSize.width > 0, gridSize.height > 0 else { return nil }

        let x = point.x - 20
        let y = point.y
        guard x >= 0, x < gridSize.width, y >= 0 else { return nil }

        let rowHeight = gridSize.height / CGFloat(weeks.count)
        let columnWidth = gridSize.width / 7

        let row = min(max(Int(y / rowHeight), 0), weeks.count - 1)
        let column = min(max(Int(x / columnWidth), 0), 6)

        guard weeks[row].indices.contains(column) else { return nil }
        return calendar.startOfDay(for: weeks[row][column])
    }

    @State private var gridSize: CGSize = .zero

    // MARK: - 할 일 배치

    /// 할 일을 그리드에 배정한다.
    ///
    /// **마감일이 아니라 시작일에서 출발한다.** 마감일에만 찍으면 일반 투두 앱과 다를 게 없다.
    /// 시작일부터 마감일까지 점선으로 이어 "언제부터 언제까지"가 한눈에 보이게 한다.
    /// 리드타임이 없으면 시작일 자체가 없으므로 마감일에 점 하나만 찍는다.
    /// 시작 시점이 지났는데 아직 시작하지 않았으면 오늘 칸에도 함께 띄운다 — 놓치면 안 되므로.
    private func taskItems(in days: [Date]) -> [GridTaskItem] {
        guard let first = days.first, let last = days.last else { return [] }

        let resolver = TaskResolver(manager: manager, now: now)
        let rangeStart = calendar.startOfDay(for: first)
        let rangeEnd = calendar.startOfDay(for: last)
        let today = calendar.startOfDay(for: now)

        var items: [GridTaskItem] = []

        for resolved in resolver.resolve(allTasks) {
            guard let due = resolved.effectiveDueAt.map({ calendar.startOfDay(for: $0) })
            else { continue }

            // 착수마감이 없으면(리드타임 없음) 마감일에 점 하나.
            let start = resolved.startDeadline.map { calendar.startOfDay(for: $0) } ?? due
            // 점선 표시를 끄면 시작 지점만 남긴다.
            let end = manager.showsTaskSpan ? max(start, due) : start

            if start <= rangeEnd, end >= rangeStart {
                items.append(
                    GridTaskItem(resolved: resolved, startDay: start, endDay: end, isEcho: false)
                )
            }

            if resolved.task.status == .notStarted,
               let startDeadline = resolved.startDeadline,
               startDeadline < now,
               start != today,
               today >= rangeStart, today <= rangeEnd {
                items.append(
                    GridTaskItem(resolved: resolved, startDay: today, endDay: today, isEcho: true)
                )
            }
        }

        return items
    }
}

// MARK: - 한 주

private struct WeekRow: View {
    let manager: CalendarManager
    let days: [Date]
    let dayEvents: [Date: [DayEvent]]
    let tasks: [GridTaskItem]
    let now: Date
    let selectionRange: ClosedRange<Date>?
    let onSelect: (Date) -> Void
    let onAdd: (Date) -> Void
    let onOpenEvent: (DayEvent) -> Void
    let onOpenTask: (ResolvedTask) -> Void

    private var calendar: Calendar { manager.calendar }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / 7
            // 칸이 커지면 막대도 글자도 함께 커진다.
            let metrics = GridMetrics.forRowHeight(proxy.size.height)
            let layout = WeekLayout.build(
                days: days,
                dayEvents: dayEvents,
                tasks: tasks,
                availableHeight: proxy.size.height,
                metrics: metrics,
                calendar: calendar
            )

            ZStack(alignment: .topLeading) {
                cellBackgrounds(metrics)

                // 막대는 칸 위에 겹쳐 그린다. 주 경계를 넘는 것도 한 줄로 이어진다.
                ForEach(layout.segments) { segment in
                    segmentView(segment, metrics: metrics)
                        .frame(
                            width: max(0, columnWidth * CGFloat(segment.columnSpan) - 4),
                            height: segment.height
                        )
                        .offset(
                            x: columnWidth * CGFloat(segment.startColumn) + 2,
                            y: segment.y
                        )
                }

                ForEach(Array(layout.overflowByColumn.keys.sorted()), id: \.self) { column in
                    if let count = layout.overflowByColumn[column] {
                        Text("+\(count)")
                            .font(.system(size: metrics.titleFontSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: max(0, columnWidth - 8), alignment: .leading)
                            .offset(
                                x: columnWidth * CGFloat(column) + 4,
                                y: layout.overflowY
                            )
                    }
                }
            }
        }
    }

    private func cellBackgrounds(_ metrics: GridMetrics) -> some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.timeIntervalSinceReferenceDate) { day in
                DayCellBackground(
                    metrics: metrics,
                    date: day,
                    dayNumber: calendar.component(.day, from: day),
                    isInMonth: manager.isInDisplayedMonth(day),
                    isToday: calendar.isDateInToday(day),
                    isSelected: calendar.isDate(day, inSameDayAs: manager.selectedDate),
                    isInDragRange: selectionRange?.contains(calendar.startOfDay(for: day)) ?? false,
                    onSelect: { onSelect(day) },
                    onAdd: { onAdd(day) }
                )
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: GridSegment, metrics: GridMetrics) -> some View {
        switch segment.kind {
        case .event(let dayEvent):
            EventBar(
                metrics: metrics,
                dayEvent: dayEvent,
                isDimmed: !manager.isInDisplayedMonth(days[segment.startColumn]),
                continuesBefore: segment.continuesBefore,
                continuesAfter: segment.continuesAfter,
                onOpen: { onOpenEvent(dayEvent) }
            )
        case .task(let item):
            TaskBar(
                metrics: metrics,
                item: item,
                isSpanning: segment.columnSpan > 1 || segment.continuesBefore || segment.continuesAfter,
                continuesBefore: segment.continuesBefore,
                continuesAfter: segment.continuesAfter,
                onOpen: { onOpenTask(item.resolved) }
            )
        }
    }

}

// MARK: - 날짜 칸 배경

private struct DayCellBackground: View {
    let metrics: GridMetrics
    let date: Date
    let dayNumber: Int
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isInDragRange: Bool
    let onSelect: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(dayNumber)")
                    .font(.system(size: metrics.dayNumberFontSize, weight: isToday ? .bold : .regular))
                    .foregroundStyle(numberColor)
                    .frame(width: metrics.dayNumberFontSize + 7, height: metrics.dayNumberFontSize + 7)
                    .background {
                        if isToday {
                            // 선택 표시가 파란 테두리라, 오늘은 빨강으로 구분한다.
                            Circle().fill(Color.red)
                        }
                    }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .frame(height: metrics.numberRowHeight)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onAdd)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if isInDragRange { return Color.accentColor.opacity(0.22) }
        if isSelected { return Color.accentColor.opacity(0.12) }
        return .clear
    }

    private var numberColor: Color {
        if isToday { return .white }
        let base = Color.weekdayLabel(for: Calendar.current.component(.weekday, from: date))
        return isInMonth ? base : base.opacity(0.35)
    }
}

// MARK: - 막대

/// 일정 막대. 채워진 색으로 그린다.
private struct EventBar: View {
    let metrics: GridMetrics
    let dayEvent: DayEvent
    let isDimmed: Bool
    let continuesBefore: Bool
    let continuesAfter: Bool
    let onOpen: () -> Void

    @State private var isShowingPreview = false
    @State private var hoverDelay: Task<Void, Never>?

    /// 캘린더 색은 옅게 깔고, 글자는 검정으로 읽는다.
    ///
    /// 색을 꽉 채우면 일정이 많은 날이 색 덩어리로 보이고 흰 글씨는 잘 안 읽힌다.
    /// Apple 캘린더처럼 배경은 옅게 두고 **좌측 세로 바에 원본 색**을 남겨 소속을 구분한다.
    private static let timedBackgroundOpacity: Double = 0.16
    /// 종일 일정은 좌측 바 없이 배경만으로 구분하므로 조금 더 진하게.
    private static let allDayBackgroundOpacity: Double = 0.26
    /// 인접 달 칸은 흐리게.
    private static let dimFactor: Double = 0.45

    private var isAllDay: Bool { dayEvent.primary.isAllDay }

    var body: some View {
        let color = dayEvent.primary.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray
        let base = isAllDay ? Self.allDayBackgroundOpacity : Self.timedBackgroundOpacity
        let backgroundOpacity = isDimmed ? base * Self.dimFactor : base

        HStack(spacing: 0) {
            // 시각 일정은 좌측에 원본 색 세로 바. 종일은 배경 전체로 구분한다.
            if !isAllDay {
                Rectangle()
                    .fill(color.opacity(isDimmed ? Self.dimFactor : 1))
                    .frame(width: 3)
            }

            HStack(spacing: 2) {
                if continuesBefore {
                    Image(systemName: "chevron.compact.left")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                // 제목은 막대 시작 부분에 한 번만.
                Text(title)
                    .font(.system(size: metrics.titleFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if continuesAfter {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .foregroundStyle(isDimmed ? Color.primary.opacity(0.45) : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color.opacity(backgroundOpacity))
        .clipShape(
            // 이어지는 쪽은 각지게, 끝나는 쪽은 둥글게 해서 연결을 드러낸다.
            UnevenRoundedRectangle(
                topLeadingRadius: continuesBefore ? 0 : 3,
                bottomLeadingRadius: continuesBefore ? 0 : 3,
                bottomTrailingRadius: continuesAfter ? 0 : 3,
                topTrailingRadius: continuesAfter ? 0 : 3
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            cancelHover()
            onOpen()
        }
        .onHover { hovering in
            if hovering {
                hoverDelay?.cancel()
                hoverDelay = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { isShowingPreview = true }
                }
            } else {
                cancelHover()
            }
        }
        .popover(isPresented: $isShowingPreview, arrowEdge: .trailing) {
            EventPreviewCard(dayEvent: dayEvent)
        }
    }

    private func cancelHover() {
        hoverDelay?.cancel()
        hoverDelay = nil
        isShowingPreview = false
    }

    private var title: String {
        dayEvent.primary.title ?? "(제목 없음)"
    }
}

/// 할 일 막대.
///
/// 일정과 한눈에 구분되어야 한다. 일정은 채운 색 실선, 할 일은 **점 + 점선**이다.
///
/// ```
/// ● 할 일 제목 ┄┄┄┄┄┄┄┄ ●
/// 착수일                마감일
/// ```
///
/// 색은 판정을 따른다 — 여유 / 오늘 시작 / 늦음 / 완료.
private struct TaskBar: View {
    let metrics: GridMetrics
    let item: GridTaskItem
    /// 시작일과 마감일이 다른가. 같으면 점선 없이 점 하나로 끝낸다.
    let isSpanning: Bool
    let continuesBefore: Bool
    let continuesAfter: Bool
    let onOpen: () -> Void

    @State private var isShowingPreview = false
    @State private var hoverDelay: Task<Void, Never>?

    private var resolved: ResolvedTask { item.resolved }
    private var task: ManagedTask { resolved.task }
    private var isDone: Bool { task.status == .done }

    var body: some View {
        HStack(spacing: 3) {
            // 시작 지점. 앞 주에서 이어져 왔으면 점을 찍지 않는다.
            if !continuesBefore {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: 7, weight: .bold))
            }

            Text(task.title)
                .font(.system(size: metrics.titleFontSize, weight: .medium))
                .strikethrough(isDone)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if isSpanning {
                // 마감까지 점선으로 잇는다. 일정 막대의 실선과 구분된다.
                DashedRule()
                    .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .frame(height: 1.2)
                    .frame(maxWidth: .infinity)

                // 마감 지점. 다음 주로 이어지면 점을 찍지 않는다.
                if !continuesAfter {
                    Circle()
                        .frame(width: 5, height: 5)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(item.isEcho ? 0.06 : 0.10))
        )
        .opacity(isDone ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            cancelHover()
            onOpen()
        }
        .onHover { hovering in
            if hovering {
                hoverDelay?.cancel()
                hoverDelay = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { isShowingPreview = true }
                }
            } else {
                cancelHover()
            }
        }
        .popover(isPresented: $isShowingPreview, arrowEdge: .trailing) {
            TaskPreviewCard(resolved: resolved, isEcho: item.isEcho)
        }
    }

    private func cancelHover() {
        hoverDelay?.cancel()
        hoverDelay = nil
        isShowingPreview = false
    }

    private var tint: Color {
        if isDone { return .secondary }
        switch resolved.judgment {
        case .overdue: return .red
        case .startToday: return .orange
        case .relaxed, nil: return .accentColor
        }
    }

}

/// 가로 점선 한 줄.
private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 마우스를 올렸을 때 나오는 미리보기.
///
/// **여기서는 고치지 않는다.** 마우스가 벗어나면 사라지는 화면에 편집을 넣으면
/// 조작하다가 놓치기 쉽다. 고치는 것은 클릭해서 여는 시트가 맡는다.
struct EventPreviewCard: View {
    let dayEvent: DayEvent

    private var event: EKEvent { dayEvent.primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title ?? "(제목 없음)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Label(timeText, systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(dayEvent.events.enumerated()), id: \.offset) { _, source in
                HStack(spacing: 5) {
                    Circle()
                        .fill(source.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                        .frame(width: 7, height: 7)
                    Text(source.calendar?.title ?? "(캘린더 없음)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 200, maxWidth: 300, alignment: .leading)
    }

    private var timeText: String {
        guard let start = event.startDate else { return "-" }
        if event.isAllDay {
            let end = event.endDate ?? start
            let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
            return sameDay
                ? "\(StartlineFormat.spokenDay.string(from: start)) 종일"
                : "\(StartlineFormat.spokenDay.string(from: start)) ~ \(StartlineFormat.spokenDay.string(from: end)) 종일"
        }
        let end = event.endDate ?? start
        return "\(StartlineFormat.spokenDayTime(start)) ~ \(StartlineFormat.spokenDayTime(end))"
    }
}

// MARK: - 월 머리글

private struct MonthHeaderView: View {
    let manager: CalendarManager
    let scheduler: NotificationScheduler

    @State private var isShowingCalendarList = false
    @State private var isShowingNotifications = false

    var body: some View {
        HStack(spacing: 0) {
            // 10·11·12월처럼 글자가 늘어나도 버튼이 밀리지 않도록 폭을 고정한다.
            Text(monthTitle)
                .font(.title2.bold())
                .frame(width: 138, alignment: .leading)

            HStack(spacing: 2) {
                Button { manager.goToPreviousMonth() } label: { Image(systemName: "chevron.left") }
                    .help("이전 달")
                Button { manager.goToNextMonth() } label: { Image(systemName: "chevron.right") }
                    .help("다음 달")
            }
            .buttonStyle(.borderless)

            Button {
                manager.goToToday()
            } label: {
                Text("오늘")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.30), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.leading, 22)

            Spacer()

            Button {
                isShowingCalendarList.toggle()
            } label: {
                Image(systemName: hasFilters
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .help("보여줄 것 고르기")
            .popover(isPresented: $isShowingCalendarList, arrowEdge: .bottom) {
                CalendarFilterList(manager: manager)
            }

            Button {
                isShowingNotifications.toggle()
            } label: {
                Image(systemName: notificationIcon)
            }
            .buttonStyle(.borderless)
            .help("알림 상태")
            .padding(.leading, 10)
            .popover(isPresented: $isShowingNotifications, arrowEdge: .bottom) {
                NotificationStatusView(scheduler: scheduler)
            }

            Button {
                manager.loadCalendarsAndEvents()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("다시 불러오기")
            .padding(.leading, 10)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var hasFilters: Bool {
        !manager.hiddenCalendarIDs.isEmpty || !manager.showsTasks || !manager.showsTaskSpan
    }

    /// 알림이 꺼져 있으면 한눈에 보이게 한다.
    private var notificationIcon: String {
        switch scheduler.authorization {
        case .denied: return "bell.slash"
        case .notDetermined: return "bell"
        default: return "bell.badge"
        }
    }

    private var monthTitle: String {
        Self.monthFormatter.string(from: manager.displayedMonth)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "yyyy년 M월"
        return formatter
    }()
}

/// 그리드에 무엇을 보여줄지 고르는 목록.
struct CalendarFilterList: View {
    let manager: CalendarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("보여줄 것")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("전체 선택") { manager.showAllCalendars() }
                    .disabled(manager.hiddenCalendarIDs.isEmpty)
                Button("전체 해제") { manager.hideAllCalendars() }
                    .disabled(manager.hiddenCalendarIDs.count == manager.calendars.count)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Divider()

            Toggle(isOn: Binding(
                get: { manager.showsTasks },
                set: { manager.setShowsTasks($0) }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text("할 일")
                        .font(.caption)
                }
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: Binding(
                get: { manager.showsTaskSpan },
                set: { manager.setShowsTaskSpan($0) }
            )) {
                Text("마감까지 점선 표시")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(!manager.showsTasks)
            .padding(.leading, 16)

            Divider()

            if manager.calendars.isEmpty {
                Text("등록된 캘린더가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(manager.calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: Binding(
                                get: { manager.isVisible(calendar) },
                                set: { manager.setVisible($0, for: calendar) }
                            )) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(cgColor: calendar.cgColor))
                                        .frame(width: 9, height: 9)
                                    Text(calendar.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(calendar.source.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: - 요일 머리글

private struct WeekdayHeaderView: View {
    let headers: [WeekdayHeader]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(headers) { header in
                Text(header.symbol)
                    .font(.caption.bold())
                    .foregroundStyle(Color.weekdayLabel(for: header.weekday))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 20)
    }
}

// MARK: - 보조

extension Color {
    /// 일요일 빨강 / 토요일 파랑.
    static func weekdayLabel(for weekday: Int) -> Color {
        switch weekday {
        case 1: return .red
        case 7: return .blue
        default: return .primary
        }
    }

}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// 할 일에 마우스를 올렸을 때 나오는 미리보기.
/// 일정과 마찬가지로 여기서는 고치지 않는다.
struct TaskPreviewCard: View {
    let resolved: ResolvedTask
    var isEcho = false

    private var task: ManagedTask { resolved.task }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 그리드에서 잘려 보이던 제목을 온전히 보여준다.
            Text(task.title)
                .font(.headline)
                .strikethrough(task.status == .done)
                .fixedSize(horizontal: false, vertical: true)

            if let parentTitle = resolved.parentTitle {
                Label(parentTitle, systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let startDeadline = resolved.startDeadline {
                Label(
                    "\(StartlineFormat.spokenDayTime(startDeadline))에 시작",
                    systemImage: "flag"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let due = resolved.effectiveDueAt {
                Label(
                    "\(StartlineFormat.spokenDayTime(due))까지",
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let duration = task.estimatedDuration {
                Label(
                    "\(StartlineFormat.duration(duration)) 걸림",
                    systemImage: "hourglass"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if task.status == .done {
                    Text("완료")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                } else if task.status == .inProgress {
                    Text(TaskStatus.inProgress.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else if let judgment = resolved.judgment {
                    JudgmentBadge(judgment: judgment)
                }

                if isEcho {
                    Text("시작 시점이 지났어요")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
    }
}
