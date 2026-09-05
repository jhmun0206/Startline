//
//  MiniCalendarPicker.swift
//  Startline
//
//  부모 일정을 고르는 작은 월간 캘린더.
//
//  드롭다운 목록은 일정이 수십 건이면 훑을 수가 없다.
//  사람은 "언제쯤"으로 일정을 기억하므로 날짜에서 출발하게 한다.
//

import EventKit
import SwiftUI

struct MiniCalendarPicker: View {
    let manager: CalendarManager
    /// 고른 일정.
    @Binding var selection: EKEvent?
    /// 처음 펼칠 달·날짜의 기준.
    let anchorDate: Date

    @State private var month = Date()
    @State private var selectedDay = Date()
    @State private var eventsByDay: [Date: [EKEvent]] = [:]
    @State private var didLoad = false

    private var calendar: Calendar { manager.calendar }

    private var dayEvents: [EKEvent] {
        eventsByDay[calendar.startOfDay(for: selectedDay)] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            monthHeader
            weekdayHeader
            grid
            Divider()
            dayEventList
        }
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - 머리글

    private var monthHeader: some View {
        HStack(spacing: 6) {
            Text(Self.monthFormatter.string(from: month))
                .font(.callout.bold())
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help("이전 달")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .help("다음 달")
        }
        .buttonStyle(.borderless)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(manager.weekdayHeaders()) { header in
                Text(header.symbol)
                    .font(.caption2)
                    .foregroundStyle(Color.weekdayLabel(for: header.weekday))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 그리드

    private var grid: some View {
        let weeks = CalendarManager.gridDays(for: month, calendar: calendar).chunked(into: 7)

        return VStack(spacing: 2) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 2) {
                    ForEach(week, id: \.timeIntervalSinceReferenceDate) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isInMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let hasEvents = !(eventsByDay[calendar.startOfDay(for: day)] ?? []).isEmpty

        return VStack(spacing: 1) {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption)
                .foregroundStyle(numberColor(day, isInMonth: isInMonth, isSelected: isSelected))

            // 일정이 있는 날만 점을 찍는다.
            Circle()
                .fill(hasEvents ? (isSelected ? Color.white : Color.accentColor) : .clear)
                .frame(width: 3, height: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = calendar.startOfDay(for: day) }
    }

    private func numberColor(_ day: Date, isInMonth: Bool, isSelected: Bool) -> Color {
        if isSelected { return .white }
        let base = Color.weekdayLabel(for: calendar.component(.weekday, from: day))
        return isInMonth ? base : base.opacity(0.35)
    }

    // MARK: - 그 날의 일정

    @ViewBuilder
    private var dayEventList: some View {
        Text(Self.dayFormatter.string(from: selectedDay))
            .font(.caption.bold())
            .foregroundStyle(.secondary)

        if dayEvents.isEmpty {
            Text("이 날에는 일정이 없어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(dayEvents, id: \.self) { event in
                        eventRow(event)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        let isChosen = selection.map { same($0, event) } ?? false

        return HStack(spacing: 6) {
            Circle()
                .fill(event.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                .frame(width: 7, height: 7)

            Text(timeText(event))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(isChosen ? .white : .secondary)
                .frame(width: 42, alignment: .leading)

            Text(event.title ?? "(제목 없음)")
                .font(.caption)
                .foregroundStyle(isChosen ? .white : .primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isChosen {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isChosen ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selection = event }
    }

    private func timeText(_ event: EKEvent) -> String {
        guard !event.isAllDay, let start = event.startDate else { return "종일" }
        return Self.timeFormatter.string(from: start)
    }

    private func same(_ lhs: EKEvent, _ rhs: EKEvent) -> Bool {
        lhs.eventIdentifier == rhs.eventIdentifier && lhs.startDate == rhs.startDate
    }

    // MARK: - 로드

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        // 이미 고른 일정이 있으면 그 달을 펼친다.
        let anchor = selection?.startDate ?? anchorDate
        month = CalendarManager.startOfMonth(for: anchor, calendar: calendar)
        selectedDay = calendar.startOfDay(for: anchor)
        reload()
    }

    private func step(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        month = next
        reload()
    }

    private func reload() {
        eventsByDay = manager.eventsByDay(forMonth: month)
    }

    // MARK: - 형식

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .startlineDisplay
        f.dateFormat = "yyyy년 M월"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .startlineDisplay
        f.dateFormat = "M월 d일 (E)"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .startlineDisplay
        f.dateFormat = "HH:mm"
        return f
    }()
}
