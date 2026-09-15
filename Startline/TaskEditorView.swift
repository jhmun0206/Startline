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

    @Environment(PersistenceReporter.self) private var saver

    @State private var isConfirmingDelete = false

    /// 편집 대상. nil 이면 새로 만든다.
    let task: ManagedTask?
    /// 새로 만들 때의 기본 마감 날짜.
    let defaultDueDate: Date
    /// 부모 일정 후보를 찾는 데 쓴다.
    let manager: CalendarManager

    /// 다른 시트 안에 끼워 열렸을 때 돌아갈 곳의 이름. nil 이면 독립 시트다.
    var backTitle: String?
    /// 저장·삭제·되돌아가기로 이 폼을 마칠 때. 값이 있으면 시트를 닫지 않는다.
    var onFinish: (() -> Void)?

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
    /// 「며칠 전까지」의 직접 입력 줄을 펼쳤는지. 칩에 없는 값을 불러오면 켜진다.
    @State private var isEnteringCustomDays = false

    /// UI로 표현할 수 없는 기존 리드타임(시간 단위 등)을 편집 중에 잃지 않도록 보관한다.
    @State private var preservedLeadTime: LeadTime?

    private var isEditing: Bool { task != nil }

    private var estimatedDuration: TimeInterval? {
        let total = TimeInterval(hours * 3600 + minutes * 60)
        return total > 0 ? total : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: isEditing ? "할 일 수정" : "할 일 추가",
                hasUnsavedInput: hasUnsavedInput,
                backTitle: backTitle,
                onBack: onFinish
            ) { dismiss() }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SheetTextField(
                        placeholder: "새로운 할 일",
                        text: $title,
                        font: .title3
                    )

                    dueModeSelector

                    switch dueMode {
                    case .specificDate:
                        SheetField {
                            HStack(spacing: 6) {
                                DatePicker("", selection: $dueAt, displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.field)
                                DatePicker("", selection: $dueAt, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .datePickerStyle(.field)
                                Text("까지")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        .environment(\.locale, .startlineDisplay)

                    case .attachedToEvent:
                        parentEventRow
                    }

                    durationBlock

                    if estimatedDuration == nil {
                        reminderFallback
                    }

                    if let deadline = startDeadline {
                        startNote(deadline)
                    }
                }
                .padding(.horizontal, SheetMetrics.padding)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: SheetMetrics.maxContentHeight)

            Divider()

            HStack {
                if isEditing {
                    Button("삭제", role: .destructive) { isConfirmingDelete = true }
                }
                Spacer()
                Button(isEditing ? "저장" : "추가") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: SheetMetrics.width)
        .onAppear(perform: load)
        .alert("이 할 일을 지울까요?", isPresented: $isConfirmingDelete) {
            Button("지우기", role: .destructive) { delete() }
            Button("그만두기", role: .cancel) {}
        } message: {
            Text("‘\(title)’를 목록에서 지워요. 연결된 일정은 그대로 남아요.")
        }
    }

    /// 착수마감이 산출될 때만 나온다. 남은 시간을 숫자로 환산하지 않는다. (명세서 5.4)
    private func startNote(_ deadline: Date) -> some View {
        Label(
            "\(StartlineFormat.spokenDayTime(deadline))에 시작해야 해요",
            systemImage: "flag"
        )
        .font(.callout)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SheetMetrics.corner)
                .fill(Color.accentColor.opacity(0.12))
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 「언제까지」 방식 고르기

    /// 라디오 대신 좌우 2분할 버튼. 고른 쪽만 은은한 파란 배경으로 남는다.
    private var dueModeSelector: some View {
        HStack(spacing: 8) {
            modeButton("특정 날짜", .specificDate)
            modeButton("일정에 맞춰", .attachedToEvent)
        }
        .padding(.vertical, 2)
    }

    private func modeButton(_ label: String, _ mode: DueMode) -> some View {
        let isOn = dueMode == mode

        return Text(label)
            .font(.callout)
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { dueMode = mode }
    }

    // MARK: - 부모 일정 선택 (명세서 5.3)

    /// 목록 드롭다운 대신 작은 달력에서 고른다.
    /// 사람은 "언제쯤"으로 일정을 기억하므로 날짜에서 출발하는 편이 찾기 쉽다.
    @ViewBuilder
    private var parentEventRow: some View {
        SheetField {
            MiniCalendarPicker(
                manager: manager,
                selection: $parentEvent,
                anchorDate: defaultDueDate
            )
        }

        if let parentEvent {
            SheetField(verticalPadding: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(parentEvent.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                        .frame(width: 9, height: 9)
                    Text(parentEvent.title ?? "(제목 없음)")
                        .font(.callout.bold())
                        .lineLimit(1)
                    Spacer(minLength: 6)
                }

                // 일정 폼의 초안 행과 **같은 부품**을 쓴다. 추가와 수정이 어긋나지 않게.
                DaysBeforeChips(
                    label: "언제까지",
                    daysBefore: $daysBeforeParent,
                    isEnteringCustom: $isEnteringCustomDays
                )
            }
        } else {
            Text("위 달력에서 일정을 하나 고르세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 부모 시작시각 기준 상대 마감. 음수가 "며칠 전". (명세서 4.1)
    private var offsetFromParent: TimeInterval {
        -TimeInterval(daysBeforeParent) * 24 * 60 * 60
    }

    // MARK: - 소요시간 입력

    private var durationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("얼마나 걸릴까요")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                ForEach(DurationPreset.all) { preset in
                    presetChip(preset)
                }
            }

            SheetField(verticalPadding: 5) {
                HStack(spacing: 5) {
                    Text("직접")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0", value: $hours, format: .number)
                        .textFieldStyle(.plain)
                        .frame(width: 34)
                        .multilineTextAlignment(.trailing)
                    Text("시간").font(.caption)
                    TextField("0", value: $minutes, format: .number)
                        .textFieldStyle(.plain)
                        .frame(width: 34)
                        .multilineTextAlignment(.trailing)
                    Text("분").font(.caption)
                    Spacer(minLength: 0)
                    Button("지우기") {
                        hours = 0
                        minutes = 0
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(hours == 0 && minutes == 0)
                }
            }
        }
    }

    private func presetChip(_ preset: DurationPreset) -> some View {
        let isOn = estimatedDuration == preset.duration

        return Text(preset.label)
            .font(.caption)
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { apply(preset) }
    }

    private func apply(_ preset: DurationPreset) {
        let totalMinutes = Int(preset.duration) / 60
        hours = totalMinutes / 60
        minutes = totalMinutes % 60
    }

    // MARK: - 소요시간을 모를 때

    /// 소요시간이 비어 있을 때만 나온다. 계산 방식을 묻는 대신
    /// "며칠 전에 알려줄까"라는 사용자가 답할 수 있는 질문으로 바꾼다.
    private var reminderFallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("얼마나 걸릴지 모르겠다면, 며칠 전에 알려드릴까요?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                choiceButton("3일 전", .threeDays)
                choiceButton("1주 전", .oneWeek)
                choiceButton("알림 없음", .never)
            }
        }
    }

    private func choiceButton(_ label: String, _ choice: ReminderChoice) -> some View {
        let isOn = reminderChoice == choice

        return Text(label)
            .font(.caption)
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                reminderChoice = choice
                preservedLeadTime = nil
            }
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
            parentEvent = manager.parentEvent(
                id: parentEventID,
                occurrenceDate: task.parentOccurrenceDate
            )
            if let offset = task.offsetFromParent {
                daysBeforeParent = max(0, Int((-offset / (24 * 60 * 60)).rounded()))
                // 칩에 없는 값(예: 5일 전)이면 「직접」을 켜 그 값을 그대로 보여준다.
                // 가까운 칩으로 바꾸지 않는다. (원칙 1)
                isEnteringCustomDays = DaysBeforeChips.needsCustom(for: daysBeforeParent)
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

    private func delete() {
        guard let task else { return }
        modelContext.delete(task)
        saver.commit(modelContext)
        finish()
    }

    /// 독립 시트면 닫고, 다른 폼 안에 끼워 열렸으면 그 폼으로 돌아간다.
    private func finish() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    /// 저장하지 않은 입력이 있는지.
    private var hasUnsavedInput: Bool {
        if let task {
            return title != task.title
                || estimatedDuration != task.estimatedDuration
                || currentLeadTime != task.leadTime
        }
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
            || estimatedDuration != nil
            || parentEvent != nil
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let task {
            task.title = trimmed
            // 사용자 입력값을 그대로 저장한다. 배수를 곱하지 않는다. (원칙 1)
            task.estimatedDuration = estimatedDuration
            task.leadTime = currentLeadTime
            apply(to: task)
        } else {
            // 새로 만들 때는 「일정에 맞춰」로 고르고 실제로 일정을 집었을 때만 붙인다.
            let parent = dueMode == .attachedToEvent ? parentEvent : nil
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

        // 지연 저장에 맡기지 않는다. 여기서 디스크까지 내려가야 한다.
        saver.commit(modelContext)
        finish()
    }

    /// 편집 시 부모 연결 상태를 반영한다.
    /// 부모 연결을 반영한다.
    ///
    /// **부모를 못 찾았다는 이유로 저장된 연결을 지우지 않는다.**
    /// `load()` 는 `dueMode` 를 「일정에 맞춰」로 두고 부모를 찾아보는데, 그 조회가
    /// 한 번 실패하면 `parentEvent` 가 비어 있게 된다. 그 상태로 저장을 누르면
    /// 예전 구현은 연결을 통째로 끊었다 — 사용자는 저장만 눌렀는데 관계가 사라졌다.
    ///
    /// 연결을 끊는 것은 사용자가 **「특정 날짜」를 직접 고른 경우뿐**이다.
    private func apply(to task: ManagedTask) {
        let decision = TaskLinkPolicy.decideOnSave(
            wantsAttachment: dueMode == .attachedToEvent,
            resolvedParentID: parentEvent?.eventIdentifier,
            resolvedParentStart: parentEvent?.startDate,
            offsetFromParent: offsetFromParent,
            fixedDueAt: dueAt,
            effectiveDueAt: effectiveDueAt
        )

        switch decision {
        case .detach(let reason):
            // 「특정 날짜」로 되돌린 경우. 부모를 떼고 고른 날짜를 확정 마감으로 삼는다.
            task.detachFromParent(lastKnownDueAt: dueAt, reason: reason)

        case .keepStored:
            // 부모를 아직 못 찾았다. 저장된 연결도 마감도 손대지 않는다.
            break

        case .link(let eventID, let occurrenceDate, let offset, let dueAt):
            task.parentEventID = eventID
            task.parentOccurrenceDate = occurrenceDate
            task.offsetFromParent = offset
            // 부모가 삭제됐을 때 승격시킬 값을 미리 남겨둔다. (명세서 4.2)
            task.dueAt = dueAt
        }
    }
}
