//
//  TodoSectionView.swift
//  Startline
//
//  우측 패널의 「오늘 시작」 영역과 할 일 목록.
//  명세서 4.1 배치 근거 / 4.2 우측 단 / 5.4 표시 정책
//

import SwiftData
import SwiftUI

// MARK: - 오늘 착수

/// 명세서 5.2 1계층 — 우측 패널 최상단 고정.
/// 사용자가 이미 아는 오늘 일정보다, 모르고 있는 착수 항목이 위에 와야 한다.
/// **항목이 0개면 이 블록 자체가 사라진다.**
struct TodayStartSection: View {
    let tasks: [ResolvedTask]
    let onSelect: (ResolvedTask) -> Void

    /// 오늘이 착수마감인 항목 + 착수마감이 지났는데 미시작인 항목.
    private var attentionTasks: [ResolvedTask] {
        tasks
            .filter(\.needsStartAttention)
            .sorted { lhs, rhs in
                let l = lhs.startDeadline ?? .distantFuture
                let r = rhs.startDeadline ?? .distantFuture
                if l != r { return l < r }
                return lhs.task.title < rhs.task.title
            }
    }

    var body: some View {
        if !attentionTasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("오늘 시작", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)

                // 배지를 달지 않는다. 블록 제목이 이미 "오늘 시작"이라는 뜻을 담고 있고,
                // 같은 항목이 아래 목록에도 나타나므로 양쪽에 배지가 있으면 시선이 흩어진다.
                ForEach(attentionTasks) { resolved in
                    // "회의 장소 연락 → GDG 미팅" — 부모가 붙으면 맥락을 함께 보여준다.
                    Text(resolved.contextualTitle)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(resolved) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
        }
    }
}

// MARK: - 판정 배지

/// 명세서 5.4 — 숫자가 아니라 판정을 보여준다.
/// "N시간 남았습니다" 는 여유로 인식되어 착수를 지연시키므로 쓰지 않는다.
struct JudgmentBadge: View {
    let judgment: StartJudgment

    var body: some View {
        Text(judgment.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch judgment {
        case .relaxed: return .secondary
        case .startToday: return .orange
        case .overdue: return .red
        }
    }
}

// MARK: - 할 일 행

struct TaskRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceReporter.self) private var saver

    let resolved: ResolvedTask
    /// 일정 아래에 딸린 할 일이면 들여쓴다.
    var isNested = false
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var task: ManagedTask { resolved.task }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isNested {
                Spacer().frame(width: 14)
            }

            Button {
                toggleDone()
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(isNested ? .callout : .body)
                        .strikethrough(task.status == .done)
                        .foregroundStyle(task.status == .done ? .secondary : .primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if task.status == .inProgress {
                        Text(TaskStatus.inProgress.label)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    } else if let judgment = resolved.judgment {
                        JudgmentBadge(judgment: judgment)
                    }
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 체크박스는 제외하고 본문만 눌러야 수정 시트가 열린다.
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if task.status == .notStarted {
                // 명세서 9.1 — 이 기록이 10장 캘리브레이션의 입력이 된다.
                Button("지금 시작") {
                    saver.perform(modelContext) { task.markStarted() }
                }
            }
            if task.status != .notStarted {
                Button("미시작으로 되돌리기") {
                    saver.perform(modelContext) { task.markNotStarted() }
                }
            }
            Button("편집", action: onEdit)
            Divider()
            Button("삭제", role: .destructive, action: onDelete)
        }
    }

    private func toggleDone() {
        saver.perform(modelContext) {
            if task.status == .done {
                task.markNotStarted()
            } else {
                task.markDone()
            }
        }
    }

    /// 언제 시작해야 하는지와 얼마나 걸리는지.
    /// 남은 시간을 숫자로 환산해 보여주지 않는다. (명세서 5.4)
    private var detailText: String {
        var parts: [String] = []

        if let deadline = resolved.startDeadline {
            parts.append("\(StartlineFormat.spokenDayTime(deadline))에 시작")
        } else {
            parts.append("시작 시점 없음")
        }

        if let duration = task.estimatedDuration {
            parts.append("\(StartlineFormat.duration(duration)) 걸림")
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - 할 일 섹션

struct TodoSectionContent: View {
    let tasks: [ResolvedTask]
    let emptyText: String
    let onEdit: (ResolvedTask) -> Void
    let onDelete: (ResolvedTask) -> Void

    var body: some View {
        if tasks.isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(tasks) { resolved in
                TaskRow(
                    resolved: resolved,
                    onEdit: { onEdit(resolved) },
                    onDelete: { onDelete(resolved) }
                )
            }
        }
    }
}
