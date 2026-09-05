//
//  DayDetailView.swift
//  Startline
//
//  명세서 4.2 우측 — 「오늘 착수」 + 선택된 날짜의 일정 + TO-DO.
//

import Combine
import EventKit
import SwiftData
import SwiftUI

struct DayDetailView: View {
    let manager: CalendarManager

    @Environment(\.modelContext) private var modelContext

    // Phase 1 의 항목 수는 적어서 전체를 읽고 메모리에서 거른다.
    @Query(sort: \ManagedTask.dueAt) private var allTasks: [ManagedTask]

    /// 착수 판정이 시간에 따라 바뀌므로 주기적으로 갱신한다.
    @State private var now = Date()
    @State private var editingTask: ManagedTask?
    @State private var isAddingTask = false

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var events: [DayEvent] {
        manager.events(on: manager.selectedDate)
    }

    /// 선택된 날짜가 마감인 할 일.
    private var tasksForSelectedDate: [ManagedTask] {
        allTasks.filter {
            manager.calendar.isDate($0.dueAt, inSameDayAs: manager.selectedDate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 명세서 4.1 — 최상단 고정. 항목이 0개면 블록 자체가 사라진다.
            TodayStartSection(tasks: allTasks, now: now) { task in
                manager.selectedDate = manager.calendar.startOfDay(for: task.dueAt)
                if !manager.isInDisplayedMonth(task.dueAt) {
                    manager.setDisplayedMonth(task.dueAt)
                    manager.selectedDate = manager.calendar.startOfDay(for: task.dueAt)
                }
            }

            header
            Divider()

            List {
                Section("일정") {
                    if events.isEmpty {
                        Text("일정이 없습니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { dayEvent in
                            EventRow(dayEvent: dayEvent, day: manager.selectedDate)
                        }
                    }
                }

                Section {
                    TodoSectionContent(
                        tasks: tasksForSelectedDate,
                        now: now,
                        onEdit: { editingTask = $0 },
                        onDelete: delete
                    )
                } header: {
                    HStack {
                        Text("TO-DO")
                        Spacer()
                        Button {
                            isAddingTask = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("할 일 추가")
                    }
                }
            }
            .listStyle(.inset)
        }
        .onReceive(clock) { now = $0 }
        .sheet(isPresented: $isAddingTask) {
            TaskEditorView(task: nil, defaultDueDate: manager.selectedDate)
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task, defaultDueDate: task.dueAt)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dateTitle)
                .font(.title3.bold())
            Text("일정 \(events.count)개 · 할 일 \(tasksForSelectedDate.count)개")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func delete(_ task: ManagedTask) {
        modelContext.delete(task)
    }

    private var dateTitle: String {
        Self.dateFormatter.string(from: manager.selectedDate)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "yyyy년 M월 d일 (E)"
        return formatter
    }()
}

/// 일정 한 행 — [시각] [제목] [소속 캘린더명]
struct EventRow: View {
    let dayEvent: DayEvent
    /// 이 행이 놓인 날짜. 여러 날에 걸친 일정의 시각 표기에 쓴다.
    let day: Date

    private var event: EKEvent { dayEvent.primary }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(timeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(event.title ?? "(제목 없음)")
                    .font(.body)

                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                calendarLabel
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 중복 등록된 일정은 어느 캘린더들에 있는지 모두 보여준다.
    private var calendarLabel: some View {
        HStack(spacing: 4) {
            ForEach(Array(dayEvent.events.enumerated()), id: \.offset) { _, source in
                HStack(spacing: 3) {
                    Circle()
                        .fill(source.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                        .frame(width: 6, height: 6)
                    Text(source.calendar?.title ?? "(캘린더 없음)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 종일이면 "종일", 아니면 "HH:mm – HH:mm".
    /// 이 날 이전에 시작했거나 이후까지 이어지면 말줄임표로 표시한다.
    private var timeText: String {
        guard let start = event.startDate else { return "-" }
        if event.isAllDay { return "종일" }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let end = event.endDate ?? start

        let startText = start < dayStart ? "…" : Self.timeFormatter.string(from: start)
        let endText = end >= dayEnd ? "…" : Self.timeFormatter.string(from: end)
        return "\(startText) – \(endText)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
