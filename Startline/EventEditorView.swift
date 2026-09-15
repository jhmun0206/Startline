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
    /// 이 화면이 대표하는 **묶음 전체**. 여러 캘린더에 같은 일정이 등록된 경우 2건 이상이 된다.
    ///
    /// 삭제는 묶음 전체가 대상이다. 예전에는 대표 일정 하나만 지워서, 화면에서는
    /// 사라진 것처럼 보이는데 실제로는 남아 있는 일정이 생겼다. (BL-048)
    var groupedEvents: [EKEvent] = []
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
    /// 반복 일정을 고칠 때 적용 범위를 묻는 중.
    @State private var isConfirmingRecurringSave = false

    /// 같은 시트 안에서 세부 편집으로 들어간 할 일. 값이 있으면 할 일 폼이 뜬다.
    @State private var editingLinkedTask: ManagedTask?

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
        /// 「며칠 전까지」의 직접 입력 줄을 펼쳤는지.
        var isEnteringCustomDays = false
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

    /// 실제로 지울 일정들. 묶음이 전달되지 않았으면 대표 일정 하나뿐이다.
    private var deleteTargets: [EKEvent] {
        guard let event else { return [] }
        return groupedEvents.isEmpty ? [event] : groupedEvents
    }

    /// 이 일정에 딸린 할 일 개수. 삭제 확인 문구에 쓴다.
    private var attachedTaskCount: Int {
        guard let identifier = event?.eventIdentifier else { return 0 }
        return allTasks.filter { $0.parentEventID == identifier }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let task = editingLinkedTask {
                // 같은 시트 자리에서 내용만 바꾼다. 일정 폼의 미저장 내용은
                // @State 로 그대로 남아 있으므로 돌아오면 이어서 쓸 수 있다.
                TaskEditorView(
                    task: task,
                    defaultDueDate: task.dueAt ?? defaultDate,
                    manager: manager,
                    backTitle: "일정으로",
                    onFinish: returnFromLinkedTask
                )
            } else if isReadOnly {
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
        .alert("어디까지 바꿀까요?", isPresented: $isConfirmingRecurringSave) {
            Button("이 일정만") { performSave(span: .thisEvent) }
            Button("이후 모든 일정") { performSave(span: .futureEvents) }
            Button("그만두기", role: .cancel) {}
        } message: {
            Text("반복되는 일정이에요. 이후 회차까지 바꾸면 되돌릴 수 없어요.")
        }
        .alert(deleteTitle, isPresented: $isConfirmingDelete) {
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
        Label("반복되는 일정이에요. 저장할 때 어디까지 바꿀지 고릅니다.", systemImage: "repeat")
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
                AttachedTaskRow(
                    edit: $edit,
                    onOpen: { editingLinkedTask = edit.task },
                    onRemove: {
                        // 지우기는 저장할 때 반영된다.
                        linkedEdits.removeAll { $0.id == edit.id }
                    }
                )
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

                    Button {
                        draftTasks.removeAll { $0.id == draft.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("이 줄 지우기")
                }

                DaysBeforeChips(
                    label: "언제까지",
                    daysBefore: draft.daysBefore,
                    isEnteringCustom: draft.isEnteringCustomDays
                )

                HStack(spacing: 4) {
                    // 독립 「할 일」 시트가 같은 것을 「얼마나 걸릴까요」로 부른다.
                    // 한 가지를 두 곳에서 다르게 부르지 않는다.
                    Text("얼마나 걸릴까요")
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
        // 모양은 `SheetChip` 하나로 모았다. 보이는 결과는 종전과 같다.
        SheetChip(label: label, isOn: isOn(), action: action)
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

    /// 할 일 세부 편집을 마치고 일정 폼으로 돌아온다.
    ///
    /// 할 일 쪽 변경은 그 폼에서 이미 저장됐으므로 목록을 다시 읽어 반영한다.
    /// 지워졌으면 목록에서 사라진다.
    private func returnFromLinkedTask() {
        editingLinkedTask = nil
        didLoadLinked = false
        loadLinkedTasks()
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

    private var deleteTitle: String {
        deleteTargets.count > 1 ? "\(deleteTargets.count)개를 함께 지울까요?" : "이 일정을 지울까요?"
    }

    /// 되돌릴 수 없고 다른 기기까지 번지는 일이라, 무슨 일이 벌어지는지 그대로 적는다.
    private var deleteWarning: String {
        var lines = ["‘\(event?.title ?? "")’를 지우면 되돌릴 수 없어요. 연결된 계정과 다른 기기에서도 사라져요."]

        // 한 줄로 보이지만 실제로는 여러 건인 경우. 몇 개가 어디서 사라지는지 밝힌다.
        if deleteTargets.count > 1 {
            let names = deleteTargets
                .map { $0.calendar?.title ?? "(캘린더 없음)" }
                .joined(separator: " · ")
            lines.append("이 줄에는 일정 \(deleteTargets.count)개가 묶여 있어요. \(names) 에서 모두 사라져요.")
        }

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
        // 반복 일정을 고칠 때는 삭제와 같은 수준으로 범위를 묻는다. (BL-024)
        if isEditing, isRecurring {
            isConfirmingRecurringSave = true
            return
        }
        performSave(span: .thisEvent)
    }

    private func performSave(span: EKSpan) {
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
                    span: span
                )
                applyLinkedEdits(eventStart: range.start)
                createDraftTasks(for: event, eventStart: range.start)
                saver.commit(modelContext)
                finishWithoutShaking()
            } else {
                let created = try manager.createEvent(
                    title: title,
                    calendar: targetCalendar,
                    start: range.start,
                    end: range.end,
                    isAllDay: isAllDay
                )
                createDraftTasks(for: created, eventStart: range.start)
                finishWithoutShaking()
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 저장을 마치고 시트를 닫는다.
    ///
    /// **임시 막대를 여기서 지운다.** `onDisappear` 에 맡기면 안 된다.
    ///
    /// 일정을 만들면 그리드가 곧바로 다시 그려지는데, 그 시점에 임시 막대가 아직
    /// 살아 있으면 막대가 **2개**(임시 + 실제)가 되어 행이 늘어난다. 그러고 나서
    /// 시트가 닫히며 `onDisappear` 가 임시 막대를 지우면 행이 다시 줄어든다.
    /// 그리드가 위아래로 두 번 흔들리는 이유가 이것이다.
    ///
    /// 지우기와 만들기를 **같은 동기 블록**에 두면 한 번의 갱신으로 합쳐진다.
    /// 임시 막대는 이미 실제 일정과 같은 레인 규칙을 따르므로(`GridLayout`)
    /// 레인 수가 그대로여서 높이가 변하지 않는다.
    private func finishWithoutShaking() {
        draft.clear()
        dismiss()
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
        let targets = deleteTargets
        guard !targets.isEmpty else { return }
        errorMessage = nil

        // 묶음 전체를 지운다. 하나라도 실패하면 거기서 멈추고 알린다 —
        // 조용히 넘어가면 화면에서 사라진 것이 실제로는 남는다. (BL-048)
        do {
            for target in targets {
                try manager.deleteEvent(target, span: span)
            }
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
/// 일정에 딸린 할 일 한 줄.
///
/// **행을 두 섹션으로 나눈다. 「밝아지는 곳 = 눌리는 곳」.**
///
///     ┌──────────────────────────────────┬─────┐
///     │  졸프 주제 선정하기      1일 전까지 │  ⊖  │
///     └──────────────────────────────────┴─────┘
///           본문 (누르면 상세 편집)          삭제
///
/// 예전에는 한 줄에 체크·제목칸·스테퍼·`›`·⊖ 가 모두 있었다. `›` 는 "누르면 들어간다"는
/// 안내일 뿐 그 자체로 하는 일이 없었고, 스테퍼는 상세 편집과 기능이 겹쳤다.
/// 어디를 눌러야 무엇이 되는지도 알 수 없었다.
///
/// **완료 체크는 두지 않는다.** 여기는 일정을 편집하러 들어온 화면이고,
/// 할 일 완료는 우측 패널에서 하는 행위다. 완료 여부는 취소선으로 보여주기만 한다.
///
/// **스테퍼를 뺀 이유** — 같은 값을 두 경로에서 고칠 수 있으면 어느 쪽이 기준인지
/// 모호해진다. 상세 편집에서 더 편하게 조정할 수 있으므로 중복이다. 스테퍼를
/// 조작하려다 시트가 열리는 충돌도 함께 사라진다. 「N일 전까지」는 값 확인용으로 남긴다.
private struct AttachedTaskRow: View {
    @Binding var edit: EventEditorView.LinkedTaskEdit
    /// 본문을 눌러 세부 편집으로 들어간다.
    let onOpen: () -> Void
    let onRemove: () -> Void

    /// 완료 여부는 **보여주기만** 한다. 여기서 완료 처리하지 않는다.
    /// 완료 체크는 우측 패널에서 하는 행위다.
    private var isDone: Bool { edit.task.status == .done }

    var body: some View {
        HStack(spacing: 0) {
            // 좌측 — 본문. 읽기 전용이며 누르면 상세 편집으로 넘어간다.
            RowSection(action: onOpen, help: "소요시간 등 자세히 고치기", expands: true) {
                HStack(spacing: 8) {
                    Text(edit.title.isEmpty ? "제목 없음" : edit.title)
                        .font(.callout)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(edit.daysBefore == 0 ? "당일까지" : "\(edit.daysBefore)일 전까지")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            // 우측 — 삭제. 여기를 눌러도 시트는 열리지 않는다.
            RowSection(action: onRemove, help: "이 할 일 지우기") {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SheetMetrics.corner)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

/// 행 안의 독립된 클릭 영역 하나.
///
/// 섹션끼리 **빈틈 없이 맞닿는다.** 여백을 섹션이 직접 들고 있어야
/// 밝아지는 넓이와 눌리는 넓이가 같아진다. 바깥에서 간격을 주면
/// 그 틈은 아무 데도 속하지 않아 눌러도 반응이 없다.
private struct RowSection<Content: View>: View {
    let action: () -> Void
    let help: String
    /// 남는 자리를 이 섹션이 가져갈지. 본문만 켠다.
    /// 셋 다 켜면 HStack 이 폭을 똑같이 나눠 가져 체크와 삭제가 쓸데없이 넓어진다.
    var expands = false
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(RowSectionStyle(isHovering: isHovering, expands: expands))
            .onHover { isHovering = $0 }
            .help(help)
    }
}

private struct RowSectionStyle: ButtonStyle {
    let isHovering: Bool
    let expands: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(fill(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// 누르는 동안 한 단계 더 진해진다. 눌린 것이 보여야 반응이 있었다고 느낀다.
    private func fill(isPressed: Bool) -> Color {
        if isPressed { return Color.primary.opacity(0.13) }
        return Color.primary.opacity(isHovering ? 0.06 : 0)
    }
}
