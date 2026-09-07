//
//  TodoSectionView.swift
//  Startline
//
//  우측 패널의 「오늘 시작」 영역과 할 일 목록.
//  명세서 4.1 배치 근거 / 4.2 우측 단 / 5.4 표시 정책
//

import SwiftData
import SwiftUI

// MARK: - 공통 부품

/// 우측 패널의 한 항목을 감싸는 카드.
/// 텍스트만 나열하면 어디까지가 한 항목인지 알 수 없다.
struct PanelCard<Content: View>: View {
    var tint: Color = .clear
    /// 눌러서 여는 카드인지. 마우스를 올리면 배경이 살짝 바뀌어 누를 수 있음을 알린다.
    var isInteractive = false
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(baseColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            // 카드 전체가 눌리도록 모양을 명시한다. 안쪽 뷰가 좁아도 빈 곳이 반응한다.
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovering in
                guard isInteractive else { return }
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var baseColor: Color {
        tint == .clear ? Color(nsColor: .controlBackgroundColor) : tint
    }
}

/// 카드 안에서 **눌리는 단위 하나**를 감싼다.
///
/// 한 카드에 클릭 대상이 둘 이상이면(일정 + 딸린 할 일) 카드 전체를 밝히면 안 된다.
/// 호버가 하나인데 클릭 결과가 둘이면 지금 커서가 어느 쪽에 있는지 알 수 없다.
/// **밝아지는 범위와 눌리는 범위를 같게 한다.**
struct HoverRegion<Content: View>: View {
    let onTap: () -> Void
    /// 위아래 여백. 영역끼리 맞닿게 하려면 사이 간격을 이 값으로 흡수시킨다.
    var verticalPadding: CGFloat = 4
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onTap)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// 계층 제목.
struct SectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }
}

// MARK: - 오늘 시작

/// 명세서 5.2 1계층 — 우측 패널 최상단 고정.
/// 사용자가 이미 아는 오늘 일정보다, 모르고 있는 항목이 위에 와야 한다.
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
            PanelCard(tint: Color.orange.opacity(0.10)) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("오늘 시작", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)

                    // 배지를 달지 않는다. 블록 제목이 이미 "오늘 시작"이라는 뜻을 담고 있고,
                    // 같은 항목이 아래 목록에도 나타나므로 양쪽에 배지가 있으면 시선이 흩어진다.
                    ForEach(attentionTasks) { resolved in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                            Text(resolved.contextualTitle)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(resolved) }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 14)
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
    ///
    /// **들여쓰기 말고는 아무것도 다르지 않다.** 같은 데이터가 위치에 따라 다르게 보이면
    /// 사용자는 둘을 다른 것으로 인식한다. 계층은 들여쓰기와 구분선으로만 나타낸다.
    var isNested = false
    /// 「할 일」 섹션에서는 부모 일정명을 함께 보여준다.
    /// 부모 카드 아래에서는 이미 맥락이 있으므로 붙이지 않는다.
    var showsParentContext = false
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
                    Text(showsParentContext ? resolved.contextualTitle : task.title)
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
