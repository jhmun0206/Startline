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
/// 우측 패널 카드의 안쪽 여백. 네 방향 모두 같은 값을 쓴다.
/// 한쪽만 넓으면 카드가 비뚤어 보인다.
enum CardMetrics {
    /// 카드 경계에서 내용까지. 호버 영역이 없는 카드가 쓴다.
    static let inset: CGFloat = 8
    /// 카드 경계에서 **호버 영역**까지.
    /// 하이라이트가 테두리에 닿지 않도록 남기는 틈이다.
    static let borderGap: CGFloat = 3
    /// 호버 영역에서 내용까지.
    ///
    /// `borderGap + regionInset == inset` 이라, 호버 영역을 끼워도
    /// 내용이 놓이는 자리는 그대로다.
    static let regionInset: CGFloat = 5
}

struct PanelCard<Content: View>: View {
    var tint: Color = .clear
    /// 안쪽 여백. 호버 영역을 품는 카드는 `CardMetrics.borderGap` 을 넘긴다.
    var inset: CGFloat = CardMetrics.inset
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(baseColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            }
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
    /// 한 번 클릭 — 고르기.
    let onSelect: () -> Void
    /// 두 번 클릭 — 고치기.
    var onOpen: (() -> Void)?
    /// 고른 것과 연결돼 함께 선명해지는 중인지.
    var isHighlighted = false
    var isSelected = false
    /// 네 방향 여백. 영역끼리 맞닿게 하려면 사이 간격을 이 값으로 흡수시킨다.
    /// **이 값이 곧 호버·클릭 영역의 크기다.**
    var inset: CGFloat = CardMetrics.regionInset
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.55),
                                      lineWidth: isSelected ? 1.5 : 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovering = $0 }
            // 두 번 클릭을 먼저 선언해야 한 번 클릭과 구분된다.
            .onTapGesture(count: 2) { (onOpen ?? onSelect)() }
            .onTapGesture(perform: onSelect)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }

    private var fill: Color {
        if isHighlighted { return Color.accentColor.opacity(isSelected ? 0.16 : 0.10) }
        return Color.primary.opacity(isHovering ? 0.06 : 0)
    }
}

/// 계층 제목./// 계층 제목.
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
///
/// **항상 같은 높이의 한 줄이다.** 목록을 늘어놓으면 항목을 완료하거나 날짜를 옮길 때마다
/// 블록 높이가 변해 아래 「일정」·「할 일」 섹션이 통째로 밀린다.
/// 어떤 할 일인지는 아래 「할 일」 섹션에 이미 있으므로 여기서는 **개수만** 알린다.
///
/// 오늘 날짜 기준이다. 고른 날짜와 무관하게 늘 오늘을 말한다.
struct TodayStartSection: View {
    let tasks: [ResolvedTask]
    let now: Date

    /// 세 경우 모두 같은 높이여야 아래가 흔들리지 않는다.
    private static let lineHeight: CGFloat = 22

    private var calendar: Calendar { .current }

    /// 오늘 시작해야 하는 일. 완료한 것도 「원래 있었는지」를 세기 위해 포함한다.
    private var todaysTasks: [ResolvedTask] {
        tasks.filter { resolved in
            guard let startDeadline = resolved.startDeadline else { return false }
            if calendar.isDate(startDeadline, inSameDayAs: now) { return true }
            // 시작 시점을 놓친 채 아직 손대지 않은 것도 오늘 몫이다.
            return resolved.task.status == .notStarted && startDeadline < now
        }
    }

    private var remainingCount: Int {
        todaysTasks.filter { $0.task.status != .done }.count
    }

    private enum State {
        case remaining(Int)
        case allDone
        case none
    }

    private var state: State {
        if remainingCount > 0 { return .remaining(remainingCount) }
        // 원래 있었는데 전부 체크한 경우에만 마쳤다고 말한다.
        return todaysTasks.isEmpty ? .none : .allDone
    }

    var body: some View {
        PanelCard(tint: tint.opacity(0.10), inset: CardMetrics.borderGap) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.bold())
                Text(message)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            // 아이콘과 글자를 세로 가운데에 두고 위아래 여백을 같게 한다.
            .frame(height: Self.lineHeight)
            .padding(.horizontal, CardMetrics.regionInset)
            .padding(.vertical, CardMetrics.regionInset)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.15), value: remainingCount)
    }

    private var message: String {
        switch state {
        case .remaining(let count): return "오늘 시작할 일이 \(count)개 남았어요"
        case .allDone: return "오늘 할 일을 다 마쳤어요. 수고했어요"
        case .none: return "오늘 시작할 일이 없어요"
        }
    }

    private var symbol: String {
        switch state {
        case .remaining: return "exclamationmark.triangle.fill"
        case .allDone: return "checkmark.circle.fill"
        case .none: return "calendar"
        }
    }

    private var tint: Color {
        switch state {
        case .remaining: return .orange
        case .allDone: return .green
        case .none: return .secondary
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
        HStack(alignment: .top, spacing: 7) {
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

            VStack(alignment: .leading, spacing: 2) {
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
        .padding(.vertical, 2)
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
