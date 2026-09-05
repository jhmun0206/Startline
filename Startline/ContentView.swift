//
//  ContentView.swift
//  Startline
//
//  Created by 문정환 on 9/5/26.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var manager = CalendarManager()

    var body: some View {
        Group {
            switch manager.accessState {
            case .notDetermined:
                AccessRequestView(manager: manager)
            case .denied:
                AccessDeniedView()
            case .authorized:
                // 명세서 4.2 — 좌: 월간 그리드 / 우: 선택 날짜 상세
                HSplitView {
                    MonthGridView(manager: manager)
                        .frame(minWidth: 480, idealWidth: 700)
                    DayDetailView(manager: manager)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 460)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
    }
}

// MARK: - 권한 미결정

/// 시스템 권한 팝업 이전에 이유를 먼저 설명하는 사전 안내 화면. (명세서 3.1)
private struct AccessRequestView: View {
    let manager: CalendarManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("캘린더 접근이 필요합니다")
                .font(.title2.bold())

            Text("등록된 일정을 읽어 무엇을 언제 시작해야 하는지 알려드려요.\n일정을 고치거나 밖으로 보내지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("캘린더 접근 요청") {
                Task { await manager.requestAccess() }
            }
            .keyboardShortcut(.defaultAction)

            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 권한 거부

private struct AccessDeniedView: View {
    @Environment(\.openURL) private var openURL

    private let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("캘린더 접근이 거부되어 있습니다")
                .font(.title2.bold())

            Text("시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서\nStartline을 허용한 뒤 앱을 다시 실행해 주세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let settingsURL {
                Button("시스템 설정 열기") { openURL(settingsURL) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: ManagedTask.self, inMemory: true)
}
