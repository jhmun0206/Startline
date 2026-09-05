//
//  TodoSectionView.swift
//  Startline
//
//  우측 패널의 「오늘 착수」 영역과 TO-DO 목록.
//  명세서 4.1 배치 근거 / 4.2 우측 단 / 5.4 표시 정책
//

import SwiftData
import SwiftUI

// MARK: - 오늘 착수

/// 명세서 4.1 — 우측 패널 최상단 고정.
/// 사용자가 이미 아는 오늘 일정보다, 모르고 있는 착수 항목이 위에 와야 한다.
/// **항목이 0개면 이 블록 자체가 사라진다.**
struct TodayStartSection: View {
    let tasks: [ManagedTask]
    let now: Date
    let onSelect: (ManagedTask) -> Void

    /// 오늘이 착수마감인 항목 + 착수마감이 지났는데 미시작인 항목.
    private var attentionTasks: [ManagedTask] {
        tasks
            .filter { $0.needsStartAttention(now: now) }
            .sorted { lhs, rhs in
                let l = lhs.startDeadline() ?? .distantFuture
                let r = rhs.startDeadline() ?? .distantFuture
                if l != r { return l < r }
                return lhs.title < rhs.title
            }
    }

    var body: some View {
        if !attentionTasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("오늘 착수", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)

                ForEach(attentionTasks) { task in
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let judgment = task.judgment(now: now) {
                            JudgmentBadge(judgment: judgment)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(task) }
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

// MARK: - TO-DO 행

struct TaskRow: View {
    let task: ManagedTask
    let now: Date
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
                        .font(.body)
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
                    } else if let judgment = task.judgment(now: now) {
                        JudgmentBadge(judgment: judgment)
                    }
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if task.status == .notStarted {
                // 명세서 5.3 — 이 기록이 6장 캘리브레이션의 입력이 된다.
                Button("지금 시작") { task.markStarted() }
            }
            if task.status != .notStarted {
                Button("미시작으로 되돌리기") { task.markNotStarted() }
            }
            Button("편집", action: onEdit)
            Divider()
            Button("삭제", role: .destructive, action: onDelete)
        }
    }

    private func toggleDone() {
        if task.status == .done {
            task.markNotStarted()
        } else {
            task.markDone()
        }
    }

    /// 착수마감과 소요시간을 보여준다.
    /// 남은 시간을 숫자로 환산해 보여주지 않는다. (명세서 5.4)
    private var detailText: String {
        var parts: [String] = []

        if let deadline = task.startDeadline() {
            parts.append("착수 \(StartlineFormat.dayTime.string(from: deadline))")
        } else {
            parts.append("착수마감 없음")
        }

        if let duration = task.estimatedDuration {
            parts.append("소요 \(StartlineFormat.duration(duration))")
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - TO-DO 섹션

struct TodoSectionContent: View {
    let tasks: [ManagedTask]
    let now: Date
    let onEdit: (ManagedTask) -> Void
    let onDelete: (ManagedTask) -> Void

    var body: some View {
        if tasks.isEmpty {
            Text("할 일이 없습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(tasks) { task in
                TaskRow(
                    task: task,
                    now: now,
                    onEdit: { onEdit(task) },
                    onDelete: { onDelete(task) }
                )
            }
        }
    }
}
