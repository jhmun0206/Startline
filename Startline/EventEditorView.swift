//
//  EventEditorView.swift
//  Startline
//
//  일정 만들기 / 고치기 / 지우기. EventKit 에 직접 쓴다.
//
//  이 앱의 핵심 흐름은 "미팅을 잡으면서 준비할 일도 같이 만든다"이다.
//  그래서 폼 안에서 준비 할 일을 여러 개 함께 적고, 저장할 때 한꺼번에 만든다.
//

import EventKit
import SwiftData
import SwiftUI

struct EventEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceReporter.self) private var saver
    @Environment(DraftEventPreview.self) private var draft

    let manager: CalendarManager
    /// 고칠 일정. nil 이면 새로 만든다.
    let event: EKEvent?
    /// 새로 만들 때의 기준 시작 날짜.
    let defaultDate: Date
    /// 드래그로 고른 기간의 마지막 날. 없으면 하루짜리.
    var defaultEndDate: Date?

    @Query private var allTasks: [ManagedTask]

    @State private var title = ""
    @State private var startDay = Date()
    @State private var endDay = Date()
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var isAllDay = false
    @State private var selectedCalendarID: String?

    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    /// 일정을 저장할 때 함께 만들 할 일들. 폼 안에서 여러 개를 한 번에 적는다.
    @State private var draftTasks: [DraftTask] = []

    /// 이미 연결된 할 일의 편집 사본.
    ///
    /// 모델에 직접 묶으면 저장 버튼을 누르기 전에 반영돼, 일정 본문과 기준이 어긋난다.
    /// 시트 안에서는 사본만 고치고 저장할 때 한꺼번에 반영한다. (BL-037)
    @State private var linkedEdits: [LinkedTaskEdit] = []
    @State private var didLoadLinked = false

    /// 연결된 할 일 한 건의 편집 상태.
    struct LinkedTaskEdit: Identifiable {
        let id: UUID
        let task: ManagedTask
        var title: String
        var daysBefore: Int
        let originalTitle: String
        let originalDaysBefore: Int

        var isChanged: Bool {
            title != originalTitle || daysBefore != originalDaysBefore
        }
    }

    /// 폼 안에서만 쓰는 할 일 초안.
    struct DraftTask: Identifiable {
        let id = UUID()
        var title = ""
        /// 부모 일정 기준 며칠 전까지가 **마감**인지.
        var daysBefore = 1
        /// 소요시간. 고르면 착수일 역산이 켜진다.
        var duration: TimeInterval?
        /// 직접 입력 줄을 펼쳤는지.
        var isEnteringCustom = false
        var hours = 0
        var minutes = 0

        /// 직접 입력값을 반영한 최종 소요시간.
        var resolvedDuration: TimeInterval? {
            if isEnteringCustom {
                let total = TimeInterval(hours * 3600 + minutes * 60)
                return total > 0 ? total : nil
            }
            return duration
        }
    }

    /// 폼 한 줄에 들어가는 프리셋. 폭이 좁아 셋으로 줄였다.
    private static let inlinePresets: [DurationPreset] = Array(DurationPreset.all.prefix(3))

    private var isEditing: Bool { event != nil }

    /// 구독·생일 캘린더의 일정은 고칠 수 없다.
    private var isReadOnly: Bool {
        guard let event else { return false }
        return !manager.isEditable(event)
    }

    private var isRecurring: Bool { event?.hasRecurrenceRules == true }

    /// 이 일정에 딸린 할 일 개수. 삭제 확인 문구에 쓴다.
    private var attachedTaskCount: Int {
        guard let identifier = event?.eventIdentifier else { return 0 }
        return allTasks.filter { $0.parentEventID == identifier }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isReadOnly {
                readOnlyBody
            } else {
                editableBody
            }
        }
        .frame(width: SheetMetrics.width)
        .onAppear(perform: load)
        .onAppear(perform: loadLinkedTasks)
        // 시트에 적힌 날짜를 캘린더에서 눈으로 확인할 수 있어야 한다.
        // 새 일정을 만드는 동안 그리드에 임시 막대를 띄우고, 날짜를 바꾸면 따라 움직인다.
        .onAppear(perform: syncDraft)
        .onChange(of: startDay) { _, _ in syncDraft() }
        .onChange(of: endDay) { _, _ in syncDraft() }
        .onChange(of: isAllDay) { _, _ in syncDraft() }
        .onDisappear { draft.clear() }
    }

    // MARK: - 읽기 전용

    /// 고칠 수 없는 일정은 편집 폼을 열지 않고 내용과 이유만 보여준다.
    /// 고칠 수 없는 일정은 편집 폼을 열지 않고 내용과 이유만 보여준다.
    private var readOnlyBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "일정 보기") { dismiss() }

            VStack(alignment: .leading, spacing: 10) {
                SheetField {
                    Text(event?.title ?? "(제목 없음)")
                        .font(.title3)
                }
                SheetField {
                    Text(eventTimeSummary)
                }
                if let location = event?.location, !location.isEmpty {
                    SheetField {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                }
                SheetField {
                    CalendarLabel(calendar: event?.calendar)
                }

                Label(
                    "‘\(event?.calendar?.title ?? "이 캘린더")’는 구독하거나 자동으로 만들어진 캘린더라 Startline에서 고칠 수 없어요. 원래 만든 곳에서 바꿔 주세요.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SheetMetrics.padding)
            .padding(.bottom, 14)

            Divider()
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    // MARK: - 편집 가능

    private var editableBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: isEditing ? "일정 수정" : "일정 추가",
                hasUnsavedInput: hasUnsavedInput
            ) { dismiss() }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // 라벨 대신 플레이스홀더가 무엇을 넣는 칸인지 말한다.
                    SheetTextField(
                        placeholder: "새로운 일정",
                        text: $title,
                        font: .title3
                    )

                    whenField
                    calendarField

                    taskSection
                    if isRecurring { recurringNote }
                    if !isRangeValid {
                        errorNote("끝나는 시각이 시작하는 시각보다 빨라요.")
                    }
                    if let errorMessage { errorNote(errorMessage) }
                }
                .padding(.horizontal, SheetMetrics.padding)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: SheetMetrics.maxContentHeight)

            Divider()
            footer
        }
        .alert("이 일정을 지울까요?", isPresented: $isConfirmingDelete) {
            if isRecurring {
                Button("이 일정만", role: .destructive) { delete(span: .thisEvent) }
                Button("이후 모든 일정", role: .destructive) { delete(span: .futureEvents) }
            } else {
                Button("지우기", role: .destructive) { delete(span: .thisEvent) }
            }
            Button("그만두기", role: .cancel) {}
        } message: {
            Text(deleteWarning)
        }
    }

    /// 시작과 끝을 각각 날짜 + 시각으로 받는다. 여러 날에 걸친 일정을 만들 수 있어야 한다.
    private var whenField: some View {
        SheetField {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("시작")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)
                    DatePicker("", selection: $startDay, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    if !isAllDay {
                        DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text("끝")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)
                    DatePicker("", selection: $endDay, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    if !isAllDay {
                        DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    Spacer(minLength: 0)
                }

                Toggle("하루 종일", isOn: $isAllDay)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .environment(\.locale, .startlineDisplay)
    }

    @ViewBuilder
    private var calendarField: some View {
        if manager.writableCalendars.isEmpty {
            SheetField {
                Text("새 일정을 넣을 수 있는 캘린더가 없어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            CalendarPickerField(
                calendars: manager.writableCalendars,
                selectedID: $selectedCalendarID
            )
        }
    }

    private var recurringNote: some View {
        Label("반복되는 일정이에요. 고치면 이 회차만 바뀌어요.", systemImage: "repeat")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func errorNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("삭제", role: .destructive) { isConfirmingDelete = true }
            }
            Spacer()
            Button(isEditing ? "저장" : "만들기") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          || manager.writableCalendars.isEmpty
                          || !isRangeValid)
        }
        .padding(16)
    }

    // MARK: - 이 일정 전에 할 일

    /// 이 일정 전에 미리 할 일.
    ///
    /// 만들 때뿐 아니라 **고칠 때도 붙일 수 있어야 한다.** 이미 연결된 할 일은
    /// 여기서 바로 고치고 지운다. (명세서 8장)
    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이 일정 전에 미리 할 일")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($linkedEdits) { $edit in
                AttachedTaskRow(edit: $edit) {
                    // 지우기는 저장할 때 반영된다.
                    linkedEdits.removeAll { $0.id == edit.id }
                }
            }

            ForEach($draftTasks) { $draft in
                draftRow($draft)
            }

            Button {
                draftTasks.append(DraftTask())
            } label: {
                Label("할 일 추가", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    /// 한 줄에 제목 · 마감 시점 · 소요시간을 모두 담는다.
    private func draftRow(_ draft: Binding<DraftTask>) -> some View {
        SheetField(verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("무엇을 미리 해둘까요", text: draft.title)
                        .textFieldStyle(.plain)
                        .font(.callout)

                    Stepper(value: draft.daysBefore, in: 0...365) {
                        // "며칠 전"이 마감이라는 것을 문구로 드러낸다.
                        Text(draft.wrappedValue.daysBefore == 0 ? "당일까지" : "\(draft.wrappedValue.daysBefore)일 전까지")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .fixedSize()

                    Button {
                        draftTasks.removeAll { $0.id == draft.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("이 줄 지우기")
                }

                HStack(spacing: 4) {
                    Text("얼마나")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(Self.inlinePresets) { preset in
                        durationChip(preset.label, draft: draft) {
                            draft.wrappedValue.duration == preset.duration
                                && !draft.wrappedValue.isEnteringCustom
                        } action: {
                            draft.wrappedValue.isEnteringCustom = false
                            draft.wrappedValue.duration =
                                draft.wrappedValue.duration == preset.duration ? nil : preset.duration
                        }
                    }

                    durationChip("직접", draft: draft) {
                        draft.wrappedValue.isEnteringCustom
                    } action: {
                        draft.wrappedValue.isEnteringCustom.toggle()
                        if draft.wrappedValue.isEnteringCustom { draft.wrappedValue.duration = nil }
                    }

                    if draft.wrappedValue.isEnteringCustom {
                        TextField("0", value: draft.hours, format: .number)
                            .textFieldStyle(.plain)
                            .frame(width: 26)
                            .multilineTextAlignment(.trailing)
                        Text("시간").font(.caption2)
                        TextField("0", value: draft.minutes, format: .number)
                            .textFieldStyle(.plain)
                            .frame(width: 26)
                            .multilineTextAlignment(.trailing)
                        Text("분").font(.caption2)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func durationChip(
        _ label: String,
        draft: Binding<DraftTask>,
        isOn: () -> Bool,
        action: @escaping () -> Void
    ) -> some View {
        let on = isOn()
        return Text(label)
            .font(.caption2)
            .fontWeight(on ? .semibold : .regular)
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(on ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// 이 일정에 이미 붙어 있는 할 일.
    private var attachedTasks: [ManagedTask] {
        guard let identifier = event?.eventIdentifier else { return [] }
        return allTasks
            .filter { $0.parentEventID == identifier }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    /// 그리드의 임시 막대를 지금 입력값에 맞춘다.
    ///
    /// 기존 일정을 고칠 때는 실제 막대가 이미 있으므로 띄우지 않는다.
    private func syncDraft() {
        guard !isEditing else { return }
        let range = resolvedRange()
        draft.set(start: range.start, end: max(range.end, range.start))
    }

    /// 연결된 할 일을 편집 사본으로 옮긴다.
    private func loadLinkedTasks() {
        guard !didLoadLinked else { return }
        didLoadLinked = true

        let dayLength: TimeInterval = 24 * 60 * 60
        linkedEdits = attachedTasks.map { task in
            let days = task.offsetFromParent.map { max(0, Int((-$0 / dayLength).rounded())) } ?? 0
            return LinkedTaskEdit(
                id: task.id,
                task: task,
                title: task.title,
                daysBefore: days,
                originalTitle: task.title,
                originalDaysBefore: days
            )
        }
    }

    /// 저장 시점에 연결된 할 일 변경을 한꺼번에 반영한다.
    private func applyLinkedEdits(eventStart: Date) {
        let dayLength: TimeInterval = 24 * 60 * 60
        let keptIDs = Set(linkedEdits.map(\.id))

        // 목록에서 뺀 것은 지운다.
        for task in attachedTasks where !keptIDs.contains(task.id) {
            modelContext.delete(task)
        }

        for edit in linkedEdits where edit.isChanged {
            let trimmed = edit.title.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { edit.task.title = trimmed }

            let offset = -TimeInterval(edit.daysBefore) * dayLength
            edit.task.offsetFromParent = offset
            edit.task.dueAt = eventStart.addingTimeInterval(offset)
        }
    }

    /// 끝이 시작보다 이르면 저장을 막는다.
    private var isRangeValid: Bool {
        let range = resolvedRange()
        return range.end >= range.start
    }

    /// 저장하지 않은 입력이 있는지. 닫기를 눌렀을 때 되물을지 판단한다.
    private var hasUnsavedInput: Bool {
        if isEditing {
            guard let event else { return false }
            if linkedEdits.contains(where: \.isChanged) { return true }
            if linkedEdits.count != attachedTasks.count { return true }
            if draftTasks.contains(where: { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return true
            }
            return title != (event.title ?? "")
                || isAllDay != event.isAllDay
                || !manager.calendar.isDate(startDay, inSameDayAs: event.startDate ?? startDay)
        }
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
            || draftTasks.contains { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - 문구

    private var eventTimeSummary: String {
        guard let event, let start = event.startDate else { return "-" }
        if event.isAllDay {
            return "\(StartlineFormat.spokenDay.string(from: start)) 종일"
        }
        let end = event.endDate ?? start
        return "\(StartlineFormat.spokenDayTime(start)) ~ \(Self.timeFormatter.string(from: end))"
    }

    /// 되돌릴 수 없고 다른 기기까지 번지는 일이라, 무슨 일이 벌어지는지 그대로 적는다.
    private var deleteWarning: String {
        var lines = ["‘\(event?.title ?? "")’를 지우면 되돌릴 수 없어요. 연결된 계정과 다른 기기에서도 사라져요."]
        if attachedTaskCount > 0 {
            lines.append("이 일정에 연결된 할 일 \(attachedTaskCount)개는 삭제되지 않고 남습니다.")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - 로드 / 저장 / 삭제

    private func load() {
        let calendar = manager.calendar

        guard let event else {
            startDay = defaultDate
            endDay = defaultEndDate ?? defaultDate
            startTime = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: defaultDate) ?? defaultDate
            endTime = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: defaultDate) ?? defaultDate
            // 드래그로 여러 날을 고른 경우엔 종일 일정이 자연스럽다.
            isAllDay = defaultEndDate.map { !calendar.isDate($0, inSameDayAs: defaultDate) } ?? false
            selectedCalendarID = manager.defaultWritableCalendar?.calendarIdentifier
            return
        }

        title = event.title ?? ""
        isAllDay = event.isAllDay

        let start = event.startDate ?? defaultDate
        let end = WeekLayout.adjustedEnd(of: event, calendar: calendar) ?? start

        startDay = start
        startTime = start
        endDay = end
        endTime = end
        selectedCalendarID = event.calendar?.calendarIdentifier
            ?? manager.defaultWritableCalendar?.calendarIdentifier
    }

    /// 날짜와 시각을 합친다.
    private func combined(day: Date, time: Date) -> Date {
        let calendar = manager.calendar
        let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)

        var parts = DateComponents()
        parts.year = dayParts.year
        parts.month = dayParts.month
        parts.day = dayParts.day
        parts.hour = timeParts.hour
        parts.minute = timeParts.minute
        return calendar.date(from: parts) ?? time
    }

    private func resolvedRange() -> (start: Date, end: Date) {
        let calendar = manager.calendar
        guard isAllDay else {
            return (combined(day: startDay, time: startTime), combined(day: endDay, time: endTime))
        }

        let start = calendar.startOfDay(for: startDay)
        let lastDay = calendar.startOfDay(for: max(endDay, startDay))
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay)?
            .addingTimeInterval(-1) ?? start
        return (start, end)
    }

    private func save() {
        errorMessage = nil

        guard let targetCalendar = manager.writableCalendars.first(
            where: { $0.calendarIdentifier == selectedCalendarID }
        ) ?? manager.defaultWritableCalendar else {
            errorMessage = CalendarManager.WriteError.noWritableCalendar.errorDescription
            return
        }

        let range = resolvedRange()

        do {
            if let event {
                try manager.updateEvent(
                    event,
                    title: title,
                    calendar: targetCalendar,
                    start: range.start,
                    end: range.end,
                    isAllDay: isAllDay,
                    span: .thisEvent
                )
                applyLinkedEdits(eventStart: range.start)
                createDraftTasks(for: event, eventStart: range.start)
                saver.commit(modelContext)
                dismiss()
            } else {
                let created = try manager.createEvent(
                    title: title,
                    calendar: targetCalendar,
                    start: range.start,
                    end: range.end,
                    isAllDay: isAllDay
                )
                createDraftTasks(for: created, eventStart: range.start)
                dismiss()
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 폼에 적어둔 할 일들을 이 일정에 딸린 할 일로 만든다.
    private func createDraftTasks(for event: EKEvent, eventStart: Date) {
        guard let parentEventID = event.eventIdentifier else { return }

        for draft in draftTasks {
            let trimmed = draft.title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let offset = -TimeInterval(draft.daysBefore) * 24 * 60 * 60
            let duration = draft.resolvedDuration

            let task = ManagedTask(
                title: trimmed,
                parentEventID: parentEventID,
                parentOccurrenceDate: eventStart,
                offsetFromParent: offset,
                lastKnownDueAt: eventStart.addingTimeInterval(offset),
                estimatedDuration: duration,
                // 소요시간을 골랐으면 역산한다. 아니면 그날까지 하는 일로 둔다.
                leadTime: duration == nil ? .fixed(days: 0) : .durationBased
            )
            modelContext.insert(task)
        }
        draftTasks.removeAll()
        saver.commit(modelContext)
    }

    private func delete(span: EKSpan) {
        guard let event else { return }
        errorMessage = nil
        do {
            try manager.deleteEvent(event, span: span)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .startlineDisplay
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - 이미 붙어 있는 할 일 한 줄

/// 일정 수정 시트에서 연결된 할 일을 고친다.
///
/// **모델이 아니라 편집 사본에 묶는다.** 저장을 눌러야 반영되는 일정 본문과
/// 기준을 맞추기 위해서다. 그만두면 아무것도 남지 않는다. (BL-037)
private struct AttachedTaskRow: View {
    @Binding var edit: EventEditorView.LinkedTaskEdit
    let onRemove: () -> Void

    var body: some View {
        SheetField(verticalPadding: 5) {
            HStack(spacing: 6) {
                Image(systemName: edit.task.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(edit.task.status == .done ? Color.accentColor : .secondary)

                TextField("제목", text: $edit.title)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .strikethrough(edit.task.status == .done)

                Stepper(value: $edit.daysBefore, in: 0...365) {
                    Text(edit.daysBefore == 0 ? "당일까지" : "\(edit.daysBefore)일 전까지")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
                .fixedSize()

                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("이 할 일 지우기")
            }
        }
    }
}
