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

    // Phase 1 의 항목 수는 적어서 전체를 읽고 메모리에서 거른다. (BL-017)
    @Query(sort: \ManagedTask.createdAt) private var allTasks: [ManagedTask]

    /// 착수 판정이 시간에 따라 바뀌므로 주기적으로 갱신한다.
    @State private var now = Date()
    @State private var editingTask: ManagedTask?
    @State private var isAddingTask = false
    /// 부모 일정이 사라져 독립 할 일로 전환된 항목들. (명세서 4.2)
    @State private var detachedTitles: [String] = []

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var resolver: TaskResolver {
        TaskResolver(manager: manager, now: now)
    }

    private var events: [DayEvent] {
        manager.events(on: manager.selectedDate)
    }

    private var resolvedTasks: [ResolvedTask] {
        resolver.resolve(allTasks)
    }

    /// 3계층 중 3계층 — 부모 없는 독립 할 일 가운데 선택 날짜가 마감인 것.
    private var independentTasks: [ResolvedTask] {
        resolvedTasks
            .filter { !$0.isAttached }
            .filter { resolved in
                guard let due = resolved.effectiveDueAt else { return false }
                return manager.calendar.isDate(due, inSameDayAs: manager.selectedDate)
            }
            .sorted { ($0.effectiveDueAt ?? .distantFuture) < ($1.effectiveDueAt ?? .distantFuture) }
    }

    /// 부모 일정 식별자 → 딸린 할 일. 2계층에서 일정 아래 들여쓰기로 붙인다.
    private var tasksByParent: [String: [ResolvedTask]] {
        Dictionary(grouping: resolvedTasks.filter(\.isAttached)) { $0.task.parentEventID ?? "" }
            .mapValues { group in
                group.sorted { ($0.effectiveDueAt ?? .distantFuture) < ($1.effectiveDueAt ?? .distantFuture) }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1계층 — 최상단 고정. 항목이 0개면 블록 자체가 사라진다. (명세서 5.2)
            TodayStartSection(tasks: resolvedTasks) { resolved in
                jump(to: resolved)
            }

            header
            Divider()

            List {
                eventSection
                if !independentTasks.isEmpty {
                    independentSection
                }
            }
            .listStyle(.inset)
        }
        .onReceive(clock) { now = $0 }
        .task(id: manager.displayedMonth) { syncLinks() }
        .sheet(isPresented: $isAddingTask) {
            TaskEditorView(task: nil, defaultDueDate: manager.selectedDate, manager: manager)
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(
                task: task,
                defaultDueDate: task.dueAt ?? manager.selectedDate,
                manager: manager
            )
        }
        .alert("일정이 사라져 할 일만 남겨뒀어요", isPresented: detachedAlertBinding) {
            Button("확인") { detachedTitles = [] }
        } message: {
            Text("\(detachedTitles.joined(separator: ", "))\n연결된 일정이 삭제돼서, 마지막 마감 그대로 따로 관리해요.")
        }
    }

    // MARK: - 2계층: 일정 + 딸린 할 일

    private var eventSection: some View {
        Section("일정") {
            if events.isEmpty {
                Text("일정이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { dayEvent in
                    EventRow(dayEvent: dayEvent, day: manager.selectedDate)

                    ForEach(attachedTasks(for: dayEvent)) { resolved in
                        TaskRow(
                            resolved: resolved,
                            isNested: true,
                            onEdit: { editingTask = resolved.task },
                            onDelete: { delete(resolved) }
                        )
                    }
                }
            }
        }
    }

    /// 이 일정에 딸린 할 일. 중복 등록분 중 어느 캘린더의 것을 골랐든 찾아낸다.
    private func attachedTasks(for dayEvent: DayEvent) -> [ResolvedTask] {
        let identifiers = Set(dayEvent.events.compactMap(\.eventIdentifier))
        return identifiers.flatMap { tasksByParent[$0] ?? [] }
            .sorted { ($0.effectiveDueAt ?? .distantFuture) < ($1.effectiveDueAt ?? .distantFuture) }
    }

    // MARK: - 3계층: 독립 할 일

    private var independentSection: some View {
        Section {
            TodoSectionContent(
                tasks: independentTasks,
                emptyText: "할 일이 없습니다.",
                onEdit: { editingTask = $0.task },
                onDelete: delete
            )
        } header: {
            Text("할 일")
        }
    }

    // MARK: - 머리글

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(dateTitle)
                    .font(.title3.bold())
                Spacer()
                Button {
                    isAddingTask = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("할 일 추가")
            }
            Text("일정 \(events.count)개 · 할 일 \(independentTasks.count)개")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 동작

    /// 부모 일정 상태를 저장값에 반영한다. 화면을 그리는 중이 아니라 여기서만 쓴다.
    private func syncLinks() {
        let detached = TaskLinkMaintenance.sync(tasks: allTasks, manager: manager, now: now)
        if !detached.isEmpty { detachedTitles = detached }
    }

    private func jump(to resolved: ResolvedTask) {
        guard let due = resolved.effectiveDueAt else { return }
        if !manager.isInDisplayedMonth(due) {
            manager.setDisplayedMonth(due)
        }
        manager.selectedDate = manager.calendar.startOfDay(for: due)
    }

    private func delete(_ resolved: ResolvedTask) {
        modelContext.delete(resolved.task)
    }

    private var detachedAlertBinding: Binding<Bool> {
        Binding(
            get: { !detachedTitles.isEmpty },
            set: { if !$0 { detachedTitles = [] } }
        )
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
