//
//  MonthGridView.swift
//  Startline
//
//  명세서 4.2 좌측 — 월간 그리드.
//  일정을 점(dot)이 아니라 제목이 보이는 색상 바로 표시한다. (명세서 4.1)
//

import EventKit
import UserNotifications
import SwiftUI

struct MonthGridView: View {
    let manager: CalendarManager
    /// 그리드에서 일정을 클릭했을 때.
    let onOpenEvent: (DayEvent) -> Void
    /// 빈 곳을 더블클릭해 그 날짜로 새 항목을 만들 때.
    let onAddOnDate: (Date) -> Void
    let scheduler: NotificationScheduler

    var body: some View {
        VStack(spacing: 0) {
            MonthHeaderView(manager: manager, scheduler: scheduler)
            Divider()
            WeekdayHeaderView(headers: manager.weekdayHeaders())
            Divider()
            grid
        }
    }

    /// 표시 중인 한 달을 그린다.
    ///
    /// `manager.displayedMonth` 하나만 보고 그린다. 화면에 보이는 달과 머리글이
    /// 어긋날 수 없도록 기준을 하나로 유지한다. (BL-002 실패 원인)
    private var grid: some View {
        let calendar = manager.calendar
        let month = manager.displayedMonth
        let dayEvents = manager.dayEvents(forMonth: month)
        let weeks = CalendarManager.gridDays(for: month, calendar: calendar).chunked(into: 7)

        return VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.timeIntervalSinceReferenceDate) { day in
                        DayCell(
                            date: day,
                            dayNumber: calendar.component(.day, from: day),
                            events: dayEvents[calendar.startOfDay(for: day)] ?? [],
                            isInMonth: manager.isInDisplayedMonth(day),
                            isToday: calendar.isDateInToday(day),
                            isSelected: calendar.isDate(day, inSameDayAs: manager.selectedDate),
                            onSelect: {
                                manager.selectedDate = calendar.startOfDay(for: day)
                            },
                            onAdd: {
                                manager.selectedDate = calendar.startOfDay(for: day)
                                onAddOnDate(calendar.startOfDay(for: day))
                            },
                            onOpenEvent: { dayEvent in
                                manager.selectedDate = calendar.startOfDay(for: day)
                                onOpenEvent(dayEvent)
                            }
                        )
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        // 캐시가 비워지면 다시 그린다.
        .id(manager.dataRevision)
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
            Text(monthTitle)
                .font(.title2.bold())

            // ‹ › 는 달 이름에 바로 붙여 같은 덩어리로 읽히게 한다.
            HStack(spacing: 2) {
                Button { manager.goToPreviousMonth() } label: { Image(systemName: "chevron.left") }
                    .help("이전 달")
                Button { manager.goToNextMonth() } label: { Image(systemName: "chevron.right") }
                    .help("다음 달")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 6)

            // 「오늘」은 성격이 다른 동작이라 간격을 두고 버튼처럼 보이게 한다.
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
                Image(systemName: hasHiddenCalendars
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .help("보여줄 캘린더 고르기")
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

    private var hasHiddenCalendars: Bool { !manager.hiddenCalendarIDs.isEmpty }

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

/// 보여줄 캘린더를 고르는 목록. 체크를 끄면 그리드와 우측 패널 양쪽에서 빠진다.
struct CalendarFilterList: View {
    let manager: CalendarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("보여줄 캘린더")
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
                .frame(maxHeight: 300)
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

// MARK: - 날짜 칸

private struct DayCell: View {
    let date: Date
    let dayNumber: Int
    let events: [DayEvent]
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    /// 빈 곳 더블클릭.
    let onAdd: () -> Void
    let onOpenEvent: (DayEvent) -> Void

    private static let barHeight: CGFloat = 15
    private static let barSpacing: CGFloat = 2
    private static let numberRowHeight: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let capacity = Self.capacity(forHeight: proxy.size.height)

            VStack(alignment: .leading, spacing: Self.barSpacing) {
                dayNumberView
                    .frame(height: Self.numberRowHeight)

                ForEach(visibleEvents(capacity: capacity)) { dayEvent in
                    EventBar(
                        dayEvent: dayEvent,
                        isDimmed: !isInMonth,
                        onOpen: { onOpenEvent(dayEvent) }
                    )
                    .frame(height: Self.barHeight)
                }

                if let overflow = overflowCount(capacity: capacity) {
                    Text("+\(overflow)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .frame(height: Self.barHeight, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        }
        .contentShape(Rectangle())
        // 더블클릭을 먼저 선언해야 한 번 클릭과 구분된다.
        // 일정 바는 자기 탭을 먹으므로 여기까지 오지 않는다 — 바 더블클릭은 수정 시트로 간다.
        .onTapGesture(count: 2, perform: onAdd)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var dayNumberView: some View {
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
        .padding(.leading, 1)
    }

    private var numberColor: Color {
        if isToday { return .white }
        let base = Color.weekdayLabel(for: Calendar.current.component(.weekday, from: date))
        return isInMonth ? base : base.opacity(0.35)
    }

    /// 칸 높이에서 날짜 숫자 줄을 뺀 나머지에 몇 개의 바가 들어가는지.
    private static func capacity(forHeight height: CGFloat) -> Int {
        let available = height - numberRowHeight - barSpacing - 3
        guard available > 0 else { return 0 }
        return max(0, Int((available + barSpacing) / (barHeight + barSpacing)))
    }

    /// 전부 들어가면 전부, 넘치면 "+N" 자리를 한 칸 비워둔다.
    private func visibleEvents(capacity: Int) -> [DayEvent] {
        guard events.count > capacity else { return events }
        return Array(events.prefix(max(0, capacity - 1)))
    }

    private func overflowCount(capacity: Int) -> Int? {
        guard events.count > capacity else { return nil }
        let hidden = events.count - max(0, capacity - 1)
        return hidden > 0 ? hidden : nil
    }
}

/// 일정 한 건을 나타내는 색상 바. 제목이 바 안에 직접 보인다.
/// 칸이 좁으므로 시각은 넣지 않는다. 시각은 마우스를 올리면 나오는 미리보기와 우측 패널에서 본다.
private struct EventBar: View {
    let dayEvent: DayEvent
    let isDimmed: Bool
    let onOpen: () -> Void

    @State private var isShowingPreview = false
    @State private var hoverDelay: Task<Void, Never>?

    var body: some View {
        let color = dayEvent.primary.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray

        Text(title)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(color.readableForeground)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(isDimmed ? 0.35 : 0.9))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                cancelHover()
                onOpen()
            }
            .onHover { hovering in
                if hovering {
                    // 칸 위를 스쳐 지나갈 때마다 뜨지 않도록 잠깐 기다린다.
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

/// 마우스를 올렸을 때 나오는 미리보기.
///
/// **여기서는 고치지 않는다.** 마우스가 벗어나면 사라지는 화면에 편집을 넣으면
/// 조작하다가 놓치기 쉽다. 고치는 것은 클릭해서 여는 시트가 맡는다.
struct EventPreviewCard: View {
    let dayEvent: DayEvent

    private var event: EKEvent { dayEvent.primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 그리드에서 잘려 보이던 제목을 여기서는 온전히 보여준다.
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
            return "\(StartlineFormat.spokenDay.string(from: start)) 종일"
        }
        let end = event.endDate ?? start
        return "\(StartlineFormat.spokenDayTime(start)) ~ \(Self.timeFormatter.string(from: end))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .startlineDisplay
        f.dateFormat = "HH:mm"
        return f
    }()
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
