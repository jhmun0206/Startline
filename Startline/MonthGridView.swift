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
        let dayTasks = manager.showsTasks ? taskMap(in: days) : [:]

        return VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                WeekRow(
                    manager: manager,
                    days: week,
                    dayEvents: dayEvents,
                    dayTasks: dayTasks,
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

    /// 할 일을 그리드 날짜에 배정한다.
    ///
    /// **마감일이 아니라 시작일에 놓는다.** 마감일에 찍으면 일반 투두 앱과 다를 게 없다.
    /// 리드타임이 없으면 시작일 자체가 없으므로 마감일에 놓는다.
    /// 시작일이 지났는데 아직 시작하지 않았으면 오늘 칸에도 함께 띄운다 — 놓치면 안 되므로.
    private func taskMap(in days: [Date]) -> [Date: [ResolvedTask]] {
        guard let first = days.first, let last = days.last else { return [:] }

        let resolver = TaskResolver(manager: manager, now: now)
        let range = calendar.startOfDay(for: first)...calendar.startOfDay(for: last)
        let today = calendar.startOfDay(for: now)

        var map: [Date: [ResolvedTask]] = [:]

        for resolved in resolver.resolve(allTasks) {
            guard let anchor = gridDate(for: resolved) else { continue }

            if range.contains(anchor) {
                map[anchor, default: []].append(resolved)
            }

            // 시작 시점이 지났는데 미시작이면 오늘 칸에도 보여준다.
            if resolved.task.status == .notStarted,
               let startDeadline = resolved.startDeadline,
               startDeadline < now,
               anchor != today,
               range.contains(today) {
                map[today, default: []].append(resolved)
            }
        }

        for (day, list) in map {
            map[day] = list.sorted { lhs, rhs in
                let l = lhs.startDeadline ?? lhs.effectiveDueAt ?? .distantFuture
                let r = rhs.startDeadline ?? rhs.effectiveDueAt ?? .distantFuture
                if l != r { return l < r }
                return lhs.task.title < rhs.task.title
            }
        }
        return map
    }

    private func gridDate(for resolved: ResolvedTask) -> Date? {
        if case .none = resolved.task.leadTime {
            return resolved.effectiveDueAt.map { calendar.startOfDay(for: $0) }
        }
        let anchor = resolved.startDeadline ?? resolved.effectiveDueAt
        return anchor.map { calendar.startOfDay(for: $0) }
    }
}

// MARK: - 한 주

private struct WeekRow: View {
    let manager: CalendarManager
    let days: [Date]
    let dayEvents: [Date: [DayEvent]]
    let dayTasks: [Date: [ResolvedTask]]
    let now: Date
    let selectionRange: ClosedRange<Date>?
    let onSelect: (Date) -> Void
    let onAdd: (Date) -> Void
    let onOpenEvent: (DayEvent) -> Void
    let onOpenTask: (ResolvedTask) -> Void

    static let barHeight: CGFloat = 15
    static let barSpacing: CGFloat = 2
    static let numberRowHeight: CGFloat = 20

    private var calendar: Calendar { manager.calendar }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / 7
            let capacity = Self.capacity(forHeight: proxy.size.height)
            let layout = WeekLayout.build(
                days: days,
                dayEvents: dayEvents,
                dayTasks: dayTasks,
                capacity: capacity,
                calendar: calendar
            )

            ZStack(alignment: .topLeading) {
                cellBackgrounds

                // 막대는 칸 위에 겹쳐 그린다. 주 경계를 넘는 일정도 한 줄로 이어진다.
                ForEach(layout.segments) { segment in
                    segmentView(segment)
                        .frame(
                            width: max(0, columnWidth * CGFloat(segment.columnSpan) - 4),
                            height: Self.barHeight
                        )
                        .offset(
                            x: columnWidth * CGFloat(segment.startColumn) + 2,
                            y: Self.numberRowHeight + CGFloat(segment.lane) * (Self.barHeight + Self.barSpacing)
                        )
                }

                ForEach(Array(layout.overflowByColumn.keys.sorted()), id: \.self) { column in
                    if let count = layout.overflowByColumn[column] {
                        Text("+\(count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: max(0, columnWidth - 8), alignment: .leading)
                            .offset(
                                x: columnWidth * CGFloat(column) + 4,
                                y: Self.numberRowHeight + CGFloat(capacity) * (Self.barHeight + Self.barSpacing)
                            )
                    }
                }
            }
        }
    }

    private var cellBackgrounds: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.timeIntervalSinceReferenceDate) { day in
                DayCellBackground(
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
    private func segmentView(_ segment: GridSegment) -> some View {
        switch segment.kind {
        case .event(let dayEvent):
            EventBar(
                dayEvent: dayEvent,
                isDimmed: !manager.isInDisplayedMonth(days[segment.startColumn]),
                continuesBefore: segment.continuesBefore,
                continuesAfter: segment.continuesAfter,
                onOpen: { onOpenEvent(dayEvent) }
            )
        case .task(let resolved):
            TaskBar(resolved: resolved, onOpen: { onOpenTask(resolved) })
        }
    }

    /// 날짜 숫자 줄을 뺀 나머지에 몇 줄이 들어가는지.
    static func capacity(forHeight height: CGFloat) -> Int {
        let available = height - numberRowHeight - barSpacing - 3
        guard available > 0 else { return 0 }
        return max(0, Int((available + barSpacing) / (barHeight + barSpacing)))
    }
}

// MARK: - 날짜 칸 배경

private struct DayCellBackground: View {
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
                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                    .foregroundStyle(numberColor)
                    .frame(width: 19, height: 19)
                    .background {
                        if isToday {
                            // 선택 표시가 파란 테두리라, 오늘은 빨강으로 구분한다.
                            Circle().fill(Color.red)
                        }
                    }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .frame(height: WeekRow.numberRowHeight)

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
    let dayEvent: DayEvent
    let isDimmed: Bool
    let continuesBefore: Bool
    let continuesAfter: Bool
    let onOpen: () -> Void

    @State private var isShowingPreview = false
    @State private var hoverDelay: Task<Void, Never>?

    var body: some View {
        let color = dayEvent.primary.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray

        HStack(spacing: 2) {
            if continuesBefore {
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 8, weight: .bold))
            }
            // 제목은 막대 시작 부분에 한 번만.
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if continuesAfter {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(color.readableForeground)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            // 이어지는 쪽은 각지게, 끝나는 쪽은 둥글게 해서 연결을 드러낸다.
            UnevenRoundedRectangle(
                topLeadingRadius: continuesBefore ? 0 : 3,
                bottomLeadingRadius: continuesBefore ? 0 : 3,
                bottomTrailingRadius: continuesAfter ? 0 : 3,
                topTrailingRadius: continuesAfter ? 0 : 3
            )
            .fill(color.opacity(isDimmed ? 0.35 : 0.9))
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
/// 일정과 한눈에 구분되어야 한다. 일정은 채운 색, 할 일은 **테두리 + 체크 아이콘**이다.
/// 색은 판정을 따른다 — 여유 / 오늘 시작 / 늦음 / 완료.
private struct TaskBar: View {
    let resolved: ResolvedTask
    let onOpen: () -> Void

    private var task: ManagedTask { resolved.task }
    private var isDone: Bool { task.status == .done }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 8, weight: .bold))
            Text(task.title)
                .font(.system(size: 10, weight: .medium))
                .strikethrough(isDone)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(tint.opacity(0.55), lineWidth: 1)
        )
        .opacity(isDone ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(helpText)
    }

    private var tint: Color {
        if isDone { return .secondary }
        switch resolved.judgment {
        case .overdue: return .red
        case .startToday: return .orange
        case .relaxed, nil: return .accentColor
        }
    }

    private var helpText: String {
        var parts = [task.title]
        if let parentTitle = resolved.parentTitle { parts.append("→ \(parentTitle)") }
        if let deadline = resolved.startDeadline {
            parts.append("\(StartlineFormat.spokenDayTime(deadline))에 시작")
        }
        return parts.joined(separator: " · ")
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
        !manager.hiddenCalendarIDs.isEmpty || !manager.showsTasks
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

    /// 배경색 밝기에 따라 읽히는 전경색을 고른다.
    var readableForeground: Color {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * srgb.redComponent
            + 0.587 * srgb.greenComponent
            + 0.114 * srgb.blueComponent
        return luminance > 0.65 ? .black : .white
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
