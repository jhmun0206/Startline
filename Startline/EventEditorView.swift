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

    let manager: CalendarManager
    /// 고칠 일정. nil 이면 새로 만든다.
    let event: EKEvent?
    /// 새로 만들 때의 기준 날짜.
    let defaultDate: Date

    @Query private var allTasks: [ManagedTask]

    @State private var title = ""
    @State private var day = Date()
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var isAllDay = false
    @State private var selectedCalendarID: String?

    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    /// 일정을 저장할 때 함께 만들 할 일들. 폼 안에서 여러 개를 한 번에 적는다.
    @State private var draftTasks: [DraftTask] = []

    /// 폼 안에서만 쓰는 할 일 초안.
    struct DraftTask: Identifiable {
        let id = UUID()
        var title = ""
        var daysBefore = 1
    }

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

                    if !isEditing { draftTaskSection }
                    if isRecurring { recurringNote }
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

    /// "2026. 9. 23.  오전 9:00 ~ 오전 10:00" 을 한 줄로.
    private var whenField: some View {
        SheetField {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    DatePicker("", selection: $day, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)

                    if !isAllDay {
                        DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                        Text("~")
                            .foregroundStyle(.secondary)
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
                          || manager.writableCalendars.isEmpty)
        }
        .padding(16)
    }

    // MARK: - 이 일정 전에 할 일

    /// 일정을 만들면서 준비 작업을 여러 개 한꺼번에 적는다.
    /// 저장하면 모두 이 일정에 딸린 할 일로 만들어진다. (명세서 8장)
    ///
    /// 이 블록만 설명 문구를 남긴다. 빈 칸만 있으면 무엇을 적는 자리인지 알 수 없다.
    private var draftTaskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이 일정 전에 미리 할 일")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($draftTasks) { $draft in
                SheetField(verticalPadding: 5) {
                    HStack(spacing: 6) {
                        TextField("무엇을 미리 해둘까요", text: $draft.title)
                            .textFieldStyle(.plain)
                            .font(.callout)

                        Stepper(value: $draft.daysBefore, in: 0...365) {
                            Text(draft.daysBefore == 0 ? "당일" : "\(draft.daysBefore)일 전")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .fixedSize()

                        Button {
                            draftTasks.removeAll { $0.id == draft.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("이 줄 지우기")
                    }
                }
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

    /// 저장하지 않은 입력이 있는지. 닫기를 눌렀을 때 되물을지 판단한다.
    private var hasUnsavedInput: Bool {
        if isEditing {
            guard let event else { return false }
            return title != (event.title ?? "")
                || isAllDay != event.isAllDay
                || !manager.calendar.isDate(day, inSameDayAs: event.startDate ?? day)
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
            day = defaultDate
            startTime = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: defaultDate) ?? defaultDate
            endTime = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: defaultDate) ?? defaultDate
            selectedCalendarID = manager.defaultWritableCalendar?.calendarIdentifier
            return
        }

        title = event.title ?? ""
        isAllDay = event.isAllDay
        day = event.startDate ?? defaultDate
        startTime = event.startDate ?? defaultDate
        endTime = event.endDate ?? startTime
        selectedCalendarID = event.calendar?.calendarIdentifier
            ?? manager.defaultWritableCalendar?.calendarIdentifier
    }

    /// 날짜는 `day` 에서, 시각은 `startTime`/`endTime` 에서 가져와 합친다.
    private func combined(_ time: Date) -> Date {
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
        guard isAllDay else { return (combined(startTime), combined(endTime)) }

        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? start
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

    /// 폼에 적어둔 할 일들을 방금 만든 일정에 딸린 할 일로 만든다.
    private func createDraftTasks(for event: EKEvent, eventStart: Date) {
        guard let parentEventID = event.eventIdentifier else { return }

        for draft in draftTasks {
            let trimmed = draft.title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let offset = -TimeInterval(draft.daysBefore) * 24 * 60 * 60
            let task = ManagedTask(
                title: trimmed,
                parentEventID: parentEventID,
                parentOccurrenceDate: eventStart,
                offsetFromParent: offset,
                lastKnownDueAt: eventStart.addingTimeInterval(offset),
                // 소요시간을 아직 모르므로 "그날까지"로 둔다.
                // 착수마감이 실효마감과 같아져 그 날 「오늘 시작」에 뜬다.
                leadTime: .fixed(days: 0)
            )
            modelContext.insert(task)
        }
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
