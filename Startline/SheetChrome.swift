//
//  SheetChrome.swift
//  Startline
//
//  시트 공통 부품 — 머리글(닫기 버튼)과 캘린더 고르기.
//

import EventKit
import SwiftUI

// MARK: - 시트 머리글

/// 제목 + 우측 상단 닫기 버튼.
///
/// 하단의 「그만두기」 버튼을 대신한다. Esc 로도 닫힌다.
/// 쓰던 내용이 있으면 `hasUnsavedInput` 을 켜서 한 번 되묻는다.
struct SheetHeader: View {
    let title: String
    var hasUnsavedInput = false
    let onClose: () -> Void

    @State private var isConfirmingClose = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                if hasUnsavedInput {
                    isConfirmingClose = true
                } else {
                    onClose()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("닫기")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .alert("쓰던 내용을 버릴까요?", isPresented: $isConfirmingClose) {
            Button("버리고 닫기", role: .destructive, action: onClose)
            Button("계속 쓰기", role: .cancel) {}
        } message: {
            Text("저장하지 않은 내용은 사라져요.")
        }
    }
}

// MARK: - 캘린더 고르기

/// 캘린더 이름 왼쪽에 그 캘린더의 색상 점을 보여준다. (Apple 캘린더와 같은 방식)
struct CalendarLabel: View {
    let calendar: EKCalendar?
    var showsSource = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(calendar.map { Color(cgColor: $0.cgColor) } ?? Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)

            Text(calendar?.title ?? "캘린더 선택")

            if showsSource, let source = calendar?.source.title {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 캘린더를 고르는 드롭다운.
///
/// `Picker` 대신 `Menu` 를 쓴다. 접혀 있을 때의 표시가 곧 이 뷰의 라벨이라
/// 색상 점이 확실히 남는다. `Picker` 는 접힌 상태를 시스템이 다시 그려 점이 사라진다.
struct CalendarPickerField: View {
    let calendars: [EKCalendar]
    @Binding var selectedID: String?

    private var selected: EKCalendar? {
        calendars.first { $0.calendarIdentifier == selectedID }
    }

    var body: some View {
        Menu {
            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                Button {
                    selectedID = calendar.calendarIdentifier
                } label: {
                    // 메뉴 항목에서는 SF Symbol 이 색을 지킨다.
                    Label {
                        Text("\(calendar.title) · \(calendar.source.title)")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color(cgColor: calendar.cgColor))
                    }
                }
            }
        } label: {
            CalendarLabel(calendar: selected)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
