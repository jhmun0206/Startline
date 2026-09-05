//
//  TaskEditorView.swift
//  Startline
//
//  할 일 입력 시트.
//
//  사용자에게 계산 방식을 고르라고 묻지 않는다. 사용자는 자기 상황만 말하고,
//  리드타임 방식은 소요시간 입력 여부에서 자동으로 결정된다.
//  명세서 12장 「소요시간 입력 마찰」 — 입력을 선택으로 바꾼다.
//

import EventKit
import SwiftData
import SwiftUI

struct TaskEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// 편집 대상. nil 이면 새로 만든다.
    let task: ManagedTask?
    /// 새로 만들 때의 기본 마감 날짜.
    let defaultDueDate: Date
    /// 부모 일정 후보를 찾는 데 쓴다.
    let manager: CalendarManager

    /// 「언제까지」를 정하는 두 방식. (명세서 5.3)
    private enum DueMode: Hashable {
        case specificDate
        case attachedToEvent
    }

    /// 소요시간을 모를 때 고르는 대안.
    private enum ReminderChoice: Hashable {
        case threeDays
        case oneWeek
        case never
    }

    @State private var title = ""
    @State private var dueMode: DueMode = .specificDate
    @State private var dueAt = Date()
    @State private var hours = 0
    @State private var minutes = 0
    @State private var reminderChoice: ReminderChoice?

    /// 부모로 고른 일정.
    @State private var parentEvent: EKEvent?
    /// 부모 일정 시작 기준 며칠 전인지.
    @State private var daysBeforeParent = 1
    @State private var candidates: [EKEvent] = []

    /// UI로 표현할 수 없는 기존 리드타임(시간 단위 등)을 편집 중에 잃지 않도록 보관한다.
    @State private var preservedLeadTime: LeadTime?

    private var isEditing: Bool { task != nil }

    private var estimatedDuration: TimeInterval? {
        let total = TimeInterval(hours * 3600 + minutes * 60)
        return total > 0 ? total : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "할 일 편집" : "할 일 추가")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("무엇을", text: $title)
                }

                Section("언제까지") {
                    Picker("", selection: $dueMode) {
                        Text("특정 날짜").tag(DueMode.specificDate)
                        Text("일정에 맞춰").tag(DueMode.attachedToEvent)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    switch dueMode {
                    case .specificDate:
                        DatePicker("날짜", selection: $dueAt, displayedComponents: .date)
                        DatePicker("시간", selection: $dueAt, displayedComponents: .hourAndMinute)
                    case .attachedToEvent:
                        parentEventRow
                    }
                }
                .environment(\.locale, .startlineDisplay)

                Section("얼마나 걸릴까요") {
                    presetRow
                    manualRow

                    if estimatedDuration == nil {
                        reminderFallback
                    }
                }

                if let deadline = startDeadline {
                    Section("이때 시작해야 해요") {
                        Text("\(StartlineFormat.spokenDayTime(deadline))에 시작해야 해요")
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "저장" : "추가") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
        .onAppear(perform: load)
    }

    // MARK: - 부모 일정 선택 (명세서 5.3)

    /// [일정 선택 ▾] 의 [N]일 전
    @ViewBuilder
    private var parentEventRow: some View {
        if candidates.isEmpty {
            Text("이 날짜 근처에 고를 수 있는 일정이 없어요.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Picker("일정", selection: parentSelection) {
                Text("일정 선택").tag(String?.none)
                ForEach(candidates, id: \.eventIdentifier) { event in
                    Text(eventLabel(event)).tag(Optional(eventKey(event)))
                }
            }

            Stepper(value: $daysBeforeParent, in: 0...365) {
                Text(daysBeforeParent == 0 ? "일정 당일" : "\(daysBeforeParent)일 전")
            }
        }
    }

    /// Picker 는 Hashable 값을 요구하므로 일정 자체 대신 키로 오간다.
    private var parentSelection: Binding<String?> {
        Binding(
            get: { parentEvent.map(eventKey) },
            set: { key in
                parentEvent = candidates.first { eventKey($0) == key }
            }
        )
    }

    private func eventKey(_ event: EKEvent) -> String {
        "\(event.eventIdentifier ?? "")|\(event.startDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private func eventLabel(_ event: EKEvent) -> String {
        let title = event.title ?? "(제목 없음)"
        guard let start = event.startDate else { return title }
        return "\(StartlineFormat.spokenDay.string(from: start)) \(title)"
    }

    /// 부모 시작시각 기준 상대 마감. 음수가 "며칠 전". (명세서 4.1)
    private var offsetFromParent: TimeInterval {
        -TimeInterval(daysBeforeParent) * 24 * 60 * 60
    }

    // MARK: - 소요시간 입력

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(DurationPreset.all) { preset in
                Button(preset.label) { apply(preset) }
                    .buttonStyle(.bordered)
                    .tint(isSelected(preset) ? .accentColor : nil)
            }
            Spacer()
        }
    }

    private var manualRow: some View {
        HStack(spacing: 6) {
            Text("직접 입력")
                .foregroundStyle(.secondary)
            Spacer()
            TextField("0", value: $hours, format: .number)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
            Text("시간")
            TextField("0", value: $minutes, format: .number)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
            Text("분")
            Button("지우기") {
                hours = 0
                minutes = 0
            }
            .buttonStyle(.borderless)
            .disabled(hours == 0 && minutes == 0)
        }
    }

    private func apply(_ preset: DurationPreset) {
        let totalMinutes = Int(preset.duration) / 60
        hours = totalMinutes / 60
        minutes = totalMinutes % 60
    }

    private func isSelected(_ preset: DurationPreset) -> Bool {
        estimatedDuration == preset.duration
    }

    // MARK: - 소요시간을 모를 때

    /// 소요시간이 비어 있을 때만 나온다. 계산 방식을 묻는 대신
    /// "며칠 전에 알려줄까"라는 사용자가 답할 수 있는 질문으로 바꾼다.
    private var reminderFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("얼마나 걸릴지 모르겠다면, 며칠 전에 알려드릴까요?")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                choiceButton("3일 전", .threeDays)
                choiceButton("1주 전", .oneWeek)
                choiceButton("알림 없음", .never)
                Spacer()
            }
        }
    }

    private func choiceButton(_ label: String, _ choice: ReminderChoice) -> some View {
        Button(label) {
            reminderChoice = choice
            preservedLeadTime = nil
        }
        .buttonStyle(.bordered)
        .tint(reminderChoice == choice ? .accentColor : nil)
    }

    // MARK: - 리드타임 결정

    /// 사용자에게 묻지 않고 결정한다.
    /// 소요시간이 있으면 역산, 없으면 고른 대안, 아무것도 없으면 리드타임 없음.
    private var currentLeadTime: LeadTime {
        if estimatedDuration != nil { return .durationBased }

        switch reminderChoice {
        case .threeDays: return .fixed(days: 3)
        case .oneWeek: return .fixed(days: 7)
        case .never: return .none
        case nil: return preservedLeadTime ?? .none
        }
    }

    /// 지금 입력 상태로 계산되는 실효마감. (명세서 4.2)
    private var effectiveDueAt: Date? {
        switch dueMode {
        case .specificDate:
            return dueAt
        case .attachedToEvent:
            guard let start = parentEvent?.startDate else { return nil }
            return start.addingTimeInterval(offsetFromParent)
        }
    }

    private var startDeadline: Date? {
        let preview = ManagedTask(
            title: title,
            dueAt: effectiveDueAt,
            estimatedDuration: estimatedDuration,
            leadTime: currentLeadTime
        )
        return preview.startDeadline(effectiveDueAt: effectiveDueAt)
    }

    // MARK: - 로드 / 저장

    private func load() {
        candidates = manager.candidateEvents(around: defaultDueDate)

        guard let task else {
            // 새 항목의 기본 마감은 선택한 날짜의 23:59.
            var components = Calendar.current.dateComponents([.year, .month, .day], from: defaultDueDate)
            components.hour = 23
            components.minute = 59
            dueAt = Calendar.current.date(from: components) ?? defaultDueDate
            return
        }

        title = task.title
        dueAt = task.dueAt ?? defaultDueDate

        if let duration = task.estimatedDuration {
            let totalMinutes = Int(duration) / 60
            hours = totalMinutes / 60
            minutes = totalMinutes % 60
        }

        // 부모가 붙어 있으면 「일정에 맞춰」로 열고, 후보 목록에 없으면 부모를 직접 찾아 채운다.
        if let parentEventID = task.parentEventID {
            dueMode = .attachedToEvent
            let found = manager.parentEvent(
                id: parentEventID,
                occurrenceDate: task.parentOccurrenceDate
            )
            if let found {
                if !candidates.contains(where: { $0.eventIdentifier == found.eventIdentifier }) {
                    candidates.insert(found, at: 0)
                }
                parentEvent = found
            }
            if let offset = task.offsetFromParent {
                daysBeforeParent = max(0, Int((-offset / (24 * 60 * 60)).rounded()))
            }
        }

        // 저장된 리드타임을 이 화면의 선택지로 되돌린다.
        // 대응되는 선택지가 없으면(시간 단위 등) 원래 값을 그대로 보존한다.
        switch task.leadTime {
        case .fixed(days: 3): reminderChoice = .threeDays
        case .fixed(days: 7): reminderChoice = .oneWeek
        case .none: reminderChoice = .never
        case .durationBased: reminderChoice = nil
        default: preservedLeadTime = task.leadTime
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // 「일정에 맞춰」인데 일정을 안 골랐으면 부모 없이 저장한다.
        let parent = dueMode == .attachedToEvent ? parentEvent : nil

        if let task {
            task.title = trimmed
            // 사용자 입력값을 그대로 저장한다. 배수를 곱하지 않는다. (원칙 1)
            task.estimatedDuration = estimatedDuration
            task.leadTime = currentLeadTime
            apply(parent: parent, to: task)
        } else {
            let newTask: ManagedTask
            if let parent, let parentEventID = parent.eventIdentifier {
                newTask = ManagedTask(
                    title: trimmed,
                    parentEventID: parentEventID,
                    parentOccurrenceDate: parent.startDate,
                    offsetFromParent: offsetFromParent,
                    lastKnownDueAt: effectiveDueAt,
                    estimatedDuration: estimatedDuration,
                    leadTime: currentLeadTime
                )
            } else {
                newTask = ManagedTask(
                    title: trimmed,
                    dueAt: dueAt,
                    estimatedDuration: estimatedDuration,
                    leadTime: currentLeadTime
                )
            }
            modelContext.insert(newTask)
        }

        dismiss()
    }

    /// 편집 시 부모 연결 상태를 반영한다.
    private func apply(parent: EKEvent?, to task: ManagedTask) {
        guard let parent, let parentEventID = parent.eventIdentifier else {
            // 「특정 날짜」로 되돌린 경우. 부모를 떼고 고른 날짜를 확정 마감으로 삼는다.
            task.detachFromParent(lastKnownDueAt: dueAt)
            return
        }

        task.parentEventID = parentEventID
        task.parentOccurrenceDate = parent.startDate
        task.offsetFromParent = offsetFromParent
        // 부모가 삭제됐을 때 승격시킬 값을 미리 남겨둔다. (명세서 4.2)
        task.dueAt = effectiveDueAt
    }
}
