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

            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
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
