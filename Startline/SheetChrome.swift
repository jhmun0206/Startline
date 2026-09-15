//
//  SheetChrome.swift
//  Startline
//
//  시트 공통 부품 — 머리글, 입력 영역 배경, 캘린더 고르기.
//
//  라벨과 입력 칸을 나란히 두지 않는다. 시선이 두 번 움직이고 폭도 낭비된다.
//  입력 칸 자체가 무엇을 넣는 곳인지 말하게 하고, 은은한 배경으로 영역을 표시한다.
//  (참조: Apple 캘린더 새 이벤트 팝오버)
//

import EventKit
import SwiftUI

// MARK: - 시트 골격

enum SheetMetrics {
    /// 시트 고정 폭. 안쪽은 이 폭 안에서만 배치한다.
    static let width: CGFloat = 420
    /// 세로가 이보다 길어지면 스크롤로 넘긴다.
    static let maxContentHeight: CGFloat = 520
    static let padding: CGFloat = 20
    static let corner: CGFloat = 8
}

/// 제목 + 우측 상단 닫기 버튼.
///
/// 하단의 「그만두기」 버튼을 대신한다. Esc 로도 닫힌다.
/// 쓰던 내용이 있으면 `hasUnsavedInput` 을 켜서 한 번 되묻는다.
struct SheetHeader: View {
    let title: String
    var hasUnsavedInput = false
    /// 같은 시트 안에서 다른 폼으로 들어왔을 때 되돌아갈 곳의 이름.
    /// 값이 있으면 제목 앞에 「← 이름」 버튼이 붙는다.
    var backTitle: String?
    var onBack: (() -> Void)?
    let onClose: () -> Void

    @State private var isConfirmingClose = false

    var body: some View {
        // 되돌아가기 링크와 제목은 **글자끼리** 밑선을 맞추고, X 버튼은 그 덩어리의
        // **가운데**에 맞춘다. 제목이 커진 뒤 baseline 으로 함께 묶으면 이미지인 X 가
        // 제목 밑선까지 내려가 어긋난다.
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let backTitle, let onBack {
                    Button(action: onBack) {
                        Label(backTitle, systemImage: "chevron.left")
                            .font(.subheadline)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.link)
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                // 시트의 머리글이다. 본문 입력란(.title3)보다 작으면 머리글로 읽히지 않는다.
                // 크기는 입력란과 같게 두고 굵기로 구분한다. .bold 는 과하다.
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            CloseButton {
                if hasUnsavedInput {
                    isConfirmingClose = true
                } else {
                    onClose()
                }
            }
        }
        .padding(.horizontal, SheetMetrics.padding)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .alert("쓰던 내용을 버릴까요?", isPresented: $isConfirmingClose) {
            Button("버리고 닫기", role: .destructive, action: onClose)
            Button("계속 쓰기", role: .cancel) {}
        } message: {
            Text("저장하지 않은 내용은 사라져요.")
        }
    }
}

/// 원형 배경을 두른 닫기 버튼.
///
/// 아이콘만 두면 배경과 구분되지 않아 누를 수 있는 것으로 보이지 않는다.
/// 시스템 창의 닫기 버튼처럼 원형 바탕을 깔고, 올렸을 때와 눌렀을 때 색이 짙어진다.
private struct CloseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
        }
        .buttonStyle(CloseButtonStyle(isHovering: isHovering))
        .keyboardShortcut(.cancelAction)
        .onHover { isHovering = $0 }
        .help("닫기")
    }
}

private struct CloseButtonStyle: ButtonStyle {
    let isHovering: Bool

    /// 아이콘보다 넉넉하게. 작은 표적은 겨냥하기 어렵다.
    private static let hitSize: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground(isPressed: configuration.isPressed))
            .frame(width: Self.hitSize, height: Self.hitSize)
            .background(Circle().fill(background(isPressed: configuration.isPressed)))
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed { return .secondary.opacity(0.34) }
        if isHovering { return .secondary.opacity(0.22) }
        return .secondary.opacity(0.13)
    }

    private func foreground(isPressed: Bool) -> Color {
        isPressed || isHovering ? .primary : .secondary
    }
}

/// 입력 가능한 영역을 나타내는 은은한 회색 배경.
struct SheetField<Content: View>: View {
    var verticalPadding: CGFloat = 7
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SheetMetrics.corner)
                    .fill(Color.secondary.opacity(0.10))
            )
    }
}

/// 라벨 없이 쓰는 텍스트 입력. 플레이스홀더가 곧 설명이다.
struct SheetTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .body

    var body: some View {
        SheetField {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
        }
    }
}

// MARK: - 캘린더 고르기

/// 캘린더 이름 왼쪽에 그 캘린더의 색상 점. (Apple 캘린더와 같은 방식)
struct CalendarLabel: View {
    let calendar: EKCalendar?
    var showsSource = true

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(calendar.map { Color(cgColor: $0.cgColor) } ?? Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)

            Text(calendar?.title ?? "캘린더 선택")
                .lineLimit(1)

            if showsSource, let source = calendar?.source.title {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 캘린더를 고르는 드롭다운.
///
/// `Menu` 를 쓰지 않는다. macOS 는 메뉴 항목의 SF Symbol 을 템플릿으로 다시 칠해
/// 색상 점이 전부 검게 나온다. 팝오버 안은 보통 SwiftUI 뷰라 `Circle` 색이 그대로 살아 있다.
struct CalendarPickerField: View {
    let calendars: [EKCalendar]
    @Binding var selectedID: String?

    @State private var isShowingList = false

    private var selected: EKCalendar? {
        calendars.first { $0.calendarIdentifier == selectedID }
    }

    var body: some View {
        Button {
            isShowingList.toggle()
        } label: {
            SheetField {
                HStack {
                    CalendarLabel(calendar: selected)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    let isChosen = calendar.calendarIdentifier == selectedID

                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(cgColor: calendar.cgColor))
                            .frame(width: 9, height: 9)
                        Text(calendar.title)
                            .foregroundStyle(isChosen ? .white : .primary)
                            .lineLimit(1)
                        Text(calendar.source.title)
                            .font(.caption)
                            .foregroundStyle(isChosen ? Color.white.opacity(0.8) : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if isChosen {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isChosen ? Color.accentColor : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedID = calendar.calendarIdentifier
                        isShowingList = false
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 280)
        .frame(maxHeight: 260)
    }
}

// MARK: - 칩

/// 시트 안에서 값 하나를 고르는 작은 칩.
///
/// 소요시간 칩이 쓰던 모양 그대로다. 「며칠 전까지」도 같은 모양을 쓰게 하려고 꺼냈다.
/// 한 시트 안에서 같은 일을 하는 것이 다르게 생기면 안 된다.
struct SheetChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// 부모 일정 기준 **「며칠 전까지」**를 고르는 칩 한 줄.
///
/// **「일정 추가」의 초안 행과 「할 일」 시트가 같은 이 부품을 쓴다.**
/// 한쪽만 바꾸면 추가와 수정이 어긋난다.
///
/// 예전에는 위아래 화살표(스테퍼)였다. 처음 보는 사람은 그것이 무엇인지 알 수 없고,
/// 값을 바꾸려면 여러 번 눌러야 하며, 고를 수 있는 범위가 보이지 않았다.
///
/// **날짜 피커로 바꾸지 말 것.** 딸린 할 일의 마감은 부모 일정 기준 **상대값**으로
/// 저장된다. (명세서 4.2) 부모가 옮겨지면 할 일도 따라가야 하기 때문이다.
/// 절대 날짜를 보여주면 그 의미가 사라지고, 부모를 옮겨도 안 따라올 것으로 오해한다.
struct DaysBeforeChips: View {
    let label: String
    @Binding var daysBefore: Int
    /// 「직접」을 펼쳤는지. 칩에 없는 값을 불러왔을 때도 켜진다.
    @Binding var isEnteringCustom: Bool

    /// 칩으로 내놓는 값들. 여기 없는 값은 「직접」이 받는다.
    static let presets: [Int] = [0, 1, 3, 7]

    static func label(for days: Int) -> String {
        switch days {
        case 0: return "당일"
        case 7: return "1주 전"
        default: return "\(days)일 전"
        }
    }

    /// 불러온 값이 칩에 없으면 「직접」을 켜 둔다. **값을 가까운 칩으로 바꾸지 않는다.** (원칙 1)
    static func needsCustom(for days: Int) -> Bool {
        !presets.contains(days)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(Self.presets, id: \.self) { preset in
                SheetChip(
                    label: Self.label(for: preset),
                    isOn: !isEnteringCustom && daysBefore == preset
                ) {
                    isEnteringCustom = false
                    daysBefore = preset
                }
            }

            SheetChip(label: "직접", isOn: isEnteringCustom) {
                // 소요시간의 「직접」과 같다 — 눌러서 펼치고 다시 눌러서 접는다.
                // 다만 값을 비우지는 않는다. 불러온 값을 보존해야 하기 때문이다.
                isEnteringCustom.toggle()
            }

            if isEnteringCustom {
                TextField("0", value: $daysBefore, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 30)
                    .multilineTextAlignment(.trailing)
                Text("일 전까지").font(.caption2).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }
}
