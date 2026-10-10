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


    private var state: TodayBanner {
        TodayBanner.state(tasks: tasks, now: now, calendar: calendar)
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
        .animation(.easeOut(duration: 0.15), value: state)
    }

    private var message: String { state.message }

    private var symbol: String {
        switch state {
        case .remaining: return "exclamationmark.triangle.fill"
        case .missed: return "exclamationmark.circle.fill"
        case .allDone: return "checkmark.circle.fill"
        case .none: return "calendar"
        }
    }

    private var tint: Color {
        switch state {
        case .remaining: return .orange
        // 「늦음」 배지와 같은 계열. 기한이 지난 일이라는 뜻이 같다.
        case .missed: return .red
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
    /// 「30분 미뤄짐」 줄이 언제 사라질지 가르는 기준 시각. 패널의 1분 시계를 받는다.
    var now: Date = Date()
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var task: ManagedTask { resolved.task }

    /// 미뤄서 다시 울릴 시각. 지났거나 완료했으면 `nil` — 줄이 사라진다. (BL-072)
    private var pendingSnooze: Date? {
        guard !task.isCompleted, let until = task.snoozedUntil, until > now else { return nil }
        return until
    }

    private static let snoozeTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .startlineDisplay
        f.dateFormat = "a h:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if isNested {
                Spacer().frame(width: 14)
            }

            Button {
                toggleDone()
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(showsParentContext ? resolved.contextualTitle : task.title)
                        .font(.body)
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if let judgment = resolved.judgment {
                        JudgmentBadge(judgment: judgment)
                    }
                }

                detailText
                    .font(.caption)

                // 미룬 걸 화면에서 알 수 있어야 한다. 알림에서만 보이면 잊는다.
                // 회색 줄과 같은 모양이면 묻히므로 배경을 깐 작은 칩으로 둔다.
                // 색은 중립 — 「늦음」(빨강)·「오늘 시작」(주황) 배지와 헷갈리지 않게.
                if let pendingSnooze {
                    SnoozeChip(text: "30분 미뤄짐 · \(Self.snoozeTimeFormatter.string(from: pendingSnooze))에 다시 알림")
                }
            }
            // 체크박스는 제외하고 본문만 눌러야 수정 시트가 열린다.
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
        }
        .padding(.vertical, 2)
        .contextMenu {
            // 할 일은 완료 / 미완료 둘뿐이다. (BL-066)
            // 예전의 「지금 시작」(진행 중으로 바꾸기)·「미시작으로 되돌리기」를 이것 하나로 바꿨다.
            Button(task.isCompleted ? "미완료로 되돌리기" : "완료", action: toggleDone)
            Button("편집", action: onEdit)
            Divider()
            Button("삭제", role: .destructive, action: onDelete)
        }
    }

    private func toggleDone() {
        saver.perform(modelContext) {
            if task.isCompleted {
                task.markNotStarted()
            } else {
                task.markDone()
            }
        }
    }

    /// 언제 시작해야 하는지와 얼마나 걸리는지.
    /// 남은 시간을 숫자로 환산해 보여주지 않는다. (명세서 5.4)
    /// 마감과 알림 시각만 말한다. 상태어(「오늘 시작」·「늦음」)는 배지가 맡는다. (TaskTimeText)
    private var timeLine: TaskTimeText.Line {
        TaskTimeText.line(
            effectiveDueAt: resolved.effectiveDueAt,
            alarmAt: resolved.startDeadline,
            isMissed: resolved.isMissed(now: now),
            isCompleted: task.isCompleted,
            now: now
        )
    }

    /// 한 줄 안에서 **마감은 한 단계 진하게, 알림은 한 단계 연하게.** 아이콘 없이 굵기·색으로만 가른다.
    ///
    /// `.secondary` 와 `.tertiary` 는 시스템 계층색이라 다크 모드에서도 두 단계 차이가 유지된다.
    private var detailText: Text {
        let line = timeLine
        let due = Text(line.due).foregroundStyle(.secondary).fontWeight(.medium)
        guard let alarm = line.alarm else { return due }
        return due
            + Text(" · ").foregroundStyle(.tertiary)
            + Text(alarm).foregroundStyle(.tertiary)
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

/// 「30분 미뤄짐 · 오후 3:10에 다시 알림」 — 배경을 깐 작은 칩.
///
/// 노션의 인라인 코드처럼 옅은 배경 위에 둔다. 판정 배지(캡슐, 색 있음)와 모양·색을 다르게 해
/// 상태가 아니라 **예약 정보**라는 것이 드러나게 한다.
struct SnoozeChip: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.07))
            )
            .fixedSize()
            .padding(.top, 2)
    }
}
