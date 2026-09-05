//
//  EventEditorView.swift
//  Startline
//
//  일정 만들기 / 고치기 / 지우기. EventKit 에 직접 쓴다.
//
//  이 앱의 핵심 흐름은 "미팅을 잡으면서 준비할 일도 같이 만든다"이다.
//  그래서 일정을 저장한 뒤 곧바로 그 일정에 딸린 할 일을 만들 수 있게 이어준다.
//

import EventKit
import SwiftData
import SwiftUI

struct EventEditorView: View {

    @Environment(\.dismiss) private var dismiss

    let manager: CalendarManager
    /// 고칠 일정. nil 이면 새로 만든다.
    let event: EKEvent?
    /// 새로 만들 때의 기준 날짜.
    let defaultDate: Date
    /// 저장한 일정을 부모로 하는 할 일 입력으로 이어갈 때 호출한다.
    var onAddTaskForEvent: ((EKEvent) -> Void)?

    @Query private var allTasks: [ManagedTask]

    @State private var title = ""
    @State private var day = Date()
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var isAllDay = false
    @State private var selectedCalendarID: String?

    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false
    /// 저장 직후 "딸린 할 일도 만들까요?" 를 띄우기 위한 값.
    @State private var savedEvent: EKEvent?

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
        .frame(width: 440)
        .onAppear(perform: load)
    }

    // MARK: - 읽기 전용

    /// 고칠 수 없는 일정은 편집 폼을 열지 않고 내용과 이유만 보여준다.
    private var readOnlyBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetTitle("일정 보기")

            Form {
                Section {
                    LabeledContent("제목", value: event?.title ?? "(제목 없음)")
                    LabeledContent("때", value: eventTimeSummary)
                    if let location = event?.location, !location.isEmpty {
                        LabeledContent("장소", value: location)
                    }
                    LabeledContent("캘린더", value: event?.calendar?.title ?? "-")
                }

                Section {
                    Label(
                        "‘\(event?.calendar?.title ?? "이 캘린더")’는 구독하거나 자동으로 만들어진 캘린더라 Startline에서 고칠 수 없어요. 원래 만든 곳에서 바꿔 주세요.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

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
            if !isEditing { sheetTitle("일정 추가") } else { sheetTitle("일정 고치기") }

            Form {
                Section {
                    TextField("제목", text: $title)
                }

                Section("언제") {
                    DatePicker("날짜", selection: $day, displayedComponents: .date)
                    Toggle("하루 종일", isOn: $isAllDay)
                    if !isAllDay {
                        DatePicker("시작", selection: $startTime, displayedComponents: .hourAndMinute)
                        DatePicker("끝", selection: $endTime, displayedComponents: .hourAndMinute)
                    }
                }
                .environment(\.locale, .startlineDisplay)

                Section("어느 캘린더에") {
                    if manager.writableCalendars.isEmpty {
                        Text("새 일정을 넣을 수 있는 캘린더가 없어요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("캘린더", selection: $selectedCalendarID) {
                            ForEach(manager.writableCalendars, id: \.calendarIdentifier) { calendar in
                                Text("\(calendar.title) · \(calendar.source.title)")
                                    .tag(Optional(calendar.calendarIdentifier))
                            }
                        }
                    }
                }

                if isRecurring {
                    Section {
                        Label("반복되는 일정이에요. 고치면 이 회차만 바뀌어요.", systemImage: "repeat")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

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
        .alert("이 일정에 딸린 할 일도 만들까요?", isPresented: savedAlertBinding) {
            Button("할 일 만들기") {
                if let savedEvent { onAddTaskForEvent?(savedEvent) }
                savedEvent = nil
                dismiss()
            }
            Button("나중에", role: .cancel) {
                savedEvent = nil
                dismiss()
            }
        } message: {
            Text("‘\(savedEvent?.title ?? "")’ 전에 미리 해둘 일이 있다면 지금 같이 적어두세요.")
        }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("지우기", role: .destructive) { isConfirmingDelete = true }
            }
            Spacer()
            Button("그만두기") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "저장" : "만들기") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          || manager.writableCalendars.isEmpty)
        }
        .padding(16)
    }

    private func sheetTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
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

    private var savedAlertBinding: Binding<Bool> {
        Binding(get: { savedEvent != nil }, set: { if !$0 { savedEvent = nil } })
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
                // 여기서 닫지 않는다. 딸린 할 일을 이어서 만들지 물어본다.
                savedEvent = created
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
