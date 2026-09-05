//
//  TaskEditorView.swift
//  Startline
//
//  TO-DO 입력 시트. 제목 / 마감시각 / 소요시간 / 리드타임 방식.
//  명세서 12장 「소요시간 입력 마찰」 — 프리셋 버튼으로 입력을 선택으로 바꾼다.
//

import SwiftData
import SwiftUI

struct TaskEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// 편집 대상. nil 이면 새로 만든다.
    let task: ManagedTask?
    /// 새로 만들 때의 기본 마감 날짜.
    let defaultDueDate: Date

    @State private var title = ""
    @State private var dueAt = Date()
    @State private var hours = 0
    @State private var minutes = 0
    @State private var leadTimeKind: LeadTimeKind = .durationBased
    @State private var leadTimeValue = 1

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
                    TextField("제목", text: $title)
                    DatePicker(
                        "마감시각",
                        selection: $dueAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section("소요시간") {
                    presetRow
                    manualRow
                }

                Section("리드타임 방식") {
                    Picker("방식", selection: $leadTimeKind) {
                        ForEach(LeadTimeKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if leadTimeKind == .fixedDays || leadTimeKind == .fixedHours {
                        Stepper(
                            value: $leadTimeValue,
                            in: 1...(leadTimeKind == .fixedDays ? 365 : 720)
                        ) {
                            Text(leadTimeKind == .fixedDays
                                 ? "\(leadTimeValue)일 전"
                                 : "\(leadTimeValue)시간 전")
                        }
                    }
                }

                Section("착수마감") {
                    startDeadlineSummary
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

    // MARK: - 착수마감 미리보기

    @ViewBuilder
    private var startDeadlineSummary: some View {
        let preview = ManagedTask(
            title: title,
            dueAt: dueAt,
            estimatedDuration: estimatedDuration,
            leadTime: currentLeadTime
        )

        if let deadline = preview.startDeadline() {
            Text(StartlineFormat.fullDayTime.string(from: deadline))
                .font(.system(.body, design: .monospaced))
        } else if leadTimeKind == .durationBased {
            Text("소요시간을 입력해야 착수마감이 계산됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("리드타임이 없어 착수마감을 계산하지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var currentLeadTime: LeadTime {
        switch leadTimeKind {
        case .durationBased: return .durationBased
        case .fixedDays: return .fixed(days: leadTimeValue)
        case .fixedHours: return .fixedHours(leadTimeValue)
        case .none: return .none
        }
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
        dueAt = task.dueAt
        leadTimeKind = task.leadTimeKind
        leadTimeValue = max(1, task.leadTimeValue)

        if let duration = task.estimatedDuration {
            let totalMinutes = Int(duration) / 60
            hours = totalMinutes / 60
            minutes = totalMinutes % 60
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let task {
            task.title = trimmed
            task.dueAt = dueAt
            // 사용자 입력값을 그대로 저장한다. 배수를 곱하지 않는다. (명세서 원칙 1)
            task.estimatedDuration = estimatedDuration
            task.leadTime = currentLeadTime
        } else {
            let newTask = ManagedTask(
                title: trimmed,
                dueAt: dueAt,
                estimatedDuration: estimatedDuration,
                leadTime: currentLeadTime
            )
            modelContext.insert(newTask)
        }

        dismiss()
    }
}
